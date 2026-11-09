# 版本验证证据

[English](VALIDATION.en.md) · [返回 README](../README.md)

本文只保留公开发布需要的脱敏统计，不包含私人路径、完整文件名、Photo ID、Job ID、Catalog 名或照片内容。

下列原有测试属于 v1.0.0；v1.0.1 的稳定性补丁验收单独记录，不能把旧版大批量数据视为新版压力测试。

## v1.1.0 验证（2026-11-09）

- 235 项 Lua 测试、208 项 TypeScript 测试通过；类型检查、ESLint、Selene 和构建通过。
- 模拟测试覆盖类别独立保存、保存/开始、选择冻结、UUID 变化后的文件身份匹配、搜索收藏、已处理照片追加模块、取消后的迟到返回、风格切换、Denoise 保持/恢复，以及状态窗口的取消和关闭行为。
- 最终菜单只保留工作台。插件包 / MCP 包分别包含 37 / 39 个文件，包含许可证；默认配置不包含本机 SDK UUID 或工作台用户设置。
- 用户确认三个中文页签正常显示；启用 Lightroom 预设组后，SDK 枚举从 77 项增加至 98 项，找到人像、天空及 CN13。

### 9 张测试 RAW 的完整方案

方案为基础去杂色 50、逐图 Auto Tone、Subject/Pop、八类 Landscape，加平滑面部皮肤、增强衣服、天空蓝色增强、CN13。使用用户指定的 Nikon NEF 测试照片，共用菜单和 MCP 后端：

- 9/9 完成，失败 0、跳过 0、warning 0，总耗时 1,431 秒（23 分 51 秒）。
- 36 个额外预设模块完成；保留 29 个独立 Landscape masks，不存在的类别正常跳过。
- 九张最终均为 Denoise 开启、Amount 50、无需更新，没有触发去杂色恢复。
- AI Mask Update 用时依次为 21、34、625、24、20、140、34、41、56 秒。最长的一张人像仍能自然完成并进入下一张；心跳不作为完成依据。
- 九张各 35 项可读取的 CN13 曲线、HSL 等参数与原预设一致；Auto Tone Exposure 有八个不同结果，范围 -0.37 至 1.74。
- 立即重跑同方案，58 秒内九张全部跳过；事件中没有新的 SDK operation、预设应用或 AI mask update。

### 已处理照片追加模块与取消后补完

- 在其中一张已处理照片上追加综合人像和 CN13，在人像预设原生调用尚未返回时请求取消。
- 任务在 6 秒内安全取消；新增人像已记为 APPLIED，未提交的风格正常跳过。worker 和 operation 均释放，无需重启 Lightroom。
- 以同方案重新提交，15 秒完成：人像记录为“已应用，补计算”，没有再次应用；只重新应用应当最后执行的 CN13，完成 AI update 和空蒙版清理。
- Denoise 最终仍为开启、50、无需更新，CN13 可读取参数再次核对一致。
- 原九张选择恢复，后续读取和提交均正常。

独立 Windows MCP EXE 在源码目录外、子进程 PATH 不含 Node 的环境完成初始化、21 个工具枚举（含三个 batch tools 和 recipe schema），并查询上述真实任务。退出后释放连接锁。

覆盖边界：本轮没有调用云端图像模型。三个页签的显示由用户确认；组合持久化及最后精简后的刷新/取消界面通过模拟检查，尚未再次手动逐项操作。人像/天空与手动应用的逐像素外观对照、每个人像细节和专门的室内食物样片未全部覆盖；没有复现此前 Adobe 原生“无法正常显示”故障，不能据此宣称 Adobe 故障已修复。

## 实测环境

- Windows 11 Home 64-bit。
- Lightroom Classic 15.5.1，构建 `202608131348-cab7eed5`。
- NVIDIA RTX 4060 Laptop GPU。
- 测试输入为 Nikon NEF RAW；不同相机、分辨率、硬件、蒙版复杂度和 Lightroom 后台负载会显著影响耗时。

