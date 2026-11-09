# Architecture and implementation

[中文](ARCHITECTURE.md) · [Back to README](../README.en.md)

This document describes the v1.1.0 implementation. Landscape preset internals are a tested compatibility technique, not an Adobe guarantee of a stable public API. Live acceptance of the new workbench is tracked separately in the validation record.

## Design boundary

Runtime paths follow this priority:

1. Lightroom Classic SDK / Develop API.
2. Lightroom presets and Lightroom's own AI recomputation.
3. Keyboard shortcuts or Windows UI Automation.
4. Image recognition.

The production path uses only the first two layers. It does not automate UI coordinates, modify `.lrcat` SQLite, or rewrite RAW files.

## Components

| File | Responsibility |
| --- | --- |
| `BatchPipeline.lua` | Selection freeze, queue, per-photo stages, error isolation, selection restore; the only backend for menu and MCP. |
| `AiState.lua` | Develop Controller synchronization, genuine Denoise, Enhance polling, and AI mask update polling. |
| `AiOperation.lua` | Independent SDK contexts, shared serialization gate, return confirmation, draining and diagnostics. |
| `BatchJobStore.lua` | In-memory jobs, JSON snapshots, JSONL events, cancellation flags, and counters. |
| `PipelineState.lua` | Durable idempotency index independent of catalog private-metadata reliability. |
| `PipelineConfig.lua` | Defaults, runtime config, request overrides, validation, and Pop UUID persistence. |
| `SubjectPreset.lua` | Adaptive Subject / Pop discovery by backing-file identity and SDK UUID. |
| `RecipePresets.lua` | Shared preset enumeration, supported preset families, UUID preflight and recipe snapshots. |
| `Workbench.lua` / `WorkbenchState.lua` | Native category configuration, search/favorites and user settings outside the plug-in folder. |
| `LandscapePreset.lua` | Plugin preset containing separate Landscape correction/mask entries. |
| `PipelineCollections.lua` | Processed, Failed, and Skipped collections. |
| `HandlerBatch.lua` | Thin adapter for the three MCP tools. |
| `MenuBatchCommon.lua` | Menu start/status/cancel, routed through the same handler/backend. |
| `server/src/tool-contracts.ts` | MCP schemas. |

## Submission and execution

`BatchPipeline.start()` merges configuration and profile, then snapshots the selection. Stable Lightroom `localIdentifier` values become the frozen queue. Later UI selection changes cannot alter the job.

A `QUEUED` snapshot is persisted, one worker is scheduled, and the caller immediately receives a Job ID. The worker resolves each frozen ID, selects exactly that photo, and verifies `catalog:getTargetPhoto()` before entering any Develop operation. Photos run serially so Enhance calls cannot compete for the Develop Controller.

Errors are isolated per photo, with edit-availability preflight. Later photos continue only when native work has safely ended. Pending SDK calls stop later submissions and selection changes; the original selection is restored after a safe end. A call returning after its job has ended does not automatically restore the original selection; the user must reselect photos. A frozen job is also bound to its original catalog, preventing identical numeric IDs in another catalog from being processed.

## Denoise

The genuine operation is:

```lua
LrDevelopController.setEnhance("denoise", true, amount)
```

Amount is configurable and defaults to 50. Before submission, the pipeline waits for the target photo to be editable and `getEnhancePanelState().denoiseEnabled` to remain true for three consecutive polls. This handles the interval where catalog selection has changed but the Develop Controller is still bound to the previous photo.

Completion requires the actual SDK return, `denoiseState == true`, the configured Amount, `enhanceNeedsUpdate == false`, and edit availability. Every loop observes cancellation and a deadline. The poll interval is not assumed completion time. `AiOperation` shares a gate across Enhance, presets, Auto Tone, mask updates, and empty-mask cleanup.

### Protection after Landscape

The current Landscape preset carries only mask structure and does not write a top-level `FilterList`, so applying it does not intentionally override Enhance/Denoise state.

The pipeline additionally validates live Denoise state after the preset sequence and at the end of the photo. `afterLandscape` remains available and workbench jobs add `afterPresets`. If state is lost, Denoise is resubmitted at most once for that photo and AI masks are updated again. Recovery never loops. `denoiseValidation` records the observations and result; a failed recovery makes the photo FAILED and keeps it out of Processed.

## Native category workbench

`MenuAIBatchWorkbench.lua` opens a native `LrView` / `LrDialogs` configuration window. Categories label five independent saved choices, not automatic classification. The modal window closes before processing. Selected IDs are captured for submission to `MenuBatchCommon.start()` and the same `HandlerBatch` / worker used by MCP. The workbench is the only menu entry. Opening during a job shows status with refresh, close and cancellation of the displayed Job ID. Closing or pressing Escape leaves the job running instead of blocking Develop with a configuration dialog.

Base settings come from the installed configuration. Extra effects initially default to off. The user can choose a Subject preset, an overall portrait preset plus details, one Sky preset and one ordinary style. Recipe order is portrait overall → details → Sky; the worker applies those before Landscape and the style afterwards. All presets use original strength. Later global settings override earlier ones as when applied manually in Lightroom.

