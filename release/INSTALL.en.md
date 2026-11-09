# Lightroom AI Batch plug-in installation (Windows)

This archive contains only the Lightroom plug-in. Menu use does not require
Node.js, MCP, or an AI agent.

1. Extract the archive to a directory you will keep; do not run it from inside the ZIP.
2. Open Lightroom Classic.
3. Choose **File → Plug-in Manager**, then click **Add**.
4. Select the extracted `LightroomMCP.lrplugin` folder.
5. Reload the plug-in or restart Lightroom Classic if the menu does not refresh.
6. Select RAW photos and open the only menu entry: **File → Plug-in Extras → AI Batch — Workbench...**
7. Choose a category and configure the three tabs: Basic preparation, Portrait and sky, and Style preset (search for CN13). Save recipes only saves; Start batch submits background work.
8. Reopen the workbench during processing to refresh status or cancel. Closing status leaves the job running.

The effective default configuration is
`LightroomMCP.lrplugin\config\pipeline.json`. After the first Adaptive
Subject / Pop run, the plug-in may save the preset UUID discovered on this
computer into that file.

Back up the existing `config\pipeline.json` before upgrading. The copy in a
new release contains defaults and should not overwrite a user file containing
a discovered UUID or custom settings.
Extract upgrades to a new directory, merge custom values and the UUID into the
new configuration, then replace the old path in Plug-in Manager.

Category choices and favorites live in `~/.config/lightroom-ai-batch/workbench.json` and survive upgrades.

If Subject/Portrait choices are missing, enable Adaptive: Subject and Adaptive:
Portrait in Lightroom's Presets + → Manage Presets, then reopen the workbench.

Extra effects initially default to off; deselecting does
not undo previous edits. Normal reruns finish pending work; force can reapply
masks. CN13 changes color, curves, sharpening and traditional NR; AI Denoise is
validated separately.

The shared v1.1.0 backend passed a live nine-RAW batch, repeat skips and a single-photo cancel/resume check. AI masking of complex portraits can take several minutes.

To uninstall, remove the plug-in in Plug-in Manager and delete the extracted
plug-in directory. This does not delete RAW files, the catalog, or the
`AI Pipeline` collections.
