# 架构与实现原理

[English](ARCHITECTURE.en.md) · [返回 README](../README.md)

本文描述 v1.1.0的实际实现。涉及 Landscape preset 内部结构的部分是本项目的实测兼容方案，不代表 Adobe 承诺的稳定公共 API。新增工作台的实机验收状态单独记在验证记录中。

## 设计边界

运行路径严格按以下优先级设计：

1. Lightroom Classic SDK / Develop API。
2. Lightroom preset 与 Lightroom 自身的 AI 重新计算机制。
3. 键盘快捷键或 Windows UI Automation。
4. 图像识别。

正式运行路径只使用前两层；没有 UI 自动化、绝对坐标点击或 `.lrcat` SQLite 修改，也不会改写 RAW 文件。

## 组件

| 文件 | 责任 |
| --- | --- |
| `BatchPipeline.lua` | 选择冻结、队列、逐图阶段、错误隔离、选择恢复；菜单和 MCP 的唯一 backend。 |
| `AiState.lua` | Develop Controller 绑定同步、真正 Denoise、Enhance 状态轮询、AI mask 更新轮询。 |
| `AiOperation.lua` | 独立 SDK 调用上下文、共享串行门闩、调用返回确认、异常收尾及诊断状态。 |
| `BatchJobStore.lua` | 内存 Job、JSON 快照、JSONL 事件、取消标志和状态计数。 |
| `PipelineState.lua` | 独立于 Catalog private metadata 的持久化幂等索引。 |
| `PipelineConfig.lua` | 默认值、运行配置、请求覆盖、校验和 Pop UUID 保存。 |
| `SubjectPreset.lua` | 通过 backing-file 身份发现 Adaptive Subject / Pop，并保存 SDK UUID。 |
| `RecipePresets.lua` | 复用预设枚举，识别可用类别、预检 UUID 并生成方案快照。 |
| `Workbench.lua` / `WorkbenchState.lua` | 原生分类配置窗口、搜索/收藏和插件目录外的用户设置。 |
| `LandscapePreset.lua` | 生成包含独立 Landscape correction/mask 的 plugin preset。 |
| `PipelineCollections.lua` | 创建和维护 Processed、Failed、Skipped 集合。 |
| `HandlerBatch.lua` | MCP 三个工具的薄适配层。 |
| `MenuBatchCommon.lua` | 菜单启动、状态和取消；调用同一 Handler/Backend。 |
| `server/src/tool-contracts.ts` | MCP 工具 schema。 |

## 从提交到结束

`BatchPipeline.start()` 首先合并配置和 profile，然后读取提交时的 selection。每张照片只保存稳定 `localIdentifier`、文件名等 Job 信息；执行队列保存冻结的 Photo IDs。之后 Lightroom 当前选择如何变化都不会改变这个 Job。

启动创建 `QUEUED` JSON 快照，加入单 worker 队列并立即返回 Job ID。worker 逐个重新解析冻结 ID、选择单张照片并确认 `catalog:getTargetPhoto()` 已绑定；所有处理阶段串行执行，避免多个 Enhance 操作争抢 Develop Controller。

每张照片独立捕获错误，并先检查可编辑状态。照片失败且内部调用已安全退出后，worker 继续下一张。SDK 操作仍未返回时停止提交后续照片，不切换选择；Job 安全结束后恢复提交前的 active photo 和选择。若调用在 Job 已结束后才返回，不再自动恢复原选择，需要用户重新选择照片。冻结任务还绑定提交时的 Catalog，切换 Catalog 不会把相同数字 ID 当作另一张照片处理。

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

每个循环检查取消标志和 deadline。轮询间隔仅用于读取状态，不代表“等待这么久就算完成”。`AiOperation` 的共享门闩同时约束 Enhance、预设、Auto Tone、mask 更新和空 mask 清理。Denoise 必须等 SDK 调用返回后，再确认界面状态符合完成条件。

### Landscape 后保护

当前 Landscape preset 只携带 mask 结构，不写入顶层 `FilterList`，因此应用 preset 时不会主动覆盖 Enhance/Denoise 状态。

流水线在整个预设序列后和照片结束前实时检查 Denoise。保留 `afterLandscape`，工作台任务增加 `afterPresets`。如果状态丢失，每张照片最多重新执行一次 Denoise，然后再次 Update AI Masks；禁止循环恢复。状态和恢复结果写入 `denoiseValidation`。恢复失败使该照片 FAILED，不进入 Processed。

