# Lightroom AI Batch MCP server

This directory contains the optional TypeScript MCP bridge. Normal Lightroom
menu use does not require Node.js, this server, or an AI agent.

Release users should download the Windows x64 MCP ZIP produced by
`scripts/build-release.ps1`; it includes a standalone executable and the
matching Lightroom plugin. Source-tree development commands are documented in
the repository root README and `CONTRIBUTING.md`.

Commands exposed by the compiled executable:

```text
lightroom-ai-batch-mcp.exe [stdio]
lightroom-ai-batch-mcp.exe install-plugin
lightroom-ai-batch-mcp.exe --help
lightroom-ai-batch-mcp.exe --version
```

The internal socket/token paths retain the historical `lightroom-mcp` name so
existing installations and processing state remain compatible.
