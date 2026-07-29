# 本机AI状态栏

一个常驻桌面的原生 macOS 小工具，用 240 像素窄栏查看本机 AI Agent 状态。Codex、QwenWorkCN、Kimi CLI 和 Kimi Work 模式已接入活动线程，Codex、QwenWorkCN 和 Kimi 的可验证额度也已接入；WorkBuddy 已接入官方 Logo 与公开会话摘要，TRAE Work 已接入官方 Logo 与隐私安全的安装、运行状态发现。

Codex、QwenWorkCN 和 Kimi 只显示正在运行、等待操作或待查看的线程；WorkBuddy 只显示公开接口返回的当前或最近会话摘要。窗口始终位于其他应用之上，可以自由摆放，也可以吸附在 Codex 左右两侧并与其底边对齐。

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
- Codex、QwenWorkCN、Kimi、WorkBuddy 与 TRAE Work 使用相同层级的独立产品栏，不增加额外分组标题。
- WorkBuddy 5.3.5 使用应用包内的官方 Logo，并通过随包公开 REST 契约显示当前和最近 48 小时的会话摘要；没有公开余额接口，因此余额固定显示“—”。
- WorkBuddy 与 TRAE Work 的安装/运行状态先独立刷新，再后台补充可验证数据；App 完成启动后会立即重查，目标产品启动或退出时也由 macOS 事件即时刷新，不必等待 30 秒轮询。产品标题行会直接显示“运行中 / 已安装 / 未安装”，不会再用“线程 —”代替进程状态；会话接口慢或暂不可用时，仍会按本机应用进程显示正确状态。
- TRAE Work 使用应用包内的官方 Logo 并保留相同的活动数、余额和线程区域；在没有稳定外部只读契约时显示“—”，不把进程数或猜测当作线程和余额。
- “活动线程”包括“运行中”“待操作”“待查看”，已完成且无待查看更新的历史线程不会显示。
- Kimi 产品栏合并 Kimi CLI 与 Kimi 桌面客户端 Work 模式：Work 模式的 `running`、`blocked`、`completed + 未读` 分别显示为“运行中”“待操作”“待查看”，已完成且已读的线程不显示。
- 按项目分组，优先使用各应用保存的真实项目名与线程名，不用英文演示名替代；Kimi Work 没有落盘项目或标题映射时统一归入“Kimi Work”并显示中文状态名称。
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
- Kimi Work：只读检查 `~/Library/Application Support/kimi-desktop/kimi-agent/` 下的 `conversation-statuses.json`、`conversation-unread.json` 和可选的 `conversation-titles.json`。读取有大小和条数上限，只保留内存中的状态、未读集合与可选显示标题，不读取会话正文，不打印、复制或上传会话键和标题。标题文件不存在时显示“Kimi Work 运行中 / 待操作 / 待查看”，不会把内部会话键显示给用户。
- Kimi CLI：只读取会话索引、标题/工作目录元数据，以及判断 `step.begin` / `step.end` 所需的事件类型；不显示事件内容。总量读取仅检查 `~/Library/Logs/kimi-desktop/main.log` 末尾最多 4 MB 中最后一次 `omniRatio` 聚合字段，不输出或保存其他日志内容。只有未闭合步骤与真实运行中的 Kimi 进程工作目录一致时才显示为活动，旧会话日志会被排除。
- WorkBuddy：匹配 `WorkBuddy.app` 与 `com.workbuddy.workbuddy`。仅在已验证的 5.3.5 版本上，通过当前用户私有的本机 sidecar 获取公开 REST 端点，并在内存中读取有界的会话 ID、名称、更新时间和当前态；名称只用于本机界面，不打印、保存或上传，不读取正文、日志、数据库、账号、凭证或余额。
- TRAE Work：匹配 macOS 分发包内的 `TRAE SOLO.app` 与 `com.trae.solo.app`，只检查应用路径、Bundle ID、版本和运行状态；不读取日志、数据库、页面、任务、额度、账号或会话内容。
- 不提交、不复制、不上传真实数据库、会话文件、任务标题、Thread ID、Chat ID、用户名路径、Token 或重置时间。
- 本地仅保存窗口位置、吸附侧，以及 Kimi 专用监控会话的 ID。

## 验收

```bash
./scripts/qa.sh
./scripts/launch_synthetic_ui_qa.sh --launch
```

验收包含原生构建、Swift 严格并发检查、应用名称与版本检查、临时签名、架构检查、三类 Agent 的固定合成测试库、自检、Kimi Work 三态与未读解析、Work/CLI 独立回退、额度解析与故障恢复、Kimi 总量合并与“总量 / Code 5h / Code 7天”窄栏展示、QwenWorkCN 非消费式待查看读取、两款产品的官方图标、WorkBuddy 运行状态优先发布与启停事件即时刷新、公开会话解析与版本闸门、TRAE IDE 排除、平级展示契约、故障隔离、输入文件只读哈希比对和脱敏扫描。

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
- Kimi 的 Code 限额依赖已安装且已登录的 Kimi CLI，总量依赖 Kimi 桌面端已经刷新过本机订阅日志；任一上游格式变化都可能让对应行暂时缺失。Kimi CLI 活动判断依赖本机 Kimi 进程工作目录；Kimi Work 活动依赖桌面客户端最后写入本机的状态与未读快照，状态新鲜度取决于 Kimi 客户端是否及时刷新。Work 标题未落盘时只能显示中文状态名称。首次启用 CLI 额度会创建一个专用本地监控会话，不会自动删除历史诊断会话。
- Kimi 当前只能打开 Agent 首页，不能精确定位到某个会话。
- WorkBuddy 仅在 5.3.5 上完成公开会话摘要适配；没有公开余额接口和单会话深链，sidecar 或公开 REST 端点不可用时线程数显示“—”，不会回退到猜测值。
- TRAE Work 尚无经过验证的稳定外部线程、余额或精确跳转契约；目前只显示官方图标、安装与运行状态，其余位置明确显示“—”。
- WorkBuddy 5.3.5 的官方 DMG 初装时通过签名与公证评估，但首次启动后会在自身签名包内新增日志文件，导致严格签名与 Gatekeeper 复验失败。项目未读取日志内容、未修改第三方应用；官方修复或说明出现前，WorkBuddy 外部安装灰测暂停。
- 日常构建仍采用 ad-hoc 签名。`build/distribution/2.1.0-build8/` 已生成独立 Developer ID 签名候选包，但尚未完成 Apple 公证，Gatekeeper 会按“Unnotarized Developer ID”拒绝；该候选包不得外发。

## 外部灰测

首批外部灰测仍以 WorkBuddy 与 TRAE Work 为重点，执行批次、测试矩阵、隐私停线条件和放量门槛见 [首批外部灰测计划](docs/FIRST_EXTERNAL_GRAY_PLAN.zh-CN.md)。当前可先推进 TRAE Work；WorkBuddy 等待上游完整性问题解除。在本项目安装包完成 Developer ID 签名与 Apple 公证前，不向外部用户分发。

## License

[MIT](LICENSE)
