describe("HandlerBatch", function()
    local calls
    local Handler

    before_each(function()
        calls = {}
        package.loaded.BatchPipeline = {
            start = function(args)
                table.insert(calls, { method = "start", args = args })
                return { jobId = "job-1", photoCount = 3, status = "running" }
            end,
            status = function(args)
                table.insert(calls, { method = "status", args = args })
                return { jobId = args.jobId, status = "COMPLETE" }
            end,
            cancel = function(args)
                table.insert(calls, { method = "cancel", args = args })
                return { jobId = args.jobId, cancelRequested = true }
            end,
        }
        package.loaded.HandlerBatch = nil
        Handler = require 'HandlerBatch'
    end)

    after_each(function()
        package.loaded.HandlerBatch = nil
        package.loaded.BatchPipeline = nil
    end)

    it("delegates start to the shared pipeline backend", function()
        local result = Handler.start({ photo_ids = { 1, 2, 3 } })

        assert.are.equal("job-1", result.jobId)
        assert.are.equal("start", calls[1].method)
        assert.are.same({ 1, 2, 3 }, calls[1].args.photo_ids)
    end)

    it("delegates status and cancel by job id", function()
        assert.are.equal("COMPLETE", Handler.status({ jobId = "job-1" }).status)
        assert.is_true(Handler.cancel({ jobId = "job-1" }).cancelRequested)
        assert.are.equal("status", calls[1].method)
        assert.are.equal("cancel", calls[2].method)
    end)
end)
