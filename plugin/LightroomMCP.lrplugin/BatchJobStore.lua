local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'
local LrUUID = import 'LrUUID'

local JSON = require 'JSON'
local Log = require 'Log'

local BatchJobStore = {}

if not _G.LightroomAIBatchJobState then
    _G.LightroomAIBatchJobState = { jobs = {} }
end
local state = _G.LightroomAIBatchJobState
local writeLocks = {}

local TERMINAL = { COMPLETE = true, FAILED = true, CANCELLED = true }

local function nowIso()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function rootDir()
    local home = LrPathUtils.getStandardFilePath("home")
    return LrPathUtils.child(LrPathUtils.child(home, ".config"), "lightroom-ai-batch")
end

local function jobsDir()
    return LrPathUtils.child(rootDir(), "jobs")
end

local function jobPath(jobId)
    return LrPathUtils.child(jobsDir(), tostring(jobId) .. ".json")
end

local function logPath(jobId)
    return LrPathUtils.child(jobsDir(), tostring(jobId) .. ".jsonl")
end

local function ensureDir()
    LrFileUtils.createAllDirectories(jobsDir())
end

local function writeJsonUnlocked(path, value)
    ensureDir()
    local tmp = path .. "." .. LrUUID.generateUUID() .. ".tmp"
    local previous = path .. ".previous"
    local encoded = JSON:encode(value)
    local fh, err = io.open(tmp, "w")
    if not fh then return false, tostring(err) end
    fh:write(encoded)
    fh:close()
    local hadCurrent = LrFileUtils.exists(path)
    if hadCurrent then
        if LrFileUtils.exists(previous) then LrFileUtils.delete(previous) end
        local backedUp = LrFileUtils.move(path, previous)
        if not backedUp then
            pcall(function() LrFileUtils.delete(tmp) end)
            return false, "could not preserve previous snapshot for " .. path
        end
    end
    local moved = LrFileUtils.move(tmp, path)
    if not moved then
        if hadCurrent and LrFileUtils.exists(previous) then
            pcall(function() LrFileUtils.move(previous, path) end)
        end
        pcall(function() LrFileUtils.delete(tmp) end)
        return false, "could not replace " .. path
    end
    if LrFileUtils.exists(previous) then
        pcall(function() LrFileUtils.delete(previous) end)
    end
    return true
end

-- The status worker and lr_batch_cancel run in separate cooperative tasks and
-- can persist the same in-memory job at the same time. A shared `<job>.tmp`
-- made those writes delete/move each other's file on Windows. Serialize each
-- target path and also give every attempt its own temp file, so cancellation
-- cannot corrupt or lose the current snapshot.
local function writeJson(path, value)
    local deadline = os.time() + 30
    while writeLocks[path] do
        if os.time() > deadline then
            return false, "timed out waiting for job snapshot writer: " .. path
        end
        LrTasks.sleep(0.01)
    end

    writeLocks[path] = true
    local ok, result, detail = LrTasks.pcall(function()
        return writeJsonUnlocked(path, value)
    end)
    writeLocks[path] = nil

    if not ok then return false, tostring(result) end
    return result, detail
end

local function readJsonFile(path)
    local fh = io.open(path, "r")
    if not fh then return nil end
    local text = fh:read("*a")
    fh:close()
    local ok, value = pcall(function() return JSON:decode(text) end)
    if ok and type(value) == "table" then return value end
    return nil
end

local function readJson(path)
    -- On Windows the SDK cannot replace an existing file in one move. During
    -- the brief path -> .previous -> new path rotation, readers and a restart
    -- must still have a complete snapshot available. Invalid/truncated primary
    -- data also falls back to the last complete generation.
    return readJsonFile(path) or readJsonFile(path .. ".previous")
end

function BatchJobStore.persist(job)
    local ok, err = writeJson(jobPath(job.jobId), job)
    if not ok then Log.error("Job persist failed " .. tostring(job.jobId) .. ": " .. tostring(err)) end
    return ok, err
end

function BatchJobStore.appendEvent(job, photoItem, step, status, reason)
    ensureDir()
    local event = {
        timestamp = nowIso(),
        jobId = job.jobId,
        photoId = photoItem and photoItem.photoId or nil,
        filename = photoItem and photoItem.filename or nil,
        step = step,
        status = status,
        reason = reason,
    }
    local fh = io.open(logPath(job.jobId), "a")
    if fh then
        fh:write(JSON:encode(event) .. "\n")
        fh:close()
    end
