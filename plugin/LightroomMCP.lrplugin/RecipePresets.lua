local JSON = require 'JSON'

local RecipePresets = {}

RecipePresets.categories = { "animals", "people", "street", "landscape", "food" }

function RecipePresets.identity(file)
    local path = (file or ""):gsub("\\", "/"):lower()
    return path:match("/settings/(.+)$") or path
end

function RecipePresets.isPop(preset)
    local path = RecipePresets.identity(preset:getFile())
    return path:find("/adaptive - subject/pop.xmp", 1, true) ~= nil
end

local function kindOf(entry, settings)
    local identity = RecipePresets.identity(entry.file)
    for _, kind in ipairs({ "subject", "portrait", "sky" }) do
        if identity:find("/adaptive - " .. kind .. "/", 1, true) then return kind end
    end
    if identity:find("/adaptive - ", 1, true)
        or (type(settings.MaskGroupBasedCorrections) == "table" and next(settings.MaskGroupBasedCorrections))
        or (type(settings.FilterList) == "table" and next(settings.FilterList)) then return "unsupported" end
    return "style"
end

function RecipePresets.changesGlobal(entry)
    local metadata = { Version = true, ProcessVersion = true, CompatibleVersion = true,
        HasSettings = true, PresetType = true, UUID = true, Cluster = true,
        Copyright = true, ContactInfo = true, CameraModelRestriction = true, RequiresRGBTables = true,
        MaskGroupBasedCorrections = true, FilterList = true }
    for _, key in ipairs(entry.settingsKeys) do
        if not metadata[key] and not key:match("^Supports") then return true end
    end
    return false
end

function RecipePresets.list()
    local DevelopHandler = require 'HandlerDevelop'
    local entries, seen = {}, {}
    for _, entry in ipairs(DevelopHandler.presetEntries()) do
        if type(entry.uuid) == "string" and entry.uuid ~= "" and not seen[entry.uuid] then
            seen[entry.uuid] = true
            local ok, settings = pcall(function() return entry.preset:getSetting() end)
            settings = ok and type(settings) == "table" and settings or {}
            entry.kind = kindOf(entry, settings)
            entry.identity = RecipePresets.identity(entry.file)
            entry.settingsKeys = {}
            for key in pairs(settings) do entry.settingsKeys[#entry.settingsKeys + 1] = tostring(key) end
            table.sort(entry.settingsKeys)
            entry.isCN13 = entry.identity:match("/style %- cinematic ii/cn13%.xmp$") ~= nil
            entries[#entries + 1] = entry
        end
    end
    table.sort(entries, function(a, b)
        return (a.folder or "") .. "/" .. (a.name or a.uuid) < (b.folder or "") .. "/" .. (b.name or b.uuid)
    end)
    return entries
end

function RecipePresets.resolve(recipe)
    if recipe == nil then return nil, {} end
    if type(recipe) ~= "table" then error("recipe must be an object") end
    local categoryFound = false
    for _, category in ipairs(RecipePresets.categories) do
        if recipe.category == category then categoryFound = true end
    end
    if not categoryFound then error("recipe.category must be animals, people, street, landscape, or food") end
    if type(recipe.presetUuids) ~= "table" or #recipe.presetUuids > 32 then
        error("recipe.presetUuids must be an array of at most 32 UUIDs")
    end
    for key in pairs(recipe.presetUuids) do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #recipe.presetUuids then
            error("recipe.presetUuids must be a dense array")
        end
    end
    local byUuid = {}
    for _, entry in ipairs(RecipePresets.list()) do byUuid[entry.uuid] = entry end
    local snapshot = { category = recipe.category, presetUuids = {}, presets = {} }
    local resolved, seen, styleSeen, skySeen = {}, {}, false, false
    for _, uuid in ipairs(recipe.presetUuids) do
        if type(uuid) ~= "string" or uuid == "" or seen[uuid] then error("Recipe UUIDs must be nonempty and unique") end
        local entry = byUuid[uuid]
        if not entry then error("Recipe preset not found: " .. uuid) end
        if entry.kind == "subject" then error("Select Subject presets using config.subjectPreset.uuid") end
        if entry.kind == "unsupported" then error("Unverified AI preset: " .. tostring(entry.name)) end
        if entry.kind == "sky" then
            if skySeen then error("A recipe can select only one Sky preset") end
            skySeen = true
        end
        if entry.kind == "style" then
            if styleSeen then error("A recipe can select only one style preset") end
            styleSeen = true
        elseif styleSeen then error("The style preset must be last in recipe.presetUuids") end
        seen[uuid] = true
        snapshot.presetUuids[#snapshot.presetUuids + 1] = uuid
        snapshot.presets[#snapshot.presets + 1] = { uuid = uuid, name = entry.name, kind = entry.kind,
            settingsKeys = entry.settingsKeys, isCN13 = entry.isCN13 }
        resolved[#resolved + 1] = entry
    end
    snapshot.signature = snapshot.category .. ":" .. JSON:encode(snapshot.presetUuids)
    return snapshot, resolved
end

return RecipePresets
