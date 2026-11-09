local LrApplication = import 'LrApplication'
local LrApplicationView = import 'LrApplicationView'
local LrDevelopController = import 'LrDevelopController'
local LrFunctionContext = import 'LrFunctionContext'
local LrTasks = import 'LrTasks'

local AiState = require 'AiState'
local AiOperation = require 'AiOperation'
local BatchJobStore = require 'BatchJobStore'
local LandscapePreset = require 'LandscapePreset'
local Log = require 'Log'
local PhotoLookup = require 'PhotoLookup'
local PipelineCollections = require 'PipelineCollections'
local PipelineConfig = require 'PipelineConfig'
local PipelineState = require 'PipelineState'
local RecipePresets = require 'RecipePresets'
local SubjectPreset = require 'SubjectPreset'

local BatchPipeline = {}

if not _G.LightroomAIBatchRuntime then
    _G.LightroomAIBatchRuntime = {
        queue = {},
        workerRunning = false,
    }
end
local runtime = _G.LightroomAIBatchRuntime
local legacyWorker = runtime.workerRunning and runtime.generation == nil
runtime.generation = runtime.generation or 0

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

local function landscapeSignature(config)
    local features = clone(config.landscape.features)
    table.sort(features)
    return table.concat(features, ",")
end

local function heartbeat(job)
    local now = os.time()
    if now - (job.lastHeartbeatEpoch or 0) < job.config.runtime.heartbeatIntervalSeconds then return end
    job.lastHeartbeatEpoch = now
    job.lastHeartbeatAt = os.date("!%Y-%m-%dT%H:%M:%SZ")
    runtime.lastHeartbeatAt = job.lastHeartbeatAt
    BatchJobStore.persist(job)
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

    if not AiOperation.isIdle() then
        Log.warn("Private metadata deferred while a Lightroom operation is active photo=" .. tostring(photoId(photo)))
        return
    end

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

local function writeExternalState(catalog, photo, values)
    local saved, err = PipelineState.update(catalog, photo, values)
    if not saved then error("Pipeline state persist failed: " .. tostring(err)) end
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
    local deadline = os.time() + config.runtime.readyTimeoutSeconds
    while os.time() <= deadline do
        heartbeat(job)
        if job.cancelRequested then return false, "cancelled" end
        local active = catalog:getTargetPhoto()
        if active == photo then return true end
        LrTasks.sleep(config.pollIntervalSeconds)
    end
    return false, "Lightroom did not make the frozen Photo ID active"
end

local function stageOptions(config, job, timeoutSeconds, index)
    return {
        timeoutSeconds = timeoutSeconds,
        pollIntervalSeconds = config.pollIntervalSeconds,
        readyTimeoutSeconds = config.runtime.readyTimeoutSeconds,
        writeAccessTimeoutSeconds = config.runtime.writeAccessTimeoutSeconds,
        drainTimeoutSeconds = config.runtime.drainTimeoutSeconds,
        heartbeatIntervalSeconds = config.runtime.heartbeatIntervalSeconds,
        jobId = job.jobId,
        onHeartbeat = function() heartbeat(job) end,
        isCancelled = function() return job.cancelRequested == true end,
        onState = function(operation)
            runtime.lastHeartbeatAt = os.date("!%Y-%m-%dT%H:%M:%SZ")
            if index then BatchJobStore.observeOperation(job, index, operation) end
        end,
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
    local options = stageOptions(config, job, config.runtime.readyTimeoutSeconds)
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

local function recoverDenoise(job, catalog, photo, config, item, phase, index)
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
            stageOptions(config, job, config.denoise.timeoutSeconds, index))
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

local function applyPreset(catalog, photo, preset, plugin, operation, timeoutSeconds)
    local result = catalog:withWriteAccessDo(
        LOC "$$$/LightroomAIBatch/History/ApplyAdaptivePreset=AI Batch Apply Adaptive Preset",
        function()
            if operation.abortRequested then error("cancelled before preset application") end
            if plugin then
                photo:applyDevelopPreset(preset, plugin)
            else
                photo:applyDevelopPreset(preset)
            end
        end, { timeout = timeoutSeconds })
    if result ~= "executed" then error("Preset write access was not executed: " .. tostring(result)) end
