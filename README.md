# 本机AI状态栏

一个常驻桌面的原生 macOS 小工具，用 240 像素窄栏查看本机 AI Agent 状态。Codex、QwenWorkCN 和 Kimi 已接入活动线程与额度；WorkBuddy、TRAE Work 已作为平级产品接入隐私安全的安装与运行状态发现。

它只显示正在运行、等待操作或待查看的线程，按真实项目分组并保留中文项目名、中文线程名。窗口始终位于其他应用之上，可以自由摆放，也可以吸附在 Codex 左右两侧并与其底边对齐。

> 非 OpenAI、阿里云或 Moonshot 官方项目。应用只在本机读取必要的状态字段，不显示、打印、保存或上传任务正文与凭证，也不会修改任何任务数据库或会话文件。

## 长期产品入口

- [产品交接与推进基线](docs/PRODUCT_HANDOFF.zh-CN.md)：当前能力、隐私边界、已知限制、产品化路线和推广验收门。
- [产品 Skill](skills/codex-recent-tasks-sidebar/SKILL.md)：构建、测试和真实桌面验收规则。
- 当前可运行产物：`build/本机AI状态栏.app`

后续在 Codex 中继续开发时，请直接打开本仓库作为“本机AI状态栏”项目，并先读取以上两个入口。

## 构建和启动

要求：

- macOS 13 或更高版本
- 已安装 Xcode Command Line Tools
- 已在本机使用过需要监控的桌面应用或命令行工具

```bash
git clone https://github.com/chuanfan-ai/codex-recent-tasks-sidebar-skill.git
cd codex-recent-tasks-sidebar-skill
./scripts/qa.sh
open "build/本机AI状态栏.app"
```

构建产物位于 `build/本机AI状态栏.app`。确认无误后，可由用户自行放入“应用程序”文件夹；构建脚本不会覆盖 `/Applications` 中的现有应用。

## 当前行为

- 固定宽度 240 像素，使用较小的系统字号，适合作为长期监控窄栏。
- 同时显示 Codex、QwenWorkCN、Kimi 三个分区的活动线程数与剩余额度。
- WorkBuddy 与 TRAE Work 各自使用与前三款产品相同字重和字号的独立产品栏，只显示已验证的安装或运行状态，不显示也不推测任务或额度。
- “活动线程”包括“运行中”“待操作”“待查看”，已完成且无待查看更新的历史线程不会显示。
- 按项目分组，优先使用各应用保存的真实项目名与线程名，不用英文演示名替代。
- 自由模式与吸附模式都全局置顶；吸附时可选 Codex 左侧或右侧，并与 Codex 底边对齐。
- Codex 通过唯一 Thread ID 精确跳转。
- QwenWorkCN 通过本机桌面端接口按 Chat ID 精确跳转。
- Kimi 当前可打开 Agent 首页，但桌面端尚未提供可验证的单会话深链，因此不能承诺精确跳到对应线程。

## 自动读取额度

- Codex：使用已安装 Codex 自带的服务和当前登录状态，只保留内存中的剩余百分比。
- QwenWorkCN：连接正在本机运行的桌面端读取额度汇总，并只读检查桌面端持久化的主线程与子线程“待查看”集合；不会调用会消费完成通知的接口，也不读取页面标题、任务正文或账号凭证。
- Kimi：总量从 Kimi 桌面端本机订阅日志的最后一次聚合比例读取；5h 与 7 天 Code 限额来自 Kimi CLI 的 `/usage`。界面固定按“总量 / Code 5h / Code 7天”三行简洁显示，正常额度统一使用中性灰，仅延迟或不可用状态使用提醒色，不因剩余比例低而变红。CLI 使用一个专用本地监控会话并在后续刷新时复用，该会话会从活动线程列表中排除。

如果相应应用未运行、CLI 未安装或现有登录态不可用，对应额度会显示不可用或省略缺失的总量行；应用不会尝试读取密钥文件或要求后台提取 Token。

## 数据与隐私边界

