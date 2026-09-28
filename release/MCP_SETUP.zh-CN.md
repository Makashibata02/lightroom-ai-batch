# Lightroom AI Batch MCP 配置（Windows x64）

MCP 是可选入口。仅使用 Lightroom 菜单时不需要运行此程序。

1. 将整个压缩包解压到一个长期保留的目录，保持 EXE 与
   `LightroomMCP.lrplugin` 处于同一目录。
2. 可运行一次：

   ```powershell
   .\lightroom-ai-batch-mcp.exe install-plugin
   ```

   如果已经手动安装插件，此命令会保留现有版本，不覆盖用户配置。
   该命令只用于首次安装，不是覆盖升级器。
3. 重启 Lightroom Classic，在“文件 → 增效工具管理器”中选择插件并点击
   “启动服务器”。
4. 把 `mcp-config.example.json` 中的占位路径换成 EXE 的绝对路径，再复制到
   你的 MCP 客户端配置中。
5. 重启 MCP 客户端，确认可以枚举 `lr_batch_pipeline`、
   `lr_batch_status`、`lr_batch_cancel`。

EXE 是独立 Windows x64 程序，不要求 Node.js，也不要求保留源码目录。
Lightroom 插件与 MCP 程序必须使用相同的请求/响应端口；默认分别为
58763 和 58764。
