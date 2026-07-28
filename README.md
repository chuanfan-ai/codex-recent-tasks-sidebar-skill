# 本机AI状态栏

一个常驻桌面的原生 macOS 小工具，用 240 像素窄栏同时查看 Codex、QwenWorkCN 和 Kimi 的剩余额度与活动线程。

它只显示正在运行、等待操作或待查看的线程，按真实项目分组并保留中文项目名、中文线程名。窗口始终位于其他应用之上，可以自由摆放，也可以吸附在 Codex 左右两侧并与其底边对齐。

> 非 OpenAI、阿里云或 Moonshot 官方项目。应用只在本机读取必要的状态字段，不显示、打印、保存或上传任务正文与凭证，也不会修改任何任务数据库或会话文件。

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
- “活动线程”包括“运行中”“待操作”“待查看”，已完成且无待查看更新的历史线程不会显示。
- 按项目分组，优先使用各应用保存的真实项目名与线程名，不用英文演示名替代。
- 自由模式与吸附模式都全局置顶；吸附时可选 Codex 左侧或右侧，并与 Codex 底边对齐。
- Codex 通过唯一 Thread ID 精确跳转。
- QwenWorkCN 通过本机桌面端接口按 Chat ID 精确跳转。
- Kimi 当前可打开 Agent 首页，但桌面端尚未提供可验证的单会话深链，因此不能承诺精确跳到对应线程。

## 自动读取额度

- Codex：使用已安装 Codex 自带的服务和当前登录状态，只保留内存中的剩余百分比。
- QwenWorkCN：连接正在本机运行的桌面端，只读取额度汇总与待查看 Chat ID，不读取页面标题、任务正文或账号凭证。
- Kimi：调用本机 Kimi CLI 的 `/usage`，使用一个专用本地监控会话并在后续刷新时复用。该会话会从活动线程列表中排除。

如果相应应用未运行、CLI 未安装或现有登录态不可用，界面会显示“额度不可用”，不会尝试读取密钥文件或要求后台提取 Token。

## 数据与隐私边界

- Codex：只读查询任务索引、未读 ID 和 rollout 事件类型；不解析或输出消息正文。
- QwenWorkCN：只读查询本机 `agents.db` 的项目、线程、更新时间和状态字段；数据库以只读方式打开。
- Kimi：只读取会话索引、标题/工作目录元数据，以及判断 `step.begin` / `step.end` 所需的事件类型；不显示事件内容。
- 不提交、不复制、不上传真实数据库、会话文件、任务标题、Thread ID、Chat ID、用户名路径、Token 或重置时间。
- 本地仅保存窗口位置、吸附侧，以及 Kimi 专用监控会话的 ID。

## 验收

```bash
./scripts/qa.sh
```

验收包含原生构建、Swift 严格并发检查、应用名称与 Info.plist 检查、临时签名、架构检查、三类 Agent 的固定合成测试库、自检、额度解析与故障恢复、输入文件只读哈希比对和脱敏扫描。

全部测试数据均由脚本临时生成，不接触真实任务内容。真实启动验收也应遵守相同边界，并且未经用户确认不得覆盖 `/Applications` 中的应用。

## 仓库结构

```text
.
├── README.md
├── AGENTS.md / CLAUDE.md
├── scripts/
│   ├── build_app.sh
│   ├── generate_app_icon.swift
│   └── qa.sh
└── skills/codex-recent-tasks-sidebar/
    ├── SKILL.md
    ├── agents/openai.yaml
    ├── scripts/build_app.sh
    └── assets/app-template/
        ├── Codex最近任务栏.swift
        ├── Info.plist
        └── AppIcon.icns
```

## 已知边界

- 仅支持 macOS；当前目标版本为 macOS 13+。
- QwenWorkCN 自动额度依赖桌面端当前提供的本机调试接口；上游变化后可能需要更新适配。
- Kimi 额度依赖已安装且已登录的 Kimi CLI。首次启用会创建一个专用本地监控会话，不会自动删除历史诊断会话。
- Kimi 当前只能打开 Agent 首页，不能精确定位到某个会话。
- 应用采用 ad-hoc 签名，没有 Apple Developer ID 公证。

## License

[MIT](LICENSE)