推荐 Lightroom Classic 15.4 或更高版本。15.3.1 的基础 capability probe 可以连接 MCP、冻结 selection、逐图 Auto Tone、枚举/应用 Pop、创建 Landscape 和更新 AI masks，但真正 Denoise 在多张连续处理时不稳定，因此不把该版本列为首发实测支持版本。

## 31 张 RAW Denoise soak test

- 从 32 项选择中冻结 31 张 RAW；一个 JPEG 被显式排除。
- 31/31 完成真正 AI Denoise，Amount 50；失败 0，跳过 0。
- 总耗时 572 秒。
- 单张 Denoise 15–18 秒，中位数 17 秒，平均 16.71 秒。
- 每张最终均为 `denoiseState=true`、`enhanceNeedsUpdate=false`。
- 原始 32 项 UI selection（包括排除的 JPEG）在 Job 后恢复。
- 立即重跑 31 张时，所有 Denoise 阶段均为 `idempotent skip`，没有再次提交 Enhance。

## 18 张 RAW Full Prepare pilot

- 18/18 完成，失败 0、跳过 0、warning 0。
- 总耗时 1,219 秒（20 分 19 秒）。
- 每张完成真正 Denoise、独立 Auto Tone、Adaptive Subject / Pop、Landscape 和 AI Mask Update。
- Denoise 15–35 秒，平均 18.94 秒。
- AI Mask Update 5–136 秒，平均 40.44 秒；等待依据 SDK 状态，不是固定 sleep。
- 共保留 29 个独立 Landscape masks：Architecture 9、Artificial Ground 8、Sky 5、Vegetation 5、Mountains 1、Natural Ground 1。
- Water 和 Snow 在该批照片中不存在，均正常跳过，没有造成照片失败。
- 18 张均写入 `processed=true` 和四个阶段的 COMPLETE；原 selection 恢复。

## 五张 Full Prepare 与逐图 Auto Tone

- 5/5 完成，失败 0、跳过 0，491 秒。
- 五张 Auto Tone Exposure 结果分别不同，证明每张独立计算，并非复制首张参数。
- 共保留 11 个独立 Landscape masks；不存在类别正常跳过。
- 立即重跑在 2 秒内把五张全部标为已处理 skip，没有新增重复 masks。

## Landscape v2 / Denoise 保持与修复

在单张未处理 RAW 上执行一次 `force=true` Full Prepare：

- Denoise、Auto、Pop、Landscape v2 和 AI Mask Update 全部完成。
- Landscape 后和最终状态均为 Denoise 开启、Amount 50、`enhanceNeedsUpdate=false`。
- 没有触发恢复；存在的两个 Landscape 类别成为独立 masks，其余正常跳过。

随后手动关闭同一照片的 Denoise，并按默认 `skipProcessed=true` 再运行：

- 识别为历史 processed 状态需要修复。
- 只重新运行 Denoise 和 AI Mask Update。
- Auto、Pop、Landscape 均为 `idempotent skip`，没有重复添加 masks。
- 8 秒完成，最终 Denoise 开启、Amount 50、无需更新。

## 菜单和本地化

- 插件从增效工具管理器重新载入后，简体中文插件名称、五个菜单、任务开始/完成弹窗、服务器字段和按钮均显示中文。
- 中英文翻译表各 60 个 key，与 Lua 引用集合完全一致。
- 菜单启动的 Job 与 MCP Handler 共用同一 backend。

## 状态与持久化

- 启动调用立即返回 Job ID，长任务由 Lightroom worker 继续执行。
- 状态查询在 AI 处理中保持可用；取消在安全边界生效。
- JSON 快照、JSONL 事件和 pipeline state 均可解析。
- Windows 快照替换窗口由 `.previous` 完整代回退保护。
- Lightroom 重启后的已完成照片仍能幂等 skip；非终态 Job 不会被错误描述为自动续跑。

## 发行构建

