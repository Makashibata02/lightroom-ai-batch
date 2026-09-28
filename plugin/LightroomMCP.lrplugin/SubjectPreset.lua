local LrApplication = import 'LrApplication'
local LrPathUtils = import 'LrPathUtils'

local PipelineConfig = require 'PipelineConfig'

local SubjectPreset = {}

local function normalized(path)
    if type(path) ~= "string" then return "" end
    return path:gsub("\\", "/"):lower()
end

local function findByUuid(uuid)
    if type(uuid) ~= "string" or uuid == "" then return nil end
    for _, folder in ipairs(LrApplication.developPresetFolders()) do
        for _, preset in ipairs(folder:getDevelopPresets()) do
            if preset:getUuid() == uuid then return preset end
        end
    end
    return nil
end

local function discoverPop()
    local matches = {}
    for _, folder in ipairs(LrApplication.developPresetFolders()) do
        for _, preset in ipairs(folder:getDevelopPresets()) do
            local file = preset:getFile()
            local path = normalized(file)
            local leaf = normalized(LrPathUtils.leafName(file or ""))
            if leaf == "pop.xmp" and path:find("/adaptive %- subject/", 1, false) then
                table.insert(matches, preset)
            end
        end
    end
    if #matches == 1 then return matches[1] end
    if #matches == 0 then
        return nil, "Adaptive Subject / Pop preset was not found by backing-file identity"
    end
    return nil, "Adaptive Subject / Pop preset identity is ambiguous"
end

function SubjectPreset.resolve(config)
    local uuid = config.subjectPreset and config.subjectPreset.uuid or ""
    local preset = findByUuid(uuid)
    if preset then return preset end

    local err
    preset, err = discoverPop()
    if not preset then return nil, err end

    config.subjectPreset.uuid = preset:getUuid()
    local saved, saveErr = PipelineConfig.saveSubjectUuid(config.subjectPreset.uuid)
    if not saved then
        return preset, "Preset found, but UUID could not be saved: " .. tostring(saveErr)
    end
    return preset
end

return SubjectPreset
