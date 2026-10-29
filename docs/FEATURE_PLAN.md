# Mia 功能增强开发需求文档 v1

> 依据:2026-10-21 代码盘点。优先级:**P1 导出 > P2 划词即问 > P3 自动命名 > P4 persona 预设**。
> 非目标(README:104 上游红线):模型控制代码执行、任意工具插件、语音、多窗口。

## P1 对话导出

**背景**:`ConversationStore.maxStored = 50`,超限静默裁剪最旧对话(Conversations.swift:39);全代码库无任何导出能力——用户历史会丢。

### 需求
- R1.1 单对话导出 Markdown:标题 + 导出时间头;消息按角色(`You:` / `Assistant:`);reasoning 折叠为 blockquote;`error`/`activity` 行导出为斜体注记;代码块原样保留 fenced。
- R1.2 单对话导出 JSON:fork 链解析后的**完整独立对话**(共享前缀吸收进单文件),沿用现有 `Codable`/iso8601 约定,可作为备份/迁移格式。
- R1.3 全量导出:用户选目录,每个对话一个 `<slug>-<短id>.md`,外加合并的 `conversations.json`。
- R1.4 入口:HistoryPopover 每行右键菜单(`Export Markdown…` / `Export JSON…`)+ 底部 `Export All…`;`NSSavePanel`/目录选择面板,默认文件名取 title slug。

### 约束
- fork 解析**必须复用**现有 parent-chain 解析逻辑,不得另写一套。
- UI 字符串英文,遵循现有代码注释风格。

### 验证(Owner: Orchestrator)
- 新增 `--smoke-export`:fixture 构造含 fork 的对话 → MD/JSON 编码 → golden 对比;无网络。
- `./build.sh debug` 编译通过;现有无 key smoke 不回归。

## P2 划词即问(Ask about selection)

**背景**:`PanelDrop` 仅支持拖放;无系统级选区捕获。

### 需求
- R2.1 `NSServices` 注册服务(Info.plist `NSServices` 声明 + `NSApp.servicesProvider`),任意 app 选中文字 → 服务菜单 "Ask Mia"。
- R2.2 handler:显示面板 → composer 预填引用块(`> 选中文本` + 空行),光标落末尾并 focus;不自动发送。
- R2.3 FirstRunHint 增加一次性提示:服务需在 系统设置 → 键盘 → 键盘快捷键 → 服务 中启用/设快捷键。

### 验证(Owner: Orchestrator)
- 预填逻辑可单元化并加 smoke;Services 注册手动验证(-notes 记录步骤)。

## P3 对话自动命名

**背景**:标题 = 首条用户消息截 40 字符(ChatStore.swift:932-936),无模型命名。

### 需求
- R3.1 首轮 assistant 回答**完成后**,异步用当前 provider 发一次 `max_tokens ≤ 24` 的命名请求;成功则回写 title 并刷新 HistoryPopover。
- R3.2 仅在 title 仍为默认派生值时执行一次(Conversation 增加标记位,防重复扣费);失败静默回退,不产生 error 行、不阻塞对话。
- R3.3 Settings › Chat 开关,默认开。

### 验证(Owner: Orchestrator)
- `--smoke-titling`:fake fixture 验证命名请求构造、回写与"仅一次"语义。

## P4 System Prompt 预设

**背景**:单一 `systemPrompt`(UserDefaults,ChatStore.swift:219)。

### 需求
- R4.1 Persona 列表(名称 + 提示词)CRUD,存储参照 `ShortcutStore` 模式。
- R4.2 Settings › Chat:active persona 选择器,含 "Custom"(保留现有自由文本编辑,零迁移成本)。
- R4.3 内置 3 个示例(Translate / Code Review / Writing),首启注入,可删可改。

### 验证(Owner: Orchestrator)
- `--smoke-persona`:切换后 wire 上的 system prompt 正确;Custom 路径不受影响。

## P5 选区浮动按钮(用户反馈升级 P2 体验)

**背景**:Services 菜单路径过深(应用菜单 → Services),用户要求:后台运行时,任意 app 选中文字,选区尾端下方浮现按钮,点击即弹出面板进入对话。

