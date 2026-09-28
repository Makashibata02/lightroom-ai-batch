return {
    LrSdkVersion = 15.0,
    LrSdkMinimumVersion = 15.0,

    LrToolkitIdentifier = 'com.lightroom.mcp',
    LrPluginName = LOC "$$$/LightroomAIBatch/PluginName=Lightroom AI Batch",

    VERSION = { major=1, minor=0, revision=0, build=0 },

    LrPluginInfoProvider = 'PluginInfoProvider.lua',
    LrMetadataProvider = 'MetadataProvider.lua',
    LrInitPlugin = 'PluginInit.lua',
    -- LrForceInitPlugin forces eager load on Lr launch, but ONLY if the
    -- plugin also exposes at least one menu item. LrExportMenuItems places
    -- these commands under File > Plug-in Extras on both Windows and macOS.
    LrForceInitPlugin = true,

    LrExportMenuItems = {
        {
            title = LOC "$$$/LightroomAIBatch/Menu/ShowStatus=Lightroom AI Batch — Show MCP Status",
            file = "MenuShowStatus.lua",
        },
        {
            title = LOC "$$$/LightroomAIBatch/Menu/DenoiseSelected=AI Batch — Denoise Selected",
            file = "MenuAIBatchDenoise.lua",
        },
        {
            title = LOC "$$$/LightroomAIBatch/Menu/FullPrepareSelected=AI Batch — Full Prepare Selected",
            file = "MenuAIBatchPrepare.lua",
        },
        {
            title = LOC "$$$/LightroomAIBatch/Menu/ShowLastJob=AI Batch — Show Last Job Status",
            file = "MenuAIBatchStatus.lua",
        },
        {
            title = LOC "$$$/LightroomAIBatch/Menu/CancelLastJob=AI Batch — Cancel Last Job",
            file = "MenuAIBatchCancel.lua",
        },
    },
}
