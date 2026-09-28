local LrPathUtils = import 'LrPathUtils'

local JSON = require 'JSON'

local PipelineConfig = {}

local DEFAULTS = {
    pipelineVersion = "1.0.0",
    denoise = { enabled = true, amount = 50, timeoutSeconds = 900 },
    autoTone = { enabled = true },
    subjectPreset = { enabled = true, uuid = "" },
    landscape = {
        enabled = true,
        features = {
            "Sky", "Snow", "Architecture", "Vegetation", "Water",
            "Natural Ground", "Artificial Ground", "Mountains",
        },
        timeoutSeconds = 900,
    },
    skipProcessed = true,
    force = false,
    processedCollection = "AI Pipeline / Processed",
    pollIntervalSeconds = 0.25,
}

local function clone(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do out[key] = clone(item) end
    return out
end

local function merge(target, source)
    if type(source) ~= "table" then return target end
    for key, value in pairs(source) do
        if type(value) == "table" and type(target[key]) == "table" then
            local isArray = value[1] ~= nil
            if isArray then
                target[key] = clone(value)
            else
                merge(target[key], value)
            end
        else
            target[key] = value
        end
    end
    return target
end

local function configPath()
    return LrPathUtils.child(LrPathUtils.child(_PLUGIN.path, "config"), "pipeline.json")
end

local function readJson(path)
    local fh = io.open(path, "r")
    if not fh then return nil end
    local text = fh:read("*a")
    fh:close()
    local ok, decoded = pcall(function() return JSON:decode(text) end)
    if not ok or type(decoded) ~= "table" then
        error("Invalid pipeline config JSON: " .. tostring(decoded))
    end
    return decoded
end

local function validate(config)
    if type(config.skipProcessed) ~= "boolean" then error("skipProcessed must be boolean") end
    if type(config.force) ~= "boolean" then error("force must be boolean") end
    if type(config.denoise.enabled) ~= "boolean" then error("denoise.enabled must be boolean") end
    if type(config.autoTone.enabled) ~= "boolean" then error("autoTone.enabled must be boolean") end
    if type(config.subjectPreset.enabled) ~= "boolean" then error("subjectPreset.enabled must be boolean") end
    if type(config.landscape.enabled) ~= "boolean" then error("landscape.enabled must be boolean") end
    config.denoise.amount = tonumber(config.denoise.amount) or 50
    if config.denoise.amount < 0 or config.denoise.amount > 100 then
        error("denoise.amount must be between 0 and 100")
    end
    config.denoise.timeoutSeconds = tonumber(config.denoise.timeoutSeconds) or 900
    config.landscape.timeoutSeconds = tonumber(config.landscape.timeoutSeconds) or 900
    if config.denoise.timeoutSeconds <= 0 then error("denoise.timeoutSeconds must be positive") end
    if config.landscape.timeoutSeconds <= 0 then error("landscape.timeoutSeconds must be positive") end
    config.pollIntervalSeconds = tonumber(config.pollIntervalSeconds) or 0.25
    if config.pollIntervalSeconds < 0.05 or config.pollIntervalSeconds > 5 then
        error("pollIntervalSeconds must be between 0.05 and 5")
    end
    if type(config.landscape.features) ~= "table" then
        error("landscape.features must be an array")
    end
    if config.landscape.features[1] == nil then error("landscape.features cannot be empty") end
    if type(config.processedCollection) ~= "string" or config.processedCollection == "" then
        error("processedCollection is required")
    end
    return config
end

function PipelineConfig.load(overrides)
    local config = clone(DEFAULTS)
    local fromDisk = readJson(configPath())
    if fromDisk then merge(config, fromDisk) end
    if type(overrides) == "table" then merge(config, overrides) end
    return validate(config)
end

local function writeConfig(config)
    local path = configPath()
    local fh, err = io.open(path, "w")
    if not fh then return false, tostring(err) end
    local ok, encoded = pcall(function() return JSON:encode(config) end)
    if not ok then
        fh:close()
        return false, tostring(encoded)
    end
    fh:write(encoded)
    fh:close()
    return true
end

function PipelineConfig.save(config)
    return writeConfig(validate(clone(config)))
end

function PipelineConfig.saveSubjectUuid(uuid)
    if type(uuid) ~= "string" or uuid == "" then return false, "preset UUID is required" end
    -- Load the user's persistent file without any per-job overrides, then
    -- update only the discovered identity. Saving the active job config would
    -- accidentally persist force/skipProcessed and stage overrides.
    local persistent = clone(DEFAULTS)
    local fromDisk = readJson(configPath())
    if fromDisk then merge(persistent, fromDisk) end
    persistent.subjectPreset.uuid = uuid
    return writeConfig(validate(persistent))
end

function PipelineConfig.defaults()
    return clone(DEFAULTS)
end

function PipelineConfig.path()
    return configPath()
end

return PipelineConfig
