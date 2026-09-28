# Lightroom AI Batch contributor notes

Read `docs/ARCHITECTURE.en.md` and `CONTRIBUTING.md` before changing the pipeline.

## Layout

- `plugin/LightroomMCP.lrplugin/` — Lightroom Classic Lua plug-in and the only batch backend.
- `server/` — optional TypeScript MCP bridge.
- `config/pipeline.json` — canonical release defaults.
- `scripts/sync-config.mjs` — keeps the source plug-in copy synchronized.
- `scripts/build-release.ps1` — explicit-whitelist Windows release builder.
- `release/` — files copied into release archives.

## Invariants

- Menu and MCP route through `HandlerBatch` to `BatchPipeline`.
- Real AI Denoise uses `setEnhance("denoise", true, amount)` and observable completion state.
- Auto Tone is called once per active photo.
- Landscape masks remain separate and neutral; v2 must not regain `FilterList = {}`.
- Long stages use polling, deadlines, and cancellation checks, never fixed completion sleeps.
- Keep the internal plug-in ID, `LightroomMCP.lrplugin` folder, socket ports, token path, and state directory compatible with existing installations.

## Checks

```text
cd server && npm run check
cd server && npm run lint
cd server && npm test
cd server && npm run build
node scripts/bump-version.mjs --check
node scripts/sync-config.mjs --check
mise run lua:lint
mise run lua:test
```

Release assets are Windows-only. There is no npm publish, MCPB, automatic branch mutation, or macOS release artifact.