`RecipePresets` reuses `HandlerDevelop.presetEntries()` for SDK objects and deduplicates aliases by UUID. Internal backing-file paths classify Adaptive Subject, Portrait and Sky without depending on localized names. Other AI families are not enabled. Optional MCP `recipe` contains `category` and ordered `presetUuids` (up to 32 unique IDs). Subject uses the existing `config.subjectPreset` slot. A style must be last; at most one Sky and one style are accepted. Missing/unsupported entries fail before Job creation.

The SDK only enumerates displayed Lightroom groups. The workbench explains how to enable Subject/Portrait in Presets + → Manage Presets. The configured Subject is also resolved before Job creation, so hidden groups do not fail halfway through processing.

User choices, favorites and UUID-to-file identities live in `workbench.json` in the runtime directory. File identity can rematch an SDK UUID after an application change. Unavailable choices produce a warning before being deselected. Save/Start persist all edited categories; Cancel does not. `force` is transient. The file uses temporary and previous generations and is never bundled in releases.

## Per-module execution and persistence

Extra presets run through `AiOperation` and the existing per-photo error boundary. The SDK context records `presetModules[uuid].status = APPLIED` immediately after application, including a late return after the owning job ends. A retry finishes AI calculation/cleanup without applying that preset twice. Final checks promote applied modules to COMPLETE. Per-photo `modules` and `PRESET:<uuid>` events report names, state, timing and reasons; `job.recipe` holds a resolved summary and deterministic signature.

An old `processed=true` does not suppress new modules. Whole-photo skip requires completed enabled base stages, the selected Subject identity and Landscape features, current live Denoise/AI state, and completed requested modules. `subjectPresetUuid` and `landscapeFeatures` track changed base choices. Records without identities retain compatibility for configured Pop/default Landscape. `stylePresetUuid` tracks the latest style, so A → B → A applies A again. Deselecting does not undo earlier edits; manual changes require explicit force when they should be overwritten.

Lightroom recomputes Subject/Portrait/Sky masks per photo, followed by empty-mask cleanup. A preset with no matching AI region can still change its declared global settings. No cloud model runs in v1.1.0; visual suggestions remain a future stage.

Recalculating Auto Tone or appending a preset with non-mask global settings invalidates the current-style marker; the selected style then reapplies last. Mask-only details and preset metadata do not invalidate it, preserving manual color refinements.

## Auto Tone

After selecting one active photo, the worker calls `LrDevelopController.setAutoTone()`. It reselects and calls again for every following photo. It never copies Exposure, Highlights, Shadows, or other values from the first image.

## Adaptive Subject / Pop

Initial discovery enumerates `LrApplication.developPresetFolders()` and matches the backing file `Pop.xmp` under the `Adaptive - Subject` resource path. Localized names such as “Pop” or “流行” are not the sole identity.

The unique match's `preset:getUuid()` is saved into the installed configuration. Later jobs resolve UUID first. `photo:applyDevelopPreset()` runs per photo, and Lightroom recomputes AI content for that photo during the final update; mask coordinates are not copied from the first photo. Missing or ambiguous identity becomes a recorded stage failure.

## Landscape subcategories

Each requested category becomes a separate neutral `Correction` and `Mask/Image` named `AUTO Landscape - <Feature>`:

| Feature | SubCategory ID |
| --- | ---: |
| Architecture | 50001 |
| Mountains | 50002 |
| Artificial Ground | 50003 |
| Natural Ground | 50004 |
| Vegetation | 50005 |
| Sky | 50006 |
| Water | 50007 |
| Snow | 50008 |

Correction and mask SyncIDs are deterministic from the category ID; local adjustments are neutral. The internal preset name contains a format version and ordered category IDs, giving each structure a stable identity without sharing a cache entry with a different structure.

After application, Lightroom recomputes masks for each photo. `deleteAllEmptyMasks()` removes categories absent from the scene. The pipeline then reads `MaskGroupBasedCorrections` to record retained independent masks and skipped categories. The serialized structure and 5000x IDs are observed Lightroom 15.5.1 behavior, not a promised stable API.

## AI Mask Update

`catalog:updateAISettings({photo})` runs in an asynchronous Lightroom task. Completion requires every photo to report both `needsUpdateAISettings() == false` and `isAvailableForEditing() == true`. Empty-mask cleanup and result inspection happen only afterward. When the Landscape preset stage is complete but the photo is not, a default rerun still performs empty-mask cleanup without reapplying the preset.

### Call lifecycle and failure boundary

Slow operations use independent `LrFunctionContext.postAsyncTaskWithContext()` contexts, with operation/job/photo IDs, call-entry logging and `callReturned`. Definite SDK or completion-predicate errors fail immediately rather than being retried as ordinary not-ready observations.

Catalog write-access acquisition has its own `runtime.writeAccessTimeoutSeconds`; the code checks for the `executed` return. This deadline does not forcibly terminate AI work already inside the callback.

