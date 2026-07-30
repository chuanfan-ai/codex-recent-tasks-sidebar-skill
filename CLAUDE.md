# Claude Code Instructions

开始任何非平凡工作前，依次完整阅读 `README.md`、`docs/PRODUCT_HANDOFF.zh-CN.md` 和 `skills/codex-recent-tasks-sidebar/SKILL.md`，以仓库文件作为产品事实层，并从仓库模板构建“本机AI状态栏”。

优先复用仓库内模板和脚本，不要从零重写。正式构建必须从安全临时目录编译，App 与交付包不得包含打包机 Home 绝对路径，`./scripts/qa.sh` 的对应脱敏检查必须通过。交付前运行完整 QA，再通过 `./scripts/launch_synthetic_ui_qa.sh --launch` 在真实 macOS 桌面环境检查三类 Agent、240 像素窄栏、全局置顶和底边吸附；不得对真实任务窗口读取可访问性树或截图。不得读取、打印、复制、提交或上传真实 Codex、QwenWorkCN、Kimi 任务内容、ID、数据库、会话文件或凭证；不得用会清空或消费状态的接口监控未读任务。覆盖 `/Applications` 前必须获得用户授权。

WorkBuddy 与 TRAE Work 统一通过 `AgentAdapter.swift` 管理，并在界面中作为与 Codex、QwenWorkCN、Kimi 平级的独立产品栏展示；产品名称使用相同字号和字重，不增加分组标题、模式说明或可见的“待适配”徽标。应用安装/运行状态必须先独立发布并持续刷新，并在产品标题行直接显示“运行中 / 已安装 / 未安装”，不得用“线程 —”代替进程状态；App 完成启动及目标产品启动/退出事件必须立即触发重查，30 秒计时器只作为兜底。WorkBuddy 仅在已验证的 5.3.5 版本上，通过当前用户私有 sidecar 提供的公开 loopback REST 契约读取有界会话摘要；自动化验收不得回传真实名称或 ID。TRAE Work 在没有稳定外部只读契约时只检查应用路径、Bundle ID、版本和运行状态。不得读取两款产品的用户目录、日志、数据库、DOM、调试端口、账号、凭证或会话正文。外部灰测任务还需读取 `docs/FIRST_EXTERNAL_GRAY_PLAN.zh-CN.md`。

Kimi 产品栏同时聚合 Kimi CLI 与桌面客户端 Work 模式。Work 模式只读解析 `conversation-statuses.json`、`conversation-unread.json` 和可选的 `conversation-titles.json`，仅将 `running`、`blocked`、`completed + 未读` 视为活动；读取必须有界、只驻留内存，不得输出会话键或真实标题。缺少标题时使用中文状态名称，不得展示内部键。CLI 与 Work 任一数据源不可用时，另一数据源仍须独立工作。`KIMI_WORK_STATUS_DIRECTORY_OVERRIDE` 仅用于指向 `build/qa-fixture` 下的合成测试目录，生产运行不得设置。

对产品路线或能力做判断时，必须区分“已实现”“已验证”“拟推进”和“上游不支持”。未经用户明确授权，不推送远端、不发布版本、不修改第三方资源。
