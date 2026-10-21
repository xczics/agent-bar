# Agent 状态浮窗：交接文档

> 这是项目最初的设计规格（2026-10-21），保留原样作为参考。实现时与它不同的地方记在 [Handoff.md](../Handoff.md#与设计文档的差异实现时做的决定)，当前用法以 [tutorial.md](tutorial.md) 为准。

Oct 21, 2026 · @Zicong

用 C++ 做一个常驻桌面的小浮窗，实时显示所有 Claude Code 会话（包括 VS Code 插件内的）是在运行、等待确认，还是已回复未读。本文档交给本地 Claude Code 实现，已有一版 Python 原型（`status_hook.py` + `agent_bar.py`）可作行为参考。

## 目标与范围

做：

- 一个 hook 可执行文件 `agent-status-hook`，由 Claude Code hooks 调用，把每个会话的状态写成一个 JSON 文件。
- 一个浮窗程序 `agent-bar`：置顶、无边框、可拖动，按“未读优先”列出所有会话。
- 点击标为已读，双击跳回对应项目的 VS Code 窗口。
- 安装脚本或说明：把 hooks 合并进 `~/.claude/settings.json`。

不做：

- 不控制 agent（不发消息、不批准权限），只显示状态。
- 不解析 transcript 内容，不联网，不做跨机器同步。
- 不写 VS Code 扩展（“是否真的看过面板”留到后续版本）。

> 待用户确认：目标平台。本文档按 Windows 和 macOS 都支持来写，实现时先做用户当前的平台。

## 技术选型

C++ 确实更省资源，但大头在 hook 而不在浮窗：hook 在每次工具调用前后都会被拉起一个新进程，启动开销会反复累积。浮窗只有一个常驻进程，用原生 API 才能明显省内存，用 Qt 则和 Python 差不多。

| 方案 | 单次启动 | 常驻内存 | 说明 |
| --- | --- | --- | --- |
| Python hook | 约 30–60 ms | 不常驻 | 每次工具调用触发 2 次，也会拖慢 agent |
| C++ hook | 约 1–3 ms | 不常驻 | 收益最大，应优先改写 |
| Python + tkinter 浮窗 | — | 约 20–40 MB | 原型版本 |
| C++ + Qt 浮窗 | — | 约 20–40 MB | 跨平台方便，但不省内存 |
| C++ + 原生 API 浮窗 | — | 约 2–8 MB | Windows 用 Win32，macOS 用 Cocoa（Objective-C++） |

上表数字为经验估算，实现后以实测为准。

决定：

- 语言用 C++17，构建用 CMake，产物是两个可执行文件。
- JSON 用单头文件库 nlohmann/json（通过 CMake FetchContent 拉取并固定版本），不引入其他依赖。
- 浮窗分为平台无关的 core 和平台 UI 层：Windows 用 Win32 + GDI，macOS 用 Cocoa（NSPanel）。先实现用户当前平台。
- 不轮询目录：用系统文件监听（Windows `ReadDirectoryChangesW`，macOS FSEvents），另加每 5 秒一次的计时器只用来刷新“已过时间”文字和判定无响应。

## 架构

&#91;embedded content: 架构 · 2 个程序，1 个共享目录\]

两个程序之间只通过状态文件目录通信，没有进程间调用：hook 崩溃不影响浮窗，浮窗没开也不影响 agent。浮窗唯一会写的字段是 `unread`。

## 状态文件协议与状态机

每个会话一个文件：`~/.claude/agent-status/<session_id>.json`（Windows 为 `%USERPROFILE%\.claude\agent-status\`）。这是 hook 与浮窗之间唯一的接口，格式与 Python 原型完全兼容，两边可以任意混用。

```json
{
  "v": 1,
  "session_id": "abc123",
  "project": "my-app",
  "cwd": "/Users/me/code/my-app",
  "state": "busy",
  "detail": "Bash",
  "unread": false,
  "since": 1792594648.72,
  "updated": 1792594648.77
}
```

| 字段 | 类型 | 含义 |
| --- | --- | --- |
| `v` | int | 协议版本，当前为 1；缺失时视为 1 |
| `project` | string | `cwd` 的最后一级目录名 |
| `state` | string | `idle` / `busy` / `waiting` / `replied` |
| `detail` | string | 工具名、提示词前 60 字符或通知文字 |
| `unread` | bool | 是否未读；浮窗点击后写回 `false` |
| `since` | float | 进入当前 `state` 的 Unix 时间（秒） |
| `updated` | float | 最后一次事件的 Unix 时间（秒） |

事件到状态的映射：

| Hook 事件 | 新状态 | unread | detail |
| --- | --- | --- | --- |
| `SessionStart` | idle | false | 空 |
| `UserPromptSubmit` | busy | false | `prompt` 前 60 字符，换行替换为空格 |
| `PreToolUse` | busy | false | `tool_name` |
| `PostToolUse` | busy | false | 保留旧值 |
| `Notification`（旧状态不是 replied） | waiting | true | `message` |
| `Notification`（旧状态是 replied） | 保持 replied | 保留旧值 | 保留旧值 |
| `Stop` | replied | true | 空 |
| `SessionEnd` | 删除文件 | — | — |

第二条 Notification 规则的原因：回复后长时间没理会，Claude Code 会发一条“等待输入”的提醒，它不应把“已回复”改成“等你确认”，也不应重置已读。

写入规则：

- `since`：状态未变时沿用旧值，状态改变时取当前时间。
- 原子写：先写同目录下的临时文件，再 `rename` 覆盖（Windows 用 `MoveFileExW` + `MOVEFILE_REPLACE_EXISTING`）。读方忽略 `.tmp` 后缀。
- 未知字段原样保留，方便以后扩展。

浮窗在读取时另外派生一个显示状态 `stale`：`state` 为 busy 且 `updated` 距今超过 10 分钟。它不写回文件。

## Hook 程序规格

`agent-status-hook` 是一个无窗口的命令行程序：从 stdin 读一个 JSON，按上表更新状态文件，然后退出。目标是单次运行低于 5 ms。

输入（Claude Code 通过 stdin 传入，只用到这些字段）：`session_id`、`hook_event_name`、`cwd`、`tool_name`、`prompt`、`message`。实现前请先对照 [Claude Code hooks 文档](https://docs.claude.com/en/docs/claude-code/hooks) 确认字段名。

硬性要求：

1. 任何情况下都以退出码 0 退出，不向 stdout 输出任何内容。退出码 2 或 stdout 的 JSON 会被 Claude Code 当作指令，可能拦下工具调用。
2. 调试信息只在设置了环境变量 `AGENT_STATUS_DEBUG=1` 时写到 `agent-status/hook.log`。
3. 输入非法、字段缺失、文件损坏时静默放弃，不抛异常到 main 之外。
4. `session_id` 只允许字母、数字、`-` 和 `_`，否则放弃，防止路径穿越。
5. 同一会话的事件可能并发（并行工具调用）。读改写用文件锁保护：POSIX 用 `flock` 锁 `<session_id>.lock`，Windows 用 `LockFileEx`；拿不到锁就等最多 50 ms，超时则放弃本次更新。
6. UTF-8 全程处理；截断 `prompt` 时按 Unicode 字符计数，不切断多字节字符。
7. 静态链接（Windows `/MT`），单文件分发；Windows 版使用 console 子系统但不弹窗。

settings.json 配置（七个事件均指向同一个程序，`PreToolUse`/`PostToolUse` 加 `"matcher": "*"`）：

```json
{
  "hooks": {
    "PreToolUse": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "~/.claude/bin/agent-status-hook" }] }],
    "Stop": [{ "hooks": [{ "type": "command", "command": "~/.claude/bin/agent-status-hook" }] }]
  }
}
```

提供 `install` 脚本（macOS 为 shell，Windows 为 PowerShell）：复制二进制到 `~/.claude/bin/`，并把上述七个事件**合并**进已有的 `settings.json`，不覆盖用户已有的其他 hooks，重复运行不产生重复条目。修改前先备份为 `settings.json.bak`。

## 浮窗程序规格

`agent-bar` 是一个常驻进程，空闲时 CPU 接近 0%、内存低于 10 MB。代码分两层：

- `core/`（纯 C++17，可单元测试）：扫描目录、解析状态文件、派生 `stale`、排序、标为已读（带同一把文件锁）、清理过期记录、格式化时长。
- `platform/win/` 和 `platform/mac/`：窗口、绘制、文件监听、菜单、启动 VS Code。

显示：

| 显示状态 | 颜色 | 文字 |
| --- | --- | --- |
| waiting | 红 `#e5484d` | 等你确认 |
| replied | 绿 `#30a46c` | 已回复 |
| busy | 橙 `#f5a524` | 运行中 |
| stale | 灰 `#8b8d98` | 无响应? |
| idle | 灰 `#8b8d98` | 空闲 |

