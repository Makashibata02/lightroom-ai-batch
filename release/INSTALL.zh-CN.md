# Lightroom AI Batch 插件安装（Windows）

此压缩包只包含 Lightroom 插件；使用菜单功能不需要 Node.js、MCP 或 AI Agent。

1. 将压缩包解压到一个长期保留的目录，不要直接从 ZIP 内运行。
2. 打开 Lightroom Classic。
3. 进入“文件 → 增效工具管理器”，点击“添加”。
4. 选择解压后的 `LightroomMCP.lrplugin` 文件夹。
5. 如果菜单没有立即刷新，请重新载入增效工具或重启 Lightroom Classic。
6. 选择 RAW 照片，进入“文件 → 增效工具额外信息”：
   - `AI 批处理 — 对所选照片去杂色`
   - `AI 批处理 — 完整预处理所选照片`

默认配置位于 `LightroomMCP.lrplugin\config\pipeline.json`。首次运行
Adaptive Subject / Pop 后，插件可能将本机发现的 preset UUID 写入该文件。

升级前请备份现有 `config\pipeline.json`。新版压缩包中的配置是默认值，
不要直接覆盖已经保存 UUID 或自定义选项的用户配置。
建议解压到新目录，把自定义值和 UUID 合并到新版配置，再在增效工具管理器中
移除旧路径并添加新路径。

卸载：在增效工具管理器中移除插件，然后删除你解压出的插件目录。
这不会删除 RAW、Catalog 或 `AI Pipeline` 集合。
