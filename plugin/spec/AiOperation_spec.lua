require 'spec_helper'
local helper = require 'batch_test_helper'

describe("AiOperation lifecycle", function()
    local sdk, operation
    before_each(function() sdk = helper.new(); operation = require 'AiOperation' end)
    after_each(function() sdk.restore() end)

    it("waits for the SDK return even when visible state is already complete", function()
        local entered = false
        local ok = operation.run("TEST", 1, function()
            entered = true
            sdk.tasksApi.sleep(2)
        end, function() return true end, { timeoutSeconds = 5 })
        assert.is_true(ok)
        assert.is_true(entered)
        assert.is_true(sdk.now >= 1002)
        assert.is_true(operation.isIdle())
    end)

    it("reports a definite SDK error without waiting for the long deadline", function()
        local ok, err = operation.run("TEST", 1, function() error("bad photo") end,
            function() return false end, { timeoutSeconds = 900 })
        assert.is_false(ok)
        assert.matches("bad photo", err)
        assert.is_true(sdk.now < 1002)
        assert.is_true(operation.isIdle())
    end)

    it("drains an active call on cancellation before allowing another operation", function()
        local ok, err = operation.run("TEST", 1, function() sdk.tasksApi.sleep(2) end,
            function() return true end, { timeoutSeconds = 10, drainTimeoutSeconds = 3,
                isCancelled = function() return sdk.now >= 1001 end })
        assert.is_false(ok)
        assert.are.equal("cancelled", err)
        assert.is_true(sdk.now >= 1002)
        assert.is_true(operation.isIdle())
    end)

    it("quarantines a still-active native call and releases only after its late return", function()
        local ok, _, state = operation.run("TEST", 1, function() sdk.tasksApi.sleep(20) end,
            function() return true end, { timeoutSeconds = 1, drainTimeoutSeconds = 2 })
        assert.is_false(ok)
        assert.is_true(state.restartRequired)
        local invoked = false
        local nextOk = operation.run("NEXT", 2, function() invoked = true end,
            function() return true end, {})
        assert.is_false(nextOk)
        assert.is_false(invoked)
        sdk.advance(20)
        assert.is_true(operation.isIdle())
        assert.is_true(operation.run("NEXT", 2, function() invoked = true end, function() return true end, {}))
    end)

    it("does not leave a busy flag when scheduling fails", function()
        sdk.scheduleError = "scheduler unavailable"
        local ok, err = operation.run("TEST", 1, function() end, function() return true end, {})
        assert.is_false(ok)
        assert.matches("scheduler unavailable", err)
        assert.is_true(operation.isIdle())
    end)

    it("treats completion-predicate errors as fatal rather than transient", function()
        local ok, err = operation.run("TEST", 1, function() end,
            function() error("cannot read photo") end, { timeoutSeconds = 900 })
        assert.is_false(ok)
        assert.matches("cannot read photo", err)
        assert.is_true(sdk.now < 1002)
        assert.is_true(operation.isIdle())
    end)

    it("fails immediately when write access was aborted instead of treating it as completion", function()
        local photo = sdk.photo(1)
        sdk.select({ photo })
        sdk.writeResult = "aborted"
        local ai = require 'AiState'
        local ok, err = ai.updateMasks(sdk.catalog, { photo }, { timeoutSeconds = 900 })
        assert.is_false(ok)
        assert.matches("not executed", err)
        assert.are.same({}, sdk.maskCalls)
        assert.is_true(sdk.now < 1002)
    end)

    it("prevents a delayed write callback from running after cancellation", function()
        local photo = sdk.photo(1)
        sdk.select({ photo })
        sdk.writeHook = function() sdk.tasksApi.sleep(2) end
        local ai = require 'AiState'
        local ok = ai.updateMasks(sdk.catalog, { photo }, { timeoutSeconds = 10,
            drainTimeoutSeconds = 3, isCancelled = function() return sdk.now >= 1001 end })
        assert.is_false(ok)
        assert.are.same({}, sdk.maskCalls)
        assert.is_true(operation.isIdle())
    end)
end)