### 需求
- R5.1 选区检测:全局鼠标监听(免权限)判定"选区手势"(拖拽 ≥12pt 或 双击/三击),满足后在鼠标抬起点(≈选区尾端)**下方**显示小型非激活浮动按钮面板;自动消失(6s 无交互或任意下次点击/滚轮/Esc)。
- R5.2 取词:保存剪贴板(changeCount + items)→ 模拟 ⌘C → 轮询 changeCount(≤150ms)读取文本 → 还原剪贴板;需要辅助功能权限,未授权时 Settings 显示状态与授权入口(kAXTrustedCheckOptionPrompt 一次性引导)。
- R5.3 点击行为:隐藏按钮 → `PanelController.show()`(复用 P2 非激活路径)→ 走 P2 的 `.miaQuoteSelection` 通道预填引用块并聚焦;Settings 增加 "Send immediately"(默认关),开启则直接以引用块作为消息发送。
- R5.4 Settings:Chat 页(或 General,由实现者按布局惯例定)增加 "Show selection button"(默认开,随权限状态展示)。
- R5.5 抑制:事件点位于 Mia 自身窗口(面板/按钮)内不触发;按钮已显示期间不重复触发;P2 Services 通道保留不动。
- R5.6 已知边界(记录不修):纯键盘选区(Shift+方向键)不触发;取词效果依赖目标 app 对 ⌘C 的响应(文本可选即可,业界同款方案)。

### 验证(Owner: Orchestrator)
- 手势判定/锚点钳制/自动发送决策提取纯函数入 `--smoke-selection`(扩展);权限与浮动按钮 GUI 行为出手动清单,用户实测。



| # | 任务 | 状态 |
|---|---|---|
| T1.1 | 导出编码层(MD/JSON,含 fork 解析复用) | ✅ 完成 |
| T1.2 | 导出 UI 入口(HistoryPopover 右键 + Export All) | ✅ 完成 |
| T1.3 | `--smoke-export` + 编译/回归验证 | ✅ 完成(9/9 ok;find/rerun/chat-search 回归通过) |
| T2.1 | Services 注册 + 选区 handler | ✅ 完成 |
| T2.2 | composer 预填 + 首启提示 | ✅ 完成(`--smoke-selection` 9/9;回归通过;Services 系统级交互留手动清单) |
| T3.1 | 命名请求 + 回写 + 仅一次标记 | ✅ 完成 |
| T3.2 | 设置开关 | ✅ 完成(`--smoke-titling` 22/22;默认开,object(forKey:) 模式) |
| T4.1 | Persona 存储 CRUD | ✅ 完成 |
| T4.2 | 切换 UI + 内置示例 | ✅ 完成(`--smoke-persona` 10/10;Custom 路径逐字节断言) |
| T5.1 | 选区手势检测 + 浮动按钮面板 | ✅ 完成 |
| T5.2 | ⌘C 取词 + 剪贴板还原 | ✅ 完成 |
| T5.3 | 点击 → 面板/引用/直接发送 + Settings Selection 区块 | ✅ 完成(`--smoke-selection` 扩至 24 断言) |

**进度反馈机制**:每阶段由实施方(fixer)交付 → Orchestrator 读 diff + 本地 build/smoke 验证 → 更新本表与进度日志 → 下一阶段派发。

## 进度日志

