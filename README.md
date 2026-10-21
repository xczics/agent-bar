# agent-bar

一个常驻桌面的小浮窗，实时显示你所有 Claude Code 会话（包括 VS Code 插件里的）的状态：**运行中**、**等你确认**、还是**已回复未读**。

<p>
  <img src="docs/images/compact.png" height="44" alt="紧凑模式：一排彩色的灯">
  &nbsp;&nbsp;
  <img src="docs/images/expanded.png" width="300" alt="展开后的会话列表">
</p>

- **紧凑模式**（默认）：一排会发光的灯，一个灯对应一个会话；灯上方是项目简称，下方是状态简写，两者都可以关掉。未读的灯外面会扩散光环。单击灯，直接跳到那个项目的 VS Code 窗口。
- **展开列表**：点右侧的 ⌄ 按钮展开，可以看到项目名、状态、已过时间和当前在做的事。
- 两个小程序，C++ 编写：hook 单次运行约 1 ms，浮窗空闲时几乎不占 CPU。
- 只读状态，不控制 agent，不联网。

> 目前支持 macOS 11 及以上版本（Apple 芯片和 Intel 都支持）。Windows 版在规划中。

## 安装

**让你的 agent 帮你装**（最省事）：把下面这段 prompt 原样发给 Claude Code（或其他能执行命令的 agent）即可。

```text
请帮我在这台 Mac 上安装 agent-bar（https://github.com/xczics/agent-bar）——一个显示所有 Claude Code 会话状态的桌面浮窗。按下面的步骤做，遇到任何错误先停下来告诉我：

1. 确认系统是 macOS 11 或更高版本。
2. 在一个新建的临时目录里，下载最新 release 的 universal 包和对应的 .sha256 文件：
   gh release download -R xczics/agent-bar -p '*-macos-universal.tar.gz*'
   （没有 gh 时，用 curl 读取 https://api.github.com/repos/xczics/agent-bar/releases/latest，找到这两个 asset 的下载地址再下载。）
   用 shasum -a 256 -c 校验，然后解压。
3. 先完整阅读解压出来的 install.sh，确认它只做这三件事：把程序复制到 ~/.claude/bin/；备份 ~/.claude/settings.json 并合并 agent-status-hook 的 hooks；启动浮窗。然后问我要不要开机自启，按我的回答运行 ./install.sh 或 ./install.sh --autostart。
4. 运行 ~/.claude/bin/agent-bar --list，确认列表里能看到当前这个会话。
5. 告诉我：浮窗在屏幕右上角；settings.json 的备份在哪里；卸载命令是 ~/.claude/bin/agent-bar-uninstall。

不要改动 settings.json 中与 agent-status-hook 无关的任何内容。
```

**从 Release 手动安装**：

```sh
V=0.0.1
curl -fsSLO https://github.com/xczics/agent-bar/releases/download/v$V/agent-bar-$V-macos-universal.tar.gz
tar xzf agent-bar-$V-macos-universal.tar.gz
agent-bar-$V-macos-universal/install.sh
```

用 `curl` 下载不会带上隔离属性。如果是用浏览器下载的，安装脚本会自动去掉 `com.apple.quarantine`。

**从源码安装**：

```sh
git clone https://github.com/xczics/agent-bar.git && cd agent-bar
cmake -S . -B build && cmake --build build -j
scripts/install.sh
```

安装脚本会：

1. 把 `agent-status-hook` 和 `agent-bar` 复制到 `~/.claude/bin/`；
2. 把 7 个 hook **合并**进 `~/.claude/settings.json`（先备份为 `settings.json.bak`，不动你已有的其他 hooks，重复运行也不会产生重复条目）；
3. 启动浮窗。

加上 `--autostart` 参数可以设成开机自启（之后也能在右键菜单里切换）。

## 使用

| 颜色（默认） | 状态 | 含义 |
| --- | --- | --- |
| 🟢 绿（发光） | 运行中 | 正在思考或调用工具 |
| 🟡 黄 | 已回复 | 这一轮已经答完，等你回话 |
| 🔴 红 | 等你确认 | Claude 在等你批准权限或回答问题 |
| 暗绿（熄灭） | 空闲 | 刚开的会话，还没发消息 |
| ⚪ 灰 | 无响应? | 运行中但已经超过 10 分钟没有任何动静 |

颜色都可以在右键菜单 →“设置…”里自己改。

- **紧凑模式**：单击灯 = 标为已读，并在 VS Code 里打开该项目；单击右侧 ⌄ 按钮（或空白处）= 展开列表。
- **展开列表**：单击一行 = 标为已读；双击 = 标为已读并打开 VS Code；点右上角的“收起”回到紧凑模式。
- **拖动**：在浮窗任意位置按住拖动即可移动（原地松开才算点击）。
- **右键菜单**：展开/收起、全部标为已读、清理空闲记录、紧凑模式（以及灯上简称、灯下状态两个开关）、开机自启、设置…、退出。
- **设置窗口**：自定义每种状态的颜色（可恢复默认）、显示选项、无响应阈值、开机自启。

更详细的说明（配置项、命令行参数、排错、卸载）见 [使用教程](docs/tutorial.md)。

## 工作原理

```text
Claude Code ──hook(stdin JSON)──▶ agent-status-hook ──写──▶ ~/.claude/agent-status/<session>.json
                                                                      │ FSEvents
                                                                      ▼
                                                                  agent-bar（浮窗）
```

两个程序只通过状态文件目录通信：hook 崩溃不影响浮窗，浮窗没开也不影响 agent。协议与状态机见 [设计文档](docs/design.md)。

## 卸载

```sh
~/.claude/bin/agent-bar-uninstall           # 加 --purge 会同时删除状态目录
```

卸载会从 settings.json 移除 hooks（同样先备份）、退出浮窗，并删除开机自启项和二进制文件。

## 开发

见 [教程 · 从源码构建与测试](docs/tutorial.md#从源码构建与测试)。正在做和规划中的工作记在 [Handoff.md](Handoff.md)，已完成的内容记在 [changelog/](changelog/)。

## License

[MIT](LICENSE)