end

local function runAutoTone(catalog, timeoutSeconds)
    LrDevelopController.setAutoTone()
    local result = catalog:withWriteAccessDo(
        LOC "$$$/LightroomAIBatch/History/FlushAutoTone=AI Batch Flush Auto Tone",
        function() end,
        { timeout = timeoutSeconds })
    if result ~= "executed" then error("Auto Tone flush was not executed: " .. tostring(result)) end
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
    if not AiOperation.isIdle() then
        table.insert(job.warnings, "Collection " .. name .. " deferred: Lightroom SDK operation still active")
        return
    end
    local ok, err = LrTasks.pcall(function()
        PipelineCollections.add(catalog, collections, name, photo, job.config.runtime.writeAccessTimeoutSeconds)
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
    job.currentPhotoId = photoId(photo)
    job.currentFilename = filename(photo)
    runtime.lastHeartbeatAt = os.date("!%Y-%m-%dT%H:%M:%SZ")
    local function failPhoto(reason)
        if config.profile ~= "denoise-only" then
            writeProperties(catalog, photo, { processed = "false" })
        end
        for moduleIndex, module in ipairs(item.modules or {}) do
            if module.status == "QUEUED" then
                BatchJobStore.setModuleStatus(job, index, moduleIndex, "SKIPPED", "photo stopped before preset submission")
            end
        end
        local cancelled = job.cancelRequested and AiOperation.isIdle()
        BatchJobStore.finishPhoto(job, index, cancelled and "SKIPPED" or "FAILED", tostring(reason))
        safeAddToCollection(job, catalog, shared.collections, cancelled and "Skipped" or "Failed", photo)
    end
    local function photoOperation(kind, invoke)
        local ok, detail = AiOperation.run(kind, photoId(photo), function(operation)
            if LrApplication.activeCatalog() ~= catalog or catalog:getTargetPhoto() ~= photo then
                error("Active catalog or photo changed before " .. kind)
            end
            invoke(operation)
        end, function() return true end,
            stageOptions(config, job, config.landscape.timeoutSeconds, index))
        if not ok then error(detail) end
    end
    local metadataProcessed = config.profile ~= "denoise-only"
        and getProperty(catalog, photo, "pipelineVersion") == config.pipelineVersion
        and getProperty(catalog, photo, "processed") == "true"
    local subjectUuid = getProperty(catalog, photo, "subjectPresetUuid")
    local subjectMatches = not config.subjectPreset.enabled or
        (shared.subjectPreset and (subjectUuid == shared.subjectPreset:getUuid()
            or (subjectUuid == nil and RecipePresets.isPop(shared.subjectPreset))))
    local savedLandscape = getProperty(catalog, photo, "landscapeFeatures")
    local landscapeMatches = savedLandscape == landscapeSignature(config) or
        (savedLandscape == nil and landscapeSignature(config) == shared.defaultLandscapeSignature)
    local baseComplete = (not config.autoTone.enabled or alreadyComplete(catalog, photo, config, "AUTO_TONE"))
        and (not config.subjectPreset.enabled or (subjectMatches and alreadyComplete(catalog, photo, config, "SUBJECT_PRESET")))
        and (not config.landscape.enabled or (landscapeMatches and alreadyComplete(catalog, photo, config, "LANDSCAPE")))
    local moduleStates = clone(getProperty(catalog, photo, "presetModules") or {})
    local currentStyle = getProperty(catalog, photo, "stylePresetUuid")
    local pendingModules, recipeHasAI = false, false
    item.modules = {}
    for moduleIndex, entry in ipairs(shared.recipePresets) do
        local state = moduleStates[entry.uuid]
        if not state or state.status ~= "COMPLETE" or
            (entry.kind == "style" and currentStyle ~= entry.uuid) then pendingModules = true end
        if entry.kind ~= "style" then recipeHasAI = true end
        item.modules[moduleIndex] = { uuid = entry.uuid, name = entry.name, kind = entry.kind, status = "QUEUED" }
    end

    local selected, selectErr = selectPhoto(catalog, photo, config, job)
    if not selected then
        BatchJobStore.finishPhoto(job, index, "FAILED", selectErr)
        safeAddToCollection(job, catalog, shared.collections, "Failed", photo)
        return
    end

    local available, availableError = AiState.waitForPhotoAvailable(photo,
        stageOptions(config, job, config.runtime.readyTimeoutSeconds))
    if not available then
        failPhoto("PHOTO_READY: " .. tostring(availableError))
        return
    end

    local initialDenoiseSatisfied = nil
    if config.denoise.enabled then
        local panel, detail
        initialDenoiseSatisfied, panel, detail = inspectDenoise(photo, config, job)
        recordDenoiseValidation(item, "initial", initialDenoiseSatisfied, panel, detail)
        if detail then
            markStage(job, index, catalog, photo, config, "DENOISE", "FAILED", "FAILED", detail)
            failPhoto("DENOISE_READY: " .. tostring(detail))
            return
        end
    end

    local aiCurrent = true
    if config.subjectPreset.enabled or config.landscape.enabled or recipeHasAI then
        local checked, needsUpdate = LrTasks.pcall(function() return photo:needsUpdateAISettings() end)
        if not checked then failPhoto("AI_STATE: " .. tostring(needsUpdate)); return end
        aiCurrent = needsUpdate == false
    end
    if config.profile ~= "denoise-only" and config.skipProcessed and not config.force
        and metadataProcessed and baseComplete and not pendingModules
        and aiCurrent
        and (not config.denoise.enabled or initialDenoiseSatisfied) then
        for moduleIndex in ipairs(item.modules) do
            BatchJobStore.setModuleStatus(job, index, moduleIndex, "SKIPPED", "already applied")
        end
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
                    stageOptions(config, job, config.denoise.timeoutSeconds, index))
            end)
            if ok and result then
                markStage(job, index, catalog, photo, config, "DENOISE", "COMPLETE", "DENOISE_COMPLETE")
                item.denoise = detail
            else
                local reason = ok and detail or result
                markStage(job, index, catalog, photo, config, "DENOISE", "FAILED", "FAILED", tostring(reason))
                addError(errors, "DENOISE", reason)
                failPhoto(table.concat(errors, " | "))
                return
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
            local ok, err = LrTasks.pcall(function()
                photoOperation("AUTO_TONE", function()
                    runAutoTone(catalog, config.runtime.writeAccessTimeoutSeconds)
                    if currentStyle and currentStyle ~= "" then
                        currentStyle = ""
                        writeExternalState(catalog, photo, { stylePresetUuid = "" })
                    end
                end)
            end)
            if ok then
                markStage(job, index, catalog, photo, config, "AUTO_TONE", "COMPLETE", "AUTO_TONE_COMPLETE")
            else
                markStage(job, index, catalog, photo, config, "AUTO_TONE", "FAILED", "FAILED", tostring(err))
                addError(errors, "AUTO_TONE", err)
                if not AiOperation.isIdle() then failPhoto(err); return end
            end
        end
    else
        BatchJobStore.setPhotoStatus(job, index, "SKIPPED", "AUTO_TONE", "disabled")
    end

    if config.subjectPreset.enabled then
        if alreadyComplete(catalog, photo, config, "SUBJECT_PRESET") and subjectMatches then
            BatchJobStore.setPhotoStatus(job, index, "SUBJECT_PRESET_COMPLETE", "SUBJECT_PRESET", "idempotent skip")
        elseif not shared.subjectPreset then
            markStage(job, index, catalog, photo, config, "SUBJECT_PRESET", "FAILED", "FAILED",
                shared.subjectError)
            addError(errors, "SUBJECT_PRESET", shared.subjectError)
        else
            BatchJobStore.setPhotoStatus(job, index, "SUBJECT_PRESET_RUNNING", "SUBJECT_PRESET", nil)
            local ok, err = LrTasks.pcall(function()
                photoOperation("SUBJECT_PRESET", function(operation)
                    applyPreset(catalog, photo, shared.subjectPreset, nil, operation,
                        config.runtime.writeAccessTimeoutSeconds)
                    writeExternalState(catalog, photo, { subjectPresetUuid = shared.subjectPreset:getUuid() })
                end)
            end)
            if ok then
                markStage(job, index, catalog, photo, config, "SUBJECT_PRESET", "COMPLETE",
                    "SUBJECT_PRESET_COMPLETE")
            else
                markStage(job, index, catalog, photo, config, "SUBJECT_PRESET", "FAILED", "FAILED", tostring(err))
                addError(errors, "SUBJECT_PRESET", err)
                if not AiOperation.isIdle() then failPhoto(err); return end
            end
        end
    else
        BatchJobStore.setPhotoStatus(job, index, "SKIPPED", "SUBJECT_PRESET", "disabled")
    end

    local function applyRecipePresets(stylePhase)
        for moduleIndex, entry in ipairs(shared.recipePresets) do
            if (entry.kind == "style") == stylePhase then
                if job.cancelRequested then failPhoto("job cancelled"); return false end
                local previous = moduleStates[entry.uuid]
                if not config.force and previous and (entry.kind ~= "style" or currentStyle == entry.uuid) and
                    (previous.status == "APPLIED" or previous.status == "COMPLETE") then
                    BatchJobStore.setModuleStatus(job, index, moduleIndex, "SKIPPED",
                        previous.status == "APPLIED" and "preset applied; finishing AI calculation" or "already applied")
                else
                    BatchJobStore.setModuleStatus(job, index, moduleIndex, "RUNNING")
                    local ok, err = LrTasks.pcall(function()
                        photoOperation("PRESET:" .. entry.uuid, function(operation)
                            applyPreset(catalog, photo, entry.preset,
                                entry.scope == "plugin" and _PLUGIN or nil, operation,
                                config.runtime.writeAccessTimeoutSeconds)
                            -- This runs in the SDK context, including a late
                            -- return after cancellation, before the gate opens.
                            moduleStates[entry.uuid] = { status = "APPLIED", name = entry.name,
                                kind = entry.kind, appliedAt = os.date("!%Y-%m-%dT%H:%M:%SZ") }
                            local values = { presetModules = moduleStates }
                            if entry.kind == "style" then
                                currentStyle = entry.uuid
                                values.stylePresetUuid = entry.uuid
                            elseif currentStyle and currentStyle ~= "" and RecipePresets.changesGlobal(entry) then
                                -- A newly added overall portrait preset can
                                -- overwrite HSL. Restore the selected style
                                -- after it, without replaying mask-only edits.
                                currentStyle = ""
                                values.stylePresetUuid = ""
                            end
                            writeExternalState(catalog, photo, values)
                        end)
                    end)
                    if not ok then
                        BatchJobStore.setModuleStatus(job, index, moduleIndex, "FAILED", tostring(err))
                        failPhoto("PRESET " .. tostring(entry.name) .. ": " .. tostring(err))
                        return false
                    end
                    BatchJobStore.setModuleStatus(job, index, moduleIndex, "APPLIED")
                end
            end
        end
        return true
    end

    if not applyRecipePresets(false) then return end

    local landscapeApplied = false
    local landscapeCleanupNeeded = false
    if config.landscape.enabled then
        if alreadyComplete(catalog, photo, config, "LANDSCAPE") and landscapeMatches then
            BatchJobStore.setPhotoStatus(job, index, "LANDSCAPE_COMPLETE", "LANDSCAPE", "idempotent skip")
            -- The preset stage can finish before mask calculation/cleanup is
            -- interrupted. Resume its cleanup without reapplying the preset.
            landscapeCleanupNeeded = not metadataProcessed
        elseif not shared.landscapePreset then
            markStage(job, index, catalog, photo, config, "LANDSCAPE", "SKIPPED", "SKIPPED",
                shared.landscapeError)
        else
            BatchJobStore.setPhotoStatus(job, index, "LANDSCAPE_RUNNING", "LANDSCAPE", nil)
            local ok, err = LrTasks.pcall(function()
                photoOperation("LANDSCAPE", function(operation)
                    applyPreset(catalog, photo, shared.landscapePreset, _PLUGIN, operation,
                        config.runtime.writeAccessTimeoutSeconds)
                    writeExternalState(catalog, photo, { landscapeFeatures = landscapeSignature(config) })
                end)
            end)
            if ok then
                landscapeApplied = true
                landscapeCleanupNeeded = true
                markStage(job, index, catalog, photo, config, "LANDSCAPE", "COMPLETE", "LANDSCAPE_COMPLETE")
            else
                markStage(job, index, catalog, photo, config, "LANDSCAPE", "SKIPPED", "SKIPPED", tostring(err))
                if not AiOperation.isIdle() then failPhoto(err); return end
            end
        end
    else
        BatchJobStore.setPhotoStatus(job, index, "SKIPPED", "LANDSCAPE", "disabled")
    end

    if not applyRecipePresets(true) then return end

    local maskUpdateAllowed = true
    if (landscapeApplied or #shared.recipePresets > 0) and config.denoise.enabled then
        local satisfied, panel, detail = inspectDenoise(photo, config, job)
        if landscapeApplied then recordDenoiseValidation(item, "afterLandscape", satisfied, panel, detail) end
        if #shared.recipePresets > 0 then recordDenoiseValidation(item, "afterPresets", satisfied, panel, detail) end
        if not satisfied and detail then
            failPhoto("DENOISE_VALIDATION: " .. tostring(detail))
            return
        elseif not satisfied then
            local recovered, recoveryDetail = recoverDenoise(
                job, catalog, photo, config, item, "Develop presets", index)
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

    if not AiOperation.isIdle() then failPhoto("Denoise recovery did not safely finish"); return end

    if job.cancelRequested then
        BatchJobStore.finishPhoto(job, index, "SKIPPED", "job cancelled")
        safeAddToCollection(job, catalog, shared.collections, "Skipped", photo)
        return
    end

    local masksEnabled = config.subjectPreset.enabled or config.landscape.enabled or recipeHasAI
    local subjectCleanupNeeded = config.subjectPreset.enabled and
        (not metadataProcessed or not subjectMatches or config.force)
    local function updateAIMasks()
        BatchJobStore.setPhotoStatus(job, index, "AI_MASK_UPDATE_RUNNING", "AI_MASK_UPDATE", nil)
        local maskTimeout = config.landscape.timeoutSeconds
        local ok, result, detail = LrTasks.pcall(function()
            return AiState.updateMasks(catalog, { photo }, stageOptions(config, job, maskTimeout, index))
        end)
        if not (ok and result) then
            local reason = ok and detail or result
            BatchJobStore.setPhotoStatus(job, index, "FAILED", "AI_MASK_UPDATE", tostring(reason))
            addError(errors, "AI_MASK_UPDATE", reason)
            return false
        elseif landscapeCleanupNeeded or recipeHasAI or subjectCleanupNeeded then
            local cleanOk, cleanErr = LrTasks.pcall(function()
                photoOperation("EMPTY_MASK_CLEANUP", function(operation)
                    local accessResult = catalog:withWriteAccessDo(
                    LOC "$$$/LightroomAIBatch/History/DeleteEmptyMasks=AI Batch Delete Empty Masks",
                    function()
                        if operation.abortRequested then error("cancelled before empty mask cleanup") end
                        catalog:deleteAllEmptyMasks({ photo })
                    end, { timeout = config.runtime.writeAccessTimeoutSeconds })
                    if accessResult ~= "executed" then error("Empty mask cleanup was not executed") end
                end)
            end)
            if not cleanOk then
                addError(errors, "EMPTY_MASK_CLEANUP", cleanErr)
                return false
            end
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
        if not updateAIMasks() then
            failPhoto(table.concat(errors, " | "))
            return
        end
    elseif masksEnabled then
        BatchJobStore.setPhotoStatus(job, index, "FAILED", "AI_MASK_UPDATE",
            "skipped because Denoise recovery failed")
    end

    if config.denoise.enabled then
        local finalSatisfied, finalPanel, finalDetail = inspectDenoise(photo, config, job)
        recordDenoiseValidation(item, "final", finalSatisfied, finalPanel, finalDetail)
        if not finalSatisfied then
            local validation = validationFor(item)
            if not finalDetail and not validation.recoveryAttempted then
                local recovered, recoveryDetail = recoverDenoise(
                    job, catalog, photo, config, item, "final AI state validation", index)
                if recovered then
                    if masksEnabled and not updateAIMasks() then
                        failPhoto(table.concat(errors, " | "))
                        return
                    end
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

    if not AiOperation.isIdle() then failPhoto("Final recovery did not safely finish"); return end

    if #errors > 0 then
        local reason = table.concat(errors, " | ")
        if config.profile ~= "denoise-only" then
            writeProperties(catalog, photo, { processed = "false" })
        end
        BatchJobStore.finishPhoto(job, index, "FAILED", reason)
        safeAddToCollection(job, catalog, shared.collections, "Failed", photo)
    else
        for moduleIndex, entry in ipairs(shared.recipePresets) do
            local state = moduleStates[entry.uuid]
            if state and state.status == "APPLIED" then
                state.status = "COMPLETE"
                state.validatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ")
                BatchJobStore.setModuleStatus(job, index, moduleIndex, "COMPLETE")
            end
        end
        if #shared.recipePresets > 0 then
            writeExternalState(catalog, photo, { presetModules = moduleStates })
        end
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
    if catalog ~= entry.catalog then error("Active catalog changed before the frozen job started") end
    local resolved = PhotoLookup.resolveMany(catalog, entry.photoIds)
    local photos = {}
    for i, result in ipairs(resolved) do photos[i] = result.photo or false end

    LrTasks.pcall(function() LrApplicationView.switchToModule("develop") end)

    local collections
    local collectionsOk, collectionsResult = LrTasks.pcall(function()
        return PipelineCollections.ensure(catalog, job.config.processedCollection,
            job.config.runtime.writeAccessTimeoutSeconds)
    end)
    if collectionsOk then
        collections = collectionsResult
    else
        table.insert(job.warnings, "Collections unavailable: " .. tostring(collectionsResult))
    end

    local subjectPreset, subjectError = entry.subjectPreset, entry.subjectWarning
    if job.config.subjectPreset.enabled and not subjectPreset then
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
        recipePresets = entry.recipePresets or {},
        defaultLandscapeSignature = landscapeSignature(PipelineConfig.load()),
    }

    for index = 1, #job.photos do
        local photo = photos[index]
        if job.cancelRequested then break end
        if LrApplication.activeCatalog() ~= catalog then error("Active catalog changed during batch") end
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
        if not AiOperation.isIdle() then
            local reason = "Lightroom SDK operation has not returned; remaining photos were not submitted"
            job.restartRequired = true
            for remaining = index + 1, #job.photos do
                BatchJobStore.finishPhoto(job, remaining, "SKIPPED", reason)
            end
            BatchJobStore.setJobStatus(job, "FAILED", reason)
            return
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
    if not AiOperation.isIdle() then
        Log.warn("Selection restore deferred: Lightroom SDK operation still active")
        return
    end
    if type(entry.restorePhotoIds) ~= "table" or entry.restorePhotoIds[1] == nil then return end
    local catalog = LrApplication.activeCatalog()
    if catalog ~= entry.catalog then
        Log.warn("Selection restore skipped because the active catalog changed")
        return
    end
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

