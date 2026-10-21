# 开发指南

给想改 agent-bar 代码的人看：项目结构、构建测试、状态协议，以及**如何让 agent-bar 支持你喜欢的 agent**。

## 目录

- [架构](#架构)
- [构建与测试](#构建与测试)
- [状态协议](#状态协议)
- [为你喜欢的 agent 添加支持](#为你喜欢的-agent-添加支持)
- [移植到新平台](#移植到新平台)
- [文档约定与发版](#文档约定与发版)

## 架构

```text
agent 的 hook ──stdin──▶ agent-status-hook [--agent <name>]
                              │ adapter：把原始事件转成内部的 7 种事件
                              │ apply_event：状态机
                              ▼
                 ~/.claude/agent-status/<session>.json   ◀── 唯一的接口
                              │ FSEvents
                              ▼
                          agent-bar（浮窗）
```

| 目录 / 文件 | 内容 |
| --- | --- |
| `core/include/agentbar/status.hpp` | `HookEvent`（内部事件）、`apply_event`（状态机）、`Session`、排序、显示文本 |
| `core/include/agentbar/adapter.hpp` | **adapter 注册表**：每种 agent 一个，把它的原始事件转成 `HookEvent` |
| `core/include/agentbar/store.hpp` | 状态目录：文件锁、原子写、扫描、标为已读、清理、会话发现、`attach` |
| `core/include/agentbar/settings.hpp` | 把 hooks 合并进 Claude Code 的 `settings.json` |
| `core/include/agentbar/config.hpp` | `bar.ini` |
| `hook/main.cpp` | `agent-status-hook`：hook 模式，以及 `emit` / `install-hooks` / `uninstall-hooks` 子命令 |
| `platform/mac/main.mm` | macOS 浮窗（NSPanel、绘制、FSEvents、菜单、设置窗口、`attach`） |
| `tests/test_core.cpp` | core 单元测试，不依赖任何测试框架 |
| `scripts/` | 安装、卸载、验收、冒烟测试、打包 |

`core/` 不依赖任何平台 UI，所有逻辑都应该放在这里并写单元测试；平台层只负责窗口、绘制和系统调用。

## 构建与测试

需要 CMake 3.20 及以上版本和支持 C++17 的编译器（macOS 上装 Xcode Command Line Tools 即可）。唯一的第三方依赖是 nlohmann/json，由 CMake 自动拉取并固定版本。

```sh
cmake -S . -B build && cmake --build build -j
ctest --test-dir build --output-on-failure   # 单元测试
scripts/acceptance.sh                        # hook 验收（事件序列、非法输入、并发、emit、性能）
scripts/bar-smoke.sh                         # 浮窗冒烟（会短暂弹出一个测试窗口）
build/bin/agent-bar --snapshot /tmp/a.png [compact|expanded|settings]   # 离屏渲染界面，检查视觉改动
```

所有测试都使用临时的 `AGENT_STATUS_DIR`，不会碰真实的 `~/.claude`。CI（`.github/workflows/ci.yml`）会在 macOS 和 Linux 上跑同样的步骤。

## 状态协议

每个会话一个文件：`~/.claude/agent-status/<session_id>.json`。这是 hook 和浮窗之间唯一的接口，完整定义见 [design.md](design.md#状态文件协议与状态机)。

```json
{
  "v": 1,
  "session_id": "abc123",
  "agent": "claude",
  "project": "my-app",
  "cwd": "/Users/me/code/my-app",
  "state": "busy",
  "detail": "Bash",
  "unread": false,
  "since": 1792594648.72,
  "updated": 1792594648.77
}
```

- `state` 只有四种取值：`idle` / `busy` / `waiting` / `replied`。“无响应”（stale）由浮窗在读取时推导，不写进文件。
- `agent` 是 adapter 的名字，用来区分不同的 agent。旧文件没有这个字段时，按 Claude Code 处理。
- 写文件必须先对 `<session_id>.lock` 加 `flock`，再写临时文件并 rename 覆盖。用 `store::handle_event` 就自动满足这些要求。
- 不认识的字段要原样保留。

**内部事件**（`HookEvent.event`）沿用 Claude Code 的 7 个事件名。任何 agent 都要映射到这几个事件上：

| 内部事件 | 含义 | 结果状态 |
| --- | --- | --- |
| `SessionStart` | 会话开始 | idle |
| `UserPromptSubmit` | 用户发了消息（`prompt` 进 detail） | busy |
| `PreToolUse` | 开始调用工具（`tool_name` 进 detail） | busy |
| `PostToolUse` | 工具调用结束 | busy |
| `Notification` | 需要用户确认或回答（`message` 进 detail） | waiting（已回复时保持 replied） |
| `Stop` | 这一轮回答完了 | replied，未读 |
| `SessionEnd` | 会话结束 | 删除文件 |

## 为你喜欢的 agent 添加支持

目标：让另一种 agent（例如某个 CLI 编程助手）的会话也显示在浮窗上。思路是写一个 **adapter**，把它的原始事件转换成上面的内部事件；剩下的状态机、存储和界面都可以直接复用。

### 0. 先摸清对方能提供什么

你需要从对方 agent 那里拿到：

| 需要的信息 | 用途 | 拿不到怎么办 |
| --- | --- | --- |
| 事件通知机制：hook、notify 回调或插件 API，能调用外部程序 | 驱动状态变化 | 没有的话就做不了，只能等对方支持 |
| 每次调用传入的数据格式（stdin JSON、命令行参数，还是环境变量） | 写解析函数 | — |
| 会话 ID | 状态文件名 | 用 cwd 加进程号做哈希，自己造一个稳定的 ID |
| 工作目录 cwd | 项目名、点击跳转 | 用 hook 进程自己的当前目录 |
| “回答完了”和“需要确认”这两类事件 | 最有价值的两个状态（已回复 / 等你确认） | 只有“回答完了”也够用 |

在接入代码之前，可以先用 `emit` 手动模拟，看一下浮窗上的效果：

```sh
~/.claude/bin/agent-status-hook emit --agent mytool --session-id demo1 --event UserPromptSubmit --cwd ~/code/x --prompt "fix bug"
~/.claude/bin/agent-status-hook emit --agent mytool --session-id demo1 --event Stop
~/.claude/bin/agent-status-hook emit --agent mytool --session-id demo1 --event SessionEnd
```

### 1. 写解析函数

在 `core/src/adapter.cpp` 里加一个函数，把对方的原始输入转换成 `HookEvent`。下面是一个虚构 agent “mytool”的例子：假设它的 hook 从 stdin 传入 `{"type": "turn_end", "conversation": "...", "workdir": "..."}`。

```cpp
namespace {

std::optional<HookEvent> parse_mytool(std::string_view raw) {
  json j = json::parse(raw.begin(), raw.end(), nullptr, /*allow_exceptions=*/false);
  if (j.is_discarded() || !j.is_object()) return std::nullopt;

  HookEvent ev;
  ev.session_id = j.value("conversation", "");
  ev.cwd = j.value("workdir", "");
  const std::string type = j.value("type", "");
  if (type == "session_start")         ev.event = "SessionStart";
  else if (type == "user_message")   { ev.event = "UserPromptSubmit"; ev.prompt = j.value("text", ""); }
  else if (type == "tool_call")      { ev.event = "PreToolUse"; ev.tool_name = j.value("tool", ""); }
  else if (type == "approval_needed"){ ev.event = "Notification"; ev.message = j.value("reason", ""); }
  else if (type == "turn_end")         ev.event = "Stop";
  else if (type == "session_end")      ev.event = "SessionEnd";
  else return std::nullopt;            // 不关心的事件直接忽略

  if (!is_valid_session_id(ev.session_id)) return std::nullopt;
  return ev;
}

}  // namespace
```

要点：

- **绝不能抛异常**：用 `allow_exceptions=false`，并且对字段类型做检查（`j.value` 在类型不符时会抛异常，正式代码里要先判断 `is_string()`，可以参考 `parse_hook_input`）。
- **session_id 只允许 `[A-Za-z0-9_-]`**。如果对方的 ID 含有其他字符（比如路径或 `:`），就做一次转换（替换字符或取哈希），并且保证同一个会话每次都得到同一个结果。
- 把对方的事件映射到上面表格里最接近的内部事件。对方没有的事件可以不管：缺了 `PreToolUse` 只是 detail 少一些信息；缺了 `SessionEnd` 时，记录会在 12 小时后被自动清理。
- 不需要设置 `ev.agent`，`parse_with()` 会自动填上。

### 2. 注册

在同一个文件的 `adapters()` 表里加一行（`claude` 必须保持在第一位，它是默认 adapter）：

```cpp
static const std::vector<Adapter> list = {
    {"claude", "Claude Code", &parse_hook_input},
    {"mytool", "MyTool", &parse_mytool},
};
```

`name` 会出现在命令行和状态文件里，只能用 `[a-z0-9_-]`；`display_name` 会显示在浮窗的展开列表和 tooltip 里（例如 `MyTool · my-app`）。

### 3. 写测试

在 `tests/test_core.cpp` 里，用对方**真实的** payload 样例写测试：每种事件一条，再加上非法输入和不认识的事件。`adapters_registry` 测试会自动检查所有 adapter 都能悄悄拒绝垃圾输入。

```cpp
TEST(adapter_mytool) {
  const Adapter* a = find_adapter("mytool");
  auto e = parse_with(*a, R"({"type":"turn_end","conversation":"c1","workdir":"/x/proj"})");
  CHECK(e && e->event == "Stop" && e->agent == "mytool");
  CHECK(!parse_with(*a, R"({"type":"something_else","conversation":"c1"})"));
}
```

### 4. 让对方 agent 调用 hook

在对方的配置里，让它在每个事件发生时运行：

```sh
~/.claude/bin/agent-status-hook --agent mytool    # 原始数据从 stdin 传入
```

hook 模式下的硬性规则对所有 adapter 都一样：**永远以退出码 0 结束，不往 stdout 输出任何内容**，因为很多 agent 会把 hook 的输出当成指令。如果对方只能通过命令行参数传数据，就写一个很小的包装脚本，把参数转成 JSON 再通过管道传给 hook，或者直接调用 `agent-status-hook emit ...`。

如果希望安装脚本自动完成这一步，就在 `scripts/install.sh` 里加一个可选参数（例如 `--with-mytool`）。要求和 Claude Code 的做法一样：改之前先备份，只合并不覆盖，重复运行不产生重复条目，卸载时只移除自己加的条目。要修改的配置格式比较复杂时，把合并逻辑写成 C++ 放进 `core/`，参考 `settings.cpp` 的写法，并写单元测试。

### 5. 可选增强

- **会话发现**：如果对方也维护了正在运行的会话列表，可以仿照 `store::discover_sessions` 写一个，让浮窗启动时就能看到已经开着的会话。
- **点击跳转**：现在点击灯会执行 `code <cwd>`。如果对方 agent 跑在别的地方（终端、独立 App），可以在 `platform/mac/main.mm` 的 `clickedLight:` 里按 `Session.agent` 做不同的处理。
- **`attach`**：现在的实现靠 Claude Code 的会话登记来认出所属会话，其他 agent 需要自己的识别方式。

### 6. 文档

- `docs/tutorial.md` 的“支持哪些 agent”表格里加一行，并写清楚怎么配置。
- `changelog/unreleased.md` 里记一条。
- 提 PR 时说明你实测过的 agent 版本。

## 移植到新平台

- `core/src/store.cpp` 目前只有 POSIX 实现（遇到 `_WIN32` 会直接 `#error`）。Windows 需要用 `LockFileEx` 实现锁，用 `MoveFileExW(MOVEFILE_REPLACE_EXISTING)` 实现原子替换，并补一个 `parent_pid` 的实现。
- 浮窗放在 `platform/<平台>/` 下，只负责窗口、绘制、目录监听和菜单；排序、文本、布局（例如 `light_grid`）都直接调用 `core/`。
- 安装脚本要写入**绝对路径**（Windows 不会展开 `~`）。

## 文档约定与发版

- `Handoff.md`：只记正在做和规划中的工作。
- `changelog/unreleased.md`：已完成但还没发布的内容；发版时改名为 `changelog/vX.Y.Z.md`，它同时就是 GitHub Release 的说明。
- `docs/tutorial.md`：始终和当前行为一致，改了用户能看到的行为就要同步更新。
- `Inbox.md`：维护者留言箱，处理完的条目要删掉。

发版步骤：修改 `CMakeLists.txt` 里的 `project(agent-bar VERSION x.y.z)`，把 `changelog/unreleased.md` 改名为 `changelog/vx.y.z.md`，提交后打 tag `vx.y.z` 并推送。`release.yml` 会检查 tag 和 CMake 里的版本号是否一致，然后构建 universal 包并发布。