- Codex：只读查询任务索引、未读 ID 和 rollout 事件类型；不解析或输出消息正文。
- QwenWorkCN：只读查询本机 `agents.db` 的项目、线程、更新时间和状态字段；数据库以只读方式打开。待查看状态只读自 `agents:unseenChanges` 与 `agents:subChatUnseenChanges`，不会被状态栏清除。
- Kimi：只读取会话索引、标题/工作目录元数据，以及判断 `step.begin` / `step.end` 所需的事件类型；不显示事件内容。总量读取仅检查 `~/Library/Logs/kimi-desktop/main.log` 末尾最多 4 MB 中最后一次 `omniRatio` 聚合字段，不输出或保存其他日志内容。只有未闭合步骤与真实运行中的 Kimi 进程工作目录一致时才显示为活动，旧会话日志会被排除。
- WorkBuddy 与 TRAE Work：只检查已验证的应用路径、Bundle ID、版本和运行状态。WorkBuddy 使用 `com.workbuddy.workbuddy`；TRAE Work 的 macOS 分发包内部仍使用 `TRAE SOLO.app` 与 `com.trae.solo.app`。不读取两款产品的日志、数据库、页面、任务、额度、账号或会话内容。
- 不提交、不复制、不上传真实数据库、会话文件、任务标题、Thread ID、Chat ID、用户名路径、Token 或重置时间。
- 本地仅保存窗口位置、吸附侧，以及 Kimi 专用监控会话的 ID。

## 验收

```bash
./scripts/qa.sh
./scripts/launch_synthetic_ui_qa.sh --launch
```

验收包含原生构建、Swift 严格并发检查、应用名称与版本检查、临时签名、架构检查、三类 Agent 的固定合成测试库、自检、额度解析与故障恢复、Kimi 总量合并与“总量 / Code 5h / Code 7天”窄栏展示、QwenWorkCN 非消费式待查看读取、WorkBuddy/TRAE Work 适配器契约、平级展示契约与故障隔离、输入文件只读哈希比对和脱敏扫描。

`qa.sh` 还会准备独立的“本机AI状态栏 QA”副本。布局、可访问性树、240 像素宽度、置顶和吸附验收必须通过 `launch_synthetic_ui_qa.sh` 启动该副本，避免桌面验收工具读取真实任务标题。未经用户确认不得覆盖 `/Applications` 中的应用。

## 仓库结构

```text
.
├── README.md
├── AGENTS.md / CLAUDE.md
├── docs/
│   ├── PRODUCT_HANDOFF.zh-CN.md
│   └── FIRST_EXTERNAL_GRAY_PLAN.zh-CN.md
├── scripts/
│   ├── build_app.sh
│   ├── generate_app_icon.swift
│   ├── launch_synthetic_ui_qa.sh
│   └── qa.sh
├── tests/
│   └── AgentAdapterContractTests.swift
└── skills/codex-recent-tasks-sidebar/
    ├── SKILL.md
    ├── agents/openai.yaml
    ├── scripts/build_app.sh
    └── assets/app-template/
        ├── AgentAdapter.swift
        ├── Codex最近任务栏.swift
        ├── Info.plist
        └── AppIcon.icns
```

## 已知边界

- 仅支持 macOS；当前目标版本为 macOS 13+。
- QwenWorkCN 自动额度依赖桌面端当前提供的本机调试接口；上游变化后可能需要更新适配。
- Kimi 的 Code 限额依赖已安装且已登录的 Kimi CLI，总量依赖 Kimi 桌面端已经刷新过本机订阅日志；任一上游格式变化都可能让对应行暂时缺失。活动判断还依赖本机 Kimi 进程的工作目录；无法安全确认进程时会按无活动处理，避免把旧日志误报为运行中。首次启用会创建一个专用本地监控会话，不会自动删除历史诊断会话。
- Kimi 当前只能打开 Agent 首页，不能精确定位到某个会话。
- WorkBuddy 与 TRAE Work 仅完成安装/运行元数据发现和安全打开应用。官方公开资料与应用包检查尚未提供可验证的任务、额度或精确任务跳转契约，因此保持“已发现 · 待适配”。
- WorkBuddy 5.3.5 的官方 DMG 初装时通过签名与公证评估，但首次启动后会在自身签名包内新增日志文件，导致严格签名与 Gatekeeper 复验失败。项目未读取日志内容、未修改第三方应用；官方修复或说明出现前，WorkBuddy 外部安装灰测暂停。
- 日常构建仍采用 ad-hoc 签名。`build/distribution/2.1.0-build8/` 已生成独立 Developer ID 签名候选包，但尚未完成 Apple 公证，Gatekeeper 会按“Unnotarized Developer ID”拒绝；该候选包不得外发。

## 外部灰测

首批外部灰测仍以 WorkBuddy 与 TRAE Work 为重点，执行批次、测试矩阵、隐私停线条件和放量门槛见 [首批外部灰测计划](docs/FIRST_EXTERNAL_GRAY_PLAN.zh-CN.md)。当前可先推进 TRAE Work；WorkBuddy 等待上游完整性问题解除。在本项目安装包完成 Developer ID 签名与 Apple 公证前，不向外部用户分发。

## License

[MIT](LICENSE)
