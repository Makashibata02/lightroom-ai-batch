local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local JSON = require 'JSON'

local WorkbenchState = {}

function WorkbenchState.path()
    local root = LrPathUtils.child(LrPathUtils.child(LrPathUtils.getStandardFilePath("home"),
        ".config"), "lightroom-ai-batch")
    return LrPathUtils.child(root, "workbench.json")
end

local function read(path)
    local fh = io.open(path, "r")
    if not fh then return nil end
    local data = fh:read("*a")
    fh:close()
    local ok, state = pcall(function() return JSON:decode(data) end)
    if ok and type(state) == "table" and state.version == 1 and type(state.categories) == "table" then
        state.favorites = state.favorites or {}
        state.identities = state.identities or {}
        return state
    end
end

function WorkbenchState.load()
    local path = WorkbenchState.path()
    local state = read(path) or read(path .. ".previous")
    if state then return state end
    if LrFileUtils.exists(path) or LrFileUtils.exists(path .. ".previous") then
        error("Cannot read workbench settings: " .. path)
    end
    return { version = 1, lastCategory = "animals", categories = {}, favorites = {}, identities = {} }
end

function WorkbenchState.save(state)
    local path = WorkbenchState.path()
    LrFileUtils.createAllDirectories(LrPathUtils.parent(path))
    local encoded = JSON:encode(state)
    local fh, err = io.open(path .. ".tmp", "w")
    if not fh then error(tostring(err)) end
    fh:write(encoded)
    fh:close()
    local previous, exists = path .. ".previous", LrFileUtils.exists(path)
    if exists then
        if LrFileUtils.exists(previous) then LrFileUtils.delete(previous) end
        if not LrFileUtils.move(path, previous) then error("Cannot back up workbench settings") end
    end
    if not LrFileUtils.move(path .. ".tmp", path) then
        if exists then LrFileUtils.move(previous, path) end
        error("Cannot save workbench settings")
    end
end

return WorkbenchState
