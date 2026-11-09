require 'spec_helper'

describe("Workbench settings persistence", function()
    local files, loadModule
    before_each(function()
        files = {}
        local modules = {
            LrPathUtils = { getStandardFilePath = function() return "test-home" end,
                child = function(a, b) return a .. "/" .. b end, parent = function(p) return p:match("(.+)/") end },
            LrFileUtils = { createAllDirectories = function() end,
                exists = function(p) return files[p] ~= nil end,
                delete = function(p) files[p] = nil end,
                move = function(a, b) if not files[a] then return false end; files[b] = files[a]; files[a] = nil; return true end },
        }
        local env = setmetatable({ import = function(name) return modules[name] end, io = {
            open = function(path, mode)
                if mode == "r" then
                    if not files[path] then return nil end
                    return { read = function() return files[path] end, close = function() end }
                end
                files[path] = ""
                return { write = function(_, text) files[path] = files[path] .. text end, close = function() end }
            end,
        } }, { __index = _G })
        loadModule = function()
            return assert(loadfile("plugin/LightroomMCP.lrplugin/WorkbenchState.lua", "t", env))()
        end
    end)

    it("retains category recipes, favorites and identities across module reloads", function()
        local module = loadModule()
        local state = module.load()
        state.categories.people = { style = "cn13", denoise = false }
        state.favorites.cn13 = true
        state.identities.cn13 = "premium/style - cinematic ii/cn13.xmp"
        module.save(state)
        local loaded = loadModule().load()
        assert.are.same(state, loaded)
        assert.is_nil(files["test-plugin/config/pipeline.json"])
    end)

    it("recovers the previous complete generation instead of discarding saved recipes", function()
        local module = loadModule()
        local state = module.load()
        state.categories.people = { style = "cn13" }
        module.save(state)
        state.categories.food = { style = "food-look" }
        module.save(state)
        files[module.path()] = "broken JSON"
        assert.are.equal("cn13", loadModule().load().categories.people.style)
    end)
end)
