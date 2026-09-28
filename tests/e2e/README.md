# Windows live E2E checks

These checks require Lightroom Classic running with the matching plug-in loaded.
They are not part of unattended CI because they operate a real catalog.

Build the MCP server first, then use:

```powershell
node tests/e2e/mcp-runner.mjs list-tools
node tests/e2e/mcp-runner.mjs tool get_selected_photos '{"limit":10}'
node tests/e2e/mcp-runner.mjs tool lr_batch_pipeline '{"profile":"denoise-only"}'
node tests/e2e/mcp-runner.mjs tool lr_batch_status '{"jobId":"<job-id>"}'
```

`manual-test.mjs` bypasses MCP and sends one raw socket request. Use it only to distinguish plug-in transport failures from MCP failures.

Any command that mutates photos or collections must use a disposable catalog or explicitly authorized test photos. Never point these checks at a production catalog by assumption. Do not add job files, tokens, logs, RAW files, catalogs, absolute personal paths, or discovered preset UUIDs to the repository.
