# PopChat 功能增强开发需求文档 v1

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
- R2.1 `NSServices` 注册服务(Info.plist `NSServices` 声明 + `NSApp.servicesProvider`),任意 app 选中文字 → 服务菜单 "Ask PopChat"。
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

## 任务拆解与进度

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

**进度反馈机制**:每阶段由实施方(fixer)交付 → Orchestrator 读 diff + 本地 build/smoke 验证 → 更新本表与进度日志 → 下一阶段派发。

## 进度日志

- 2026-10-21 文档建立;P1(T1.1+T1.2)派发实施。
- 2026-10-21 P1 完成并经 Orchestrator 验证:diff 足迹符合范围(3 改 2 增),`./build.sh debug` 零 error,`--smoke-export` 9/9 ok,golden 逐字节校验,回归 3 项 smoke 通过。新增 `ConversationStore.resolved()`(纯内存物化,复用 `loadResolved`)。P2 派发实施。
- 2026-10-21 P2 完成:Services 注册 + 非激活路径 handler + 追加式引用预填 + 一次性提示;`--smoke-selection` 9/9。`--smoke-firstrun` 失败经 HEAD 基线 worktree 判定为环境性既有失败,与改动无关。P3 派发。
- 2026-10-21 P3 完成:`Titling` 纯函数层 + dispatch 即置位的仅一次守卫 + 旧 JSON 兼容;`--smoke-titling` 22/22。`--smoke-find` 为非确定抖动(同二进制连跑双态),非回归。P4 派发。
- 2026-10-22 P4 完成:`PersonaStore` + Custom 路径逐字节断言;`--smoke-persona` 10/10。**最终全量验收**(完整跑通一次,HEAD 基线对照):23 项 smoke 20 项 PASS(含 codex×4 与 `--smoke-file`,此前疑似悬挂系运行耗时超过守卫时限);3 项失败均为环境项——`--smoke-history` 屏幕几何断言在 HEAD 基线同样失败、`--smoke-search`/`--smoke-pasteable` 为本机 deepseek key 401;另 `--smoke-find` 偶发抖动重跑可过、`--smoke-firstrun` 基线即环境性失败。P1-P4 零回归。四阶段全部交付。