- 2026-10-21 文档建立;P1(T1.1+T1.2)派发实施。
- 2026-10-21 P1 完成并经 Orchestrator 验证:diff 足迹符合范围(3 改 2 增),`./build.sh debug` 零 error,`--smoke-export` 9/9 ok,golden 逐字节校验,回归 3 项 smoke 通过。新增 `ConversationStore.resolved()`(纯内存物化,复用 `loadResolved`)。P2 派发实施。
- 2026-10-21 P2 完成:Services 注册 + 非激活路径 handler + 追加式引用预填 + 一次性提示;`--smoke-selection` 9/9。`--smoke-firstrun` 失败经 HEAD 基线 worktree 判定为环境性既有失败,与改动无关。P3 派发。
- 2026-10-21 P3 完成:`Titling` 纯函数层 + dispatch 即置位的仅一次守卫 + 旧 JSON 兼容;`--smoke-titling` 22/22。`--smoke-find` 为非确定抖动(同二进制连跑双态),非回归。P4 派发。
- 2026-10-22 P4 完成:`PersonaStore` + Custom 路径逐字节断言;`--smoke-persona` 10/10。**最终全量验收**(完整跑通一次,HEAD 基线对照):23 项 smoke 20 项 PASS(含 codex×4 与 `--smoke-file`,此前疑似悬挂系运行耗时超过守卫时限);3 项失败均为环境项——`--smoke-history` 屏幕几何断言在 HEAD 基线同样失败、`--smoke-search`/`--smoke-pasteable` 为本机 deepseek key 401;另 `--smoke-find` 偶发抖动重跑可过、`--smoke-firstrun` 基线即环境性失败。P1-P4 零回归。四阶段全部交付。
- 2026-10-22 用户手动测试反馈①:Personas 名称输入框与编辑区视觉无区分 → designer 三轮修复(最终根因:grouped Form 在 AppKit 层重组自定义行;Chat 页改手搭卡片布局,`52f61d0`),observer 像素复核通过。
- 2026-10-22 用户手动测试反馈②:Services 菜单路径太深 → P5 选区浮动按钮(需求当日补入本文档)。fixer 交付:手势检测/⌘C 取词还原/非激活浮动按钮/点击经 P2 通道或直接发送/Settings Selection 区块(双开关 + AX 权限状态行);`--smoke-selection` 24/24,回归通过。浮动按钮 GUI 行为与多屏锚定为手动验证项(清单在交付记录)。
- 2026-10-22 Chat 页 UI 按用户反馈四轮迭代:①标签+盒式输入框(d0470a5);②NAME 同行+左对齐(根因:grouped Form 重组自定义行,Chat 页改手搭卡片布局,52f61d0);③控件右对齐+列表分割线(be116d2);④开关 mini 档+下拉内容宽(179376f)。observer 五轮像素复核全部通过。
- 2026-10-22 P5 用户实测:选区按钮/授权/点击链路全通;AX 状态行因系统广播不触发而显示陈旧,补 didBecomeActive 刷新(e1127c4)。**P1-P5 全部交付、验收、经用户手动测试确认。** 已知运维项:ad-hoc 签名导致每次重建 TCC 授权失效,可选配固定签名证书根治。README 已补 P1-P5 功能说明。
- 2026-10-22 **品牌迁移 PopChat → Mia**:全量更名(bundle ID `app.tapfun.mia`、数据目录、热键名、originator `mia`、仓库 imdlan/mia-desktop);新增 `BrandMigration`(旧 defaults 域 + 热键键名 + 数据目录一次性迁移,`--smoke-migration` 8/8 隔离自测);新 logo(AppIcon.icns + 菜单栏 template 图标)、新截图、README 重整、旧仓库 imdlan/PopChat 归档;OpenAI preset 默认模型 gpt-4o→gpt-6-luna(2027-01-14 关闭,官方替代)。0.2.0 准备就绪,待公证凭据后发布。

## P6 对话结束后台通知(用户反馈)

**背景**:面板失焦即整体隐藏(`AppDelegate.applicationDidResignActive` → `hide()`),回答完成时用户几乎必然在其他 App 中且无任何信号,只能反复手动唤起查看;长回答 + typewriter 滞后使等待常达数十秒。

### 需求
- R6.1 触发点在 `ChatStore` stream 收尾(`isStreaming = false` 处):成功完成/出错(`.error`、`.contentRejected`)/空回复均通知;手动 Stop(`Task.isCancelled`)静默——停止即用户在场;Mia 为前台 App 时不打扰。
- R6.2 通知 = 系统横幅(点击 → `NSApp.activate` + `panelController.show()` 唤起面板)+ 系统音效(Pop/Basso);横幅 `content.sound = nil`,音效统一由 `NSSound` 播放,单一开关避免双重声音。
- R6.3 Settings › General › Notifications:主开关(默认关)+ 音效子开关(默认开);开启主开关时才请求系统授权;授权被拒时音效兜底。
- R6.4 新文件 `CompletionNotifier.swift`(`@MainActor` 单例 + `UNUserNotificationCenterDelegate`),`AppDelegate` 启动时接线。

