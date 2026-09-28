local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'

local JSON = require 'JSON'

local PipelineState = {}

local function rootDir()
    local home = LrPathUtils.getStandardFilePath("home")
    return LrPathUtils.child(LrPathUtils.child(home, ".config"), "lightroom-ai-batch")
end

local function statePath()
    return LrPathUtils.child(rootDir(), "pipeline-state.json")
end

local function readState()
    local fh = io.open(statePath(), "r")
    if not fh then return { version = 1, photos = {} } end
    local text = fh:read("*a")
    fh:close()
    local ok, decoded = pcall(function() return JSON:decode(text) end)
    if not ok or type(decoded) ~= "table" then return { version = 1, photos = {} } end
    decoded.photos = decoded.photos or {}
    return decoded
end

if not _G.LightroomAIBatchPipelineState then
    _G.LightroomAIBatchPipelineState = readState()
end
local state = _G.LightroomAIBatchPipelineState

local function catalogPath(catalog)
    local ok, value = pcall(function() return catalog:getPath() end)
    if ok and type(value) == "string" and value ~= "" then return value end
    return "active-catalog"
end

local function photoPath(photo)
    local ok, value = pcall(function() return photo:getRawMetadata("path") end)
    if ok and type(value) == "string" then return value end
    return ""
end

local function keyFor(catalog, photo)
    return catalogPath(catalog) .. "::" .. tostring(photo.localIdentifier) .. "::" .. photoPath(photo)
end

local function persist()
    LrFileUtils.createAllDirectories(rootDir())
    local path = statePath()
    local tmp = path .. ".tmp"
    local ok, encoded = pcall(function() return JSON:encode(state) end)
    if not ok then return false, tostring(encoded) end
    local fh, err = io.open(tmp, "w")
    if not fh then return false, tostring(err) end
    fh:write(encoded)
    fh:close()
    if LrFileUtils.exists(path) then LrFileUtils.delete(path) end
    if not LrFileUtils.move(tmp, path) then return false, "could not replace " .. path end
    return true
end

function PipelineState.get(catalog, photo)
    return state.photos[keyFor(catalog, photo)]
end

function PipelineState.update(catalog, photo, values)
    local key = keyFor(catalog, photo)
    local item = state.photos[key] or {
        catalogPath = catalogPath(catalog),
        photoId = photo.localIdentifier,
        path = photoPath(photo),
    }
    for field, value in pairs(values) do item[field] = value end
    item.updatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ")
    state.photos[key] = item
    return persist()
end

function PipelineState.path()
    return statePath()
end

return PipelineState