local function failUnfinished(job, reason)
    for index, item in ipairs(job.photos) do
        if not item.counted then
            BatchJobStore.finishPhoto(job, index, item.status == "QUEUED" and "SKIPPED" or "FAILED", reason)
        end
    end
    job.restartRequired = not AiOperation.isIdle()
    BatchJobStore.setJobStatus(job, "FAILED", reason)
end

local function reconcileOrphan()
    if not runtime.orphanedJobId then return end
    local id = runtime.orphanedJobId
    local ok, err = LrTasks.pcall(function()
        local job = BatchJobStore.get(id)
        if job and job.status ~= "COMPLETE" and job.status ~= "FAILED" and job.status ~= "CANCELLED" then
            failUnfinished(job, "Batch worker context ended unexpectedly")
        end
    end)
    if ok then runtime.orphanedJobId = nil end
    if not ok then Log.error("Worker interruption record failed: " .. tostring(err)) end
end

local function failQueued(reason)
    while #runtime.queue > 0 do
        local entry = table.remove(runtime.queue, 1)
        local ok, err = LrTasks.pcall(function()
            local job = BatchJobStore.get(entry.jobId)
            if job then failUnfinished(job, reason) end
        end)
        if not ok then Log.error("Queued job finalization failed: " .. tostring(err)) end
    end
