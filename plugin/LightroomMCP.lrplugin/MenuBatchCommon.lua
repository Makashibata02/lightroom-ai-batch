local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'

local HandlerBatch = require 'HandlerBatch'

local MenuBatchCommon = {}

if not _G.LightroomAIBatchMenuState then
    _G.LightroomAIBatchMenuState = {
        lastJobId = nil,
        monitors = {},
    }
end
local state = _G.LightroomAIBatchMenuState

local STATUS_TITLE = LOC "$$$/LightroomAIBatch/Dialog/StatusTitle=AI Batch Status"
local CANCEL_TITLE = LOC "$$$/LightroomAIBatch/Dialog/CancelTitle=AI Batch Cancel"

local TERMINAL = {
    COMPLETE = true,
    FAILED = true,
    CANCELLED = true,
}

local function summary(job)
    return LOC("$$$/LightroomAIBatch/Dialog/Summary=Job ID: ^1^nProfile: ^2^nStatus: ^3^n^nSelected: ^4^nCompleted: ^5^nFailed: ^6^nSkipped: ^7^nDuration: ^8 seconds",
        tostring(job.jobId),
        tostring(job.config and job.config.profile or "configured"),
        tostring(job.status),
        tostring(job.selected or job.photoCount or 0),
        tostring(job.completed or 0),
        tostring(job.failed or 0),
        tostring(job.skipped or 0),
        tostring(job.durationSeconds or "—"))
end

local function monitor(jobId, title)
    if state.monitors[jobId] then return end
    state.monitors[jobId] = true
    LrTasks.startAsyncTask(function()
        while true do
            local ok, job = LrTasks.pcall(function()
                return HandlerBatch.status({ jobId = jobId })
            end)
            if not ok then
                state.monitors[jobId] = nil
                LrDialogs.message(title,
                    LOC("$$$/LightroomAIBatch/Dialog/StatusCheckFailed=Status check failed:^n^n^1",
                        tostring(job)),
                    "critical")
                return
            end
            if TERMINAL[job.status] then
                state.monitors[jobId] = nil
                LrDialogs.message(
                    title .. LOC "$$$/LightroomAIBatch/Dialog/FinishedSuffix= — Finished",
                    summary(job),
                    job.status == "COMPLETE" and "info" or "warning")
                return
            end
            -- This is status polling, not an assumption that an AI operation
            -- completed after a fixed delay. The backend remains authoritative.
            LrTasks.sleep(1)
        end
    end)
end

function MenuBatchCommon.start(title, args)
    LrTasks.startAsyncTask(function()
        local ok, result = LrTasks.pcall(function() return HandlerBatch.start(args or {}) end)
        if not ok then
            LrDialogs.message(title, tostring(result), "critical")
            return
        end
        state.lastJobId = result.jobId
        LrDialogs.message(
            title,
            LOC("$$$/LightroomAIBatch/Dialog/JobStarted=Job started^n^nJob ID: ^1^nPhotos: ^2^nProfile: ^3^n^nThe original selection will be restored when the job ends.",
                tostring(result.jobId),
                tostring(result.photoCount),
                tostring(result.profile or "configured")),
            "info")
        monitor(result.jobId, title)
    end)
end

function MenuBatchCommon.showLastStatus()
    LrTasks.startAsyncTask(function()
        if not state.lastJobId then
            LrDialogs.message(STATUS_TITLE,
                LOC "$$$/LightroomAIBatch/Dialog/NoJob=No AI Batch job was started in this Lightroom session.",
                "warning")
            return
        end
        local ok, job = LrTasks.pcall(function()
            return HandlerBatch.status({ jobId = state.lastJobId })
        end)
        if ok then
            LrDialogs.message(STATUS_TITLE, summary(job), "info")
        else
            LrDialogs.message(STATUS_TITLE, tostring(job), "critical")
        end
    end)
end

function MenuBatchCommon.cancelLast()
    LrTasks.startAsyncTask(function()
        if not state.lastJobId then
            LrDialogs.message(CANCEL_TITLE,
                LOC "$$$/LightroomAIBatch/Dialog/NoJob=No AI Batch job was started in this Lightroom session.",
                "warning")
            return
        end
        local ok, result = LrTasks.pcall(function()
            return HandlerBatch.cancel({ jobId = state.lastJobId })
        end)
        if ok then
            local message
            if result.cancelRequested then
                message = LOC("$$$/LightroomAIBatch/Dialog/CancelRequested=Cancellation requested for Job ID:^n^1^n^nThe active Lightroom operation will stop at a safe boundary.",
                    tostring(result.jobId))
            else
                message = LOC("$$$/LightroomAIBatch/Dialog/AlreadyTerminal=Job ID ^1 is already in terminal state ^2.",
                    tostring(result.jobId), tostring(result.status))
            end
            LrDialogs.message(
                CANCEL_TITLE,
                message,
                "info")
        else
            LrDialogs.message(CANCEL_TITLE, tostring(result), "critical")
        end
    end)
end

return MenuBatchCommon
