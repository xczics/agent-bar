# Handoff

这里只记**正在做**和**规划中**的工作。已完成的内容移到 [changelog/](changelog/)，用法写进 [docs/tutorial.md](docs/tutorial.md)。人类留言放在 [Inbox.md](Inbox.md)。

当前版本：0.0.1（macOS）。上次更新：2026-10-21。

## 正在做

- [ ] **1 小时空闲测量**：`scripts/bar-idle.sh 3600`，验收标准是平均 CPU < 0.1%。20 秒的短样本里有过一次 0.55%，原因是每 5 秒计时器都重绘一次；之后已改成“显示内容变了才重绘”，等长测结果确认。
- [ ] **人工验收**：同时开两个 VS Code 窗口、各跑一个会话，浮窗应显示两个灯，状态各自正确；单击灯能跳到对应的窗口。本机已确认 VS Code 插件会话能被记录。

## 规划中

### 近期

- [ ] **内存**：目标是 10 MB 以内，实测约 14 MB（空白 Cocoa 面板的基线就要约 10 MB）。可以尝试：用 CoreText 直接绘制、复用 NSFont 和属性字典、紧凑模式下不加载 CJK 字体；或者接受现状，把设计目标改成“< 16 MB”。
- [ ] **系统通知**（设计文档里的第二阶段）：会话变为 waiting 或 replied 时发通知，可在菜单里关闭。需要先打包成 `.app` bundle（UNUserNotificationCenter 要求有 bundle），顺便可以加图标。
- [ ] **紧凑模式自动收起**：展开后，鼠标离开浮窗 N 秒自动收回紧凑模式（可选，等用户确认要不要）。
- [ ] **签名与公证**：目前只有 ad-hoc 签名。用浏览器下载后需要运行 install.sh 才能去掉隔离属性。

### 之后

- [ ] **Windows 版 agent-bar**（里程碑 4）：Win32 + GDI，用 `ReadDirectoryChangesW` 监听目录，`LockFileEx` 加锁，`MoveFileExW` 原子替换；需要在 `core/src/store.cpp` 里加 Win32 分支（目前遇到 `_WIN32` 会直接 `#error`）；install 脚本用 PowerShell，并且必须写入绝对路径。
- [ ] Windows 版 CI 和 Release 产物。

## 与设计文档的差异（实现时做的决定）

- 新增**紧凑模式**并设为默认（用户要求）；展开列表即原设计中的界面。
- hook 带了管理子命令（`install-hooks` / `uninstall-hooks`），由它负责合并 settings.json。这样不依赖 python 或 jq，以后 Windows 也能复用。
- 新增环境变量 `AGENT_STATUS_DIR`，用于测试隔离。
- Notification 的 `detail` 会把换行换成空格，并截断到 200 个字符。原规格只说用 `message`，没有限制长度。
- 本机没有 Python 原型，“互通”是按协议格式验证的：在 `acceptance.sh` 里用 Python 模拟原型的写法。
- 观察到 Claude Code 现在会热加载 settings.json 里的 hooks，设计文档中“安装后需要重启会话”这一条可能已经过时。
