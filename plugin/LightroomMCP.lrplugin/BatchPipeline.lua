local LrApplication = import 'LrApplication'
local LrApplicationView = import 'LrApplicationView'
local LrDevelopController = import 'LrDevelopController'
local LrFunctionContext = import 'LrFunctionContext'
local LrTasks = import 'LrTasks'

local AiState = require 'AiState'
local BatchJobStore = require 'BatchJobStore'
local LandscapePreset = require 'LandscapePreset'
local Log = require 'Log'
local PhotoLookup = require 'PhotoLookup'
local PipelineCollections = require 'PipelineCollections'
local PipelineConfig = require 'PipelineConfig'
local PipelineState = require 'PipelineState'
local SubjectPreset = require 'SubjectPreset'

local BatchPipeline = {}

if not _G.LightroomAIBatchRuntime then
    _G.LightroomAIBatchRuntime = {
        queue = {},
        workerRunning = false,
    }
end
local runtime = _G.LightroomAIBatchRuntime

local STAGE_METADATA = {
    DENOISE = "denoiseStatus",
    AUTO_TONE = "autoToneStatus",
    SUBJECT_PRESET = "subjectStatus",
    LANDSCAPE = "landscapeStatus",
}

local PROFILES = {
    configured = true,
    ["denoise-only"] = true,
    full = true,
}

