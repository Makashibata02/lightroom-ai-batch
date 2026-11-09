local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'
local LrFunctionContext = import 'LrFunctionContext'

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
    local message = LOC("$$$/LightroomAIBatch/Dialog/Summary=Job ID: ^1^nProfile: ^2^nStatus: ^3^n^nSelected: ^4^nCompleted: ^5^nFailed: ^6^nSkipped: ^7^nDuration: ^8 seconds",
        tostring(job.jobId),
        tostring(job.config and job.config.profile or "configured"),
        tostring(job.status),
        tostring(job.selected or job.photoCount or 0),
        tostring(job.completed or 0),
        tostring(job.failed or 0),
        tostring(job.skipped or 0),
        tostring(job.durationSeconds or "—"))
    local operation = job.activeOperation or job.lastOperation
    message = message .. LOC("$$$/LightroomAIBatch/Dialog/RuntimeSummary=^n^nCurrent photo: ^1^nExecution: ^2^nQueue position: ^3^nLast heartbeat: ^4^nSDK call returned: ^5",
        tostring(job.currentFilename or "—"),
        tostring(operation and operation.state or job.executionState or job.status),
        tostring(job.queuePosition or 0),
        tostring(job.lastHeartbeatAt or "—"),
        operation and tostring(operation.callReturned) or "—")
    if job.failureReason then
        message = message .. LOC("$$$/LightroomAIBatch/Dialog/FailureReason=^n^nReason: ^1", job.failureReason)
    end
    if job.recipe then
        message = message .. LOC("$$$/LightroomAIBatch/Workbench/RecipeSummary=^n^nRecipe category: ^1^nAdditional presets:", job.recipe.category)
        for _, preset in ipairs(job.recipe.presets or {}) do
            message = message .. "\n" .. tostring(preset.name)
            if preset.isCN13 then
                message = message .. "\n" .. LOC "$$$/LightroomAIBatch/Workbench/CN13Impact=CN13 changes color/HSL, curves, sharpening and traditional noise reduction. Genuine AI Denoise is validated separately."
            end
        end
    end
    if job.restartRequired then
        message = message .. LOC "$$$/LightroomAIBatch/Dialog/RestartRequired=^n^nLightroom's internal operation has not safely ended. New operations are blocked. If it remains active, restart Lightroom. Completed photos will not be automatically rerun."
    end
    return message
end

local function monitor(jobId, title)
    if state.monitors[jobId] then return end
    state.monitors[jobId] = true
    LrFunctionContext.postAsyncTaskWithContext("LightroomAIBatchMenuMonitor", function(context)
        context:addCleanupHandler(function() state.monitors[jobId] = nil end)
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
    LrFunctionContext.postAsyncTaskWithContext("LightroomAIBatchMenuStart", function()
        local currentId = HandlerBatch.preferredJobId()
        if currentId then
            local checked, current = LrTasks.pcall(function() return HandlerBatch.status({ jobId = currentId }) end)
            if checked and (not TERMINAL[current.status] or current.activeOperation or current.restartRequired) then
                state.lastJobId = currentId
                LrDialogs.message(title,
                    LOC "$$$/LightroomAIBatch/Dialog/AlreadyRunning=An existing batch or Lightroom operation is still active. No additional job was created."
                    .. "\n\n" .. summary(current), "warning")
                return
            end
        end
        local ok, result = LrTasks.pcall(function() return HandlerBatch.start(args or {}) end)
        if not ok then
            LrDialogs.message(title, tostring(result), "critical")
            return
        end
        state.lastJobId = result.jobId
        local submitted = LOC("$$$/LightroomAIBatch/Dialog/JobSubmitted=Job submitted^n^nJob ID: ^1^nPhotos: ^2^nProfile: ^3^nStatus: ^4^n^nThe original selection will be restored after a safe end.",
            tostring(result.jobId), tostring(result.photoCount),
            tostring(result.profile or "configured"), tostring(result.status))
        LrDialogs.message(
            title,
            submitted,
            "info")
        monitor(result.jobId, title)
    end)
end

function MenuBatchCommon.showLastStatus()
    LrFunctionContext.postAsyncTaskWithContext("LightroomAIBatchMenuStatus", function()
        state.lastJobId = HandlerBatch.preferredJobId(state.lastJobId)
        if not state.lastJobId then
            LrDialogs.message(STATUS_TITLE,
                LOC "$$$/LightroomAIBatch/Dialog/NoJob=No AI Batch job was started in this Lightroom session.",
                "warning")
            return
        end
        while true do
            local ok, job = LrTasks.pcall(function()
                return HandlerBatch.status({ jobId = state.lastJobId })
            end)
            if not ok then
                LrDialogs.message(STATUS_TITLE, tostring(job), "critical")
                return
            end
            if TERMINAL[job.status] and not job.activeOperation then
                LrDialogs.message(STATUS_TITLE, summary(job), "info")
                return
            end
            local result = LrDialogs.confirm(STATUS_TITLE, summary(job),
                LOC "$$$/LightroomAIBatch/Workbench/Refresh=Refresh status",
                LOC "$$$/LightroomAIBatch/Common/Close=Close",
                LOC "$$$/LightroomAIBatch/Workbench/Cancel=Cancel batch")
            if result == "other" then MenuBatchCommon.cancelLast(job.jobId) end
            if result ~= "ok" then return end
        end
    end)
end

function MenuBatchCommon.cancelLast(jobId)
    LrFunctionContext.postAsyncTaskWithContext("LightroomAIBatchMenuCancel", function()
        state.lastJobId = jobId or HandlerBatch.preferredJobId(state.lastJobId)
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
                message = LOC("$$$/LightroomAIBatch/Dialog/CancelRequested=Cancellation requested for Job ID:^n^1^n^nNo further photo operations will be submitted. Lightroom's active internal call must finish before the batch can safely stop.",
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
