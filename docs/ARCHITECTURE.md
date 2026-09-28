# 架构与实现原理

[English](ARCHITECTURE.en.md) · [返回 README](../README.md)

本文描述 v1.0.0 的实际实现。涉及 Landscape preset 内部结构的部分是本项目的实测兼容方案，不代表 Adobe 承诺的稳定公共 API。

## 设计边界

运行路径严格按以下优先级设计：

1. Lightroom Classic SDK / Develop API。
2. Lightroom preset 与 Lightroom 自身的 AI 重新计算机制。
3. 键盘快捷键或 Windows UI Automation。
4. 图像识别。

v1.0.0 的正式运行路径只使用前两层；没有 UI 自动化、绝对坐标点击或 `.lrcat` SQLite 修改，也不会改写 RAW 文件。

## 组件

| 文件 | 责任 |
| --- | --- |
| `BatchPipeline.lua` | 选择冻结、队列、逐图阶段、错误隔离、选择恢复；菜单和 MCP 的唯一 backend。 |
| `AiState.lua` | Develop Controller 绑定同步、真正 Denoise、Enhance 状态轮询、AI mask 更新轮询。 |
| `BatchJobStore.lua` | 内存 Job、JSON 快照、JSONL 事件、取消标志和状态计数。 |
| `PipelineState.lua` | 独立于 Catalog private metadata 的持久化幂等索引。 |
| `PipelineConfig.lua` | 默认值、运行配置、请求覆盖、校验和 Pop UUID 保存。 |
| `SubjectPreset.lua` | 通过 backing-file 身份发现 Adaptive Subject / Pop，并保存 SDK UUID。 |
| `LandscapePreset.lua` | 生成包含独立 Landscape correction/mask 的 plugin preset。 |
| `PipelineCollections.lua` | 创建和维护 Processed、Failed、Skipped 集合。 |
| `HandlerBatch.lua` | MCP 三个工具的薄适配层。 |
| `MenuBatchCommon.lua` | 菜单启动、状态和取消；调用同一 Handler/Backend。 |
| `server/src/tool-contracts.ts` | MCP 工具 schema。 |

## 从提交到结束

`BatchPipeline.start()` 首先合并配置和 profile，然后读取提交时的 selection。每张照片只保存稳定 `localIdentifier`、文件名等 Job 信息；执行队列保存冻结的 Photo IDs。之后 Lightroom 当前选择如何变化都不会改变这个 Job。

启动创建 `QUEUED` JSON 快照，加入单 worker 队列并立即返回 Job ID。worker 逐个重新解析冻结 ID、选择单张照片并确认 `catalog:getTargetPhoto()` 已绑定；所有处理阶段串行执行，避免多个 Enhance 操作争抢 Develop Controller。

每张照片独立捕获错误。照片失败后进入 Failed，worker 继续下一张。Job 结束后恢复提交前的 active photo 和选择。

## Denoise

真正入口是：

```lua
LrDevelopController.setEnhance("denoise", true, amount)
```

Amount 来自配置，默认 50。提交前不会固定等待若干秒，而是观察：

- 目标照片可编辑；
- `getEnhancePanelState().denoiseEnabled == true`；
- 上述 ready 状态连续三个轮询周期稳定。

完成条件为：

- `denoiseState == true`；
- `denoiseAmount == config.denoise.amount`；
- `enhanceNeedsUpdate == false`；
- 照片恢复可编辑。

每个循环检查取消标志和 deadline。轮询间隔仅用于读取状态，不代表“等待这么久就算完成”。同一进程还使用 `enhanceTaskBusy` 阻止重叠 Enhance 调用。

### Landscape 后保护

当前 Landscape preset 只携带 mask 结构，不写入顶层 `FilterList`，因此应用 preset 时不会主动覆盖 Enhance/Denoise 状态。

流水线还在 Landscape 后和照片结束前实时检查 Denoise。如果状态丢失，每张照片最多重新执行一次 Denoise，然后再次 Update AI Masks；禁止循环恢复。状态和恢复结果写入 `denoiseValidation`。恢复失败使该照片 FAILED，不进入 Processed。

## Auto Tone

worker 已经把当前照片设为唯一 active photo，随后调用一次：

```lua
LrDevelopController.setAutoTone()
```

下一张照片会重新选择并再次调用，因此每张由 Lightroom 独立计算。代码没有读取第一张的 Exposure/Highlights/Shadows 再复制给其他照片。

## Adaptive Subject / Pop

首次运行遍历 `LrApplication.developPresetFolders()`。发现逻辑匹配 preset backing file：文件名 `Pop.xmp`，路径身份位于 `Adaptive - Subject`；它不以中文“流行”或英文 “Pop” 显示名作为唯一标识。

发现唯一匹配项后保存 `preset:getUuid()` 到已安装插件的配置。后续先按 UUID 查找。每张照片单独调用 `photo:applyDevelopPreset()`，最后由 Lightroom 的 AI update 对该图重新计算主体蒙版，不复制第一张照片的 mask 坐标。

如果 backing-file 结构改变、没有匹配项或出现歧义，该阶段记录失败原因，不猜测另一个本地化名称。

## Landscape 子类别

`LandscapePreset.lua` 为请求中的每个类别建立一个独立 `Correction` 和 `Mask/Image`，名称统一为 `AUTO Landscape - <Feature>`。当前映射：

| Feature | SubCategory ID |
| --- | ---: |
| Architecture | 50001 |
| Mountains | 50002 |
| Artificial Ground | 50003 |
| Natural Ground | 50004 |
| Vegetation | 50005 |
| Sky | 50006 |
| Water | 50007 |
| Snow | 50008 |

