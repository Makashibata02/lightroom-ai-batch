local LrApplication = import 'LrApplication'
local LrBinding = import 'LrBinding'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local HandlerBatch = require 'HandlerBatch'
local MenuBatchCommon = require 'MenuBatchCommon'
local PipelineConfig = require 'PipelineConfig'
local RecipePresets = require 'RecipePresets'
local WorkbenchState = require 'WorkbenchState'

local Workbench = {}
local opened = false
local TITLE = LOC "$$$/LightroomAIBatch/Menu/Workbench=AI Batch — Workbench..."
local NONE = LOC "$$$/LightroomAIBatch/Workbench/None=None"
local OVERALL = { ["Enhance Portrait.xmp"] = true, ["Polished Portrait.xmp"] = true,
    ["Glamour Portrait.xmp"] = true, ["Gritty Portrait.xmp"] = true }
local CATEGORY_NAMES = {
    animals = LOC "$$$/LightroomAIBatch/Workbench/Animals=Animals",
    people = LOC "$$$/LightroomAIBatch/Workbench/People=People",
    street = LOC "$$$/LightroomAIBatch/Workbench/Street=Street",
    landscape = LOC "$$$/LightroomAIBatch/Workbench/Landscape=Landscape",
    food = LOC "$$$/LightroomAIBatch/Workbench/Food=Food",
}
local FEATURE_NAMES = {
    Sky = LOC "$$$/LightroomAIBatch/Workbench/Sky=Sky",
    Snow = LOC "$$$/LightroomAIBatch/Workbench/Snow=Snow",
    Architecture = LOC "$$$/LightroomAIBatch/Workbench/Architecture=Architecture",
    Vegetation = LOC "$$$/LightroomAIBatch/Workbench/Vegetation=Vegetation",
    Water = LOC "$$$/LightroomAIBatch/Workbench/Water=Water",
    ["Natural Ground"] = LOC "$$$/LightroomAIBatch/Workbench/NaturalGround=Natural Ground",
    ["Artificial Ground"] = LOC "$$$/LightroomAIBatch/Workbench/ArtificialGround=Artificial Ground",
    Mountains = LOC "$$$/LightroomAIBatch/Workbench/Mountains=Mountains",
}
local FEATURES = { "Sky", "Snow", "Architecture", "Vegetation", "Water",
    "Natural Ground", "Artificial Ground", "Mountains" }

local function isOverall(entry)
    return OVERALL[(entry.file or ""):gsub("\\", "/"):match("([^/]+)$")] == true
end