### 已知事项
- 横幅是否弹出由 系统设置 › 通知 › Mia 的"通知样式"与专注模式决定:样式为"无"或专注模式开启时,通知静默进入通知中心(实测确认),音效不受影响。

### 验证(Owner: Orchestrator)
- `./build.sh` 编译零警告、bundle 冒烟通过;默认关闭确认(defaults 键缺失即 off);端到端横幅/音效/点击唤起真机手动验证。

## P7 回答 footer 统计(用户需求)

**背景**:三条 provider 路径的 usage 此前全部被丢弃——OpenAI-compatible 的 usage 终末 chunk 在 `choices?.first` 守卫处静默消失;Codex `turn/completed` 与 ChatGPT `response.completed` 的 usage 字段从未解析。UI 对"这轮回答花了多少资源"零反馈。

### 需求
- R7.1 `ChatStreamEvent` 新增 `.usage(TurnUsage)`,三路径在终态前 yield;工具循环多轮累加。
- R7.2 OpenAI-compatible:请求体加 `stream_options.include_usage`;解析 choices 为空的 usage chunk 与搭车在内容 chunk 上的 usage;该参数被 400 拒绝时自动去参重试一次。
- R7.3 `TurnStats { totalTokens, outputTokens, duration }` 挂 `ChatMessage`(optional,随对话 iso8601 持久化,旧记录 nil)。
- R7.4 assistant footer 右侧(行动按钮对侧)显示 "62518 tokens · 5m 42s · 51.2 tok/s":total 含 prompt(成本口径),tok/s 用 output ÷ 网络时长(含工具回合,已知稀释,声明为口径而非缺陷);无 usage 仅显示耗时;手动 Stop(Task cancelled)不统计;默认显示无开关。

### 验证(Owner: Orchestrator)
- `--smoke-usage`:usage-only chunk / 搭车 chunk / 缺失 nil / 多轮累加 / 三段与降级格式化,9 项断言;真机核对与 provider 后台一致性留待人工。

## P8 用户气泡时间戳 + 直角造型(用户需求)

**背景**:对话流无任何时间信息,长对话回看无法定位时序。

### 需求
- R8.1 `ChatMessage.createdAt`(optional,iso8601 持久化):send 各路径记录用户消息发送时刻,assistant 记录回合开始。
- R8.2 用户气泡下方 hover 显示 "2026-10-23 13:03:42"(POSIX 固定格式防本地化漂移,右对齐 10pt tertiary,0.15s 淡入);assistant 行不显示——单侧时间戳即可推断每轮时序。
- R8.3 气泡直角(`UnevenRoundedRectangle`),对齐右侧发言方向;0.4.0 起依用户反馈改为**右下角**直角(原右上角)。

### 验证(Owner: Orchestrator)
- 构建零 error、bundle 冒烟通过;hover/造型为视觉验收,人工确认。

## P9 模型选择弹窗过滤搜索(用户需求)

**背景**:部分 provider 模型目录极大(OpenRouter 300+),滚动肉眼定位困难;且渲染上限 200 行,目录后半的模型此前根本不可见。

### 需求
- R9.1 模型列列表上方加过滤输入框(复用 HistoryPopover 的 `KeyRoutingTextField`:打开即聚焦、IME 组合安全);列头显示 `Provider · N of M models` 命中反馈。
- R9.2 模糊匹配:大小写 + 分隔符(`-._/:` 与空白)不敏感、多词无序——"gpt 4o"、"4o mini"、"gpt-4o" 均命中 `gpt-4o-mini-2024…`。
- R9.3 过滤作用于全量目录后再套 renderCap(第 200 行之后的模型可搜到);弹窗高度按未过滤全量计算,输入中外壳尺寸不变(5c 纪律)。
- R9.4 键盘:↑/↓ 移动光标、↩ 提交、⎋ 先清空过滤再关弹窗;`KeyCaptureView` 不再自动抢第一响应者(避免与输入框竞争),Tab 仍可达保留 ←/→ 列浏览。
- R9.5 附带(用户反馈):用户气泡直角由右上角改为右下角(修订 P8/R8.3)。

