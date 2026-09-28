# v1.0.0 validation evidence

[中文](VALIDATION.md) · [Back to README](../README.en.md)

This public record keeps aggregate evidence only. Private paths, full filenames, Photo IDs, Job IDs, catalog names, and image content are omitted.

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

## Conclusion

On Windows 11 with Lightroom Classic 15.5.1, the v1.0.0 Denoise-only and Full Prepare paths passed live RAW batch validation. Timing demonstrates scale only and must not be generalized to other computers or photographs.
