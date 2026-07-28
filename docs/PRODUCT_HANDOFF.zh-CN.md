# 本机AI状态栏：产品交接与推进基线

更新日期：2026-07-28  
当前版本：2.1.0（Build 10）
当前开发分支：`feat/local-ai-statusbar`

## 1. 产品入口

- 源码仓库：[chuanfan-ai/codex-recent-tasks-sidebar-skill](https://github.com/chuanfan-ai/codex-recent-tasks-sidebar-skill)
- 本机构建产物：`build/本机AI状态栏.app`
- 核心源码：`skills/codex-recent-tasks-sidebar/assets/app-template/Codex最近任务栏.swift`
- 适配器契约：`skills/codex-recent-tasks-sidebar/assets/app-template/AgentAdapter.swift`
- 首批外部灰测计划：`docs/FIRST_EXTERNAL_GRAY_PLAN.zh-CN.md`
- 构建入口：`scripts/build_app.sh`
- 完整验收入口：`scripts/qa.sh`
- 合成桌面验收入口：`scripts/launch_synthetic_ui_qa.sh`
- 产品 Skill：`skills/codex-recent-tasks-sidebar/SKILL.md`

继续开发前，按以下顺序读取：

1. `README.md`
2. 本文档
3. `skills/codex-recent-tasks-sidebar/SKILL.md`
4. `AGENTS.md`
5. 与本次改动直接相关的源码和测试脚本

## 2. 产品定义

“本机AI状态栏”是一款常驻桌面的原生 macOS 小工具，让用户在不频繁切换窗口的情况下，持续看到本机 AI Agent 的活动线程、待查看状态和剩余额度。

已稳定使用的主体能力服务于同时使用 Codex、QwenWorkCN 和 Kimi 的个人用户。2.1.0 开始把固定三款产品扩展为可发现、可解释的本机 Agent 监控平台，并新增 WorkBuddy 与 TRAE Work。

产品不做任务管理，不替用户执行、终止或归档任务，也不读取任务正文。它只提供状态观察和安全跳转。

## 3. 已实现能力

### 桌面形态

- 原生 macOS App，最低支持 macOS 13。
- 固定宽度 240 像素，使用紧凑字号。
- 窗口可自由摆放，并始终位于其他普通应用之上。
- 可吸附到 Codex 左侧或右侧，吸附时与 Codex 底边对齐。
- 可跟随 Codex 的前后台状态，也可单独置顶显示。

### Agent 状态

- 同时显示 Codex、QwenWorkCN、Kimi。
- “活动线程”统一包括：运行中、待操作、待查看。
- 已完成且没有待查看更新的历史线程不显示。
- 按真实项目分组，显示各产品保存的中文项目名和中文线程名。
- 新增统一 `LocalAgentAdapter` 契约，定义产品描述、支持等级、能力、应用元数据、健康状态与故障隔离。
- WorkBuddy 与 TRAE Work 分别作为独立产品栏展示，产品名称与 Codex、QwenWorkCN、Kimi 使用相同字号和字重，并动态使用已安装应用包内的官方 Logo，缺失时回退到系统 App 图标。
- WorkBuddy 5.3.5 通过随包公开 REST 契约显示当前和最近 48 小时的会话摘要；TRAE Work 的线程与两款产品的余额在没有稳定契约时显示“—”，不用进程数、旧缓存或猜测填充。

### 支持矩阵

| 产品 | 支持等级 | 活动/待查看 | 额度 | 跳转 | 2.1.0 数据来源 |
|---|---|---:|---:|---|---|
| Codex | 完整支持 | 是 | 是 | 精确任务 | 只读任务索引、未读 ID、事件类型与官方用量服务 |
| QwenWorkCN | 完整支持 | 是 | 是 | 精确任务 | 只读数据库字段、非消费式待查看集合与桌面桥 |
| Kimi | 部分支持 | 是 | 是 | Agent 首页 | 有界会话元数据、进程工作目录、聚合额度与 CLI |
| WorkBuddy | 部分支持 | 是（公开摘要） | 否 | 打开应用 | 应用元数据、当前用户私有 sidecar 与公开 loopback REST |
| TRAE Work | 已发现但未支持 | 否 | 否 | 打开应用 | 应用路径、Bundle ID、版本和运行状态 |

### WorkBuddy 与 TRAE Work 本机事实

2026-07-28 在 Apple Silicon Mac 上完成以下官方分发包核验：

- WorkBuddy：官网更新通道版本 `5.3.5.34189228`，应用版本 `5.3.5`，应用名 `WorkBuddy.app`，Bundle ID `com.workbuddy.workbuddy`，Developer ID 团队 `FN2V63AD2J`。官方 DMG 首次安装后通过严格签名与系统公证评估；首次启动后，应用在自身签名包内新增 `editor_sdk.log`，随后 `codesign --verify --deep --strict` 与 Gatekeeper 校验均因密封资源变化失败。未读取该日志，也未修改第三方应用包。
- TRAE Work：中国区下载通道版本 `2.3.59354`，应用内部版本 `0.1.40`，macOS 应用仍命名为 `TRAE SOLO.app`，Bundle ID `com.trae.solo.app`，Developer ID 团队 `79M8227NKH`，系统评估为已公证。
- WorkBuddy 5.3.5 随包文档提供公开只读会话 REST 契约。状态栏只从当前用户拥有、父目录权限为 `0700` 的本机 sidecar 获取 `127.0.0.1` 端点，再有界读取会话 ID、名称、更新时间和当前态；不读取会话正文。其他 WorkBuddy 版本默认停用该能力。
- WorkBuddy 尚未提供公开余额或单会话跳转契约；TRAE Work 尚未提供可从外部独立调用并验证的线程、余额或单任务跳转契约。2.1.0 不接入两款产品的日志、用户数据库、DOM、调试端口、账号、凭证或私有协议。

### 跳转

- Codex：通过唯一 Thread ID 精确跳转到对应任务。
- QwenWorkCN：通过本机桌面端接口按 Chat ID 精确跳转。
- Kimi：当前只能打开 Agent 首页。桌面端尚未提供经过验证的单会话深链，因此不能承诺精确跳转。

### 剩余额度

- Codex：使用 Codex 已有登录状态读取剩余百分比。
- QwenWorkCN：从正在运行的本机桌面端读取额度汇总。
- Kimi：分三行显示“总量 / Code 5h / Code 7天”。
  - 总量来自 Kimi 桌面端本机订阅日志中的最后一次聚合比例。
  - Code 5h 和 Code 7天来自 Kimi CLI 的 `/usage`。
  - 正常额度统一使用中性灰，不因比例较低而变红。

## 4. 隐私与动作边界

以下边界是产品约束，不是临时实现选择：

- 不读取、显示、打印、保存、复制或上传任务正文。
- 不读取或导出 Token、Cookie、账号凭证和密钥文件。
- 不提交真实数据库、会话文件、任务标题、Thread ID、Chat ID 或用户名路径。
- 对数据库只做只读访问，不修改任务、未读、归档或会话状态。
- 不调用会消费或清空“待查看”状态的接口。
- 不自动结束、归档、删除或重新排序任何 Agent 任务。
- 不在未经确认时覆盖 `/Applications` 中的现有 App。
- 不把用户本机的私有状态数据放入测试库、安装包、日志或远端仓库。

测试必须使用脚本临时生成的固定合成数据。真实桌面验收只观察必要的状态结果，不输出任务名称、内容和 ID。

## 5. 当前实现结构

```text
本机AI状态栏
├── README.md                         产品说明和快速入口
├── docs/
│   ├── PRODUCT_HANDOFF.zh-CN.md     长期交接基线
│   └── FIRST_EXTERNAL_GRAY_PLAN.zh-CN.md
├── scripts/
│   ├── build_app.sh                 根构建入口
│   ├── generate_app_icon.swift      图标生成
│   ├── launch_synthetic_ui_qa.sh    合成数据桌面验收副本
│   └── qa.sh                        构建、签名、测试、自检、脱敏
├── tests/
│   └── AgentAdapterContractTests.swift
└── skills/codex-recent-tasks-sidebar/
    ├── SKILL.md                     实施与验收规则
    ├── scripts/build_app.sh         实际构建脚本
    └── assets/app-template/
        ├── AgentAdapter.swift       统一适配器模型与首批发现适配器
        ├── Codex最近任务栏.swift     主应用源码
        ├── Info.plist               App 元数据
        └── AppIcon.icns             App 图标
```

统一适配器模型与 WorkBuddy/TRAE Work 发现逻辑已从主文件拆到 `AgentAdapter.swift`。Codex、QwenWorkCN、Kimi 的既有状态聚合和主要 SwiftUI 展示仍集中在主文件；继续增加可读任务的适配器前，应再拆出状态聚合层、窗口层和视图层。

## 6. 质量基线

每次非文案级改动都必须运行：

```bash
./scripts/qa.sh
```

现有 QA 覆盖：

- 原生构建与 Swift 严格并发检查
- App 名称、Info.plist、架构和临时签名
- Codex、QwenWorkCN、Kimi 固定合成测试库
- 活动线程、待查看、项目分组和中文名称
- 三类额度解析、故障恢复和窄栏文案
- WorkBuddy 与 TRAE Work 的精确 Bundle 匹配、应用包内官方 Logo、TRAE IDE 排除、元数据最小化和适配器故障隔离
- WorkBuddy 公开会话端点约束、会话解析、48 小时窗口、数量上限和版本闸门
- WorkBuddy 与 TRAE Work 的平级产品标题、活动数/余额/线程区域，以及界面不出现分组说明、模式说明或“待适配”徽标
- 独立 Bundle ID 的合成桌面验收副本，阻止布局工具接触真实任务标题
- 输入文件只读哈希比对
- 自检和脱敏扫描

高风险交互改动还需要真实启动验收：

```bash
./scripts/launch_synthetic_ui_qa.sh --launch
```

- 图标和 Dock 行为正确
- 240 像素宽度和全局置顶正确
- 左右吸附与底边对齐正确
- 跟随 Codex 前后台和单独置顶正确
- Codex、QwenWorkCN 点击后精确跳转
- Kimi 只承诺打开 Agent 首页
- WorkBuddy 与 TRAE Work 以平级产品栏显示官方图标和相同的信息区域；合成数据可验证线程与余额布局，生产环境只显示已验证数据
- WorkBuddy 点击线程只打开应用，不承诺精确会话跳转；TRAE Work 点击只打开应用

桌面布局与可访问性检查必须在合成副本中完成。真实应用只允许做不回传标题或 ID 的运行状态检查。

终端通过、页面提示或 `ok: true` 都不能单独作为交付证据。必须回读构建产物，并检查真实使用面。

## 7. 已知限制

- 当前只支持 macOS。
- 日常构建采用 ad-hoc 签名。2026-07-28 已生成 Developer ID 签名的 2.1.0（Build 8）候选包并通过 `codesign --verify --deep --strict`，但本机未确认 notarytool 凭据，系统评估仍为 `Unnotarized Developer ID`；不得向外部用户分发。
- QwenWorkCN 额度依赖桌面端当前提供的本机调试接口，上游变化可能导致暂时不可用。
- Kimi 总量依赖桌面端已经刷新本机订阅日志；Code 限额依赖已安装且登录的 Kimi CLI。
- Kimi 活动判断依赖安全可确认的进程工作目录；无法确认时按无活动处理，避免把旧日志误报为运行中。
- Kimi 尚不能精确跳到单个会话。
- WorkBuddy 仅在已验证的 5.3.5 版本上支持公开会话摘要；sidecar 或公开 REST 端点不可用时线程显示“—”，没有公开余额或精确会话跳转契约。
- TRAE Work 尚无经过验证的稳定外部线程、额度或精确任务跳转契约。
- WorkBuddy 5.3.5 首次启动后会改变自身已签名应用包，导致严格签名与 Gatekeeper 复验失败。这是已复现的上游完整性阻断项；在官方修复包或可验证说明出现前，暂停 WorkBuddy 的外部安装灰测。
- 既有三款 Agent 的主要状态聚合与展示仍集中在主 Swift 文件中，不适合直接扩展到大量深度适配产品。

## 8. 产品化推进路线

以下条目同时标注 2.1.0 已完成部分与拟推进部分。

### P0：从固定三款产品变成可扩展平台

1. 已完成统一 Agent 适配器基础协议，定义：
   - 产品是否已安装、是否正在运行
   - 活动线程和待查看能力
   - 额度能力
   - 精确跳转能力
   - 数据来源、刷新频率和故障状态
2. 已完成 WorkBuddy 与 TRAE Work 的应用和进程元数据扫描，以及 WorkBuddy 5.3.5 的公开会话摘要适配；不扫描任务正文。
3. 已建立三级支持等级：
   - 完整支持：可显示活动线程、额度和跳转
   - 部分支持：只显示能够安全确认的状态
   - 已发现但未支持：只提示产品已存在，不猜测任务或额度
4. 已在悬浮说明中显示两款产品的数据来源和隐私说明；独立开关与完整产品管理页仍为拟推进。
5. 所有适配器默认“读不到就不显示”，禁止用旧缓存或猜测制造活动状态。

优先否决路径：发现某个 Cowork 产品进程后，直接抓取其日志、数据库或界面文本并尝试通用解析。这样虽然接入快，但会产生隐私风险、误报和上游升级后的不可控故障。

### P0：首次使用体验

- 增加首次启动引导，解释能读取什么、不能读取什么。
- 展示发现的产品、支持等级和需要用户确认的权限。
- 提供产品管理页，可重新扫描、启停适配器和查看连接健康度。
- 没有任何支持产品时，仍能给出清楚的下一步，而不是空白窗口。

### P1：稳定性与可诊断性

- 将主 Swift 文件拆分为适配器层、状态聚合层、窗口层和视图层。
- 为每个适配器建立版本契约、固定测试库和失效回退。
- 增加不含私有内容的健康诊断页和可复制诊断摘要。
- 对上游格式变化显示“暂不可用”和原因，不保留误导性的旧状态。
- 在干净账号、无 CLI、应用未运行、登录过期等场景做完整回归。

### P1：可分发版本

- 使用 Apple Developer ID 签名并完成公证。
- 提供可验证的安装包、版本号、更新说明和卸载说明。
- 建立安全更新机制和回滚路径。
- 补齐隐私说明、数据来源说明和支持矩阵。
- 清除安装包中的开发者路径、测试数据、调试端口和本机标识。

### P2：推广验证

- 按 `FIRST_EXTERNAL_GRAY_PLAN.zh-CN.md` 先邀请 3–5 名真实用户，在不同 Mac、不同 Agent 组合上灰度使用。
- 记录误报、漏报、上游兼容和首次使用完成率，不记录任务内容。
- 达到稳定门槛后再发布公开版本，不把本机可运行等同于可推广。

## 9. “可以推广给别人”的验收门

公开推广前，至少要同时满足：

- 新用户无需修改源码即可完成安装和首次配置。
- 支持等级、权限和隐私边界在界面中可见。
- 任一 Agent 读取失败不会影响其他 Agent，也不会误报活动。
- 安装包已签名、公证，并能在一台干净 Mac 上安装、启动、更新和卸载。
- 没有用户专属路径、凭证、真实任务数据或内部测试残留。
- 关键能力有固定测试和真实桌面验收。
- 已有清楚的版本、兼容范围、已知限制和反馈入口。

## 10. 后续任务的完成定义

任何后续优化只有在以下条件都满足时才算完成：

1. 需求和不做事项已明确。
2. 代码、文档和产品文案保持一致。
3. `./scripts/qa.sh` 全部通过。
4. 与改动相关的真实桌面行为已验证。
5. 没有读取或泄露真实任务内容。
6. 没有未经授权覆盖 `/Applications`、推送远端或改变任务状态。
7. 已说明完成项、验证证据、剩余限制和下一步。
