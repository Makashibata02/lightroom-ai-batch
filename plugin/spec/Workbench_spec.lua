require 'spec_helper'
local helper = require 'batch_test_helper'

describe("Native category workbench", function()
    local sdk, props, saved, starts, state, showDialog
    before_each(function()
        sdk = helper.new()
        sdk.select({ sdk.photo(7), sdk.photo(9) })
        sdk.preset("skin", "portrait", "Smooth Face")
        sdk.preset("clothes", "portrait", "Enhance Clothes")
        sdk.preset("polished", "portrait", "Polished Portrait")
        sdk.preset("blue", "sky", "Blue Pop")
        sdk.preset("cn13", "style", "CN13")
        state = { version = 1, categories = {}, favorites = {}, identities = {}, lastCategory = "animals" }
        saved, starts = {}, {}
        package.loaded.WorkbenchState = {
            load = function() return state end,
            save = function(value) saved[#saved + 1] = value end,
        }
        package.loaded.MenuBatchCommon = {
            start = function(_, args) starts[#starts + 1] = args end,
            showLastStatus = function() end, cancelLast = function() end,
        }
        local factory = setmetatable({}, { __index = function(_, kind)
            return function(_, args) args.control = kind; return args end
        end })
        sdk.extraImports = {
            LrView = { osFactory = function() return factory end, bind = function(key) return key end },
            LrBinding = { makePropertyTable = function()
                local values, observers = {}, {}
                props = setmetatable({}, {
                    __index = function(_, key)
                        if key == "addObserver" then return function(_, name, callback) observers[name] = callback end end
                        return values[key]
                    end,
                    __newindex = function(t, key, value)
                        local old = values[key]; values[key] = value
                        if old ~= value and observers[key] then observers[key](t, key, value) end
                    end,
                })
                return props
            end },
            LrDialogs = { presentModalDialog = function(args) return showDialog(args) end,
                message = function(...) sdk.messages[#sdk.messages + 1] = { ... } end },
        }
    end)
    after_each(function() sdk.restore() end)

    local function run()
        require 'Workbench'.show()
        sdk.advance(2)
        assert.are.same({}, sdk.errors)
        for _, message in ipairs(sdk.messages) do
            if message[3] == "critical" then error(message[2]) end
        end
    end

    it("uses existing defaults without enabling extra effects", function()
        showDialog = function()
            assert.is_true(props.denoise)
            assert.are.equal(50, props.amount)
            assert.are.equal("default", props.subject)
            assert.are.equal("", props.overall)
            assert.are.equal("", props.sky)
            assert.are.equal("", props.style)
            assert.is_false(props.portrait_skin)
            return "cancel"
        end
        run()
        assert.are.equal(0, #saved)
        assert.are.equal(0, #starts)
        assert.is_nil(sdk.photos[7].presetCalls)
    end)

    it("keeps independent category choices and does not persist force", function()
        showDialog = function()
            props.category = "people"
            props.portrait_skin, props.style, props.force = true, "cn13", true
            props.category = "food"
            assert.is_false(props.portrait_skin)
            assert.are.equal("", props.style)
            assert.is_false(props.force)
            props.denoise = false
            return "other"
        end
        run()
        assert.are.equal(1, #saved)
        assert.is_true(saved[1].categories.people.portraits.skin)
        assert.are.equal("cn13", saved[1].categories.people.style)
        assert.is_false(saved[1].categories.food.denoise)
        assert.is_nil(saved[1].categories.people.force)
        assert.are.equal(0, #starts)
    end)

    it("submits the frozen selection and ordered recipe through the common menu backend", function()
        showDialog = function()
            props.category = "people"
            props.overall, props.portrait_skin, props.sky, props.style = "polished", true, "blue", "cn13"
            return "ok"
        end
        run()
        assert.are.equal(1, #starts)
        assert.are.same({ 7, 9 }, starts[1].photo_ids)
        assert.are.same({ "polished", "skin", "blue", "cn13" }, starts[1].recipe.presetUuids)
        assert.are.equal("people", starts[1].recipe.category)
        assert.is_true(starts[1].config.denoise.enabled)
        assert.is_false(starts[1].force)
    end)

    it("restores preset identity and favorites after a runtime UUID changes", function()
        state.lastCategory = "people"
        state.categories.people = { style = "old-cn13" }
        state.favorites["old-cn13"] = true
        state.identities["old-cn13"] = "premium/style - cinematic ii/cn13.xmp"
        showDialog = function()
            assert.are.equal("cn13", props.style)
            props.search = "nonmatching search"
            assert.are.equal("cn13", props.style)
            assert.are.equal("cn13", props.styleItems[2].value)
            return "other"
        end
        run()
        assert.is_true(saved[1].favorites.cn13)
    end)
end)
