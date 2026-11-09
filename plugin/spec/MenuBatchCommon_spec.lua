require 'spec_helper'
local helper = require 'batch_test_helper'

describe("Batch menu routing", function()
    local sdk, pipeline, menu
    before_each(function()
        sdk = helper.new()
        pipeline = require 'BatchPipeline'
        menu = require 'MenuBatchCommon'
    end)
    after_each(function() sdk.restore() end)

    it("shows the active job instead of silently creating another one", function()
        sdk.select({ sdk.photo(1) })
        sdk.enhanceHook = function() sdk.tasksApi.sleep(4) end
        local active = pipeline.start({ profile = "full" })
        sdk.advance(1)
        menu.start("test menu", { profile = "full" })
        sdk.advance(0.5)
        assert.are.equal(1, #sdk.jobs)
        assert.is_not_nil(sdk.messages[1][2]:find(active.jobId, 1, true))
    end)

    it("queries and cancels the actual active job rather than the last queued job", function()
        sdk.select({ sdk.photo(1) })
        sdk.enhanceHook = function() sdk.tasksApi.sleep(2) end
        local active = pipeline.start({ profile = "full" })
        local queued = pipeline.start({ profile = "full" })
        _G.LightroomAIBatchMenuState.lastJobId = queued.jobId
        sdk.advance(1)
        menu.showLastStatus()
        sdk.advance(0.1)
        assert.is_not_nil(sdk.messages[1][2]:find(active.jobId, 1, true))
        menu.cancelLast()
        sdk.advance(0.1)
        assert.is_true(sdk.jobs[active.jobId].cancelRequested)
        assert.is_nil(sdk.jobs[queued.jobId].cancelRequested)
        sdk.advance(20)
        assert.are.equal("CANCELLED", sdk.jobs[active.jobId].status)
        assert.are.equal("COMPLETE", sdk.jobs[queued.jobId].status)
    end)

    it("can cancel the displayed running job from the workbench status dialog", function()
        sdk.select({ sdk.photo(1) })
        sdk.enhanceHook = function() sdk.tasksApi.sleep(2) end
        local active = pipeline.start({ profile = "full" })
        sdk.confirmResponse = "other"
        sdk.advance(1)
        menu.showLastStatus()
        sdk.advance(0.1)
        assert.is_true(sdk.jobs[active.jobId].cancelRequested)
        sdk.advance(10)
        assert.are.equal("CANCELLED", sdk.jobs[active.jobId].status)
    end)

    it("closing status leaves the running job untouched", function()
        sdk.select({ sdk.photo(1) })
        sdk.enhanceHook = function() sdk.tasksApi.sleep(2) end
        local active = pipeline.start({ profile = "full" })
        sdk.advance(1)
        menu.showLastStatus()
        sdk.advance(0.1)
        assert.is_nil(sdk.jobs[active.jobId].cancelRequested)
        assert.are.equal("Close", sdk.messages[1][4])
        sdk.advance(20)
        assert.are.equal("COMPLETE", sdk.jobs[active.jobId].status)
    end)
end)