end

function BatchJobStore.create(photoItems, config, warnings)
    local jobId = LrUUID.generateUUID()
    local job = {
        jobId = jobId,
        photoCount = #photoItems,
        selected = #photoItems,
        completed = 0,
        failed = 0,
        skipped = 0,
        status = "QUEUED",
        cancelRequested = false,
        createdAt = nowIso(),
        startedAt = nil,
        endedAt = nil,
        durationSeconds = nil,
        warnings = warnings or {},
        config = config,
        photos = photoItems,
    }
    state.jobs[jobId] = job
    BatchJobStore.persist(job)
    BatchJobStore.appendEvent(job, nil, "JOB", "QUEUED", nil)
    return job
end

function BatchJobStore.get(jobId)
    local job = state.jobs[jobId]
    if job then return job end
    job = readJson(jobPath(jobId))
    if not job then return nil end
    if not TERMINAL[job.status] then
        job.status = "FAILED"
        job.endedAt = nowIso()
        job.failureReason = "Lightroom restarted before the job completed"
        BatchJobStore.persist(job)
    end
    state.jobs[jobId] = job
    return job
end

function BatchJobStore.cancel(jobId)
    local job = BatchJobStore.get(jobId)
    if not job then return nil, "Unknown jobId: " .. tostring(jobId) end
    if TERMINAL[job.status] then return job end
    job.cancelRequested = true
    BatchJobStore.persist(job)
    BatchJobStore.appendEvent(job, nil, "JOB", "CANCEL_REQUESTED", nil)
    return job
end

function BatchJobStore.setJobStatus(job, status, reason)
    job.status = status
    if status == "RUNNING" and not job.startedAt then
        job.startedAt = nowIso()
        job.startedEpoch = os.time()
    end
    if TERMINAL[status] then
        job.endedAt = nowIso()
        if job.startedEpoch then job.durationSeconds = os.time() - job.startedEpoch end
        job.startedEpoch = nil
    end
    if reason then job.failureReason = reason end
    BatchJobStore.persist(job)
    BatchJobStore.appendEvent(job, nil, "JOB", status, reason)
end

function BatchJobStore.setPhotoStatus(job, index, status, step, reason)
    local item = job.photos[index]
    item.status = status
    item.currentStep = step
    item.updatedAt = nowIso()
    if not item.startedAt then
        item.startedAt = item.updatedAt
        item.startedEpoch = os.time()
    end
    item.steps = item.steps or {}
    local stepItem = item.steps[step] or {
        startedAt = item.updatedAt,
        startedEpoch = os.time(),
    }
    stepItem.status = status
    stepItem.updatedAt = item.updatedAt
    stepItem.reason = reason
    local inProgress = status == "DENOISE_SUBMITTED" or status:match("_RUNNING$") ~= nil
    if not inProgress then
        stepItem.endedAt = item.updatedAt
        if stepItem.startedEpoch then stepItem.durationSeconds = os.time() - stepItem.startedEpoch end
        stepItem.startedEpoch = nil
    end
    item.steps[step] = stepItem
    if reason then
        item.reason = reason
    elseif status == "COMPLETE" then
        item.reason = nil
    end
    BatchJobStore.persist(job)
    BatchJobStore.appendEvent(job, item, step, status, reason)
end

function BatchJobStore.finishPhoto(job, index, status, reason)
    local item = job.photos[index]
    local wasCounted = item.counted == true
    item.status = status
    item.endedAt = nowIso()
    if item.startedEpoch then item.durationSeconds = os.time() - item.startedEpoch end
    item.startedEpoch = nil
    if reason then
        item.reason = reason
    elseif status == "COMPLETE" then
        item.reason = nil
    end
    if not wasCounted then
        if status == "COMPLETE" then
            job.completed = job.completed + 1
        elseif status == "FAILED" then
            job.failed = job.failed + 1
        elseif status == "SKIPPED" then
            job.skipped = job.skipped + 1
        end
        item.counted = true
    end
    BatchJobStore.persist(job)
    BatchJobStore.appendEvent(job, item, "PHOTO", status, reason)
end

function BatchJobStore.directory()
    return jobsDir()
end

return BatchJobStore