Timeout/cancellation sets an abort flag and enters `DRAINING` without releasing the gate. A delayed write callback checks that flag before editing. Only an observed SDK return releases the gate. If draining expires first, execution becomes `RESTART_REQUIRED`: the current job fails, remaining photos are skipped, queued jobs fail explicitly, and new operations are blocked. A genuine late return permits new submissions; a call that never returns requires a Lightroom restart.

Worker-context cleanup only clears its owned identity; it does not yield or write the catalog. An independent monitor or later status query finalizes unexpectedly abandoned jobs as FAILED. Generation checks keep old cleanup from changing a newer worker. A heartbeat proves observer liveness, not AI progress or completion of native work.

A failed mask update ends the photo without triggering Denoise recovery while unavailable or holding access. Collection marking and private-metadata mirrors are deferred/skipped with diagnostics during a pending native call; external state retains the processing result.

## Jobs, status, and cancellation

Job snapshots live at `~/.config/lightroom-ai-batch/jobs/<jobId>.json`; the event stream is a sibling `.jsonl`. Writes use unique temporary files, a cooperative per-target lock, and a complete `.previous` generation to survive Windows replacement windows.

Menu and MCP submit work without waiting for the batch. `lr_batch_status` returns the snapshot; `lr_batch_cancel` sets `cancelRequested`. Polling loops and stage boundaries observe that flag. Cancellation never force-kills a Lightroom internal operation.

Start returns actual state, usually `QUEUED`, rather than presenting queued work as running. Queued cancellation removes and finalizes the job immediately. Menu status/cancel prefer the backend's active job; another processing-menu click shows the existing job. Status adds current photo, queue position, heartbeat, active operation and restartRequired without changing tool names or job terminal states. Release v1.1.0 is separate from the retained 1.0.0 idempotency format version.

Persistence supports querying and diagnosis, not automatic resume. Reading a non-terminal job after Lightroom restart marks it FAILED with an interruption reason.

## Idempotency and Denoise state checks

Stage state is mirrored to plug-in private metadata and `pipeline-state.json`. The external index is keyed by catalog path, Photo ID, and source path. Fields include pipeline version, job ID, stage states, processed, and processedAt.

A non-skipped Full Prepare/configured photo is marked `processed=false` before processing stages, including a forced rerun of an already processed photo. Only successful final checks restore `processed=true`, so interruption cannot leave a partially reapplied pipeline marked complete.

A whole-photo processed skip occurs only after the target photo is active and live Denoise is inspected. If metadata records completion but current Denoise is off, Amount differs, or Enhance needs update, live state wins: only Denoise reruns, recorded Auto/Pop/Landscape stages are skipped, and existing AI masks are updated. This targeted repair does not change the pipeline version or trigger a complete rerun of the photo.

## Configuration source

`config/pipeline.json` is the repository's canonical default. `scripts/sync-config.mjs` checks or updates the source plug-in copy; release packaging always copies the root file directly into the staged plug-in.

Runtime precedence is defaults → installed file → per-job `config` → top-level force/skipProcessed → profile stage switches. Saving a discovered Pop UUID reloads persistent configuration and changes only that UUID, never transient job overrides.

## Localization

User-visible strings use Lightroom SDK `LOC` keys. English and Simplified Chinese tables cover the plug-in name, the single workbench entry, workbench, dialogs, manager fields/buttons, metadata titles, and visible history operations. Preset/mask/collection names, config keys, MCP tool names, status codes, and logs stay English for cross-language compatibility. Other locales use inline English fallbacks. Preset display labels come from Lightroom's SDK.

## Extending the project

### Add a stage

1. Define boundaries, public status, and per-photo error isolation in `BatchPipeline.lua`.
2. Give slow calls observable conditions, deadlines, and cancellation checks; never infer completion from a fixed delay.
3. Add metadata/state fields when the stage must be idempotent.
4. Decide whether failure permits later stages; only error-free photos may become Processed.
5. Add Lua specs, MCP/TypeScript tests, bilingual docs, and real-RAW evidence.

### Add a Landscape category

1. Verify its real SubCategory ID on the target Lightroom version.
2. Update `FEATURE_IDS`, default config, and the MCP enum.
3. Give the correction and mask separate deterministic SyncIDs, neutral adjustments, and a consistent name.
4. Validate present/absent scenes, reruns, and final Denoise state.

### Add an MCP tool

1. Implement a `Handler*.lua` function and register it in `PluginInfoProvider.lua` `DISPATCH`.
2. Add the contract in `server/src/tool-contracts.ts`.
3. Update validation and tool-list tests.
4. A matching menu command must call the same handler/backend instead of duplicating logic.

## API stability statement

The project prefers the Lightroom SDK, but a call verified on Lightroom 15.5.1 is not automatically a future compatibility guarantee. Enhance argument forms, Enhance panel state, and Landscape preset internals require a capability probe after Lightroom upgrades. Adobe's SDK entry point is [Lightroom Classic SDK](https://developer.adobe.com/lightroom-classic).
