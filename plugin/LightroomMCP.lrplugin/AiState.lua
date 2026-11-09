local LrDevelopController = import 'LrDevelopController'
local LrApplication = import 'LrApplication'
local LrTasks = import 'LrTasks'

local AiOperation = require 'AiOperation'
local Log = require 'Log'

local AiState = {}

local function cancelled(options)
    return options and options.isCancelled and options.isCancelled()
end

local function waitFor(predicate, options)
    local timeoutSeconds = options.timeoutSeconds or 900
    local pollInterval = options.pollIntervalSeconds or 0.25
    local deadline = os.time() + timeoutSeconds
    while os.time() <= deadline do
        if options.onHeartbeat then options.onHeartbeat() end
        if cancelled(options) then return false, "cancelled" end
        local ok, value, detail, fatal = LrTasks.pcall(predicate)
        if ok and value then return true, detail end
        if ok and fatal then return false, tostring(fatal) end
        if not ok then return false, tostring(value) end
        LrTasks.sleep(pollInterval)
    end
    return false, "timed out after " .. tostring(timeoutSeconds) .. " seconds"
end

local function denoiseState(photo, amount)
    local panel = LrDevelopController.getEnhancePanelState()
    local available = photo:isAvailableForEditing()
    local desired = panel
        and panel.denoiseState == true
        and tonumber(panel.denoiseAmount) == tonumber(amount)
        and panel.enhanceNeedsUpdate == false
        and available == true
    return desired, panel
end

local function panelSummary(panel, available)
    if type(panel) ~= "table" then
        return "panel=nil available=" .. tostring(available)
    end
    return table.concat({
        "denoiseState=" .. tostring(panel.denoiseState),
        "denoiseEnabled=" .. tostring(panel.denoiseEnabled),
        "denoiseAmount=" .. tostring(panel.denoiseAmount),
        "enhanceNeedsUpdate=" .. tostring(panel.enhanceNeedsUpdate),
        "available=" .. tostring(available),
    }, " ")
end

local function waitForDenoiseReady(photo, options)
    options = options or {}
    -- catalog:setSelectedPhotos() can report the new target before the Develop
    -- controller has rebound its Enhance panel. On Windows 15.5.1 the interim
    -- panel has denoiseEnabled=false and an immediate setEnhance call is
    -- rejected. Wait for the real controller state to be stable instead of
    -- guessing with a fixed delay.
    local readyStableCount = 0
    local lastReadySummary = nil
    local ready, readyDetail = waitFor(function()
        if LrApplication.activeCatalog():getTargetPhoto() ~= photo then
            return false, nil, "Active photo changed before Denoise inspection"
        end
        local panel = LrDevelopController.getEnhancePanelState()
        local available = photo:isAvailableForEditing()
        local summary = panelSummary(panel, available)
        if summary ~= lastReadySummary then
            lastReadySummary = summary
            Log.info("Denoise readiness photo=" .. tostring(photo.localIdentifier)
                .. " " .. summary)
        end

        if panel and panel.denoiseEnabled == true and available == true then
            readyStableCount = readyStableCount + 1
        else
            readyStableCount = 0
        end
        return readyStableCount >= 3, panel
    end, {
        timeoutSeconds = options.readyTimeoutSeconds or 30,
        pollIntervalSeconds = options.pollIntervalSeconds,
        isCancelled = options.isCancelled,
        onHeartbeat = options.onHeartbeat,
    })
    if not ready then
        return false, readyDetail
    end
    return true, readyDetail
end

-- Reads the Enhance state only after Lightroom's Develop controller has
-- stably rebound to the selected photo. getEnhancePanelState() is controller
-- state rather than a photo-bound API, so callers must select `photo` first.
function AiState.inspectDenoise(photo, amount, options)
    local ready, detail = waitForDenoiseReady(photo, options)
    if not ready then
        return false, nil, "Denoise controls did not become ready: " .. tostring(detail)
    end
    local desired, panel = denoiseState(photo, amount)
    return desired, panel, nil
end

function AiState.submitDenoise(photo, amount, options)
    options = options or {}
    if not AiOperation.isIdle() then return false, "a previous Lightroom SDK call is still active" end
    local ready, readyDetail = waitForDenoiseReady(photo, options)
    if not ready then
        return false, "Denoise controls did not become ready: " .. tostring(readyDetail)
    end

    -- Do not resubmit an already-satisfied Enhance operation. On Lightroom
    -- 15.3 setEnhance can leave its SDK call alive even after the panel state
    -- is complete; a redundant call can then monopolize the next photo.
    local alreadyDone, existingPanel = denoiseState(photo, amount)
    if alreadyDone then
        Log.info("Denoise already satisfied photo=" .. tostring(photo.localIdentifier)
            .. " amount=" .. tostring(amount))
        return true, existingPanel
    end
    local lastSummary = nil
    Log.info("Denoise submit photo=" .. tostring(photo.localIdentifier)
        .. " amount=" .. tostring(amount))
    local function desiredState()
        if LrApplication.activeCatalog():getTargetPhoto() ~= photo then
            return false, nil, "Active photo changed during Denoise"
        end
        local desired, panel = denoiseState(photo, amount)
        local available = photo:isAvailableForEditing()
        local summary = panelSummary(panel, available)
        if summary ~= lastSummary then
            lastSummary = summary
            Log.info("Denoise state photo=" .. tostring(photo.localIdentifier)
                .. " " .. summary)
        end
        if not desired and panel and panel.denoiseEnabled == false then
            return false, panel, "Denoise is unavailable for this photo"
        end
        return desired, panel
    end

    return AiOperation.run("DENOISE", photo.localIdentifier, function()
        if LrApplication.activeCatalog():getTargetPhoto() ~= photo then
            error("Active photo changed before Denoise submission")
        end
        LrDevelopController.setEnhance("denoise", true, amount)
    end, desiredState, options)
end

function AiState.updateMasks(catalog, photos, options)
    options = options or {}
    local function complete()
        for _, photo in ipairs(photos) do
            if photo:needsUpdateAISettings() then return false end
            if not photo:isAvailableForEditing() then return false end
        end
        return true
    end

    return AiOperation.run("AI_MASK_UPDATE", photos[1] and photos[1].localIdentifier,
        function(operation)
            if LrApplication.activeCatalog() ~= catalog or catalog:getTargetPhoto() ~= photos[1] then
                error("Active catalog or photo changed before AI mask update")
            end
            local result = catalog:withWriteAccessDo(
                LOC "$$$/LightroomAIBatch/History/UpdateAISettings=AI Batch Update AI Settings",
                function()
                    if operation.abortRequested then error("cancelled before AI mask update") end
                    Log.info("AI mask write callback entered id=" .. operation.operationId)
                    catalog:updateAISettings(photos)
                    Log.info("AI mask write callback returned id=" .. operation.operationId)
                end, { timeout = options.writeAccessTimeoutSeconds or 30 })
            if result ~= "executed" then error("AI mask write access was not executed: " .. tostring(result)) end
        end, complete, options)
end

function AiState.waitForPhotoAvailable(photo, options)
    return waitFor(function()
        if LrApplication.activeCatalog():getTargetPhoto() ~= photo then
            return false, nil, "Active photo changed while waiting for edit availability"
        end
        return photo:isAvailableForEditing() == true
    end, options)
end

return AiState
