return {
    LrSdkVersion = 15.0,
    LrSdkMinimumVersion = 15.0,

    LrToolkitIdentifier = 'com.lightroom.mcp',
    LrPluginName = LOC "$$$/LightroomAIBatch/PluginName=Lightroom AI Batch",

    VERSION = { major=1, minor=1, revision=0, build=0 },

    LrPluginInfoProvider = 'PluginInfoProvider.lua',
    LrMetadataProvider = 'MetadataProvider.lua',
    LrInitPlugin = 'PluginInit.lua',
    -- LrForceInitPlugin forces eager load on Lr launch, but ONLY if the
    -- plugin also exposes at least one menu item. LrExportMenuItems places
    -- these commands under File > Plug-in Extras on both Windows and macOS.
    LrForceInitPlugin = true,

    LrExportMenuItems = {
        {
            title = LOC "$$$/LightroomAIBatch/Menu/Workbench=AI Batch — Workbench...",
            file = "MenuAIBatchWorkbench.lua",
        },
    },
}
