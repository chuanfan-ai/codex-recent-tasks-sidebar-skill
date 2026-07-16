# Codex 最近任务栏

一个原生 macOS 伴生小工具：直接显示最近活跃的 Codex 任务时间，按工作文件夹分组，并可精确跳转到对应任务。

它支持吸附在 Codex 左侧或右侧、跟随 Codex 前后层级，也可以切换为独立置顶窗口。应用有自己的图标和 Dock 入口。

> 非 OpenAI 官方项目。模板只读取本机 Codex 数据，不联网、不上传任务、不修改数据库。

## 最快使用：把这段话交给任意智能体

```text
请克隆 https://github.com/chuanfan-ai/codex-recent-tasks-sidebar-skill ，完整阅读 skills/codex-recent-tasks-sidebar/SKILL.md，直接使用仓库内模板构建 Codex 最近任务栏。先运行 ./scripts/qa.sh，确认构建、签名、固定测试库、自检和脱敏扫描全部通过；再真实启动 App，验证图标与 Dock、左右吸附、跟随 Codex 前后台、单独置顶、点击任务精确跳转。未经我确认不要覆盖 /Applications 里的现有 App，也不要读取、打印、复制或上传我的真实任务内容。
```

适用于 Codex、Claude Code 及其他能读取本地文件、执行终端命令的智能体。

## 自己构建

要求：

- macOS 13 或更高版本
- 已安装并至少使用过一次 Codex / ChatGPT 桌面端
- 已安装 Xcode Command Line Tools，系统存在 `/usr/bin/swiftc`

```bash
git clone https://github.com/chuanfan-ai/codex-recent-tasks-sidebar-skill.git
cd codex-recent-tasks-sidebar-skill
./scripts/qa.sh
open "build/CodexRecentTasksSidebar.app"
```

构建产物位于 `build/CodexRecentTasksSidebar.app`，窗口和 Dock 中仍显示“Codex 最近任务”。确认无误后，可以手动拖入“应用程序”文件夹。

## 功能

- 从 `~/.codex/state_5.sqlite` 或兼容位置只读加载主任务。
- 自动排除归档任务、子智能体和内部线程。
- 按真实工作目录分组；同一文件夹保留全部近期任务。
- 文件夹和任务都按最近活动时间倒序排列。
- 每条任务使用唯一 Thread ID，通过 `codex://threads/{id}` 精确打开。
- 左右吸附 Codex，也支持拖动切换吸附侧。
- 吸附模式跟随 Codex：Codex 前置时同步前置，切换其他应用时自动后置。
- 单独置顶模式保持全局前置并可自由拖动。
- 自带应用图标、Dock 入口、菜单栏入口、搜索和 30 秒刷新。

## 仓库结构

```text
.
├── README.md
├── AGENTS.md / CLAUDE.md
├── scripts/
│   ├── build_app.sh
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

Skill 文件夹可以单独安装，也可以让智能体直接读取。完整仓库额外提供固定测试库、脱敏扫描和 GitHub Actions。

## 隐私边界

- 不提交、不复制真实 Codex 数据库。
- 不在日志中打印任务正文、Thread ID 或本机用户名路径。
- App 对 Codex 数据库只执行只读查询。
- 本地仅通过 `UserDefaults` 保存窗口位置、吸附侧和显示模式。
- `build/`、SQLite、日志和本机缓存均被 `.gitignore` 排除。

## 验收

```bash
./scripts/qa.sh
```

该命令会执行：原生构建、Info.plist 校验、代码签名校验、架构检查、固定 SQLite 测试库自检、数据库只读哈希比对、缺失数据库边界测试和脱敏扫描。

CI 只使用仓库生成的固定测试数据，不访问任何真实 Codex 任务。

## 已知边界

- 仅支持 macOS；当前真实环境已在 Apple Silicon 上验证。
- Codex 如果更改本地数据库结构、Bundle ID 或深链协议，需要更新模板。
- 仓库使用 ad-hoc 签名，没有 Apple Developer ID 公证；首次运行可能受本机 Gatekeeper 设置影响。

## License

[MIT](LICENSE)
