local LrDevelopController = import 'LrDevelopController'
local LrTasks = import 'LrTasks'

local Log = require 'Log'

local AiState = {}
local enhanceTaskBusy = false

local function cancelled(options)
    return options and options.isCancelled and options.isCancelled()
end

local function waitFor(predicate, options)
    local timeoutSeconds = options.timeoutSeconds or 900
    local pollInterval = options.pollIntervalSeconds or 0.25
    local deadline = os.time() + timeoutSeconds
    local lastError
    while os.time() <= deadline do
        if cancelled(options) then return false, "cancelled" end
        local ok, value, detail, fatal = LrTasks.pcall(predicate)
        if ok and value then return true, detail end
        if ok and fatal then return false, tostring(fatal) end
        if not ok then lastError = tostring(value) end
        LrTasks.sleep(pollInterval)
    end
    if lastError then return false, "timed out; last state error: " .. lastError end
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
        timeoutSeconds = options.readyTimeoutSeconds or 15,
        pollIntervalSeconds = options.pollIntervalSeconds,
        isCancelled = options.isCancelled,
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
    if enhanceTaskBusy then
        return false, "a previous Lightroom Enhance SDK call is still active"
    end

    local callDone = false
    local callError = nil
    local lastSummary = nil
    enhanceTaskBusy = true
    Log.info("Denoise submit photo=" .. tostring(photo.localIdentifier)
        .. " amount=" .. tostring(amount))
    LrTasks.startAsyncTask(function()
        local ok, err = LrTasks.pcall(function()
            -- Lightroom Classic 15.5.1 accepts this positional SDK form. The
            -- options-table form currently used by the upstream reference was
            -- rejected live with "invalid paramName ... toggleEnhance".
            LrDevelopController.setEnhance("denoise", true, amount)
        end)
        if not ok then callError = tostring(err) end
        callDone = true
        enhanceTaskBusy = false
        if callError then
            Log.error("Denoise SDK call failed photo=" .. tostring(photo.localIdentifier)
                .. " error=" .. callError)
        else
            Log.info("Denoise SDK call returned photo=" .. tostring(photo.localIdentifier))
        end
    end)

    local function desiredState()
        if callError then return false, nil, callError end
        local desired, panel = denoiseState(photo, amount)
        local available = photo:isAvailableForEditing()
        local summary = panelSummary(panel, available)
        if summary ~= lastSummary then
            lastSummary = summary
            Log.info("Denoise state photo=" .. tostring(photo.localIdentifier)
                .. " callDone=" .. tostring(callDone) .. " " .. summary)
        end
        if callDone and not desired and panel and panel.denoiseEnabled == false then
            return false, panel, "Denoise is unavailable for this photo"
        end
        return desired, panel
    end

    return waitFor(desiredState, options)
end

function AiState.updateMasks(catalog, photos, options)
    local callDone = false
    local callError = nil
    LrTasks.startAsyncTask(function()
        local ok, err = LrTasks.pcall(function()
            catalog:withWriteAccessDo(
                LOC "$$$/LightroomAIBatch/History/UpdateAISettings=AI Batch Update AI Settings",
                function()
                    catalog:updateAISettings(photos)
                end, { timeout = options.timeoutSeconds or 900 })
        end)
        if not ok then callError = tostring(err) end
        callDone = true
    end)

    local function complete()
        if callError then error(callError) end
        if not callDone then return false end
        for _, photo in ipairs(photos) do
            if photo:needsUpdateAISettings() then return false end
            if not photo:isAvailableForEditing() then return false end
        end
        return true
    end

    return waitFor(complete, options)
end

function AiState.waitForPhotoAvailable(photo, options)
    return waitFor(function() return photo:isAvailableForEditing() == true end, options)
end

return AiState
