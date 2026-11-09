require 'spec_helper'
local helper = require 'batch_test_helper'

describe("Workbench recipes in the existing worker", function()
    local sdk, pipeline, photo
    before_each(function()
        sdk = helper.new()
        pipeline = require 'BatchPipeline'
        sdk.preset("skin", "portrait", "Smooth Face")
        sdk.preset("clothes", "portrait", "Enhance Clothes")
        sdk.preset("blue", "sky", "Blue Pop")
        sdk.preset("cn13", "style", "CN13")
        photo = sdk.photo(1, { denoise = true, metadata = { pipelineVersion = "1.0.0", processed = "true",
            denoiseStatus = "COMPLETE", autoToneStatus = "COMPLETE", subjectStatus = "COMPLETE", landscapeStatus = "COMPLETE" } })
        sdk.select({ photo })
    end)
    after_each(function() sdk.restore() end)

    it("adds modules to an old processed photo and skips them on the next run", function()
        local args = { profile = "full", recipe = { category = "people", presetUuids = { "skin", "clothes", "cn13" } } }
        local first = pipeline.start(args)
        sdk.advance(30)
        local result = pipeline.status({ jobId = first.jobId })
        assert.are.equal(1, result.completed)
        assert.are.same({ "skin", "clothes", "cn13" }, photo.appliedPresets)
        assert.is_nil(photo.autoCalls)
        assert.are.equal("COMPLETE", photo.metadata.presetModules.skin.status)
        assert.are.equal("COMPLETE", result.photos[1].modules[3].status)
        local nextJob = pipeline.start(args)
        sdk.advance(10)
        assert.are.equal(1, pipeline.status({ jobId = nextJob.jobId }).skipped)
        assert.are.equal(3, photo.presetCalls)
    end)

    it("orders AI presets before Landscape and style afterwards", function()
        photo.metadata = {}
        photo.denoise = false
        local job = pipeline.start({ profile = "full", recipe = {
            category = "landscape", presetUuids = { "blue", "cn13" } } })
        sdk.advance(30)
        assert.are.equal(1, pipeline.status({ jobId = job.jobId }).completed)
        assert.are.same({ "pop", "blue", "landscape", "cn13" }, photo.appliedPresets)
        assert.are.same({ 1 }, sdk.enhanceCalls)
    end)

    it("does not reapply presets after interrupted AI computation", function()
        sdk.maskHook = function() error("cannot display photo") end
        local args = { profile = "full", recipe = { category = "people", presetUuids = { "skin" } } }
        local failed = pipeline.start(args)
        sdk.advance(20)
        assert.are.equal(1, pipeline.status({ jobId = failed.jobId }).failed)
        assert.are.equal("APPLIED", photo.metadata.presetModules.skin.status)
        sdk.maskHook = nil
        local retry = pipeline.start(args)
        sdk.advance(20)
        assert.are.equal(1, pipeline.status({ jobId = retry.jobId }).completed)
        assert.are.equal(1, photo.presetCalls)
        assert.are.same({ 1 }, sdk.cleanupCalls)
    end)

    it("repairs Denoise lost by a style before updating masks", function()
        sdk.presetHook = function(p, id) if id == "cn13" then p.denoise = false end end
        sdk.maskHook = function(p) assert.is_true(p.denoise) end
        local job = pipeline.start({ profile = "full", recipe = { category = "people", presetUuids = { "cn13" } } })
        sdk.advance(30)
        local result = pipeline.status({ jobId = job.jobId })
        assert.are.equal(1, result.completed)
        assert.is_true(result.photos[1].denoiseValidation.recoverySucceeded)
        assert.are.same({ 1 }, sdk.enhanceCalls)
    end)

    it("applies a changed Subject choice instead of trusting the old Pop flag", function()
        sdk.preset("light", "subject", "Light")
        local args = { config = { subjectPreset = { uuid = "light" } } }
        local job = pipeline.start(args)
        sdk.advance(20)
        assert.are.equal(1, pipeline.status({ jobId = job.jobId }).completed)
        assert.are.same({ "light" }, photo.appliedPresets)
        local nextJob = pipeline.start(args)
        sdk.advance(10)
        assert.are.equal(1, pipeline.status({ jobId = nextJob.jobId }).skipped)
    end)

    it("cleans absent AI targets even with Landscape disabled", function()
        local job = pipeline.start({ config = { subjectPreset = { enabled = false }, landscape = { enabled = false } },
            recipe = { category = "food", presetUuids = { "skin", "blue" } } })
        sdk.advance(20)
        assert.are.equal(1, pipeline.status({ jobId = job.jobId }).completed)
        assert.are.same({ 1 }, sdk.cleanupCalls)
    end)

    it("switches back to a previously used style instead of skipping it", function()
        sdk.preset("other", "style", "Other Look")
        for _, uuid in ipairs({ "cn13", "other", "cn13" }) do
            local job = pipeline.start({ recipe = { category = "people", presetUuids = { uuid } } })
            sdk.advance(20)
            assert.are.equal(1, pipeline.status({ jobId = job.jobId }).completed)
        end
        assert.are.same({ "cn13", "other", "cn13" }, photo.appliedPresets)
        assert.are.equal("cn13", photo.metadata.stylePresetUuid)
    end)

    it("restores the selected style after an appended portrait preset changes global color", function()
        local polished = sdk.preset("polished", "portrait", "Polished Portrait")
        polished.getSetting = function() return { HueAdjustmentReds = 10 } end
        local first = pipeline.start({ recipe = { category = "people", presetUuids = { "cn13" } } })
        sdk.advance(20)
        assert.are.equal(1, pipeline.status({ jobId = first.jobId }).completed)
        local appended = pipeline.start({ recipe = { category = "people", presetUuids = { "polished", "cn13" } } })
        sdk.advance(20)
        assert.are.equal(1, pipeline.status({ jobId = appended.jobId }).completed)
        assert.are.same({ "cn13", "polished", "cn13" }, photo.appliedPresets)
    end)

    it("preserves manual color edits when appending a mask-only detail preset", function()
        local args = { recipe = { category = "people", presetUuids = { "cn13" } } }
        pipeline.start(args)
        sdk.advance(20)
        args.recipe.presetUuids = { "skin", "cn13" }
        local appended = pipeline.start(args)
        sdk.advance(20)
        assert.are.equal(1, pipeline.status({ jobId = appended.jobId }).completed)
        assert.are.same({ "cn13", "skin" }, photo.appliedPresets)
    end)

    it("reports a hidden or missing configured Subject preset before touching photos", function()
        package.loaded.SubjectPreset.resolve = function() return nil, "not enumerated" end
        assert.has_error(function() pipeline.start({ profile = "full" }) end)
        assert.are.equal(0, #sdk.jobs)
        assert.is_nil(photo.presetCalls)
        assert.are.same({}, sdk.enhanceCalls)
    end)

    it("updates stale AI settings on a processed photo without reapplying presets", function()
        photo.needsUpdate = true
        local job = pipeline.start({ profile = "full" })
        sdk.advance(20)
        assert.are.equal(1, pipeline.status({ jobId = job.jobId }).completed)
        assert.are.same({ 1 }, sdk.maskCalls)
        assert.is_nil(photo.presetCalls)
    end)

    it("finishes a preset returning after cancellation without applying it twice", function()
        sdk.presetHook = function(_, id) if id == "skin" then sdk.tasksApi.sleep(6) end end
        local args = { recipe = { category = "people", presetUuids = { "skin" } } }
        local first = pipeline.start(args)
        for _ = 1, 40 do
            sdk.advance(0.25)
            if photo.presetCalls then break end
        end
        pipeline.cancel({ jobId = first.jobId })
        sdk.advance(3)
        assert.is_true(pipeline.status({ jobId = first.jobId }).restartRequired)
        sdk.advance(5)
        assert.are.equal("APPLIED", photo.metadata.presetModules.skin.status)
        assert.is_false(pipeline.status({ jobId = first.jobId }).restartRequired)
        sdk.presetHook = nil
        local retry = pipeline.start(args)
        sdk.advance(20)
        assert.are.equal(1, pipeline.status({ jobId = retry.jobId }).completed)
        assert.are.equal(1, photo.presetCalls)
    end)

    it("runs newly enabled base stages and a changed Landscape feature selection", function()
        photo.metadata.autoToneStatus = nil
        local job = pipeline.start({ config = { landscape = { features = { "Sky" } } } })
        sdk.advance(20)
        assert.are.equal(1, pipeline.status({ jobId = job.jobId }).completed)
        assert.are.equal(1, photo.autoCalls)
        assert.are.same({ "landscape" }, photo.appliedPresets)
        assert.are.equal("Sky", photo.metadata.landscapeFeatures)
    end)

    it("rejects missing or ambiguous recipe input before creating a job", function()
        for _, uuids in ipairs({ { "missing" }, { "skin", "skin" }, { "cn13", "skin" }, { "pop" } }) do
            assert.has_error(function() pipeline.start({ recipe = { category = "people", presetUuids = uuids } }) end)
        end
        assert.has_error(function() pipeline.start({ recipe = { category = "unknown", presetUuids = {} } }) end)
        assert.are.equal(0, #sdk.jobs)
        assert.is_nil(photo.presetCalls)
    end)
end)