- 使用 Node.js 24.21.0 从空目录执行 `npm ci`，TypeScript check、ESLint、206 项 Jest 测试和生产构建全部通过。
- MCP 生产依赖的 `npm audit` 结果为 0 个已知漏洞。
- 白名单构建得到插件 ZIP（37 个文件）和 Windows MCP ZIP（39 个文件）；两包均包含许可证，且不包含源码依赖、日志、token、照片或 Catalog。
- 在源码目录之外解压 MCP 包后，独立 EXE 的版本、帮助、相邻插件安装、MCP 初始化和 21 个工具枚举均通过；该 EXE 不依赖 Node.js。
- `SHA256SUMS` 已用两个最终 ZIP 重新计算并反向校验。

## v1.0.1 本地验收（2026-10-05）

在上述 Windows 11 + Lightroom Classic 15.5.1 环境中，从新解压的候选发行包安装插件，保留既有配置、Pop UUID 和处理记录。

- 对用户指定的五张测试 RAW 执行 `force=true` Full Prepare：5 张完成，失败 0、跳过 0，用时 508 秒（8 分 28 秒）。其中三张最初未启用 Denoise，另两张已启用；已满足条件的 Denoise 不重复提交。
- 五张均完成独立 Auto Tone、Pop、Landscape 和 AI Mask Update。最终 Denoise 均开启、Amount 50、`enhanceNeedsUpdate=false`；没有触发 Denoise 恢复。
- 保留的独立 Landscape masks 数量依次为 4、4、3、2、1，共 14 个；不存在的类别正常跳过。
- 不重启 Lightroom，立即对同五张执行默认 Full Prepare：5 张全部因已处理且实时 Denoise 状态正确而跳过，用时 23 秒。事件记录中没有新的 SDK operation，也没有再次应用预设或更新蒙版。
- 两次任务结束后均为 `workerRunning=false`、无活动 operation、`restartRequired=false`；原五张选择恢复。
- 213 项 Lua 测试和 207 项 TypeScript 测试通过；类型检查、ESLint、Selene、构建、版本与默认配置一致性检查通过。模拟测试覆盖明确 SDK 错误、不可编辑照片、取消排空、未返回调用隔离、迟到返回、worker 异常退出、菜单任务定位，以及中断后补完空蒙版清理和强制重跑的 processed 状态保护。
- 候选插件 ZIP 包含 38 个文件，Windows MCP ZIP 包含 40 个文件；白名单与校验和检查通过。在源码目录之外解压的 EXE，以不含 Node.js 的运行环境完成 MCP 初始化、21 个工具枚举和状态查询。
- 中英文翻译表各 66 个 key，静态核对一致；新增状态/取消界面仍待用户可见验收。

随后使用用户选定、包含此前卡住照片的 12 张 RAW 验收稳定性修复：

- `force=true` Full Prepare：12/12 完成，失败 0、跳过 0、warning 0，用时 764 秒（12 分 44 秒）。其中七张最初未启用 Denoise，五张已启用。
- 最终 12 张 Denoise 均开启、Amount 50、无需更新。保留 19 个独立 Landscape masks；原 12 张选择恢复。
- AI Mask Update 单张 14–74 秒；此前卡住照片本次为 60 秒，正常完成后继续处理下一张。
- 两张小任务在第一张的原生 AI Mask Update 调用运行时取消。60 秒排空窗口结束后，任务明确为 FAILED（当前照片失败 1、未提交照片跳过 1），而非假报成功取消；未提交下一张。
- 原调用在开始后 88 秒真实返回，状态查询显示 `callReturned=true`、无活动 operation、`workerRunning=false`、`restartRequired=false`。无需重启，新任务正常启动；默认补完任务在 8 秒内完成一张、跳过一张。
- 取消恢复验收暴露了漏清理空蒙版的边界情况，已补充针对性修复和回归测试；这一补充仍待重新载入后的单张实机验收。

边界：这些主路径测试没有复现此前 Lightroom 的“无法正常显示”原生故障。模拟故障测试验证的是插件隔离与恢复逻辑，不能证明 Adobe 的显示/GPU 故障已修复。可见菜单与新增恢复收尾仍待用户验收；该候选版本尚未发布。

## v1.0.0 结论

Windows 11 + Lightroom Classic 15.5.1 上，v1.0.0 的 Denoise-only 和 Full Prepare 主路径均通过真实 RAW 批处理验证。耗时数据只用于展示量级，不能外推到其他机器或照片。