### 验证(Owner: Orchestrator)
- `swift build` 零 error;`./build.sh` bundle 冒烟 6/6 PASS;过滤/键盘/⎋ 行为与大目录 provider 经用户真机手动测试通过。

## P10 单条回复导出 + thinking 阶段贴底(用户需求)

**背景**:导出只有整对话;且 thinking 阶段/发送瞬间不贴底,新气泡被输入框遮住一半。

### 需求
- R10.1 assistant footer 的 Copy/Fork 行新增 Export(`square.and.arrow.up`),右键 Export Reply…;NSSavePanel 导出单条 Markdown(含 reasoning 引用块),文件名 `<标题 slug>-reply-<id 前 6>`,正文经 `fullText(of:)` 点按时解析(绕过打字机延迟,与 Copy 同语义)。
- R10.2 `followingWaitingGrowth`:macOS 15 以 `onScrollGeometryChange` 跟踪 content/container 高度变化,pinned 时**无动画**贴底;macOS 14 以 `pendingStatus/pendingReasoning` onChange 兜底。修复 waiting indicator 长高(status 行→3 行推理窗)与发送瞬间 compact→全高窗口动画导致的不贴底。铁律:流式 tick 期间跟随滚动不得带动画(历史冻结教训)。

### 验证(Owner: Orchestrator)
- `swift build` 零 error;`--smoke-export` 9/9(reasoningBlock/slug 抽取字节级不变);滚动行为人工验收。

## P11 Steer——流式输出中排队追问(用户需求)

**背景**:输出过程中无法追加提问。语义经调研定稿为**不打断的 queue/follow-up**(业界 Steer 多指打断;Claude Code 的"下一停顿注入"是社区吐槽点),ChatGPT/Codex 的排队追问同款。

### 需求
- R11.1 `ChatStore.SteerState`(pending/inserted 单槽):流式中 Enter 入队为 chip(再次 Enter **替换**——用户拍板);✕(`xmark`)丢弃;↑(`arrow.up.to.line`)经共享 preflight 后把 user 行**立即追加**到流式 assistant 行之下(streamTask 的 assistantIndex 簿记对此安全),置 inserted。
- R11.2 streamTask 尾部在**真回合结束**(含 Stop——用户拍板)自动 `performTurn()` 作答;`send()` 零行为重构为 `preflight()+performTurn()`。已插入待答期间 `canRerunLastTurn` 置否;newChat/adopt/fork/deleteConversation 清理;chip 不落盘,插入行随 persist 落盘。
- R11.3 chip UI:紧贴输入框上沿(VStack spacing 0),顶圆角/底直角(`UnevenRoundedRectangle`),`Color.primary.opacity(0.06)`,比输入框窄、水平居中,文字左对齐尾省略。

### 验证(Owner: Orchestrator)
- `--smoke-steer` 17 项离线全过(127.0.0.1:9 拒连,无真实网络);`--smoke-rerun` 回归证明 send 重构零行为变化;chip 视觉人工验收。

## P12 免费模板扩充 + 预填默认模型(用户需求)

**背景**:"More free APIs" 链接 404;国内供应商与 opencode 缺位。