## 原生分类工作台

`MenuAIBatchWorkbench.lua` 通过 `LrView` / `LrDialogs` 打开配置窗口。五个类别是分别保存的设置标签，不做自动分类。配置窗口在处理前关闭；当前照片 IDs 提交给 `MenuBatchCommon.start()`，进入与 MCP 相同的 `HandlerBatch` 和 worker。工作台是唯一菜单入口。任务运行时打开工作台会显示状态，提供刷新、关闭和取消当前任务；取消绑定窗口显示的 Job ID。关闭或 Escape 不取消任务，避免配置窗口阻挡 Develop。

基础设置来自已安装配置，额外效果首次关闭。主体单选，综合人像可追加细节，天空和普通风格各选一个。顺序为综合人像 → 细节 → 天空，位于 Landscape 之前；风格位于 Landscape 之后。均使用预设原始强度。全局参数的覆盖关系与 Lightroom 手动依次应用一致。

`RecipePresets` 复用 `HandlerDevelop.presetEntries()` 获取 SDK 对象，并按 UUID 去除别名重复。依赖内部 backing-file 路径识别 Adaptive Subject、Portrait、Sky，不以界面中英文名称作唯一身份。其他 AI 类别未开放。MCP 可选 `recipe` 包含 `category` 和有序的 `presetUuids`（最多 32 个不重复 UUID）；主体沿用 `config.subjectPreset`。天空和风格各最多一个，风格必须最后。缺失或不支持的预设在创建 Job 前报错。

SDK 只枚举 Lightroom 中已显示的组；工作台提示用户在“预设 ＋ → 管理预设”启用主体/人像组。默认主体预设也在创建 Job 前解析，避免处理到半途才发现隐藏组。

类别选择、收藏和 UUID 对应的文件身份保存在运行目录中的 `workbench.json`。应用变更导致 UUID 变化时可按文件身份重新匹配；仍不可用的选择先提示再取消勾选。保存/开始会保存窗口内编辑过的类别；关闭取消不保存。`force` 不保存为下次默认值。文件使用临时代和上一完整代，不进入发行包。

## 逐模块执行与持久化

额外预设都进入 `AiOperation` 和现有的逐图错误隔离。SDK 上下文在预设成功应用后立即记录 `presetModules[uuid].status = APPLIED`，包括所属 Job 结束后才迟到返回的调用。重跑补完 AI 计算和清理，不再次应用同一预设；终检通过后提升为 COMPLETE。每张照片的 `modules` 与 `PRESET:<uuid>` 事件记录名称、状态、时间及原因；`job.recipe` 保存解析后的摘要和确定性签名。

旧的 `processed=true` 不会挡住新模块。整张跳过还要求已启用的基础阶段完成、主体身份与 Landscape 类别匹配、实时 Denoise/AI 状态正确，并且所请求的模块完成。`subjectPresetUuid` 和 `landscapeFeatures` 记录基础选择变化；没有身份字段的旧记录兼容现有 Pop/默认 Landscape 工作流。`stylePresetUuid` 记录最近风格，使 A → B → A 会重新应用 A。取消勾选不撤销旧调整；需要覆盖手动修改时显式强制重跑。

Lightroom 对每张照片重新计算主体、人像、天空蒙版，之后清理空蒙版。AI 区域不存在时，预设声明的其他全局设置仍可能生效。v1.1.0 不运行云端模型，视觉建议属于后续阶段。

Auto Tone 重新计算、或追加的预设包含非蒙版的全局设置时，会使当前风格标记失效；若方案选有风格，则最后重新应用。仅含蒙版和预设元数据的细节不使标记失效，保留用户手动色彩微调。

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

之后才清理空 Landscape masks 和读取最终 mask 结果。Landscape 预设应用已完成、但整张照片尚未完成时，默认重跑仍执行空蒙版清理，不重复应用预设。

### 调用生命周期与失败边界

耗时操作使用 `LrFunctionContext.postAsyncTaskWithContext()` 建立独立上下文，记录 operation ID、job/photo ID、调用开始和 `callReturned`。明确的调用异常或完成检查异常立即成为失败，不当作普通未就绪状态反复等待。

Catalog 写入权限等待使用独立的 `runtime.writeAccessTimeoutSeconds`，并检查 `withWriteAccessDo()` 是否返回 `executed`；这个期限不用于强行终止已经进入 callback 的 AI 工作。