end

local ensureWorker
ensureWorker = function()
    if runtime.workerRunning then return end
    reconcileOrphan()
    if not AiOperation.isIdle() then
        failQueued("Previous Lightroom SDK operation has not returned; batch was not started")
        return
    end
    runtime.workerRunning = true
    runtime.generation = runtime.generation + 1
    local generation = runtime.generation
    local scheduled, scheduleError = LrTasks.pcall(function()
        LrFunctionContext.postAsyncTaskWithContext("LightroomAIBatchWorker", function(context)
            context:addCleanupHandler(function()
                if runtime.generation ~= generation then return end
                -- Cleanup handlers must not yield or perform catalog writes.
                if runtime.activeJobId then
                    runtime.orphanedJobId = runtime.activeJobId
                    AiOperation.abandon(runtime.activeJobId)
                end
                runtime.activeJobId = nil
                runtime.workerRunning = false
                Log.info("Batch worker context exited generation=" .. tostring(generation))
            end)
            while #runtime.queue > 0 do
                if not AiOperation.isIdle() then
                    failQueued("Previous Lightroom SDK operation has not returned; batch was not started")
                    break
                end
                local entry = table.remove(runtime.queue, 1)
                runtime.activeJobId = entry.jobId
                runtime.lastHeartbeatAt = os.date("!%Y-%m-%dT%H:%M:%SZ")
                local ok, err = LrTasks.pcall(function() processJob(entry) end)
                if not ok then
                    local recorded, recordError = LrTasks.pcall(function()
                        local job = BatchJobStore.get(entry.jobId)
                        if job then failUnfinished(job, tostring(err)) end
                    end)
                    if not recorded then
                        runtime.orphanedJobId = entry.jobId
                        Log.error("Job finalization failed: " .. tostring(recordError))
                    end
                    Log.error("Batch worker failed: " .. tostring(err))
                end
                local restored, restoreErr = LrTasks.pcall(function() restoreSelection(entry) end)
                if not restored then Log.warn("Original selection restore failed: " .. tostring(restoreErr)) end
                runtime.lastJobId = entry.jobId
                runtime.activeJobId = nil
            end
        end)
    end)
    if not scheduled then
        runtime.workerRunning = false
        failQueued("Batch worker could not start: " .. tostring(scheduleError))
        return
    end
    -- Independently observes context exit; it never assumes a native SDK call
    -- has ended just because the worker heartbeat is old.
    LrFunctionContext.postAsyncTaskWithContext("LightroomAIBatchWorkerMonitor", function()
        while runtime.workerRunning and runtime.generation == generation do LrTasks.sleep(1) end
        if runtime.generation ~= generation then return end
        reconcileOrphan()
        if #runtime.queue > 0 then ensureWorker() end
    end)
