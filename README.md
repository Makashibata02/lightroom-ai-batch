# Lightroom AI Batch

[English README](README.en.md) · [架构原理](docs/ARCHITECTURE.md) · [验证记录](docs/VALIDATION.md)

Lightroom AI Batch 是一个给 Windows Lightroom Classic 用的批量预处理小工具。它把 AI 去杂色、逐张自动色调、自适应主体 Pop、Landscape 场景蒙版和 AI 蒙版更新连在一起，对当前选中的照片依次执行。

普通用户直接使用 Lightroom 菜单即可；MCP 只是可选入口，不需要让 Agent 逐张判断照片。

> 非 Adobe 官方项目。当前实测平台是 Windows 11 + Lightroom Classic 15.5.1。建议使用 Lightroom Classic 15.4 或更高版本；15.3 及更早版本会给出警告但不会被强制退出。

## 为什么写这个项目

我是摄影小白，电脑配置也不算好。按固定步骤逐张修图时，经常要反复等待 Lightroom 的 AI 去杂色、主体识别和各种 AI 预设加载，照片一多就很花时间。

所以我做了这个工具：先选中一批 RAW，让 Lightroom 在后台逐张完成这些重复的准备工作。等批处理结束后，我只需要检查主体，微调已经生成的部分蒙版，再按自己的想法加滤镜和调色。它不替我决定照片应该修成什么样，只是把每张都要等待的步骤提前做完。

## 目前能做什么

| 能力 | 行为 |
| --- | --- |
| 真正 AI 去杂色 | 调用 Lightroom Enhance/Denoise，不用明亮度或颜色降噪滑块冒充；默认 Amount 50。 |
| 每张独立 Auto Tone | 每张照片成为 active photo 后单独调用 Lightroom Auto Tone，不复制第一张的结果。 |
| Adaptive Subject / Pop | 首次运行从 preset backing-file 身份发现 Pop，保存 SDK UUID，避免依赖中英文显示名。 |
| 独立 Landscape masks | 为存在的 Sky、Snow、Architecture、Vegetation、Water、Natural Ground、Artificial Ground、Mountains 创建彼此独立的中性蒙版；不存在的类别正常跳过。 |
| 状态同步 | 等待 Lightroom 的实际 Enhance/AI 状态，不用固定 `sleep(30)` 猜完成时间。 |
| 异步任务 | 启动立即返回 Job ID；可查询、取消，单张失败不终止整批。 |
| 幂等与修复 | 默认跳过已完成照片；若实时发现去杂色被关闭，只修复去杂色并更新现有蒙版。 |
| 可追踪 | 每个 Job/照片/阶段记录状态、时间、耗时、失败或跳过原因，并写入 Processed/Failed/Skipped 集合。 |

实测包括 31 张 RAW 连续去杂色（31/31）和 18 张 RAW 完整流水线（18/18）。这些是特定测试照片和设备上的结果，不是速度保证；详见[验证记录](docs/VALIDATION.md)。

## 下载哪个包

GitHub Releases 提供两个包：

- `lightroom-ai-batch-plugin-v1.0.0.zip`：普通用户首选，只使用 Lightroom 菜单，不需要 Node、MCP 或 Agent。
- `lightroom-ai-batch-mcp-windows-x64-v1.0.0.zip`：包含独立 Windows x64 MCP EXE 和配套插件，不需要 Node 或源码目录。
- `SHA256SUMS`：校验两个下载文件。

## 菜单安装与使用

1. 下载并解压插件包。
2. Lightroom Classic 中进入“文件 → 增效工具管理器”，点击“添加”，选择完整的 `LightroomMCP.lrplugin` 文件夹。
3. 如果菜单未刷新，重新载入插件或重启 Lightroom。
4. 在图库或修改照片模块选中一批 RAW。
5. 进入“文件 → 增效工具额外信息”。

菜单功能：

- `AI 批处理 — 对所选照片去杂色`：只执行真正 AI Denoise。
- `AI 批处理 — 完整预处理所选照片`：Denoise → Auto Tone → Subject/Pop → Landscape → AI Mask Update。
- `AI 批处理 — 显示上一个任务状态`：显示本次 Lightroom 会话中最后启动的菜单任务。
- `AI 批处理 — 取消上一个任务`：在安全阶段边界请求取消。
- `Lightroom AI Batch — 显示 MCP 状态`：显示可选 MCP bridge 的 socket 状态。

