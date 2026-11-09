# Version validation evidence

[中文](VALIDATION.md) · [Back to README](../README.en.md)

This public record keeps aggregate evidence only. Private paths, full filenames, Photo IDs, Job IDs, catalog names, and image content are omitted.

The earlier tests below belong to v1.0.0. Acceptance of the v1.0.1 stability patch is recorded separately; older large-batch results are not stress-test evidence for the new version.

## v1.1.0 validation (2026-11-09)

- All 235 Lua and 208 TypeScript tests passed, with type checks, ESLint, Selene and build.
- Simulated coverage includes independent categories, Save/Start, frozen selection, file identity after UUID changes, favorites/search, incremental modules, late returns after cancellation, style changes, Denoise preservation/recovery and status-dialog cancel/close behavior.
- Workbench is the only menu entry. The final plug-in / MCP archives contain 37 / 39 files with licenses; defaults contain no local SDK UUIDs or user recipes.
- The user confirmed all three Chinese tabs. Enabling Lightroom preset groups expanded SDK enumeration from 77 to 98, including portrait, Sky and CN13.

### Full recipe on nine test RAWs

The recipe combined base Denoise 50, independent Auto Tone, Subject/Pop, eight Landscape categories, Smooth Face, Enhance Clothes, Blue Pop and CN13. User-designated Nikon NEF test photos ran through the shared menu/MCP backend:

- 9/9 completed, zero failures, skips or warnings; 1,431 seconds (23 minutes 51 seconds).
- All 36 extra-preset modules completed; 29 separate Landscape masks remained. Absent categories skipped normally.
- All nine final Denoise checks were enabled, Amount 50 and current; no recovery was needed.
- AI Mask Update took 21, 34, 625, 24, 20, 140, 34, 41 and 56 seconds. The slowest portrait completed naturally and processing advanced. Heartbeats were not treated as completion.
- Each photo's 35 readable CN13 curve/HSL and related fields matched the source preset. Auto Tone Exposure had eight distinct values, ranging from -0.37 to 1.74.
- Immediate same-recipe rerun skipped all nine in 58 seconds, with no new SDK operation, preset application or AI mask update events.

### Incremental preset and cancellation recovery

- Added an overall portrait preset and CN13 to one processed photo; requested cancellation while the portrait SDK call had not returned.
- Safe cancellation completed in six seconds. The portrait remained APPLIED and the unsubmitted style skipped. Worker/operation released without restarting Lightroom.
- Resubmitting the recipe completed in 15 seconds. The already-applied portrait was not submitted again; CN13 correctly reapplied last, followed by AI update and empty-mask cleanup.
- Final Denoise stayed enabled at 50 and current; readable CN13 parameters matched again.
- The nine-photo selection was restored, and subsequent reads/submissions worked.

The standalone Windows MCP executable initialized and enumerated 21 tools (including three batch tools and recipe schema) outside the source tree with Node excluded from the child PATH, then queried the real completed job. Graceful exit released its connection lock.

Coverage boundary: no cloud image model was called. The user confirmed the three tabs; persistence and the final simplified refresh/cancel UI have simulated checks but have not been manually operated again. Pixel-level comparison with manual portrait/Sky application, every portrait detail and a dedicated indoor-food sample are not fully covered. The earlier Adobe native display failure did not recur; these results do not prove an Adobe fix.

## Tested environment

- Windows 11 Home 64-bit.
- Lightroom Classic 15.5.1, build `202608131348-cab7eed5`.
- NVIDIA RTX 4060 Laptop GPU.
- Nikon NEF RAW inputs. Camera, resolution, hardware, mask complexity, and Lightroom background load materially affect timing.

Lightroom Classic 15.4 or newer is recommended. A 15.3.1 capability probe passed MCP connectivity, selection freeze, per-photo Auto Tone, Pop enumeration/application, Landscape creation, and AI updates, but consecutive genuine Denoise was unreliable. That version is therefore not listed as a tested release platform.

## 31-RAW Denoise soak test

- Froze 31 RAW files from a 32-item selection; one JPEG was explicitly excluded.
- 31/31 completed genuine AI Denoise at Amount 50; zero failures and skips.
- Total duration: 572 seconds.
- Per-photo Denoise: 15–18 seconds, median 17, average 16.71.
- Every final state reported `denoiseState=true` and `enhanceNeedsUpdate=false`.
- The original 32-item UI selection, including the excluded JPEG, was restored.
- An immediate rerun reported `idempotent skip` for all 31 Denoise stages and submitted no second Enhance calculation.

## 18-RAW Full Prepare pilot

- 18/18 completed with zero failures, skips, or warnings.
- Total duration: 1,219 seconds (20 minutes 19 seconds).
- Every photo independently completed genuine Denoise, Auto Tone, Adaptive Subject / Pop, Landscape, and AI Mask Update.
- Denoise took 15–35 seconds, average 18.94.
- AI Mask Update took 5–136 seconds, average 40.44; completion followed SDK state, not a fixed sleep.
- 29 separate Landscape masks remained: Architecture 9, Artificial Ground 8, Sky 5, Vegetation 5, Mountains 1, Natural Ground 1.
- Water and Snow were absent from this selection and skipped normally without failing a photo.
- All 18 records contained `processed=true` and four COMPLETE stage states; the original selection was restored.

## Five-photo Full Prepare and independent Auto Tone

- 5/5 completed with zero failures or skips in 491 seconds.
- All five Auto Tone Exposure results differed, demonstrating independent computation rather than first-photo value copying.
- 11 separate Landscape masks remained; absent categories skipped normally.
- An immediate rerun skipped all five as already processed in two seconds and added no duplicate masks.

