# Agent Instructions

开始任何非平凡工作前，依次完整阅读 `README.md`、`docs/PRODUCT_HANDOFF.zh-CN.md` 和 `skills/codex-recent-tasks-sidebar/SKILL.md`，以仓库文件作为产品事实层，并从仓库模板构建“本机AI状态栏”。

优先复用仓库内模板和脚本，不要从零重写。交付前运行 `./scripts/qa.sh`，再在真实 macOS 桌面环境检查三类 Agent、240 像素窄栏、全局置顶和底边吸附。不得读取、打印、复制、提交或上传真实 Codex、QwenWorkCN、Kimi 任务内容、ID、数据库、会话文件或凭证；不得用会清空或消费状态的接口监控未读任务。覆盖 `/Applications` 前必须获得用户授权。

WorkBuddy 与 TRAE Work 是首批 Cowork 适配对象，统一通过 `AgentAdapter.swift` 管理。除非存在经过验证的稳定只读契约，否则只检查应用路径、Bundle ID、版本和运行状态，并保持“已发现 · 待适配”；不得读取两款产品的用户目录、日志、数据库、DOM、调试端口、账号或会话内容。外部灰测任务还需读取 `docs/FIRST_EXTERNAL_GRAY_PLAN.zh-CN.md`。

对产品路线或能力做判断时，必须区分“已实现”“已验证”“拟推进”和“上游不支持”。未经用户明确授权，不推送远端、不发布版本、不修改第三方资源。
