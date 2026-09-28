local LrApplication = import 'LrApplication'

local LandscapePreset = {}

local FEATURE_IDS = {
    ["Architecture"] = 50001,
    ["Mountains"] = 50002,
    ["Artificial Ground"] = 50003,
    ["Natural Ground"] = 50004,
    ["Vegetation"] = 50005,
    ["Sky"] = 50006,
    ["Water"] = 50007,
    ["Snow"] = 50008,
}

local function syncId(number)
    return string.format("%032X", number)
end

local function correction(feature, id)
    return {
        What = "Correction",
        CorrectionAmount = 1,
        CorrectionActive = true,
        CorrectionName = "AUTO Landscape - " .. feature,
        CorrectionSyncID = syncId(id * 2),
        LocalExposure = 0,
        LocalHue = 0,
        LocalSaturation = 0,
        LocalContrast = 0,
        LocalClarity = 0,
        LocalSharpness = 0,
        LocalBrightness = 0,
        LocalToningHue = 0,
        LocalToningSaturation = 0,
        LocalExposure2012 = 0,
        LocalContrast2012 = 0,
        LocalHighlights2012 = 0,
        LocalShadows2012 = 0,
        LocalWhites2012 = 0,
        LocalBlacks2012 = 0,
        LocalClarity2012 = 0,
        LocalDehaze = 0,
        LocalLuminanceNoise = 0,
        LocalMoire = 0,
        LocalDefringe = 0,
        LocalTemperature = 0,
        LocalTint = 0,
        LocalTexture = 0,
        LocalGrain = 0,
        LocalCorrectedDepth = 0,
        LocalCurveRefineSaturation = 100,
        CorrectionMasks = {
            {
                What = "Mask/Image",
                MaskActive = true,
                MaskName = "AUTO Landscape - " .. feature,
                MaskBlendMode = 0,
                MaskInverted = false,
                MaskSyncID = syncId(id * 2 + 1),
                MaskValue = 1,
                MaskVersion = 1,
                MaskSubType = 0,
                MaskSubCategoryID = id,
                ReferencePoint = "0.500000 0.500000",
                ErrorReason = 0,
            },
        },
    }
end

local function presetName(features)
    local parts = {}
    for _, feature in ipairs(features) do
        local id = FEATURE_IDS[feature]
        if not id then error("Unknown landscape feature: " .. tostring(feature)) end
        table.insert(parts, tostring(id))
    end
    return "AI Batch Landscape Neutral v2 - " .. table.concat(parts, "-")
end

local function findPluginPreset(name)
    local presets = LrApplication.getDevelopPresetsForPlugin(_PLUGIN) or {}
    for _, preset in ipairs(presets) do
        if preset:getName() == name then return preset end
    end
    return nil
end

function LandscapePreset.ensure(features)
    local name = presetName(features)
    local existing = findPluginPreset(name)
    if existing then return existing end

    local groups = {}
    for _, feature in ipairs(features) do
        table.insert(groups, correction(feature, FEATURE_IDS[feature]))
    end
    local settings = {
        Version = "18.0",
        CompatibleVersion = 251854848,
        ProcessVersion = "15.4",
        MaskGroupBasedCorrections = groups,
    }
    local preset = LrApplication.addDevelopPresetForPlugin(_PLUGIN, name, settings)
    if not preset then error("Lightroom rejected the neutral Landscape preset") end
    return preset
end

function LandscapePreset.featureIds()
    local out = {}
    for name, id in pairs(FEATURE_IDS) do out[name] = id end
    return out
end

return LandscapePreset