## Landscape v2 Denoise preservation and repair

A forced Full Prepare on one unprocessed RAW completed Denoise, Auto, Pop, Landscape v2, and AI Mask Update. Both post-Landscape and final checks reported Denoise enabled, Amount 50, and `enhanceNeedsUpdate=false`; no recovery was needed. Two present Landscape categories became separate masks and other categories skipped.

Denoise was then manually disabled and the default `skipProcessed=true` job was run:

- The job recognized stale live state on a historically processed photo.
- Only Denoise and AI Mask Update ran.
- Auto, Pop, and Landscape reported `idempotent skip`; no duplicate masks were added.
- The eight-second job ended with Denoise enabled at Amount 50 and no pending update.

## Menu and localization

- After plug-in reload, the Simplified Chinese plug-in name, five menus, start/completion dialogs, server fields, and buttons rendered in Chinese.
- English and Simplified Chinese tables each contain 60 keys, exactly matching Lua references.
- Menu jobs and MCP handlers route to the same backend.

## State and persistence

- Start returns a Job ID immediately while a Lightroom worker continues the long operation.
- Status remains available during AI work; cancellation takes effect at safe boundaries.
- JSON snapshots, JSONL events, and pipeline state remained parseable.
- A `.previous` complete generation protects Windows snapshot replacement windows.
- Completed state remains idempotent after restart; interrupted jobs are not misrepresented as automatically resumed.

## Release build

- A clean-directory `npm ci` with Node.js 24.21.0 passed TypeScript checks, ESLint, all 206 Jest tests, and the production build.
- `npm audit` reported zero known vulnerabilities in MCP production dependencies.
- The allowlisted build produced a 37-file plug-in ZIP and a 39-file Windows MCP ZIP. Both contain the license and exclude source dependencies, logs, tokens, photographs, and catalogs.
- From an extraction outside the source tree, the standalone EXE passed version, help, adjacent plug-in installation, MCP initialization, and enumeration of all 21 tools without Node.js.
- `SHA256SUMS` was regenerated from and verified against both final ZIP files.

## v1.0.1 local acceptance (2026-10-05)

The candidate plug-in was installed from a fresh package extraction on the Windows 11 / Lightroom Classic 15.5.1 environment above, preserving existing configuration, Pop UUID and processed records.

- A forced Full Prepare on five user-designated test RAWs completed all five with zero failures or skips in 508 seconds (8 minutes 28 seconds). Three initially had Denoise disabled and two already had it enabled; satisfied Denoise was not resubmitted.
- All five completed independent Auto Tone, Pop, Landscape and AI Mask Update. Every final state had Denoise enabled, Amount 50 and `enhanceNeedsUpdate=false`; no Denoise recovery was needed.
- Separate Landscape mask counts were 4, 4, 3, 2 and 1, totaling 14; absent categories skipped normally.
- Without restarting Lightroom, a default Full Prepare on the same five skipped all five as processed with current live Denoise state in 23 seconds. Events contained no new SDK operation, preset application or mask update.
- Both jobs ended with `workerRunning=false`, no active operation and `restartRequired=false`; the original five-photo selection was restored.
- All 213 Lua tests and 207 TypeScript tests passed, along with type checks, ESLint, Selene, build, version and default-configuration consistency checks. Simulated faults cover definite SDK errors, non-editable photos, cancellation draining, pending-call isolation, late return, abnormal worker exit, menu job targeting, resumed empty-mask cleanup and processed-state protection during a forced rerun.
- The candidate plug-in ZIP contains 38 files and the Windows MCP ZIP contains 40. Allowlist and checksum checks passed. The EXE extracted outside the source directory initialized MCP, enumerated 21 tools and queried status with a runtime environment that excluded Node.js.
- English and Simplified Chinese tables each contain 66 matching keys by static inspection; visible acceptance of the new status/cancellation UI is still pending.

A subsequent stability-patch acceptance used 12 user-designated RAWs, including the previously stalled photo:

- Forced Full Prepare completed 12/12 with zero failures, skips or warnings in 764 seconds (12 minutes 44 seconds). Seven initially had Denoise disabled and five already had it enabled.
- All 12 ended with Denoise enabled at Amount 50 and no pending update. 19 separate Landscape masks remained; the original 12-photo selection was restored.
- Per-photo AI Mask Update took 14–74 seconds. The previously stalled photo completed that stage in 60 seconds and later photos continued.
- A two-photo task was cancelled while the first native AI Mask Update was running. At the end of the 60-second drain window it explicitly FAILED (one failed, one unsubmitted/skipped), rather than falsely claiming a safe cancellation; the second photo was not submitted.
- The native call genuinely returned 88 seconds after entry. Status then showed `callReturned=true`, no active operation, `workerRunning=false` and `restartRequired=false`. A new job started without a Lightroom restart; a default repair completed one and skipped one in eight seconds.
- This cancellation/recovery test exposed a missing empty-mask cleanup boundary. A targeted fix and regression tests have been added; the follow-up still needs a one-photo live check after plug-in reload.

Boundary: these main-path tests did not reproduce the earlier Lightroom native display failure. Simulated faults validate plug-in isolation and recovery, not a fix to Adobe's display/GPU failure. Visible menus and the new recovery cleanup still await human acceptance; this candidate has not been published.

## v1.0.0 conclusion

On Windows 11 with Lightroom Classic 15.5.1, the v1.0.0 Denoise-only and Full Prepare paths passed live RAW batch validation. Timing demonstrates scale only and must not be generalized to other computers or photographs.
