local LrFunctionContext = import 'LrFunctionContext'
local LrTasks = import 'LrTasks'

local Log = require 'Log'

local AiOperation = {}

-- Survives module reloads: a new worker must not overlap an old native call.
if not _G.LightroomAIBatchOperations then
    _G.LightroomAIBatchOperations = { sequence = 0 }
end
local runtime = _G.LightroomAIBatchOperations

local function snapshot(operation)
    if not operation then return nil end
    return {
        operationId = operation.operationId,
        jobId = operation.jobId,
        photoId = operation.photoId,
        kind = operation.kind,
        state = operation.state,
        startedAt = operation.startedAt,
        elapsedSeconds = os.time() - operation.startedEpoch,
        callStarted = operation.callStarted,
        callReturned = operation.callReturned,
        abortRequested = operation.abortRequested,
        restartRequired = operation.state == "RESTART_REQUIRED",
        error = operation.error,
    }
end

local function release(operation)
    if runtime.active == operation and operation.callReturned then
        runtime.last = snapshot(operation)
        runtime.active = nil
    end
end

function AiOperation.active()
    local operation = runtime.active
    -- A timed-out native call can return later. Only that observed return,
    -- never elapsed time or a stale heartbeat, permits another operation.
    if operation and operation.detached and operation.callReturned then
        release(operation)
    end
    return snapshot(runtime.active)
end

function AiOperation.isIdle()
    return AiOperation.active() == nil
end

function AiOperation.last()
    AiOperation.active()
    return runtime.last
end

function AiOperation.abandon(jobId)
    local operation = runtime.active
    if not operation or operation.jobId ~= jobId then return end
    operation.abortRequested = true
    operation.detached = true
    if operation.callReturned then release(operation)
    else
        operation.state = "RESTART_REQUIRED"
        operation.error = "Owning worker ended before Lightroom SDK call returned"
    end
end

local function observe(operation, options, force)
    local now = os.time()
    if not force and operation.lastObservedState == operation.state
        and now - (operation.lastObservedEpoch or 0) < (options.heartbeatIntervalSeconds or 5) then
        return
    end
    operation.lastObservedState = operation.state
    operation.lastObservedEpoch = now
    if options.onState then
        local ok, err = LrTasks.pcall(function() options.onState(snapshot(operation)) end)
        if not ok then Log.warn("Operation observer failed: " .. tostring(err)) end
    end
end

local function stopWaiting(operation, reason, options)
    operation.abortRequested = true
    operation.state = "DRAINING"
    observe(operation, options, true)
    local deadline = os.time() + (options.drainTimeoutSeconds or 60)
    while not operation.callReturned and os.time() <= deadline do
        observe(operation, options, false)
        LrTasks.sleep(options.pollIntervalSeconds or 0.25)
    end
    if not operation.callReturned then
        operation.state = "RESTART_REQUIRED"
        operation.detached = true
        operation.error = reason .. "; Lightroom SDK call has not returned; restart Lightroom if it remains active"
        observe(operation, options, true)
        Log.error("Operation still active id=" .. operation.operationId .. " " .. operation.error)
        return false, operation.error, snapshot(operation)
    end
    operation.state = "FAILED"
    operation.error = reason
    observe(operation, options, true)
    local result = snapshot(operation)
    release(operation)
    return false, reason, result
end

-- invoke may yield inside Lightroom. Its independent context outlives a
-- cancelled caller; the caller must drain it rather than release its gate.
function AiOperation.run(kind, photoId, invoke, complete, options)
    options = options or {}
    local previous = AiOperation.active()
    if previous then
        return false, "Previous Lightroom operation is still active: " .. previous.operationId, previous
    end
    if options.isCancelled and options.isCancelled() then return false, "cancelled" end
    runtime.sequence = runtime.sequence + 1
    local operation = {
        operationId = tostring(os.time()) .. "-" .. tostring(runtime.sequence),
        jobId = options.jobId,
        photoId = photoId,
        kind = kind,
        state = "SUBMITTED",
        startedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        startedEpoch = os.time(),
        callStarted = false,
        callReturned = false,
        abortRequested = false,
    }
    runtime.active = operation
    observe(operation, options, true)
    local scheduled, scheduleError = LrTasks.pcall(function()
        LrFunctionContext.postAsyncTaskWithContext("LightroomAIBatch_" .. kind, function(context)
            context:addCleanupHandler(function()
                if not operation.callReturned then
                    operation.error = "Lightroom operation context ended before the SDK call returned"
                    -- Before invoke there cannot be an outstanding native call.
                    -- Once invoke began, its end must be observed explicitly.
                    if not operation.callStarted then operation.callReturned = true end
                    Log.error(operation.error .. " id=" .. operation.operationId)
                end
                if operation.detached then release(operation) end
            end)
            if operation.abortRequested then
                operation.error = "cancelled before SDK call"
                operation.callReturned = true
                return
            end
            operation.state = "CALL_RUNNING"
            operation.callStarted = true
            Log.info("SDK operation entered id=" .. operation.operationId .. " kind=" .. kind
                .. " photo=" .. tostring(photoId))
            local ok, err = LrTasks.pcall(function() invoke(operation) end)
            if not ok then operation.error = tostring(err) end
            operation.callReturned = true
            operation.state = "CALL_RETURNED"
            Log.info("SDK operation returned id=" .. operation.operationId
                .. " error=" .. tostring(operation.error))
        end)
    end)
    if not scheduled then
        operation.callReturned = true
        return stopWaiting(operation, tostring(scheduleError), options)
    end

    local deadline = os.time() + (options.timeoutSeconds or 900)
    while os.time() <= deadline do
        if options.isCancelled and options.isCancelled() then
            return stopWaiting(operation, "cancelled", options)
        end
        if operation.error then
            return stopWaiting(operation, operation.error, options)
        end
        if operation.callReturned then
            operation.state = "VALIDATING"
            local ok, ready, detail, fatal = LrTasks.pcall(complete)
            if not ok then return stopWaiting(operation, tostring(ready), options) end
            if fatal then return stopWaiting(operation, tostring(fatal), options) end
            if ready then
                operation.state = "COMPLETE"
                observe(operation, options, true)
                release(operation)
                return true, detail
            end
        end
        observe(operation, options, false)
        LrTasks.sleep(options.pollIntervalSeconds or 0.25)
    end
    return stopWaiting(operation, "timed out after " .. tostring(options.timeoutSeconds or 900)
        .. " seconds", options)
end

return AiOperation
