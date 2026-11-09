# Lightroom AI Batch

[中文 README](README.md) · [Architecture](docs/ARCHITECTURE.en.md) · [Validation evidence](docs/VALIDATION.en.md)

Lightroom AI Batch is a small batch-preparation tool for Lightroom Classic on Windows. Select photos of one category, choose Denoise, Auto Tone, subject, portrait and sky effects in a native workbench, optionally select a style such as CN13, then let Lightroom process each photo.

The Lightroom menu works by itself. MCP is optional, and no agent needs to judge each photograph.

> Independent community project, not affiliated with Adobe. The tested platform is Windows 11 with Lightroom Classic 15.5.1. Lightroom Classic 15.4 or newer is recommended; 15.3 and earlier produce a warning but are not blocked.

## Why I made it

I am a photography beginner, and my computer is not especially fast. When I edit photos one by one, I spend a lot of time waiting for Lightroom AI Denoise, subject detection, and AI presets to load again for every image.

This tool lets me select a batch of RAW files and leave Lightroom to perform those repetitive preparation steps first. Afterward, I only need to check the subject, fine-tune the masks that matter, and apply my own filters or color work. It does not decide how a photograph should look; it only moves the repeated waiting to the start of the workflow.

Denoise and AI masks still run on your computer; the workbench mainly reduces repeated operations. In this test run, one portrait's AI mask update took about ten minutes. Complex photos can take a long time.

## What it currently does

| Capability | Behavior |
| --- | --- |
| Category workbench | Animals, people, street, landscape and food each remember their last saved combination. Categories do not restrict the available modules. |
| Additional presets | One Subject and Sky choice; combine an overall portrait treatment with skin, clothes, eyes, teeth or hair details. Search and favorite styles; CN13 is initially favorited. |
| Genuine AI Denoise | Uses Lightroom Enhance/Denoise, never traditional luminance/color NR as a substitute; default Amount is 50. |
| Independent Auto Tone | Makes each photo active and invokes Lightroom Auto Tone separately; it never copies the first result. |
| Adaptive Subject / Pop | Discovers Pop from backing-file identity, saves the SDK UUID, and does not depend on localized display names. |
| Separate Landscape masks | Creates independent neutral masks for present Sky, Snow, Architecture, Vegetation, Water, Natural Ground, Artificial Ground, and Mountains categories. Missing categories are normal skips. |
| State synchronization | Waits for observable Lightroom Enhance/AI state instead of assuming completion after a fixed sleep. |
| Asynchronous jobs | Start returns a Job ID immediately; status and cooperative cancellation remain available. One photo failure does not abort the batch once native work has safely ended. |
| Idempotency and repair | Processed photos are skipped by default. If live Denoise state is stale, only Denoise and existing AI masks are repaired. |
| Audit trail | Job/photo/stage state, timings, errors and skip reasons are persisted, with Processed/Failed/Skipped collections. |

Live evidence includes a 31-RAW Denoise run (31/31) and an 18-RAW full run (18/18). These are measurements from one machine and photo set, not performance guarantees. See [Validation evidence](docs/VALIDATION.en.md).

## Release downloads

