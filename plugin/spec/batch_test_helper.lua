-- Cooperative SDK simulator: time advances only when a spec explicitly polls.
-- It does not claim to reproduce Lightroom's renderer or GPU implementation.
local M = {}
local MODULES = {
    "AiOperation", "AiState", "BatchPipeline", "BatchJobStore", "PipelineConfig",
    "PipelineState", "PipelineCollections", "SubjectPreset", "LandscapePreset",
    "PhotoLookup", "Log", "HandlerBatch", "MenuBatchCommon", "RecipePresets", "HandlerDevelop",
    "Workbench", "WorkbenchState",
}
local GLOBALS = { "import", "LOC", "_PLUGIN", "LightroomAIBatchOperations",
    "LightroomAIBatchRuntime", "LightroomAIBatchMenuState" }

local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copy(v) end
    return out
end

local function merge(target, values)
    for k, v in pairs(values or {}) do
        if type(v) == "table" and type(target[k]) == "table" and v[1] == nil then merge(target[k], v)
        else target[k] = copy(v) end
    end
end

function M.new()
    local savedModules, savedGlobals = {}, {}
    for _, name in ipairs(MODULES) do savedModules[name] = package.loaded[name]; package.loaded[name] = nil end
    for _, name in ipairs(GLOBALS) do savedGlobals[name] = _G[name]; _G[name] = nil end
    local savedTime = os.time
    local sdk = { now = 1000, tasks = {}, photos = {}, selection = {}, jobs = {},
        enhanceCalls = {}, maskCalls = {}, cleanupCalls = {}, collectionCalls = {}, messages = {}, errors = {}, presets = {} }
    os.time = function() return sdk.now end
    function sdk.restore()
        os.time = savedTime
        for _, name in ipairs(MODULES) do package.loaded[name] = savedModules[name] end
        for _, name in ipairs(GLOBALS) do _G[name] = savedGlobals[name] end
    end
    local function cleanup(task)
        for _, handler in ipairs(task.cleanup) do
            local ok, err = pcall(handler)
            if not ok then table.insert(sdk.errors, tostring(err)) end
        end
    end
    function sdk.advance(seconds)
        local target = sdk.now + seconds
        local limit = 0
        while true do
            limit = limit + 1
            if limit > 100000 then error("test scheduler did not quiesce") end
            local ran, nextWake = false, nil
            for _, task in ipairs(sdk.tasks) do
                if not task.dead then
                    if task.wake <= sdk.now then
                        ran = true
                        local ok, delay = coroutine.resume(task.thread)
                        if not ok then table.insert(sdk.errors, tostring(delay)) end
                        if not ok or coroutine.status(task.thread) == "dead" then
                            task.dead = true
                            cleanup(task)
                        else task.wake = sdk.now + (delay or 0) end
                    end
                    if not task.dead then nextWake = math.min(nextWake or task.wake, task.wake) end
                end
            end
            if not ran then
                if nextWake and nextWake <= target then sdk.now = nextWake
                else sdk.now = target; return end
            end
        end
    end
    function sdk.abortTask(name)
        for _, task in ipairs(sdk.tasks) do
            if not task.dead and task.name == name then task.dead = true; cleanup(task); return end
        end
        error("test task not found: " .. name)
    end
    local tasks = { pcall = pcall }
    tasks.sleep = function(seconds)
        local thread, isMain = coroutine.running()
        if thread and not isMain then coroutine.yield(seconds) else sdk.advance(seconds) end
    end
    local context = {}
    context.postAsyncTaskWithContext = function(name, fn)
        if sdk.scheduleError then error(sdk.scheduleError) end
        local task = { name = name, cleanup = {}, wake = sdk.now }
        local ctx = { addCleanupHandler = function(_, handler) table.insert(task.cleanup, handler) end }
        task.thread = coroutine.create(function() fn(ctx) end)
        table.insert(sdk.tasks, task)
    end
    local catalog = {}
    sdk.catalog = catalog
    catalog.getTargetPhoto = function() return sdk.target end
    catalog.getTargetPhotos = function() return sdk.selection end
    catalog.setSelectedPhotos = function(_, photo, selected) sdk.target = photo; sdk.selection = selected end
    catalog.withWriteAccessDo = function(_, name, fn)
        if sdk.writeResult then return sdk.writeResult end
        if sdk.writeHook then sdk.writeHook(name) end
        fn()
        return "executed"
    end
    catalog.withPrivateWriteAccessDo = function(_, fn) fn(); return "executed" end
    catalog.updateAISettings = function(_, photos)
        table.insert(sdk.maskCalls, photos[1].localIdentifier)
        if sdk.maskHook then sdk.maskHook(photos[1]) end
        for _, photo in ipairs(photos) do photo.needsUpdate = false end
    end
    catalog.deleteAllEmptyMasks = function(_, photos)
        table.insert(sdk.cleanupCalls, photos[1].localIdentifier)
    end
    local controller = {}
    controller.getEnhancePanelState = function()
        local photo = sdk.target
        return { denoiseEnabled = photo.panelEnabled ~= false, denoiseState = photo.denoise == true,
            denoiseAmount = photo.amount or 50, enhanceNeedsUpdate = photo.enhanceNeedsUpdate == true }
    end
    controller.setEnhance = function(_, _, amount)
        local photo = sdk.target
        table.insert(sdk.enhanceCalls, photo.localIdentifier)
        if sdk.enhanceHook then sdk.enhanceHook(photo) end
        photo.denoise = true
        photo.amount = amount
    end
    controller.setAutoTone = function() sdk.target.autoCalls = (sdk.target.autoCalls or 0) + 1 end
    _G.import = function(name)
        if sdk.extraImports and sdk.extraImports[name] then return sdk.extraImports[name] end
        local modules = {
            LrTasks = tasks, LrFunctionContext = context, LrDevelopController = controller,
            LrApplication = { activeCatalog = function() return catalog end,
                versionTable = function() return { major = 15, minor = 5, revision = 1 } end },
            LrApplicationView = { switchToModule = function() end },
            LrDialogs = {
                message = function(...) table.insert(sdk.messages, { ... }) end,
                confirm = function(...)
                    table.insert(sdk.messages, { ... })
                    return sdk.confirmResponse or "cancel"
                end,
            },
        }
        if not modules[name] then error("missing test import " .. name) end
        return modules[name]
    end
    _G.LOC = function(text, ...)
        local args = { ... }
        text = text:match("^[^=]*=(.*)$") or text
        local localized = text:gsub("%^n", "\n"):gsub("%^(%d+)", function(n) return tostring(args[tonumber(n)] or "") end)
        return localized
    end
    _G._PLUGIN = { path = "test-plugin" }
    package.loaded.Log = { info = function() end, warn = function() end, error = function() end }
    local config = { pipelineVersion = "1.0.0", denoise = { enabled = true, amount = 50, timeoutSeconds = 5 },
        autoTone = { enabled = true }, subjectPreset = { enabled = true },
        landscape = { enabled = true, features = { "Sky", "Water" }, timeoutSeconds = 5 },
        skipProcessed = true, force = false, processedCollection = "AI Pipeline / Processed",
        pollIntervalSeconds = 0.25, runtime = { readyTimeoutSeconds = 3,
            writeAccessTimeoutSeconds = 2, drainTimeoutSeconds = 2, heartbeatIntervalSeconds = 1 } }
    package.loaded.PipelineConfig = { load = function(overrides) local c = copy(config); merge(c, overrides); return c end }
    package.loaded.PipelineState = {
        get = function(_, photo) return photo.metadata end,
        update = function(_, photo, values) merge(photo.metadata, values); return true end,
        path = function() return "test-state" end,
    }
    package.loaded.PipelineCollections = {
        ensure = function() return {} end,
        add = function(_, _, name, photo) table.insert(sdk.collectionCalls, { name, photo.localIdentifier }) end,
    }
    function sdk.preset(uuid, kind, name)
        local groups = { portrait = "Adaptive - Portrait", subject = "Adaptive - Subject",
            sky = "Adaptive - Sky", style = "Style - Cinematic II" }
        local preset = { getUuid = function() return uuid end,
            getFile = function() return "/settings/Premium/" .. groups[kind] .. "/" .. (name or uuid) .. ".xmp" end,
            getSetting = function() return {} end }
        local entry = { uuid = uuid, name = name or uuid, folder = groups[kind], scope = "lightroom",
            file = preset:getFile(), preset = preset }
        sdk.presets[#sdk.presets + 1] = entry
        return preset
    end
    local pop = sdk.preset("pop", "subject", "Pop")
    package.loaded.SubjectPreset = { resolve = function(settings)
        if settings.subjectPreset.uuid and settings.subjectPreset.uuid ~= "" then
            for _, entry in ipairs(sdk.presets) do if entry.uuid == settings.subjectPreset.uuid then return entry.preset end end
        end
        return pop
    end }
    package.loaded.HandlerDevelop = { presetEntries = function() return sdk.presets end }
    package.loaded.LandscapePreset = { ensure = function() return {} end }
    package.loaded.PhotoLookup = { resolveMany = function(_, ids)
        local out = {}
        for _, id in ipairs(ids) do table.insert(out, { photo = sdk.photos[id] }) end
        return out
    end }
    local store = {}
    store.create = function(items, settings, warnings)
        local id = "test-job-" .. tostring(#sdk.jobs + 1)
        local job = { jobId = id, photos = items, config = settings, warnings = warnings,
            status = "QUEUED", selected = #items, photoCount = #items, completed = 0, failed = 0, skipped = 0 }
        sdk.jobs[#sdk.jobs + 1] = job
        sdk.jobs[id] = job
        return job
    end
    store.get = function(id) return sdk.jobs[id] end
    store.setJobStatus = function(job, status, reason) job.status = status; job.failureReason = reason end
    store.setPhotoStatus = function(job, index, status, step, reason)
        local photo = job.photos[index]
        photo.status = status; photo.currentStep = step
        photo.steps[step] = { status = status, reason = reason }
    end
    store.setModuleStatus = function(job, index, moduleIndex, status, reason)
        local module = job.photos[index].modules[moduleIndex]
        module.status = status; module.reason = reason
    end
    store.finishPhoto = function(job, index, status, reason)
        local photo = job.photos[index]
        photo.status = status; photo.reason = reason
        if not photo.counted then
            local key = ({ COMPLETE = "completed", FAILED = "failed", SKIPPED = "skipped" })[status]
            if key then job[key] = job[key] + 1 end
            photo.counted = true
        end
    end
    store.cancel = function(id) local job = sdk.jobs[id]; job.cancelRequested = true; return job end
    store.persist = function() return true end
    store.observeOperation = function(job, index, operation) job.photos[index].operation = operation end
    store.directory = function() return "test-jobs" end
    package.loaded.BatchJobStore = store
    function sdk.photo(id, properties)
        local photo = { localIdentifier = id, metadata = {}, available = true }
        merge(photo, properties)
        photo.getFormattedMetadata = function() return "test-" .. tostring(id) .. ".NEF" end
        photo.getPropertyForPlugin = function(_, _, key) return photo.metadata[key] end
        photo.setPropertyForPlugin = function(_, _, key, value) photo.metadata[key] = value end
        photo.isAvailableForEditing = function() return photo.available end
        photo.needsUpdateAISettings = function() return photo.needsUpdate == true end
        photo.getDevelopSettings = function() return {} end
        photo.applyDevelopPreset = function(_, preset)
            photo.presetCalls = (photo.presetCalls or 0) + 1
            photo.appliedPresets = photo.appliedPresets or {}
            local id = preset.getUuid and preset:getUuid() or "landscape"
            table.insert(photo.appliedPresets, id)
            if sdk.presetHook then sdk.presetHook(photo, id) end
        end
        sdk.photos[id] = photo
        return photo
    end
    function sdk.select(photos) sdk.selection = photos; sdk.target = photos[1] end
    sdk.tasksApi = tasks
    return sdk
end

return M
