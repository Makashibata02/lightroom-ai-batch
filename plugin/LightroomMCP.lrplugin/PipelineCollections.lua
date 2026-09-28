local PipelineCollections = {}

local function findSet(catalog, name)
    for _, set in ipairs(catalog:getChildCollectionSets()) do
        if set:getName() == name then return set end
    end
    return nil
end

local function findChild(set, name)
    for _, collection in ipairs(set:getChildCollections()) do
        if collection:getName() == name then return collection end
    end
    return nil
end

local function collectionNames(processedPath)
    local setName, processedName = tostring(processedPath or ""):match("^%s*(.-)%s*/%s*([^/]+)%s*$")
    if not setName or setName == "" then setName = "AI Pipeline" end
    if not processedName or processedName == "" then processedName = "Processed" end
    return setName, processedName
end

function PipelineCollections.ensure(catalog, processedPath)
    local out = {}
    local setName, processedName = collectionNames(processedPath)
    local set = findSet(catalog, setName)
    if not set then
        catalog:withWriteAccessDo(
            LOC "$$$/LightroomAIBatch/History/CreateCollectionSet=Create AI Pipeline Collection Set",
            function()
                catalog:createCollectionSet(setName, nil, true)
            end)
        -- Lightroom forbids reading collection information in the same write
        -- gate that created the collection set, so reacquire it afterwards.
        set = findSet(catalog, setName)
    end
    if not set then error("Could not create collection set: " .. setName) end

    out.Processed = findChild(set, processedName)
    out.Failed = findChild(set, "Failed")
    out.Skipped = findChild(set, "Skipped")
    if not out.Processed or not out.Failed or not out.Skipped then
        catalog:withWriteAccessDo(
            LOC "$$$/LightroomAIBatch/History/CreateCollections=Create AI Pipeline Collections",
            function()
                if not out.Processed then
                    out.Processed = catalog:createCollection(processedName, set, true)
                end
                if not out.Failed then out.Failed = catalog:createCollection("Failed", set, true) end
                if not out.Skipped then out.Skipped = catalog:createCollection("Skipped", set, true) end
            end)
    end
    return out
end

function PipelineCollections.add(catalog, collections, name, photo)
    local collection = collections and collections[name]
    if not collection then return false end
    catalog:withWriteAccessDo(
        LOC("$$$/LightroomAIBatch/History/MarkCollection=Mark AI Pipeline ^1", name),
        function()
            collection:addPhotos({ photo })
        end)
    return true
end

return PipelineCollections