Download v1.1.0 from [GitHub Releases](https://github.com/Makashibata02/lightroom-ai-batch/releases/latest). Package names are:

- `lightroom-ai-batch-plugin-v1.1.0.zip`: recommended for normal users. Menu operation requires no Node.js, MCP process, or agent.
- `lightroom-ai-batch-mcp-windows-x64-v1.1.0.zip`: self-contained Windows x64 MCP executable plus the matching plug-in; no Node.js or source checkout needed.
- `SHA256SUMS`: checksums for both archives.

## Menu installation and use

1. Download and extract the plug-in ZIP.
2. In Lightroom Classic, choose **File → Plug-in Manager**, click **Add**, and select the complete `LightroomMCP.lrplugin` folder.
3. Reload the plug-in or restart Lightroom if the menu is not refreshed.
4. Select a group of RAW photos in Library or Develop.
5. Choose **File → Plug-in Extras**.

There is one menu entry:

**File → Plug-in Extras → AI Batch — Workbench...**

Base preparation, extra presets, status and cancellation are accessed through the workbench. Opening it during a job shows a status window with Refresh status and Cancel batch. Closing the window leaves processing running. MCP connection status remains available in Plug-in Manager.

The workbench and MCP use the same `BatchPipeline` backend. Start Server is only needed for MCP. MCP can explicitly queue later jobs; `QUEUED` means waiting.

### Processing a day's photos with the workbench

1. Select that day's photos of one category, such as people.
2. Open **File → Plug-in Extras → AI Batch — Workbench...** and choose People.
   If Subject/Portrait choices are missing, enable **Adaptive: Subject** and **Adaptive: Portrait** under Lightroom's **Presets + → Manage Presets**, then reopen the workbench. The SDK only enumerates displayed groups.
3. In Basic preparation, check Denoise, independent Auto Tone, Subject and the desired Landscape categories. Initial values come from existing plug-in settings; Denoise defaults to 50.
4. In Portrait and sky, choose an overall treatment or individual details and, optionally, one Sky preset. Extra effects initially default to off.
5. In Style preset, search for CN13 or another preset and choose one. Toggle favorite changes the favorites list.
6. Save recipes only saves settings. Start batch saves settings, closes the configuration window and submits the job.
7. Select another category's photos and choose its category. Each category retains its own last saved combination.

The workbench assigns a recipe to the current selection; it does not classify images or write category keywords. It uses native Lightroom controls without an MCP process. Opening it during a job lets you inspect, refresh or cancel the current job.

- Deselecting an effect does not undo earlier edits. An extra preset normally applies once; switching styles and later returning to an old style reapplies that selected style.
- Overall portrait presets may already treat skin, eyes and hair; detail presets can strengthen those areas. Some also change global color settings.
- CN13 changes HSL, curves, sharpening and traditional noise reduction, and does not replace AI Denoise. Style runs last; later presets win for overlapping settings.
  Appending a portrait preset with global adjustments reapplies the selected style to retain that order; a mask-only detail does not replay the style.
- Empty face/sky masks are cleaned up normally; other global settings in a preset still follow Lightroom's native behavior.
- Skip fully completed photos controls the whole-photo skip. Force rerun replays enabled steps and can reapply masks. Use default incremental processing to retain manual edits.

For Denoise only, keep AI Denoise enabled, disable Auto Tone and Landscape, and select None for Subject, portrait, Sky and style. Keep the initial defaults for full base preparation.

The workbench currently supports SDK-enumerable Adaptive Subject, Portrait and Sky presets plus ordinary Develop styles. Other AI categories, generative removal and cloud visual grading are not included yet.

## Optional MCP entry point

Extract the MCP ZIP and keep the EXE beside `LightroomMCP.lrplugin`. See `MCP_SETUP.en.md` inside the archive.

```json
{"tool":"lr_batch_pipeline","arguments":{"profile":"configured"}}
{"tool":"lr_batch_pipeline","arguments":{"profile":"full","force":true}}
{"tool":"lr_batch_status","arguments":{"jobId":"<job-id>"}}
{"tool":"lr_batch_cancel","arguments":{"jobId":"<job-id>"}}
```

Example start result:

```json
{"jobId":"...","photoCount":18,"status":"QUEUED","profile":"full"}
```

Explicit `photo_ids` become the frozen list. Otherwise the current Lightroom selection is frozen at submission. Later selection changes do not change the job, and the plug-in attempts to restore the original active photo and selection at the end.

Submit a workbench recipe through the same tool. Obtain local SDK UUIDs with `list_develop_presets`, then order portrait, sky and the final style preset:

```json
{"tool":"lr_batch_pipeline","arguments":{"profile":"configured","recipe":{"category":"people","presetUuids":["<smooth-face-sdk-uuid>","<clothes-sdk-uuid>","<cn13-sdk-uuid>"]}}}
```

`category` is `animals`, `people`, `street`, `landscape` or `food`. Subject selection uses `config.subjectPreset.uuid`. A recipe allows up to 32 unique UUIDs, at most one Sky and one style; style must be last. Missing/unsupported presets fail before submission. Status adds the recipe summary, `recipe.signature` and per-photo `modules`: `APPLIED` means the preset was submitted successfully but calculation/final checks remain; `COMPLETE` means validation finished.

## Configuration

The single source of release defaults is [`config/pipeline.json`](config/pipeline.json). The build copies it into the plug-in. Runtime reads the installed copy:

```text
LightroomMCP.lrplugin\config\pipeline.json
```

```json
{
  "pipelineVersion": "1.0.0",
  "denoise": { "enabled": true, "amount": 50, "timeoutSeconds": 900 },
  "autoTone": { "enabled": true },
  "subjectPreset": { "enabled": true, "uuid": "" },
  "landscape": {
    "enabled": true,
    "features": [
      "Sky", "Snow", "Architecture", "Vegetation", "Water",
      "Natural Ground", "Artificial Ground", "Mountains"
    ],
    "timeoutSeconds": 900
  },
  "skipProcessed": true,
  "force": false,
  "processedCollection": "AI Pipeline / Processed",
  "pollIntervalSeconds": 0.25,
  "runtime": {
    "readyTimeoutSeconds": 30,
    "writeAccessTimeoutSeconds": 30,
    "drainTimeoutSeconds": 60,
    "heartbeatIntervalSeconds": 5
  }
}
```

Precedence, lowest to highest: built-in defaults → installed JSON → MCP `config` overrides → top-level MCP `force`/`skipProcessed` → profile stage switches.

- `configured`: honor the merged configuration.
- `denoise-only`: force Denoise on and Auto Tone/Subject/Landscape off; it does not mark a photo as fully processed.
- `full`: force all four stages on while preserving amount, timeout, and feature values.

After first discovery, the local Adaptive Subject / Pop SDK UUID may be saved to the installed configuration. Release defaults never contain a developer's UUID.

`runtime` controls photo/control readiness, acquiring catalog write access, draining an interrupted native call, and diagnostic heartbeat cadence. Normal AI deadlines still come from stages' `timeoutSeconds`; neither a heartbeat nor elapsed time proves completion. v1.1.0 retains the idempotency `pipelineVersion=1.0.0` so upgrading does not reprocess everything.

Workbench category choices, favorites and preset file identities live in `~/.config/lightroom-ai-batch/workbench.json`, outside the plug-in folder. Precedence is installed defaults → saved category choices → current window edits. Transient `force` is never saved as the next default. Changed UUIDs are rematched by saved file identity; unavailable presets produce a warning and are deselected for review before starting.

## Reruns, cancellation, and restart behavior

- With `skipProcessed=true`, a matching `pipelineVersion`, `processed=true`, and valid live Denoise state cause a whole-photo skip.
- If Denoise was manually disabled or its Amount changed, a normal rerun repairs Denoise and updates existing AI masks without reapplying Auto Tone, Pop, or Landscape.
- Later manual changes to tone or mask contents cannot be detected reliably. Use `force=true` when those stages must be reapplied, preferably on test copies first.
- Cancellation is cooperative: no later photo operations are submitted, the active Lightroom call must return before a safe stop, and unprocessed photos become skipped. Jobs that have not started are cancelled immediately.
- If Landscape was applied before mask update/cleanup was interrupted, a default rerun skips completed stages but finishes AI mask update and empty-mask cleanup. While native work remains active, the plug-in does not switch photos or restore selection. A call returning after the job has ended does not automatically restore the original selection; reselect the photos to process.
- Jobs are persisted but are not automatically resumed. Querying a non-terminal job after a Lightroom restart marks it FAILED with an interruption reason.

## Status, logs, and collections

Important statuses include `QUEUED`, `DENOISE_SUBMITTED`, `DENOISE_COMPLETE`, `AUTO_TONE_COMPLETE`, `SUBJECT_PRESET_COMPLETE`, `LANDSCAPE_COMPLETE`, `AI_MASK_UPDATE`, `COMPLETE`, `FAILED`, and `SKIPPED`.

```text
%USERPROFILE%\.config\lightroom-ai-batch\
  pipeline-state.json
  jobs\<jobId>.json
  jobs\<jobId>.jsonl
```

Per-photo status may include `denoiseValidation` with initial, post-Landscape, and final state plus one-shot recovery information.

Status also includes the current photo, `lastHeartbeatAt`, `queuePosition`, `executionState`, `activeOperation`, and `restartRequired`. Each photo's `operation` records identity and `callReturned`. A FAILED job can still have a pending Lightroom call, which prevents new operations.

The plug-in creates an `AI Pipeline` collection set with `Processed`, `Failed`, and `Skipped`. A failed photo does not stop later photos once native work has safely ended, and never enters Processed. Collection-write failures become warnings rather than replacing the processing result.

### Photo cannot be displayed, or progress stops

Definite SDK errors, unavailable controls, and non-editable photos receive a failure reason. The pipeline only advances after native work has ended; a failed mask update does not trigger blind Denoise recovery.

If a timed-out/cancelled internal call has not returned after draining, execution becomes `RESTART_REQUIRED`: later photos are not submitted, queued jobs fail explicitly, and new operations are blocked. If the old call eventually returns, the plug-in can accept work again; otherwise restart Lightroom. The plug-in cannot force-kill Lightroom's renderer. Repeated Start clicks do not fix this, and this status does not prove that the RAW file is corrupt.

## Upgrade and uninstall

Before upgrading, let the active job finish, stop the MCP server, and quit Lightroom. Back up the old `config/pipeline.json`, extract the new version to a new permanent directory, then merge custom values and the discovered Pop UUID into the new configuration. Do not replace a new configuration wholesale with an old file that may lack new keys. Remove the old path in Plug-in Manager, add the new `LightroomMCP.lrplugin`, and restart Lightroom. The internal plug-in ID and state directory stay compatible, so catalog metadata, collections, and the processed index survive the path change.

`lightroom-ai-batch-mcp.exe install-plugin` is a first-install helper. It preserves an existing plug-in and is not an overwrite upgrader. When upgrading the MCP package, point the client to the new EXE and upgrade the plug-in at the same time.

To uninstall, remove the plug-in in Plug-in Manager and delete its extracted directory. Also remove the MCP client entry if configured. This does not delete RAW files, the catalog, or `AI Pipeline` collections. Job history under `%USERPROFILE%\.config\lightroom-ai-batch` is retained unless you explicitly remove it after deciding it is no longer needed.

## Known limitations

- Only Windows 11 + Lightroom Classic 15.5.1 is marked as tested.
- Denoise was unreliable on Lightroom 15.3.1 in this test environment; 15.4+ is recommended.
- Landscape subcategories use a Develop preset structure and category IDs accepted in live tests. Adobe does not promise this as a stable public API.
- Pop discovery uses backing-file identity. If Adobe moves or renames that resource, the stage fails with a recorded reason instead of selecting by a localized name.
- The current version has no configuration GUI, job-history UI, or automatic resume.
- Runtime never edits `.lrcat` SQLite, rewrites RAW files, uses fixed screen coordinates, or requires Windows UI automation.

## Architecture overview

```text
Menu / lr_batch_pipeline
        │
        ▼
freeze Photo IDs → enqueue → return Job ID
        │
        ▼ (one worker, serial photos)
activate and verify photo
 → Denoise + state polling
 → per-photo Auto Tone
 → Subject/Pop preset
 → selected portrait/sky presets (workbench)
 → v2 Landscape preset (separate masks)
 → selected style preset (workbench)
 → validate/recover Denoise at most once
 → Update AI Settings + delete empty masks
 → final Denoise validation
 → metadata, logs, collections
        │
        ▼
restore original selection
```

See [Architecture](docs/ARCHITECTURE.en.md) for implementation boundaries and extension guidance.

## Development and release

```powershell
cd server
npm ci
npm run check
npm run lint
npm test
npm run build

cd ..
node scripts/sync-config.mjs --check
powershell -ExecutionPolicy Bypass -File scripts/build-release.ps1
```

Lua changes should also run `mise run lua:lint` and `mise run lua:test`. Release automation builds only from a `v*` tag, does not modify the main branch, does not publish npm, and produces only the two Windows ZIPs plus `SHA256SUMS`.

See [CONTRIBUTING.md](CONTRIBUTING.md) for extension conventions.

## Roadmap

- Suggestions from representative photos per category, followed by sample approval and batch processing.
- Job-history browser.
- Explicit interrupted-job resume flow.
- Community validation across more Lightroom versions.

Next steps prioritize the combinations people actually use and compatibility, followed by AI suggestions from representative photos.

## Sources and license

This project was not built from scratch. It references and reuses work from:

- [varunkumar/lightroom-mcp](https://github.com/varunkumar/lightroom-mcp): the initial primary reference for Lightroom Enhance, Develop Controller, and MCP experiments.
- [drshy-org/lightroom-py](https://github.com/drshy-org/lightroom-py): reference for the Adaptive Subject / Pop preset workflow and command-line approach.
- [Automaat/lightroom-mcp](https://github.com/Automaat/lightroom-mcp): the actual MIT-licensed base for this repository's MCP transport, catalog handlers, plug-in bootstrap, and parts of the test suite.

See [NOTICE.md](NOTICE.md) for the exact reuse and licensing scope. This project is distributed under the [MIT License](LICENSE).