- 标题行：`Agents  N 运行  M 未读`。
- 每行：彩色圆点、项目名（未读时加粗）、“状态 · 已过时间”（如 `运行中 · 3m`）、未读时右侧一个“新”徽标；第二行是灰色 `detail`，超过 48 字符截断加省略号。
- 排序：未读在前；然后 waiting → replied → busy → stale → idle；同组按 `updated` 倒序。
- 深色背景 `#1e1f24`，透明度约 93%，圆角窗口；支持高 DPI。

窗口行为：

- 始终置顶、无边框、不在任务栏 / Dock 显示、不抢焦点。macOS 用非激活的 `NSPanel`（`LSUIElement` 应用），并在所有桌面空间显示。
- 按住标题拖动；位置保存到 `agent-status/bar.ini`，下次启动恢复。
- 高度随会话数自动伸缩，宽度固定约 300 逻辑像素。
- 单击一行：标为已读。双击：标为已读并执行 `code <cwd>`（从 PATH 查找，以参数数组启动，不经过 shell）。
- 右键菜单：全部标为已读、清理空闲/无响应记录、开机自启（开/关）、退出。
- 单实例：再次启动时只把已有窗口带到前台。

数据更新：

- 目录变化通知到达后去抖 100 ms 再重新扫描，只在内容变化时重绘。
- 每 5 秒的计时器：刷新已过时间、重新判定 stale；每 10 分钟删除 `updated` 超过 12 小时的文件。
- 阈值（stale 10 分钟、过期 12 小时）可在 `bar.ini` 里调。
- 任何一个状态文件解析失败都只跳过该文件。