菜单与 MCP 调用同一个 `BatchPipeline` backend。菜单功能本身不要求点击“启动服务器”；只有使用 MCP 时才需要启动 bridge。

## 可选 MCP

解压 MCP 包，保持 EXE 与 `LightroomMCP.lrplugin` 同目录。完整步骤见包内 `MCP_SETUP.zh-CN.md`。

三个批处理工具：

```json
{"tool":"lr_batch_pipeline","arguments":{"profile":"configured"}}
{"tool":"lr_batch_pipeline","arguments":{"profile":"full","force":true}}
{"tool":"lr_batch_status","arguments":{"jobId":"<job-id>"}}
{"tool":"lr_batch_cancel","arguments":{"jobId":"<job-id>"}}
```

启动返回示例：

```json
{"jobId":"...","photoCount":18,"status":"running","profile":"full"}
```

如果传入 `photo_ids`，这些 ID 直接成为冻结列表；否则在提交瞬间冻结 Lightroom 当前选择。任务处理中用户改变当前选择不会改变 Job，结束后插件会尽量恢复提交前的 active photo 和选择。

## 配置

源码中的唯一默认配置源是 [`config/pipeline.json`](config/pipeline.json)。发行构建把它复制到插件内；实际运行时读取已安装插件中的：

```text
LightroomMCP.lrplugin\config\pipeline.json
```

```json
{
  "pipelineVersion": "1.0.0",
  "denoise": { "enabled": true, "amount": 50, "timeoutSeconds": 900 },
  "autoTone": { "enabled": true },
  "subjectPreset": { "enabled": true, "uuid": "" },
  "landscape": {
    "enabled": true,
    "features": [
      "Sky", "Snow", "Architecture", "Vegetation", "Water",
      "Natural Ground", "Artificial Ground", "Mountains"
    ],
    "timeoutSeconds": 900
  },
  "skipProcessed": true,
  "force": false,
  "processedCollection": "AI Pipeline / Processed",
  "pollIntervalSeconds": 0.25
}
```

合并优先级从低到高为：内置默认值 → 已安装插件的 JSON → MCP `config` 覆盖 → MCP 顶层 `force`/`skipProcessed` → profile 对阶段开关的强制设置。

- `configured`：按 JSON 和请求覆盖执行。
- `denoise-only`：强制开启 Denoise，关闭 Auto Tone、Subject 和 Landscape；不会把照片标为完整 processed。
- `full`：强制开启四个阶段，Amount、timeout、feature list 等仍来自配置。

首次找到 Adaptive Subject / Pop 后，插件会把本机 SDK preset UUID 保存到运行配置。发行默认值始终为空，不包含开发者机器 UUID。

## 重跑、取消与 Lightroom 重启

- 默认 `skipProcessed=true`。pipelineVersion 相同、`processed=true` 且实时去杂色状态正确时整张跳过。
- 如果已完成照片的 Denoise 被手动关闭或 Amount 改变，默认重跑只修复 Denoise，再更新已有 AI masks；Auto Tone、Pop、Landscape 不重复应用。
- 插件无法可靠判断用户后来是否手动改过 Auto Tone 或蒙版内容。需要重新应用这些阶段时使用 `force=true`；建议先在测试副本上验证。
- 取消是协作式的：当前 Lightroom 操作到达安全边界后停止，尚未处理的照片记为 skipped。
- Job 状态会写入磁盘，但当前版本不自动续跑。Lightroom 在非终态 Job 中重启后，再查询该 Job 会将其标记为 FAILED，并说明重启中断。

## 状态、日志和集合

主要状态包括：`QUEUED`、`DENOISE_SUBMITTED`、`DENOISE_COMPLETE`、`AUTO_TONE_COMPLETE`、`SUBJECT_PRESET_COMPLETE`、`LANDSCAPE_COMPLETE`、`AI_MASK_UPDATE`、`COMPLETE`、`FAILED`、`SKIPPED`。

用户状态目录：

```text
%USERPROFILE%\.config\lightroom-ai-batch\
  pipeline-state.json
  jobs\<jobId>.json
  jobs\<jobId>.jsonl
```

`lr_batch_status` 的每张照片结果还可能包含 `denoiseValidation`，记录初始、Landscape 后、最终状态以及是否做过一次恢复。