end

function BatchPipeline.start(args)
    reconcileOrphan()
    local activeOperation = AiOperation.active()
    if legacyWorker or (activeOperation and (not runtime.workerRunning
        or activeOperation.state == "DRAINING" or activeOperation.restartRequired)) then
        error(LOC "$$$/LightroomAIBatch/Dialog/OperationBlocked=A previous Lightroom operation has not safely ended. No new job was submitted. Check batch status; restart Lightroom if the operation remains active.")
    end
    args = args or {}
    local profile = args.profile or "configured"
    if not PROFILES[profile] then error("profile must be configured, denoise-only, or full") end
    local overrides = clone(args.config or {})
    if args.force ~= nil then overrides.force = args.force end
    if args.skipProcessed ~= nil then overrides.skipProcessed = args.skipProcessed end
    local config = applyProfile(PipelineConfig.load(overrides), profile)
    if args.recipe and profile == "denoise-only" then error("Recipes require configured or full profile") end
    local recipe, recipePresets = RecipePresets.resolve(args.recipe)
    local subjectPreset, subjectWarning
    if config.subjectPreset.enabled then
        subjectPreset, subjectWarning = SubjectPreset.resolve(config)
        if not subjectPreset then
            error(LOC "$$$/LightroomAIBatch/Workbench/PresetGroups=Missing Subject or Portrait options? Enable Adaptive: Subject and Adaptive: Portrait in Lightroom's Presets + > Manage Presets, then reopen the workbench."
                .. "\n" .. tostring(subjectWarning))
        end
    end
    local catalog = LrApplication.activeCatalog()
    local originalPhotos = catalog:getTargetPhotos() or {}
    local originalActive = catalog:getTargetPhoto()
    local photos, items = freezePhotos(args, catalog, originalPhotos)
    if #photos == 0 then error("No selected photos") end

    local warnings = {}
    local warning = versionWarning()
    if warning then table.insert(warnings, warning) end
    local job = BatchJobStore.create(items, config, warnings)
    if recipe then
        job.recipe = recipe
        BatchJobStore.persist(job)
    end
    table.insert(runtime.queue, {
        catalog = catalog,
        jobId = job.jobId,
        photoIds = photoIds(photos),
        restorePhotoIds = photoIds(originalPhotos),
        restoreActivePhotoId = originalActive and photoId(originalActive) or nil,
        recipePresets = recipePresets,
        subjectPreset = subjectPreset,
        subjectWarning = subjectWarning,
    })
    ensureWorker()

    return {
        jobId = job.jobId,
        photoCount = job.photoCount,
        status = job.status,
        profile = profile,
        warnings = warnings,
    }