可选（第二阶段）：某会话变为 waiting 或 replied 时发一条系统通知，可在菜单中关闭。

## 已知局限、验收标准与里程碑

已知局限（实现时保持现状，不要试图绕过）：

- Ctrl+C / Esc 中断不触发 `Stop`，只能靠 stale 阈值兜底。
- 子 agent 在主会话内运行，只体现为主会话 busy，不单独成行。
- “已读”只由发下一条消息或点击浮窗触发，无法得知用户是否看过 VS Code 面板。
- hooks 在会话启动时加载，安装后已开着的会话需要重启。
- Windows 不展开 `~`：install 脚本写入 settings.json 的必须是绝对路径。

验收标准：

- [ ] 用脚本向 hook 依次喂入 SessionStart → UserPromptSubmit → PreToolUse → Stop → Notification → SessionEnd，状态文件内容与映射表一致，最后文件被删除。
- [ ] 非法 JSON、空 stdin、含 `../` 的 session\_id 都以退出码 0 退出且不写文件。
- [ ] 50 个并发 hook 进程写同一会话，文件始终是合法 JSON。
- [ ] hook 单次运行中位数低于 5 ms（用 `hyperfine` 测）。
- [ ] 浮窗在一个状态文件变化后 300 ms 内重绘。
- [ ] 浮窗空闲 1 小时，平均 CPU 低于 0.1%，常驻内存低于 10 MB。
- [ ] 与 Python 原型互通：Python hook 写的文件 C++ 浮窗能读，反之亦然。
- [ ] 同时开两个 VS Code 窗口、各跑一个会话，浮窗显示两行且状态各自正确。
- [ ] `core/` 有单元测试，覆盖映射表每一行和排序规则。

里程碑（按顺序，每步完成后给用户看一次）：

1. CMake 工程骨架 + `core/` + 单元测试。
2. `agent-status-hook` + install 脚本，先替换掉 Python hook 实际使用（收益最大的一步）。
3. 当前平台的 `agent-bar`。
4. 另一平台的 `agent-bar`、开机自启、系统通知（可选）。
