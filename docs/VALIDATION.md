# v1.0.0 验证证据

[English](VALIDATION.en.md) · [返回 README](../README.md)

本文只保留公开发布需要的脱敏统计，不包含私人路径、完整文件名、Photo ID、Job ID、Catalog 名或照片内容。

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

## 结论

Windows 11 + Lightroom Classic 15.5.1 上，v1.0.0 的 Denoise-only 和 Full Prepare 主路径均通过真实 RAW 批处理验证。耗时数据只用于展示量级，不能外推到其他机器或照片。