end

function BatchPipeline.status(args)
    reconcileOrphan()
    if type(args) ~= "table" or type(args.jobId) ~= "string" or args.jobId == "" then
        error("jobId is required")
    end
    local job = BatchJobStore.get(args.jobId)
    if not job then error("Unknown jobId: " .. args.jobId) end
    local result = clone(job)
    result.logDirectory = BatchJobStore.directory()
    result.pipelineStatePath = PipelineState.path()
    result.workerRunning = runtime.workerRunning
    result.activeJobId = runtime.activeJobId
    result.activeOperation = AiOperation.active()
    result.lastOperation = clone(AiOperation.last())
    if result.lastOperation and result.lastOperation.jobId ~= job.jobId then result.lastOperation = nil end
    result.restartRequired = legacyWorker or (result.activeOperation and result.activeOperation.restartRequired) or false
    result.queuePosition = 0
    for position, entry in ipairs(runtime.queue) do
        if entry.jobId == job.jobId then result.queuePosition = position end
    end
    if result.startedEpoch then result.durationSeconds = os.time() - result.startedEpoch end
    return result
end

function BatchPipeline.preferredJobId(fallback)
    reconcileOrphan()
    local operation = AiOperation.active()
    return runtime.activeJobId or (operation and operation.jobId)
        or (runtime.queue[1] and runtime.queue[1].jobId) or fallback or runtime.lastJobId
end

function BatchPipeline.cancel(args)
    if type(args) ~= "table" or type(args.jobId) ~= "string" or args.jobId == "" then
        error("jobId is required")
    end
    local job, err = BatchJobStore.cancel(args.jobId)
    if not job then error(err) end
    for index = #runtime.queue, 1, -1 do
        if runtime.queue[index].jobId == job.jobId then
            table.remove(runtime.queue, index)
            for photoIndex, item in ipairs(job.photos) do
                if not item.counted then BatchJobStore.finishPhoto(job, photoIndex, "SKIPPED", "cancelled before start") end
            end
            BatchJobStore.setJobStatus(job, "CANCELLED", "cancelled before start")
        end
    end
    return {
        jobId = job.jobId,
        status = job.status,
        cancelRequested = job.cancelRequested,
    }
end

return BatchPipeline