### 需求
- R12.1 目录改指 `open-free-llm-api/awesome-freellm-apis`(经两次更正定稿)。
- R12.2 新增模板(均实测 `/models`):Z AI 智谱(GLM Flash 免费,1 并发)、ModelScope(61 免费模型,无 key 即列模型)、OpenCode Zen(opencode 官方网关);NVIDIA note 补手机验证、Mistral note 去计划名。DeepSeek 不加(无免费层,2026-07-22 已从 preset 退役)。
- R12.3 `FreeProviderTemplate.defaultModel` 单 ID 种子(名单 ID 必 rot,首 fetch 成功后被实盘覆盖):Z AI→`glm-4.7-flash`、ModelScope→`DeepSeek-V4.1-Flash-1017`、Zen→`glm-5.3-flash-free`。
- R12.4 迁移 healing:freeTemplate 命中且 defaultModel 为空的存量行回填种子;`retiredPresetDefaults`(OpenAI gpt-4o,2027-01-14 关停)且 selectedModels 为空的行刷新为当前出厂默认。
- R12.5 切换器 `allModels` 未 fetch 时以预填默认作单行目录(pill/列表/计数一致,↩ 可显式提交)。

### 验证(Owner: Orchestrator)
- 端点实测(curl /models,2026-10-24);`--smoke-providers` 修复 56dbb10 后的既有断言失败(首焦点已是过滤框)后全过;回填/healing 经用户真实 defaults 数据确认生效。

## P13 Show Dock icon 开关——⌘Tab/Dock 可唤回 panel(用户需求)

**背景**:app 为 LSUIElement/accessory 形态,无 Dock 图标也不进 ⌘Tab;用户依赖 ⌘Tab 巡视切窗时找不到 Mia。系统行为非 bug。

### 需求
- R13.1 Settings → General → Show & Hide 新增 "Show Dock icon"(UserDefaults `showDockIcon`,默认关):运行时 `setActivationPolicy(.regular/.accessory)` 即时切换,无需重启;状态栏图标与 nonactivating panel 交互全部保留。
- R13.2 regular 模式 `didBecomeActive` 时 panel 不可见且 Settings 窗口不可见则唤回 panel——⌘Tab/点 Dock 激活而无窗口弹出会像"没反应"。accessory app 永不 become active,故该 observer 仅在 Dock 模式生效。
- R13.3 mainMenu 补 ⌘Q Quit(regular 下菜单栏可见,前台 regular app 无键盘退出是死路;与状态菜单 Quit 同为 terminate: 路径)。Dock 点击唤回走既有 `applicationShouldHandleReopen`。

### 验证(Owner: Orchestrator)
- `--smoke-dock` 3 项(off 保持 accessory/on 升 regular/off 降回);providers/steer 回归;Settings 渲染截图;⌘Tab 实际唤回人工验收。

## P14 模型列表过滤非 online 条目(用户反馈)

**背景**:TokenHub(腾讯云)等目录型平台的 `/v1/models` 会列出账号未开通的模型——条目携带 `status` 字段且非 `online`,调用时报 `400004 "model or service ID does not exist"`。此前 `decodeModelList` 只解 `id`,把全量目录都放进下拉菜单,用户选中即踩坑。标准 OpenAI 形状无 `status` 字段(OpenRouter 464 条实测均无),逻辑上零影响。

### 需求
- R14.1 `Entry` 增加可选 `status` 解码:字段存在且值非 `online`(大小写不敏感)时丢弃该条目;字段缺失一律保留(absence stays absence,不猜)。
- R14.2 被丢弃的条目不得贡献 capabilities(否则会以离线模型的元数据污染在线模型的能力判定来源)。

### 验证(Owner: Orchestrator)
- `--smoke-attach-caps` fixture 扩展四例:无字段保留、`"Online"`(大写)保留、`"offline"` 丢弃、丢弃条目无 capabilities;`--smoke-providers`、`--smoke-migration` 回归通过;`./build.sh` release 构建 + bundle 冒烟通过。

## P15 SelectableText 测高与绘制统一,消除末行被 footer 遮挡(用户反馈)

**背景**:AI 回复段落最后一行折行后不可见,点击该段才出现、点击别处又消失。根因是"两套 TextKit":`sizeThatFits` 用 `boundingRect` 测高,实际绘制走 `NSTextField` 自己的 cell 布局——"标题后跟段落"形态下 `boundingRect` 少算一段 paragraphSpacing(cell 需 606pt 时只报 600pt),SwiftUI 据此给的 frame 矮 6pt,末行下缘伸进 footer 行被盖;点击触发 field editor 盖顶层才可见。13pt CJK 字形被切底部 6pt 即不可读,故用户感知为"整行消失"。

