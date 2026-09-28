# Contributing

Thanks for improving Lightroom AI Batch. Changes should preserve the project's core property: one deterministic backend shared by the Lightroom menu and MCP.

## Development setup

```powershell
cd server
npm ci
npm run check
npm run lint
npm test
npm run build
```

Lua changes also require:

```text
mise run lua:lint
mise run lua:test
```

Verify version consistency and default-config synchronization:

```powershell
node scripts/bump-version.mjs --check
node scripts/sync-config.mjs --check
```

## Runtime rules

- Prefer Lightroom SDK APIs, then Lightroom presets/recalculation.
- Do not edit the catalog SQLite database or source RAW files.
- Do not use traditional noise-reduction sliders as AI Denoise.
- Auto Tone must be invoked independently for each photo.
- Do not copy AI mask coordinates from one photo to another.
- Do not infer completion from a fixed sleep; poll observable state with a deadline and cancellation check.
- Keep one photo failure isolated from later photos.
- Keep preset names, mask names, collection names, config keys, MCP tools, statuses, and logs language-neutral English.
- User-visible UI strings belong in both translation tables and must use `LOC` fallbacks.

## Adding functionality

Read [docs/ARCHITECTURE.en.md](docs/ARCHITECTURE.en.md) before adding a stage, Landscape category, or MCP tool. A menu command that exposes MCP functionality must call the same handler/backend.

Changes involving undocumented or serialized Lightroom behavior need a real test-RAW validation record. Clearly label observed compatibility behavior rather than presenting it as an Adobe stability guarantee.

## Release build

Windows releases are built from a version tag:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/build-release.ps1
```

The script uses an explicit plug-in file whitelist and creates:

- `lightroom-ai-batch-plugin-vX.Y.Z.zip`
- `lightroom-ai-batch-mcp-windows-x64-vX.Y.Z.zip`
- `SHA256SUMS`

Do not add logs, tokens, catalogs, photos, runtime state, local UUIDs, or personal paths to an artifact.

## Attribution

Preserve the Automaat MIT copyright notice and keep [NOTICE.md](NOTICE.md) accurate when reusing external code. Research references are not automatically licensed code sources.
