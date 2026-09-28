# Lightroom AI Batch MCP setup (Windows x64)

MCP is optional. You do not need this executable when using only the Lightroom menu.

1. Extract the complete archive to a permanent directory. Keep the executable
   beside `LightroomMCP.lrplugin`.
2. Optionally install the bundled plug-in with:

   ```powershell
   .\lightroom-ai-batch-mcp.exe install-plugin
   ```

   An existing installation is preserved, including its user configuration.
   This is a first-install helper, not an overwrite upgrader.
3. Restart Lightroom Classic. In **File → Plug-in Manager**, select the plug-in
   and click **Start Server**.
4. Replace the placeholder command path in `mcp-config.example.json` with the
   absolute executable path, then merge it into your MCP client's configuration.
5. Restart the MCP client and verify that `lr_batch_pipeline`,
   `lr_batch_status`, and `lr_batch_cancel` are listed.

The executable is self-contained for Windows x64: Node.js and the source tree
are not required. The Lightroom plug-in and MCP process must use matching
request/response ports; the defaults are 58763 and 58764.