超时/取消时不立即释放门闩，而是设置 abort 标志并进入 `DRAINING`。未开始的写入 callback 检查该标志，避免取消后迟到的操作继续修改照片。只有观察到实际调用返回，才释放门闩。收尾期限后仍未返回则为 `RESTART_REQUIRED`，当前 Job 失败、后续照片 skipped、排队 Job 明确失败。新操作被拦截；旧调用后来确实返回才可重新提交，否则需重启 Lightroom。

worker 的上下文 cleanup 只清理自身身份，不在 cleanup 中 yield 或写 Catalog。独立 monitor/后续状态查询将意外退出的 Job 记为 FAILED。generation 校验防止旧 cleanup 改写新 worker。心跳只说明观察任务仍在运行，不证明 Lightroom AI 有计算进展，更不证明原生调用已经结束。

mask 更新失败后直接结束该照片，不在不可编辑或仍占用写入权限时触发 Denoise 恢复。集合标记及 private metadata 镜像在有未结束操作时延后/跳过并记录诊断；外部状态保留处理结果。

## Job、状态和取消

Job 快照位于 `~/.config/lightroom-ai-batch/jobs/<jobId>.json`，逐事件日志为同名 `.jsonl`。写入使用每次唯一临时文件、每个目标文件的协作锁，以及 `.previous` 完整代备份，降低 Windows 替换窗口中的损坏风险。

菜单和 MCP 都只提交 Job，不等待整批完成。`lr_batch_status` 返回快照；`lr_batch_cancel` 设置 `cancelRequested`。Denoise/mask 轮询和阶段边界都会观察该标志。取消不会强行终止 Lightroom 正在修改内部状态的调用。

启动返回实际状态（通常 `QUEUED`），不把排队任务描述成运行。排队取消立即移除任务并记为 CANCELLED。菜单查询/取消通过 backend 优先定位实际运行 Job；处理菜单运行中只显示已有任务。状态附加 current photo、queue position、heartbeat、active operation 和 restartRequired，不改变公共工具名或 Job 终态。发行号 v1.1.0 与幂等格式版本分开，后者保留 1.0.0。

当前持久化用于查询和诊断，不是自动续跑系统。Lightroom 重启后，读取非终态 Job 会将其标为 FAILED，并写明重启中断。

## 幂等性与 Denoise 状态检查

阶段状态同时写入：

- 插件 private metadata：便于 Catalog 内查看和搜索；
- `pipeline-state.json`：以 Catalog path、Photo ID、源文件 path 组成键，作为可靠持久化索引。

字段包括 `pipelineVersion`、`jobId`、各阶段状态、`processed` 和 `processedAt`。

未被整张跳过的 Full Prepare/configured 照片在处理阶段前先写入 `processed=false`，包括对已处理照片的强制重跑。仅最终检查全部通过才恢复 `processed=true`，中断不会让部分重新应用的流水线仍被标记为完成。

完整 profile 的快速 skip 发生在目标照片已经被激活、实时 Denoise 已检查之后。若 metadata 记录 Denoise complete/processed，但当前 panel 状态关闭、Amount 不符或仍需更新，则以实时状态为准：只重跑 Denoise，按已记录的阶段状态跳过 Auto/Pop/Landscape，再更新现有 AI masks。这个针对性修复不改变 pipelineVersion，也不会触发整张照片的完整重跑。

## 配置来源

`config/pipeline.json` 是仓库默认值的唯一源。`scripts/sync-config.mjs` 检查或更新源码插件副本；发行构建始终直接把根配置复制到包内，避免漂移。

运行时优先级：默认值 → 插件内文件 → 每 Job `config` → 顶层 force/skipProcessed → profile 阶段开关。Pop UUID 的自动保存只更新持久配置中的 UUID，不会把临时 Job override 写回。

## 本地化

可见字符串通过 Lightroom SDK `LOC` key 提供。`TranslatedStrings_en.txt` 和 `TranslatedStrings_zh_cn.txt` 覆盖插件名、工作台入口、工作台、弹窗、管理器、按钮、metadata 标题和历史记录操作；两份表必须包含相同 key。preset 名、mask 名、集合名、配置键、MCP 工具名、状态码和日志保持英文，以保证跨语言数据兼容。其他语言使用调用处的英文默认字符串。预设的显示标签来自 Lightroom SDK。

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