local function clone(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, child in pairs(value) do out[key] = clone(child) end
    return out
end

local function getVersionTable()
    local ok, value = pcall(function() return LrApplication.versionTable() end)
    if ok and type(value) == "table" then return value end
    return { major = 0, minor = 0, revision = 0 }
end

local function versionWarning()
    local version = getVersionTable()
    local major = tonumber(version.major) or 0
    local minor = tonumber(version.minor) or 0
    if major < 15 or (major == 15 and minor <= 3) then
        return string.format(
            "Lightroom Classic %d.%d detected. Denoise has a known <=15.3 model-mismatch risk; "
            .. "Landscape subcategories will be attempted experimentally and skipped on rejection.",
            major, minor)
    end
    return nil
end

local function photoId(photo)
    return photo.localIdentifier
end

local function filename(photo)
    return photo:getFormattedMetadata("fileName") or tostring(photoId(photo))
end

local function getProperty(catalog, photo, field)
    local persistent = PipelineState.get(catalog, photo)
    if persistent and persistent[field] ~= nil then return persistent[field] end
    local ok, value = pcall(function() return photo:getPropertyForPlugin(_PLUGIN, field) end)
    if ok then return value end
    return nil
end

local function writeProperties(catalog, photo, values)
    local saved, saveErr = PipelineState.update(catalog, photo, values)
    if not saved then error("Pipeline state persist failed: " .. tostring(saveErr)) end

    local ok, privateErr = LrTasks.pcall(function()
        catalog:withPrivateWriteAccessDo(function()
            for field, value in pairs(values) do
                photo:setPropertyForPlugin(_PLUGIN, field, value)
            end
        end, { timeout = 30 })
    end)
    if not ok then
        Log.warn("Private metadata mirror failed for Photo ID " .. tostring(photoId(photo))
            .. ": " .. tostring(privateErr))
    end
end

local function setStageMetadata(catalog, photo, config, jobId, stage, status)
    local field = STAGE_METADATA[stage]
    local values = {
        pipelineVersion = config.pipelineVersion,
        jobId = jobId,
    }
    if field then values[field] = status end
    writeProperties(catalog, photo, values)
end

local function alreadyComplete(catalog, photo, config, stage)
    if config.force then return false end
    if getProperty(catalog, photo, "pipelineVersion") ~= config.pipelineVersion then return false end
    local field = STAGE_METADATA[stage]
    return field and getProperty(catalog, photo, field) == "COMPLETE" or false
end

local function freezePhotos(args, catalog, selectedPhotos)
    local candidates = {}
    if type(args.photo_ids) == "table" and args.photo_ids[1] ~= nil then
        for _, entry in ipairs(PhotoLookup.resolveMany(catalog, args.photo_ids)) do
            if entry.photo then table.insert(candidates, entry.photo) end
        end
    else
        candidates = selectedPhotos or catalog:getTargetPhotos() or {}
    end

    local photos = {}
    local items = {}
    local seen = {}
    for _, photo in ipairs(candidates) do
        local id = tostring(photoId(photo))
        if not seen[id] then
            seen[id] = true
            table.insert(photos, photo)
            table.insert(items, {
                photoId = photoId(photo),
                filename = filename(photo),
                status = "QUEUED",
                steps = {},
            })
        end
    end
    return photos, items
end

local function photoIds(photos)
    local ids = {}
    for _, photo in ipairs(photos or {}) do table.insert(ids, photoId(photo)) end
    return ids
end

local function applyProfile(config, profile)
    if profile == "denoise-only" then
        config.denoise.enabled = true
        config.autoTone.enabled = false
        config.subjectPreset.enabled = false
        config.landscape.enabled = false
    elseif profile == "full" then
        config.denoise.enabled = true
        config.autoTone.enabled = true
        config.subjectPreset.enabled = true
        config.landscape.enabled = true
    end
    config.profile = profile
    return config
end

local function selectPhoto(catalog, photo, config, job)
    catalog:setSelectedPhotos(photo, { photo })
    local deadline = os.time() + 15
    while os.time() <= deadline do
        if job.cancelRequested then return false, "cancelled" end
        local active = catalog:getTargetPhoto()
        if active == photo then return true end
        LrTasks.sleep(config.pollIntervalSeconds)
    end
    return false, "Lightroom did not make the frozen Photo ID active"
end

local function stageOptions(config, job, timeoutSeconds)
    return {
        timeoutSeconds = timeoutSeconds,
        pollIntervalSeconds = config.pollIntervalSeconds,
        isCancelled = function() return job.cancelRequested == true end,
    }
end

local function validationFor(item)
    if not item.denoiseValidation then
        item.denoiseValidation = {
            recoveryAttempted = false,
            recoverySucceeded = false,
        }
    end
    return item.denoiseValidation
end

local function inspectDenoise(photo, config, job)
    local options = stageOptions(config, job, 15)
    options.readyTimeoutSeconds = 15
    local ok, satisfied, panel, detail = LrTasks.pcall(function()
        return AiState.inspectDenoise(photo, config.denoise.amount, options)
    end)
    if not ok then return false, nil, tostring(satisfied) end
    return satisfied == true, panel, detail
end

local function recordDenoiseValidation(item, phase, satisfied, panel, detail)
    local validation = validationFor(item)
    validation[phase] = {
        satisfied = satisfied == true,
        panel = panel,
        detail = detail,
    }
end

local function recoverDenoise(job, catalog, photo, config, item, phase)
    local validation = validationFor(item)
    if validation.recoveryAttempted then
        return false, "Denoise recovery was already attempted for this photo"
    end
    validation.recoveryAttempted = true
    validation.recoveryPhase = phase
    Log.warn("Denoise state was lost after " .. phase .. " for Photo ID "
        .. tostring(photoId(photo)) .. "; attempting one recovery")

    local ok, result, detail = LrTasks.pcall(function()
        return AiState.submitDenoise(photo, config.denoise.amount,
            stageOptions(config, job, config.denoise.timeoutSeconds))
    end)
    if ok and result then
        validation.recoverySucceeded = true
        validation.recoveryPanel = detail
        item.denoise = detail
        local metadataOk, metadataErr = LrTasks.pcall(function()
            setStageMetadata(catalog, photo, config, job.jobId, "DENOISE", "COMPLETE")
        end)
        if not metadataOk then
            Log.error("Recovered Denoise metadata update failed for Photo ID "
                .. tostring(photoId(photo)) .. ": " .. tostring(metadataErr))
        end
        Log.info("Denoise recovery completed for Photo ID " .. tostring(photoId(photo)))
        return true, detail
    end

    local reason = ok and detail or result
    validation.recoverySucceeded = false
    validation.recoveryError = tostring(reason)
    Log.error("Denoise recovery failed for Photo ID " .. tostring(photoId(photo))
        .. ": " .. tostring(reason))
    return false, tostring(reason)
end

local function applyPreset(catalog, photo, preset, plugin)
    catalog:withWriteAccessDo(
        LOC "$$$/LightroomAIBatch/History/ApplyAdaptivePreset=AI Batch Apply Adaptive Preset",
        function()
            if plugin then
                photo:applyDevelopPreset(preset, plugin)
            else
                photo:applyDevelopPreset(preset)
            end
        end, { timeout = 60 })
end

local function runAutoTone(catalog)
    LrDevelopController.setAutoTone()
    catalog:withWriteAccessDo(
        LOC "$$$/LightroomAIBatch/History/FlushAutoTone=AI Batch Flush Auto Tone",
        function() end,
        { timeout = 60 })
end

local function addError(errors, stage, reason)
    table.insert(errors, stage .. ": " .. tostring(reason))
end

local function inspectLandscapeMasks(photo, requestedFeatures)
    local settings = photo:getDevelopSettings()
    local groups = settings.MaskGroupBasedCorrections or {}
    local found = {}
    local foundSet = {}
    for _, group in ipairs(groups) do
        local name = group.CorrectionName
        if type(name) == "string" and name:find("AUTO Landscape - ", 1, true) == 1 then
            table.insert(found, name)
            foundSet[name] = true
        end
    end

    local missing = {}
    for _, feature in ipairs(requestedFeatures) do
        local name = "AUTO Landscape - " .. feature
        if not foundSet[name] then table.insert(missing, name) end
    end
    return {
        separateMaskCount = #found,
        created = found,
        skippedAbsent = missing,
    }
end

local function safeAddToCollection(job, catalog, collections, name, photo)
    local ok, err = LrTasks.pcall(function()
        PipelineCollections.add(catalog, collections, name, photo)
    end)
    if not ok then
        local warning = "Collection " .. name .. " update failed for Photo ID "
            .. tostring(photoId(photo)) .. ": " .. tostring(err)
        table.insert(job.warnings, warning)
        Log.warn(warning)
    end
end

local function markStage(job, index, catalog, photo, config, stage, status, publicStatus, reason)
    BatchJobStore.setPhotoStatus(job, index, publicStatus or status, stage, reason)
    local ok, err = LrTasks.pcall(function()
        setStageMetadata(catalog, photo, config, job.jobId, stage, status)
    end)
    if not ok then
        Log.error("Metadata update failed photo=" .. tostring(photoId(photo)) .. " stage="
            .. stage .. ": " .. tostring(err))
    end
end

local function processPhoto(job, index, photo, shared)
    local config = job.config
    local catalog = shared.catalog
    local item = job.photos[index]
    local errors = {}
    local metadataProcessed = config.profile ~= "denoise-only"
        and getProperty(catalog, photo, "pipelineVersion") == config.pipelineVersion
        and getProperty(catalog, photo, "processed") == "true"

    local selected, selectErr = selectPhoto(catalog, photo, config, job)
    if not selected then
        BatchJobStore.finishPhoto(job, index, "FAILED", selectErr)
        safeAddToCollection(job, catalog, shared.collections, "Failed", photo)
        return
    end

    local initialDenoiseSatisfied = nil
    if config.denoise.enabled then
        local panel, detail
        initialDenoiseSatisfied, panel, detail = inspectDenoise(photo, config, job)
        recordDenoiseValidation(item, "initial", initialDenoiseSatisfied, panel, detail)
    end

    if config.profile ~= "denoise-only" and config.skipProcessed and not config.force
        and metadataProcessed and (not config.denoise.enabled or initialDenoiseSatisfied) then
        BatchJobStore.finishPhoto(job, index, "SKIPPED", "already processed and Denoise state is current")
        safeAddToCollection(job, catalog, shared.collections, "Skipped", photo)
        return
    end

    if metadataProcessed and config.denoise.enabled and not initialDenoiseSatisfied then
        validationFor(item).legacyRepair = true
        Log.warn("Processed metadata had stale Denoise state for Photo ID "
            .. tostring(photoId(photo)) .. "; repairing without reapplying completed presets")
    end

    local startingProperties = {
        pipelineVersion = config.pipelineVersion,
        jobId = job.jobId,
    }
    if config.profile ~= "denoise-only" then startingProperties.processed = "false" end
    writeProperties(catalog, photo, startingProperties)

    if config.denoise.enabled then
        if alreadyComplete(catalog, photo, config, "DENOISE") and initialDenoiseSatisfied then
            BatchJobStore.setPhotoStatus(job, index, "DENOISE_COMPLETE", "DENOISE", "idempotent skip")
        else
            markStage(job, index, catalog, photo, config, "DENOISE", "SUBMITTED", "DENOISE_SUBMITTED")
            local ok, result, detail = LrTasks.pcall(function()
                return AiState.submitDenoise(photo, config.denoise.amount,
                    stageOptions(config, job, config.denoise.timeoutSeconds))
            end)
            if ok and result then
                markStage(job, index, catalog, photo, config, "DENOISE", "COMPLETE", "DENOISE_COMPLETE")
                item.denoise = detail
            else
                local reason = ok and detail or result
                markStage(job, index, catalog, photo, config, "DENOISE", "FAILED", "FAILED", tostring(reason))
                addError(errors, "DENOISE", reason)
            end
        end
    else
        BatchJobStore.setPhotoStatus(job, index, "SKIPPED", "DENOISE", "disabled")
    end

    if job.cancelRequested then
        BatchJobStore.finishPhoto(job, index, "SKIPPED", "job cancelled")
        safeAddToCollection(job, catalog, shared.collections, "Skipped", photo)
        return
    end

    if config.autoTone.enabled then
        if alreadyComplete(catalog, photo, config, "AUTO_TONE") then
            BatchJobStore.setPhotoStatus(job, index, "AUTO_TONE_COMPLETE", "AUTO_TONE", "idempotent skip")
        else
            BatchJobStore.setPhotoStatus(job, index, "AUTO_TONE_RUNNING", "AUTO_TONE", nil)
            local ok, err = LrTasks.pcall(function() runAutoTone(catalog) end)
            if ok then
                markStage(job, index, catalog, photo, config, "AUTO_TONE", "COMPLETE", "AUTO_TONE_COMPLETE")
            else
                markStage(job, index, catalog, photo, config, "AUTO_TONE", "FAILED", "FAILED", tostring(err))
                addError(errors, "AUTO_TONE", err)
            end
        end
    else
        BatchJobStore.setPhotoStatus(job, index, "SKIPPED", "AUTO_TONE", "disabled")
    end

    if config.subjectPreset.enabled then
        if alreadyComplete(catalog, photo, config, "SUBJECT_PRESET") then
            BatchJobStore.setPhotoStatus(job, index, "SUBJECT_PRESET_COMPLETE", "SUBJECT_PRESET", "idempotent skip")
        elseif not shared.subjectPreset then
            markStage(job, index, catalog, photo, config, "SUBJECT_PRESET", "FAILED", "FAILED",
                shared.subjectError)
            addError(errors, "SUBJECT_PRESET", shared.subjectError)
        else
            BatchJobStore.setPhotoStatus(job, index, "SUBJECT_PRESET_RUNNING", "SUBJECT_PRESET", nil)
            local ok, err = LrTasks.pcall(function()
                applyPreset(catalog, photo, shared.subjectPreset, nil)
            end)
            if ok then
                markStage(job, index, catalog, photo, config, "SUBJECT_PRESET", "COMPLETE",
                    "SUBJECT_PRESET_COMPLETE")
            else
                markStage(job, index, catalog, photo, config, "SUBJECT_PRESET", "FAILED", "FAILED", tostring(err))
                addError(errors, "SUBJECT_PRESET", err)
            end
        end
    else
        BatchJobStore.setPhotoStatus(job, index, "SKIPPED", "SUBJECT_PRESET", "disabled")
    end

    local landscapeApplied = false
    if config.landscape.enabled then
        if alreadyComplete(catalog, photo, config, "LANDSCAPE") then
            BatchJobStore.setPhotoStatus(job, index, "LANDSCAPE_COMPLETE", "LANDSCAPE", "idempotent skip")
        elseif not shared.landscapePreset then
            markStage(job, index, catalog, photo, config, "LANDSCAPE", "SKIPPED", "SKIPPED",
                shared.landscapeError)
        else
            BatchJobStore.setPhotoStatus(job, index, "LANDSCAPE_RUNNING", "LANDSCAPE", nil)
            local ok, err = LrTasks.pcall(function()
                applyPreset(catalog, photo, shared.landscapePreset, _PLUGIN)
            end)
            if ok then
                landscapeApplied = true
                markStage(job, index, catalog, photo, config, "LANDSCAPE", "COMPLETE", "LANDSCAPE_COMPLETE")
            else
                markStage(job, index, catalog, photo, config, "LANDSCAPE", "SKIPPED", "SKIPPED", tostring(err))
            end
        end
    else
        BatchJobStore.setPhotoStatus(job, index, "SKIPPED", "LANDSCAPE", "disabled")
    end

    local maskUpdateAllowed = true
    if landscapeApplied and config.denoise.enabled then
        local satisfied, panel, detail = inspectDenoise(photo, config, job)
        recordDenoiseValidation(item, "afterLandscape", satisfied, panel, detail)
        if not satisfied then
            local recovered, recoveryDetail = recoverDenoise(
                job, catalog, photo, config, item, "Landscape preset")
            if recovered then
                local recoveredSatisfied, recoveredPanel, recoveredDetail = inspectDenoise(photo, config, job)
                recordDenoiseValidation(item, "afterLandscapeRecovery",
                    recoveredSatisfied, recoveredPanel, recoveredDetail)
                if not recoveredSatisfied then
                    maskUpdateAllowed = false
                    addError(errors, "DENOISE_RECOVERY",
                        recoveredDetail or "Denoise was still inactive after Landscape recovery")
                end
            else
                maskUpdateAllowed = false
                addError(errors, "DENOISE_RECOVERY", recoveryDetail)
            end
        end
    end

    if job.cancelRequested then
        BatchJobStore.finishPhoto(job, index, "SKIPPED", "job cancelled")
        safeAddToCollection(job, catalog, shared.collections, "Skipped", photo)
        return
    end

    local masksEnabled = config.subjectPreset.enabled or config.landscape.enabled
    local function updateAIMasks()
        BatchJobStore.setPhotoStatus(job, index, "AI_MASK_UPDATE_RUNNING", "AI_MASK_UPDATE", nil)
        local maskTimeout = math.max(config.landscape.timeoutSeconds or 900, 60)
        local ok, result, detail = LrTasks.pcall(function()
            return AiState.updateMasks(catalog, { photo }, stageOptions(config, job, maskTimeout))
        end)
        if not (ok and result) then
            local reason = ok and detail or result
            BatchJobStore.setPhotoStatus(job, index, "FAILED", "AI_MASK_UPDATE", tostring(reason))
            addError(errors, "AI_MASK_UPDATE", reason)
            return false
        elseif landscapeApplied then
            local cleanOk, cleanErr = LrTasks.pcall(function()
                catalog:withWriteAccessDo(
                    LOC "$$$/LightroomAIBatch/History/DeleteEmptyMasks=AI Batch Delete Empty Masks",
                    function()
                        catalog:deleteAllEmptyMasks({ photo })
                    end, { timeout = 60 })
            end)
            if not cleanOk then Log.warn("Delete empty masks failed: " .. tostring(cleanErr)) end
        end
        if ok and result then
            BatchJobStore.setPhotoStatus(job, index, "AI_MASK_UPDATE", "AI_MASK_UPDATE", nil)
            if config.landscape.enabled then
                local inspectOk, summary = LrTasks.pcall(function()
                    return inspectLandscapeMasks(photo, config.landscape.features)
                end)
                if inspectOk then
                    item.landscape = summary
                else
                    local warning = "Landscape mask inspection failed for Photo ID "
                        .. tostring(photoId(photo)) .. ": " .. tostring(summary)
                    table.insert(job.warnings, warning)
                    Log.warn(warning)
                end
            end
        end
        return true
    end

    if masksEnabled and maskUpdateAllowed then
        updateAIMasks()
    elseif masksEnabled then
        BatchJobStore.setPhotoStatus(job, index, "FAILED", "AI_MASK_UPDATE",
            "skipped because Denoise recovery failed")
    end

    if config.denoise.enabled then
        local finalSatisfied, finalPanel, finalDetail = inspectDenoise(photo, config, job)
        recordDenoiseValidation(item, "final", finalSatisfied, finalPanel, finalDetail)
        if not finalSatisfied then
            local validation = validationFor(item)
            if not validation.recoveryAttempted then
                local recovered, recoveryDetail = recoverDenoise(
                    job, catalog, photo, config, item, "final AI state validation")
                if recovered then
                    if masksEnabled then updateAIMasks() end
                    finalSatisfied, finalPanel, finalDetail = inspectDenoise(photo, config, job)
                    recordDenoiseValidation(item, "finalAfterRecovery",
                        finalSatisfied, finalPanel, finalDetail)
                else
                    finalDetail = recoveryDetail
                end
            end
            if not finalSatisfied then
                addError(errors, "DENOISE_FINAL",
                    finalDetail or "Denoise was inactive at the end of the photo pipeline")
            end
        end
    end

    if #errors > 0 then
        local reason = table.concat(errors, " | ")
        if config.profile ~= "denoise-only" then
            writeProperties(catalog, photo, { processed = "false" })
        end
        BatchJobStore.finishPhoto(job, index, "FAILED", reason)
        safeAddToCollection(job, catalog, shared.collections, "Failed", photo)
    else
        if config.profile ~= "denoise-only" then
            writeProperties(catalog, photo, {
                processed = "true",
                processedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
            })
        end
        BatchJobStore.finishPhoto(job, index, "COMPLETE", nil)
        if config.profile ~= "denoise-only" then
            safeAddToCollection(job, catalog, shared.collections, "Processed", photo)
        end
    end
end

local function processJob(entry)
    local job = BatchJobStore.get(entry.jobId)
    if not job then return end
    if job.cancelRequested then
        BatchJobStore.setJobStatus(job, "CANCELLED", "cancelled before start")
        return
    end

    BatchJobStore.setJobStatus(job, "RUNNING")
    local catalog = LrApplication.activeCatalog()
    local resolved = PhotoLookup.resolveMany(catalog, entry.photoIds)
    local photos = {}
    for i, result in ipairs(resolved) do photos[i] = result.photo or false end

    LrTasks.pcall(function() LrApplicationView.switchToModule("develop") end)

    local collections
    local collectionsOk, collectionsResult = LrTasks.pcall(function()
        return PipelineCollections.ensure(catalog, job.config.processedCollection)
    end)
    if collectionsOk then
        collections = collectionsResult
    else
        table.insert(job.warnings, "Collections unavailable: " .. tostring(collectionsResult))
    end

    local subjectPreset, subjectError
    if job.config.subjectPreset.enabled then
        local ok, result, warning = LrTasks.pcall(function()
            return SubjectPreset.resolve(job.config)
        end)
        if ok then
            subjectPreset = result
            subjectError = warning
        else
            subjectError = tostring(result)
        end
    end

    local landscapePreset, landscapeError
    if job.config.landscape.enabled then
        local ok, result = LrTasks.pcall(function()
            return LandscapePreset.ensure(job.config.landscape.features)
        end)
        if ok then
            landscapePreset = result
        else
            landscapeError = "Lightroom rejected the experimental Landscape preset: " .. tostring(result)
            table.insert(job.warnings, landscapeError)
        end
    end

    local shared = {
        catalog = catalog,
        collections = collections,
        subjectPreset = subjectPreset,
        subjectError = subjectError or "Subject preset unavailable",
        landscapePreset = landscapePreset,
        landscapeError = landscapeError or "Landscape preset unavailable",
    }

    for index = 1, #job.photos do
        local photo = photos[index]
        if job.cancelRequested then break end
        if photo then
            local ok, err = LrTasks.pcall(function()
                processPhoto(job, index, photo, shared)
            end)
            if not ok then
                BatchJobStore.finishPhoto(job, index, "FAILED", tostring(err))
                safeAddToCollection(job, catalog, collections, "Failed", photo)
            end
        else
            BatchJobStore.finishPhoto(job, index, "FAILED", "Photo ID no longer resolves")
        end
    end

    if job.cancelRequested then
        for index, item in ipairs(job.photos) do
            if item.status == "QUEUED" then
                BatchJobStore.finishPhoto(job, index, "SKIPPED", "job cancelled")
            end
        end
        BatchJobStore.setJobStatus(job, "CANCELLED", "cancel requested")
    else
        BatchJobStore.setJobStatus(job, "COMPLETE")
    end

end

local function restoreSelection(entry)
    if type(entry.restorePhotoIds) ~= "table" or entry.restorePhotoIds[1] == nil then return end
    local catalog = LrApplication.activeCatalog()
    local resolved = PhotoLookup.resolveMany(catalog, entry.restorePhotoIds)
    local photos = {}
    local active = nil
    for _, result in ipairs(resolved) do
        if result.photo then
            table.insert(photos, result.photo)
            if tostring(photoId(result.photo)) == tostring(entry.restoreActivePhotoId) then
                active = result.photo
            end
        end
    end
    if #photos > 0 then catalog:setSelectedPhotos(active or photos[1], photos) end
end

local function ensureWorker()
    if runtime.workerRunning then return end
    runtime.workerRunning = true
    LrFunctionContext.postAsyncTaskWithContext("LightroomAIBatchWorker", function()
        while #runtime.queue > 0 do
            local entry = table.remove(runtime.queue, 1)
            local ok, err = LrTasks.pcall(function() processJob(entry) end)
            if not ok then
                local job = BatchJobStore.get(entry.jobId)
                if job then BatchJobStore.setJobStatus(job, "FAILED", tostring(err)) end
                Log.error("Batch worker failed: " .. tostring(err))
            end
            local restored, restoreErr = LrTasks.pcall(function() restoreSelection(entry) end)
            if not restored then Log.warn("Original selection restore failed: " .. tostring(restoreErr)) end
        end
        runtime.workerRunning = false
    end)
end

function BatchPipeline.start(args)
    args = args or {}
    local profile = args.profile or "configured"
    if not PROFILES[profile] then error("profile must be configured, denoise-only, or full") end
    local overrides = clone(args.config or {})
    if args.force ~= nil then overrides.force = args.force end
    if args.skipProcessed ~= nil then overrides.skipProcessed = args.skipProcessed end
    local config = applyProfile(PipelineConfig.load(overrides), profile)
    local catalog = LrApplication.activeCatalog()
    local originalPhotos = catalog:getTargetPhotos() or {}
    local originalActive = catalog:getTargetPhoto()
    local photos, items = freezePhotos(args, catalog, originalPhotos)
    if #photos == 0 then error("No selected photos") end

    local warnings = {}
    local warning = versionWarning()
    if warning then table.insert(warnings, warning) end
    local job = BatchJobStore.create(items, config, warnings)
    table.insert(runtime.queue, {
        jobId = job.jobId,
        photoIds = photoIds(photos),
        restorePhotoIds = photoIds(originalPhotos),
        restoreActivePhotoId = originalActive and photoId(originalActive) or nil,
    })
    ensureWorker()

    return {
        jobId = job.jobId,
        photoCount = job.photoCount,
        status = "running",
        profile = profile,
        warnings = warnings,
    }
end

function BatchPipeline.status(args)
    if type(args) ~= "table" or type(args.jobId) ~= "string" or args.jobId == "" then
        error("jobId is required")
    end
    local job = BatchJobStore.get(args.jobId)
    if not job then error("Unknown jobId: " .. args.jobId) end
    job.logDirectory = BatchJobStore.directory()
    job.pipelineStatePath = PipelineState.path()
    return job
end

function BatchPipeline.cancel(args)
    if type(args) ~= "table" or type(args.jobId) ~= "string" or args.jobId == "" then
        error("jobId is required")
    end
    local job, err = BatchJobStore.cancel(args.jobId)
    if not job then error(err) end
    return {
        jobId = job.jobId,
        status = job.status,
        cancelRequested = job.cancelRequested,
    }
end

return BatchPipeline