插件会创建集合组 `AI Pipeline`，默认包含 `Processed`、`Failed`、`Skipped`。单张失败不会停止后续照片；失败照片不会进入 Processed。

## 升级与卸载

升级前等待当前 Job 结束，停止 MCP server 并退出 Lightroom。备份旧插件的 `config/pipeline.json`，把新版本解压到新的长期目录，再把自己的配置项和已发现的 Pop UUID 合并到新版配置；不要用旧文件整体覆盖新版新增字段。随后在增效工具管理器中移除旧路径、添加新版 `LightroomMCP.lrplugin` 并重启 Lightroom。内部插件 ID 和状态目录保持兼容，因此 Catalog metadata、集合和已处理索引不会因换目录而丢失。

`lightroom-ai-batch-mcp.exe install-plugin` 只做首次安装；检测到已有插件时会保留它，并不是覆盖升级器。升级 MCP 包时改用新 EXE 路径并同步升级插件。

卸载时先在增效工具管理器移除插件，再删除解压目录；如果配置了 MCP 客户端，同时移除该客户端配置。此操作不会删除 RAW、Catalog 或 `AI Pipeline` 集合。`%USERPROFILE%\.config\lightroom-ai-batch` 中的任务记录默认保留，只有确认不再需要历史后才手动删除。

## 已知限制

- 只把 Windows 11 + Lightroom Classic 15.5.1 标为实测支持环境。
- Lightroom 15.3.1 的 Denoise 曾出现 SDK/model 不稳定；插件会警告但继续。建议 15.4+。
- Landscape 子类别使用 Lightroom 可接受的 Develop preset 结构和实测类别 ID。这不是 Adobe 承诺的稳定公共 API，未来 Lightroom 版本可能改变。
- Adaptive Subject / Pop 发现依赖 preset backing-file 身份；如果 Adobe 改名或重组安装资源，阶段会失败并记录原因，不会按本地化显示名称盲选。
- 当前版本没有配置 GUI、历史任务浏览器或自动续跑。
- 运行时不修改 `.lrcat` SQLite，不改写 RAW，不使用固定屏幕坐标，也不需要 Windows UI 自动化。

## 原理概览

```text
菜单 / lr_batch_pipeline
        │
        ▼
冻结 Photo IDs → 入队并立即返回 Job ID
        │
        ▼（单 worker，逐张）
选择并确认 active photo
 → Denoise + 状态轮询
 → 每张单独 Auto Tone
 → 应用 Subject/Pop preset
 → 应用 v2 Landscape preset（独立 masks）
 → 验证/必要时恢复 Denoise 一次
 → Update AI Settings + 删除空 masks
 → 最终 Denoise 校验
 → 元数据、日志、集合
        │
        ▼
恢复原选择
```

完整设计、稳定性边界和扩展方法见[架构原理](docs/ARCHITECTURE.md)。

## 开发与发布

```powershell
cd server
npm ci
npm run check
npm run lint
npm test
npm run build

cd ..
node scripts/sync-config.mjs --check
powershell -ExecutionPolicy Bypass -File scripts/build-release.ps1
```

Lua 变更还应运行 `mise run lua:lint` 和 `mise run lua:test`。发行工作流只从 `v*` tag 构建，不修改主分支、不发布 npm，只生成两个 Windows ZIP 和 `SHA256SUMS`。

扩展指南见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 路线图

- 配置界面。
- 历史任务浏览与筛选。
- 显式的中断 Job 恢复/续跑流程。
- 更多 Lightroom 版本的社区验证矩阵。

首发版本暂不继续增加照片处理阶段，先把现有流程做稳并记录清楚。

## 来源与许可证

这个项目不是从零开始，主要参考和复用了以下开源工作：

- [varunkumar/lightroom-mcp](https://github.com/varunkumar/lightroom-mcp)：最初的主要参考，用于研究 Lightroom Enhance、Develop Controller 和 MCP 控制方式。
- [drshy-org/lightroom-py](https://github.com/drshy-org/lightroom-py)：参考 Adaptive Subject / Pop 的预设调用方式和命令行使用思路。
- [Automaat/lightroom-mcp](https://github.com/Automaat/lightroom-mcp)：本仓库 MCP transport、Catalog handlers、插件启动代码和部分测试的实际 MIT 代码基础。

具体复用范围和许可证说明见 [NOTICE.md](NOTICE.md)。项目本身使用 [MIT License](LICENSE)。