### 需求
- R15.1 `sizeThatFits` 改用 field 自己的 `NSCell.cellSize(forBounds:)` 测量(谁绘制、谁测量),`boundingRect` 降级为无 cell 时的 fallback。
- R15.2 测量前把 cell 同步到将显示的字符串:SwiftUI 可能先于 `updateNSView` 调 `sizeThatFits`(streaming 每 tick),cell 里若是旧字符串,测出的高度滞后一拍。
- R15.3 新增 `--smoke-clip` 回归:8 类内容形态(latin/cjk/mixed/paras/listend/headend/linksend/urlend)× 220–700pt 宽度 0.5pt 步进共约 7700 个离屏 NSHostingView 布局,断言每个 NSTextField 的 frame 高度 ≥ 其 cell 在该宽度下的实际需要;修复前 paras 形态 961 处失配(均 +6pt),修复后 0 失配。

### 验证(Owner: Orchestrator)
- `--smoke-clip` 0 失配;`--smoke-typing`/`--smoke-scroll`/`--smoke-find`/`--smoke-rerun`/`--smoke-input`/`--smoke-history` 回归全过(`--smoke-pasteable`/`--smoke-search`/`--smoke-file` 失败为预先存在的环境问题:缺真实 API key / 裸二进制缺 bundle,与 0.6.2 对照二进制一致);用户真机确认末行无需点击即可见。

## P16 历史记录加载态——加载动画替代主窗口白屏(用户反馈)

**背景**:⌘Y 历史弹窗点开一条内容多的对话后,主界面数秒无反馈才出现内容。根因是 `ChatStore.loadConversation` 在主线程同步执行 `ConversationStore.loadResolved`:大转录(长文本、base64 附件、fork 链解析)解码即阻塞主线程数秒;此后新转录的首个 SwiftUI 布局(非 lazy VStack 全量建行)再阻塞一次,而恢复编排(`transcriptRevealed`)在布局完成前持续隐藏内容——两段阻塞期间主窗口即"白屏"。

### 需求
- R16.1 解码移出主线程:`loadConversation` 派发 `Task.detached` 执行 `loadResolved`,落地经 `finishLoading` 回主 actor adopt(或失败报错);加载窗口由新增 `@Published isLoadingConversation` 驱动 UI。
- R16.2 世代守卫:所有重指向 store 的路径(newChat、fork、deleteConversation 命中当前或 pending 会话、再次 loadConversation)bump `loadGeneration` 并经 `cancelPendingLoad()` 清态,在途加载落地即 no-op——被取代的加载不覆盖用户后续操作,已删除的目标会话不被"复活",失败路径(文件缺失)落错误行且不卡加载态;落地前若有新回合开跑,先 `stop()` 再 adopt,与同步版语义一致。
- R16.3 加载占位(用户拍板:纯动画、无文字):`ChatView.mainContent` 在 `isLoadingConversation` 期间以三点波浪动画替换转录区,pills 保留(拖拽条与身份);动画为 accent 色、CA 驱动的 repeatForever opacity(错峰仅由起始 delay 决定,repeat 不重置相位)——主线程被首个重布局阻塞时由 render server 续跑,这正是白屏修复的最后一环。出现/消失经 `.transition(.opacity)` + 仅绑定该标志的 `.animation` 双向淡入淡出,Reduce Motion 下瞬时切换。

### 验证(Owner: Orchestrator)
- 新增 `--smoke-history-load` 10 项:派发即置位、解码期间旧转录不受扰、异步 adopt 落地、完整转录解析(40×500 字符)、newChat 取消且永不 adopt、删除 pending 会话取消、缺失文件落错误行并清态;`--smoke-minsize`/`--smoke-persist`/`--smoke-rerun`/`--smoke-steer`/`--smoke-chat-search` 回归全过;加载动画观感经用户真机验收。