function Workbench.arguments(category, selection, entries)
    local byUuid, presets = {}, {}
    for _, entry in ipairs(entries) do byUuid[entry.uuid] = entry end
    local function add(uuid, kind)
        if uuid and uuid ~= "" then
            local entry = byUuid[uuid]
            if not entry or entry.kind ~= kind then error("Preset unavailable: " .. uuid) end
            presets[#presets + 1] = uuid
        end
    end
    add(selection.overall, "portrait")
    for _, entry in ipairs(entries) do
        if entry.kind == "portrait" and selection.portraits[entry.uuid] then add(entry.uuid, "portrait") end
    end
    add(selection.sky, "sky")
    add(selection.style, "style")
    local features = {}
    for _, feature in ipairs(FEATURES) do
        if selection.features[feature] then features[#features + 1] = feature end
    end
    if selection.landscape and #features == 0 then error(LOC "$$$/LightroomAIBatch/Workbench/FeatureRequired=Select at least one Landscape category.") end
    local subject = selection.subject
    if subject ~= "default" and subject ~= "" then
        if not byUuid[subject] or byUuid[subject].kind ~= "subject" then error("Subject preset unavailable") end
    end
    local config = {
        denoise = { enabled = selection.denoise, amount = tonumber(selection.amount) },
        autoTone = { enabled = selection.autoTone },
        subjectPreset = { enabled = subject ~= "" },
        landscape = { enabled = selection.landscape },
    }
    if selection.amount == nil or not tonumber(selection.amount) then error("Denoise amount is required") end
    if subject ~= "default" then config.subjectPreset.uuid = subject end
    if #features > 0 then config.landscape.features = features end
    return { profile = "configured", config = config, force = selection.force == true,
        skipProcessed = selection.skipProcessed, recipe = { category = category, presetUuids = presets } }
end

local function dialog(context)
    local activeId = HandlerBatch.preferredJobId()
    if activeId then
        local job = HandlerBatch.status({ jobId = activeId })
        if job.workerRunning or job.activeOperation then MenuBatchCommon.showLastStatus(); return end
    end
    local catalog = LrApplication.activeCatalog()
    local photos = catalog:getTargetPhotos() or {}
    local ids = {}
    for _, photo in ipairs(photos) do ids[#ids + 1] = photo.localIdentifier end
    local entries, base, state = RecipePresets.list(), PipelineConfig.load(), WorkbenchState.load()
    local byUuid, byIdentity = {}, {}
    local subjects = { { title = NONE, value = "" },
        { title = LOC "$$$/LightroomAIBatch/Workbench/ConfiguredSubject=Configured Subject preset (default: Pop)", value = "default" } }
    local overall, skies, details = { { title = NONE, value = "" } }, { { title = NONE, value = "" } }, {}
    for _, entry in ipairs(entries) do
        byUuid[entry.uuid], byIdentity[entry.identity] = entry, entry
        if entry.kind == "subject" then subjects[#subjects + 1] = { title = entry.name, value = entry.uuid }
        elseif entry.kind == "sky" then skies[#skies + 1] = { title = entry.name, value = entry.uuid }
        elseif entry.kind == "portrait" then
            if isOverall(entry) then overall[#overall + 1] = { title = entry.name, value = entry.uuid }
            else details[#details + 1] = entry end
        end
        if not state.initialized and entry.isCN13 then state.favorites[entry.uuid] = true end
    end
    state.initialized = true
    local remappedFavorites = {}
    for uuid, enabled in pairs(state.favorites) do
        local entry = byUuid[uuid] or byIdentity[state.identities[uuid]]
        remappedFavorites[entry and entry.uuid or uuid] = enabled
    end
    state.favorites = remappedFavorites
    local p = LrBinding.makePropertyTable(context)
    local f, bind = LrView.osFactory(), LrView.bind
    p.category = CATEGORY_NAMES[state.lastCategory] and state.lastCategory or "animals"
    p.search = ""
    local currentCategory = p.category
    local function collect()
        local selected = { denoise = p.denoise, amount = p.amount, autoTone = p.autoTone,
            subject = p.subject, landscape = p.landscape, overall = p.overall, sky = p.sky,
            style = p.style, portraits = {}, features = {}, skipProcessed = p.skipProcessed }
        for _, entry in ipairs(details) do selected.portraits[entry.uuid] = p["portrait_" .. entry.uuid] == true end
        for _, feature in ipairs(FEATURES) do selected.features[feature] = p["feature_" .. feature] == true end
        return selected
    end
    local function restoreUuid(uuid, missing)
        if not uuid or uuid == "" or uuid == "default" then return uuid or "" end
        if byUuid[uuid] then return uuid end
        local entry = byIdentity[state.identities[uuid]]
        if entry then return entry.uuid end
        missing[#missing + 1] = state.identities[uuid] or uuid
        return ""
    end
    local function loadCategory(category)
        local saved, missing = state.categories[category] or {}, {}
        local function value(key, default)
            if saved[key] == nil then return default end
            return saved[key]
        end
        p.denoise = value("denoise", base.denoise.enabled)
        p.amount = saved.amount or base.denoise.amount
        p.autoTone = value("autoTone", base.autoTone.enabled)
        p.landscape = value("landscape", base.landscape.enabled)
        p.skipProcessed = value("skipProcessed", base.skipProcessed)
        p.subject = restoreUuid(saved.subject or (base.subjectPreset.enabled and "default" or ""), missing)
        p.overall, p.sky, p.style = restoreUuid(saved.overall, missing), restoreUuid(saved.sky, missing), restoreUuid(saved.style, missing)
        local portraitChoices = {}
        for uuid, enabled in pairs(saved.portraits or {}) do
            if enabled then portraitChoices[restoreUuid(uuid, missing)] = true end
        end
        for _, entry in ipairs(details) do p["portrait_" .. entry.uuid] = portraitChoices[entry.uuid] == true end
        local features = saved.features
        if not features then
            features = {}
            for _, feature in ipairs(base.landscape.features) do features[feature] = true end
        end
        for _, feature in ipairs(FEATURES) do p["feature_" .. feature] = features[feature] == true end
        p.force = false
        if #missing > 0 then
            LrDialogs.message(TITLE, LOC("$$$/LightroomAIBatch/Workbench/MissingPresets=Saved presets are unavailable and have been deselected. Review the recipe before starting:^n^1", table.concat(missing, "\n")), "warning")
        end
    end
    loadCategory(currentCategory)
    local function updateStyles()
        local favorites, rest = {}, {}
        local query = (p.search or ""):lower()
        for _, entry in ipairs(entries) do
            if entry.kind == "style" and (entry.uuid == p.style or
                ((entry.folder or "") .. " / " .. (entry.name or "")):lower():find(query, 1, true)) then
                local favorite = state.favorites[entry.uuid]
                local item = { title = (favorite and "* " or "") .. (entry.folder or "") .. " / " .. entry.name, value = entry.uuid }
                local target = favorite and favorites or rest
                target[#target + 1] = item
            end
        end
        local items = { { title = NONE, value = "" } }
        for _, item in ipairs(favorites) do items[#items + 1] = item end
        for _, item in ipairs(rest) do items[#items + 1] = item end
        p.styleItems = items
        local entry = byUuid[p.style]
        p.styleImpact = entry and (entry.isCN13 and
            LOC "$$$/LightroomAIBatch/Workbench/CN13Impact=CN13 changes color/HSL, curves, sharpening and traditional noise reduction. Genuine AI Denoise is validated separately." or
            LOC("$$$/LightroomAIBatch/Workbench/PresetImpact=Preset settings (first 20): ^1", table.concat(entry.settingsKeys, ", ", 1, math.min(20, #entry.settingsKeys)))) or ""
    end
    updateStyles()
    p:addObserver("category", function(_, _, value)
        state.categories[currentCategory] = collect()
        currentCategory = value
        loadCategory(value)
        updateStyles()
    end)
    p:addObserver("search", updateStyles)
    p:addObserver("style", updateStyles)
    local function check(key, title, extra)
        local args = { title = title, value = bind(key) }
        for k, v in pairs(extra or {}) do args[k] = v end
        return f:checkbox(args)
    end
    local function popup(title, key, items)
        return f:row { f:static_text { title = title, width = 150 },
            f:popup_menu { value = bind(key), items = items, width = 390 } }
    end
    local featureRows = {}
    for row = 0, 1 do
        local controls = {}
        for column = 1, 4 do
            local feature = FEATURES[row * 4 + column]
            controls[#controls + 1] = check("feature_" .. feature, FEATURE_NAMES[feature], { width = 145, enabled = bind("landscape") })
        end
        featureRows[#featureRows + 1] = f:row(controls)
    end
    local portraitRows = {}
    for i = 1, #details, 2 do
        local row = { check("portrait_" .. details[i].uuid, details[i].name, { width = 280 }) }
        if details[i + 1] then row[#row + 1] = check("portrait_" .. details[i + 1].uuid, details[i + 1].name, { width = 280 }) end
        portraitRows[#portraitRows + 1] = f:row(row)
    end
    local categoryItems = {}
    for _, category in ipairs(RecipePresets.categories) do categoryItems[#categoryItems + 1] = { title = CATEGORY_NAMES[category], value = category } end
    local contents = f:column {
        bind_to_object = p, spacing = 10,
        f:static_text { title = LOC("$$$/LightroomAIBatch/Workbench/Selected=Selected photos: ^1. Each category remembers its last saved recipe.", tostring(#ids)), width = 610, height_in_lines = 2 },
        popup(LOC "$$$/LightroomAIBatch/Workbench/Category=Category", "category", categoryItems),
        f:tab_view {
            f:tab_view_item { title = LOC "$$$/LightroomAIBatch/Workbench/Basic=Basic preparation", identifier = "basic",
                f:column { spacing = 8,
                    f:row { check("denoise", LOC "$$$/LightroomAIBatch/Workbench/Denoise=AI Denoise"),
                        f:static_text { title = LOC "$$$/LightroomAIBatch/Workbench/Amount=Amount" },
                        f:edit_field { value = bind("amount"), width_in_chars = 5, enabled = bind("denoise") } },
                    check("autoTone", LOC "$$$/LightroomAIBatch/Workbench/AutoTone=Independent Auto Tone on every photo"),
                    popup(LOC "$$$/LightroomAIBatch/Workbench/Subject=Subject", "subject", subjects),
                    check("landscape", LOC "$$$/LightroomAIBatch/Workbench/SeparateMasks=Separate neutral Landscape masks"),
                    f:column(featureRows),
                } },
            f:tab_view_item { title = LOC "$$$/LightroomAIBatch/Workbench/Adaptive=Portrait and sky", identifier = "adaptive",
                f:column { spacing = 8,
                    popup(LOC "$$$/LightroomAIBatch/Workbench/Overall=Overall portrait", "overall", overall),
                    f:column(portraitRows),
                    f:static_text { title = LOC "$$$/LightroomAIBatch/Workbench/Overlap=Overall portrait recipes may already enhance skin, eyes and hair. Additional detail presets can strengthen the same areas.", width = 610, height_in_lines = 2 },
                    popup(FEATURE_NAMES.Sky, "sky", skies),
                } },
            f:tab_view_item { title = LOC "$$$/LightroomAIBatch/Workbench/Style=Style preset", identifier = "style",
                f:column { spacing = 8,
                    f:row { f:static_text { title = LOC "$$$/LightroomAIBatch/Workbench/Search=Search" },
                        f:edit_field { value = bind("search"), immediate = true, width_in_chars = 35 } },
                    f:popup_menu { value = bind("style"), items = bind("styleItems"), width = 600 },
                    f:push_button { title = LOC "$$$/LightroomAIBatch/Workbench/Favorite=Toggle favorite", action = function()
                        if p.style ~= "" then state.favorites[p.style] = not state.favorites[p.style]; updateStyles() end
                    end },
                    f:static_text { title = bind("styleImpact"), width = 610, height_in_lines = 4 },
                } },
        },
        f:static_text { title = LOC "$$$/LightroomAIBatch/Workbench/Incremental=These are actions to apply. Deselecting a module does not undo earlier edits. AI presets are recalculated for each photo.", width = 610, height_in_lines = 2 },
        f:static_text { title = LOC "$$$/LightroomAIBatch/Workbench/PresetGroups=Missing Subject or Portrait options? Enable Adaptive: Subject and Adaptive: Portrait in Lightroom's Presets + > Manage Presets, then reopen the workbench.", width = 610, height_in_lines = 2 },
        f:row { check("skipProcessed", LOC "$$$/LightroomAIBatch/Workbench/Skip=Skip fully completed photos"),
            check("force", LOC "$$$/LightroomAIBatch/Workbench/Force=Force rerun (may reapply masks)") },
        f:row {
            f:push_button { title = LOC "$$$/LightroomAIBatch/Workbench/Status=Show batch status", action = function(button) LrDialogs.stopModalWithResult(button, "status") end },
            f:push_button { title = LOC "$$$/LightroomAIBatch/Workbench/Cancel=Cancel batch", action = function(button) LrDialogs.stopModalWithResult(button, "cancelJob") end },
        },
    }
    while true do
        local result = LrDialogs.presentModalDialog { title = TITLE, contents = contents,
            actionVerb = LOC "$$$/LightroomAIBatch/Workbench/Start=Start batch",
            otherVerb = LOC "$$$/LightroomAIBatch/Workbench/Save=Save recipes", resizable = false }
        if result == "status" then MenuBatchCommon.showLastStatus(); return end
        if result == "cancelJob" then MenuBatchCommon.cancelLast(); return end
        if result ~= "ok" and result ~= "other" then return end
        local selected = collect()
        selected.force = p.force
        local ok, args = LrTasks.pcall(function()
            local request = Workbench.arguments(currentCategory, selected, entries)
            PipelineConfig.load(request.config)
            RecipePresets.resolve(request.recipe)
            return request
        end)
        if ok then
            selected.force = nil
            state.categories[currentCategory], state.lastCategory = selected, currentCategory
            for _, entry in ipairs(entries) do state.identities[entry.uuid] = entry.identity end
            WorkbenchState.save(state)
            if result == "ok" then
                if LrApplication.activeCatalog() ~= catalog then error("Active catalog changed while the workbench was open") end
                args.photo_ids = ids
                MenuBatchCommon.start(TITLE, args)
            else LrDialogs.message(TITLE, LOC "$$$/LightroomAIBatch/Workbench/Saved=Recipes saved.", "info") end
            return
        end
        LrDialogs.message(TITLE, tostring(args), "warning")
    end
end

function Workbench.show()
    if opened then return end
    opened = true
    LrFunctionContext.postAsyncTaskWithContext("LightroomAIBatchWorkbench", function(context)
        context:addCleanupHandler(function() opened = false end)
        local ok, err = LrTasks.pcall(function() dialog(context) end)
        if not ok then LrDialogs.message(TITLE, tostring(err), "critical") end
    end)
end

return Workbench