每个 correction/mask 使用根据类别 ID 确定生成的固定 SyncID，局部曝光、颜色等参数全部为中性值。preset 内部名包含格式版本和有序类别 ID，使同一组类别拥有稳定身份，不同结构不会共用缓存。

Lightroom 应用 preset 后为每张照片重新计算 AI 内容。`catalog:updateAISettings({photo})` 完成后调用 `deleteAllEmptyMasks()`，所以照片中不存在的 Water、Snow 等类别成为正常 skip，而不会令照片失败。随后读取 `MaskGroupBasedCorrections`，记录实际保留的独立 mask 与缺失类别。

这套 preset 序列化结构和 5000x ID 是 Lightroom 15.5.1 实测结果，不应描述为 Adobe 稳定 API。升级 Lightroom 后应先用测试 RAW 验证。

## AI Mask Update

`AiState.updateMasks()` 在异步 Lightroom task 中调用：

```lua
catalog:updateAISettings(photos)
```

完成条件不是调用返回后固定等待，而是所有目标照片同时满足：

- `photo:needsUpdateAISettings() == false`；
- `photo:isAvailableForEditing() == true`。

之后才清理空 Landscape masks 和读取最终 mask 结果。

## Job、状态和取消

Job 快照位于 `~/.config/lightroom-ai-batch/jobs/<jobId>.json`，逐事件日志为同名 `.jsonl`。写入使用每次唯一临时文件、每个目标文件的协作锁，以及 `.previous` 完整代备份，降低 Windows 替换窗口中的损坏风险。

菜单和 MCP 都只提交 Job，不等待整批完成。`lr_batch_status` 返回快照；`lr_batch_cancel` 设置 `cancelRequested`。Denoise/mask 轮询和阶段边界都会观察该标志。取消不会强行终止 Lightroom 正在修改内部状态的调用。

当前持久化用于查询和诊断，不是自动续跑系统。Lightroom 重启后，读取非终态 Job 会将其标为 FAILED，并写明重启中断。

## 幂等性与 Denoise 状态检查

阶段状态同时写入：

- 插件 private metadata：便于 Catalog 内查看和搜索；
- `pipeline-state.json`：以 Catalog path、Photo ID、源文件 path 组成键，作为可靠持久化索引。

字段包括 `pipelineVersion`、`jobId`、各阶段状态、`processed` 和 `processedAt`。

完整 profile 的快速 skip 发生在目标照片已经被激活、实时 Denoise 已检查之后。若 metadata 记录 Denoise complete/processed，但当前 panel 状态关闭、Amount 不符或仍需更新，则以实时状态为准：只重跑 Denoise，按已记录的阶段状态跳过 Auto/Pop/Landscape，再更新现有 AI masks。这个针对性修复不改变 pipelineVersion，也不会触发整张照片的完整重跑。

## 配置来源

`config/pipeline.json` 是仓库默认值的唯一源。`scripts/sync-config.mjs` 检查或更新源码插件副本；发行构建始终直接把根配置复制到包内，避免漂移。

运行时优先级：默认值 → 插件内文件 → 每 Job `config` → 顶层 force/skipProcessed → profile 阶段开关。Pop UUID 的自动保存只更新持久配置中的 UUID，不会把临时 Job override 写回。

## 本地化

可见字符串通过 Lightroom SDK `LOC` key 提供。`TranslatedStrings_en.txt` 和 `TranslatedStrings_zh_cn.txt` 覆盖插件名、五个菜单、弹窗、管理器、按钮、metadata 标题和历史记录操作；两份表必须包含相同 key。preset 名、mask 名、集合名、配置键、MCP 工具名、状态码和日志保持英文，以保证跨语言数据兼容。其他语言使用调用处的英文默认字符串。

## 如何扩展

### 新增阶段

1. 在 `BatchPipeline.lua` 定义阶段边界、public status 和 per-photo 错误处理。
2. 为耗时调用提供状态条件、deadline 和取消检查，不能用固定等待推断完成。
3. 如需幂等，在 `STAGE_METADATA` 和 `MetadataProvider.lua` 增加字段，并更新 `PipelineState` 写入。
4. 决定失败是否允许后续阶段继续；最终只有无错误照片可标为 Processed。
5. 补充 Lua spec、MCP/TypeScript test、双语文档和真实测试 RAW 证据。

### 新增 Landscape 类别

1. 先在目标 Lightroom 版本验证真实 SubCategory ID。
2. 更新 `FEATURE_IDS`、默认配置和 MCP enum。
3. 保证 correction 和 mask 拥有独立固定 SyncID、中性调整值和统一命名。
4. 验证存在与不存在类别、重复运行以及 Denoise 最终状态。

### 新增 MCP 工具

1. 在相应 `Handler*.lua` 实现并注册到 `PluginInfoProvider.lua` 的 `DISPATCH`。
2. 在 `server/src/tool-contracts.ts` 增加 contract。
3. 更新参数验证与工具枚举测试。
4. 如果菜单提供相同能力，菜单必须调用相同 handler/backend，不能复制业务逻辑。

## API 稳定性声明

项目优先使用 Lightroom SDK；但是“某个 SDK 调用在 Lightroom 15.5.1 实测可用”不等于 Adobe 对未来版本提供稳定保证。尤其是 Enhance 参数形式、Enhance panel state 和 Landscape preset 内部结构，升级后必须重新做 capability probe。Adobe SDK 入口见 [Lightroom Classic SDK](https://developer.adobe.com/lightroom-classic)。
