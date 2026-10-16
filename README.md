# dsh-oneclick-desktop

把 DSH 变成一个**桌面应用**。三个东西，装一次全都有：

| | 功能 |
|---|---|
| 🖥️ **桌面启动** | 双击桌面图标启动 DSH —— 服务、无边框窗口、托盘，一步到位 |
| 🐋 **托盘控制** | 托盘菜单：打开 / 重启 / 状态 / 退出 |
| ⚡ **chat 分屏** | 侧边栏一键把 DSH 和 `chat.deepseek.com` 并排，`Ctrl+Alt+D` 收起/拉出 |

> **Windows only.** 分屏功能用 Win32 API 摆布真实窗口，托盘和快捷方式也是 Windows 机制。
> 其他平台装上去会给出明确提示，不会静默失败。

```
┌────────────────────────┬──────────────┐
│                        │              │
│      DSH  (左 2/3)     │  chat.deep   │
│                        │  seek (右 1/3)│
│                        │              │
└────────────────────────┴──────────────┘
   点侧边栏按钮出现 →  Ctrl+Alt+D 收起 / 拉出
```

## 安装

前提：**Windows**，装有 **Microsoft Edge** 或 **Google Chrome**，DSH ≥ `0.2.0-rc.2`。

在 DSH 侧边栏的「插件」页点 **Add plugin**，填入：

```
dsh-oneclick-desktop
```

或者：

```bash
dsh plugin --profile web add dsh-oneclick-desktop
dsh plugin --profile web add github:MKInori/dsh-oneclick-desktop
```

装完**刷新页面**（`Ctrl+Shift+R`）。桌面集成在插件加载时自动完成，见下。

> **首次仍需手动装一次 DSH。** 启动器的用途是"双击图标启动 DSH"，而它由 DSH 插件安装 ——
> 这是鸡生蛋，绕不过去。装好之后图标才存在。

## 它会往你的桌面上放什么

安装插件时，宿主半会跑一次 `lib/desktop.ps1 -Mode install`：

| 动作 | 位置 |
|---|---|
| 复制启动器脚本到**稳定目录** | `~/.dsh/dsh-oneclick-desktop/launcher/` |
| 创建桌面快捷方式 | `桌面\DSH.lnk` → 指向上面那个目录 |
| 注册 URL 协议 | `HKCU\Software\Classes\dshsplit` |

> 为什么要复制一份：插件更新会**替换整个包目录**，快捷方式不能指向那里，否则一升级就断。
> 稳定目录不受插件更新影响。

**撤销全部三样**：

```powershell
powershell -ExecutionPolicy Bypass -File ~\.dsh\plugins\dsh-oneclick-desktop\plugin\lib\desktop.ps1 -Mode remove
```

**只看当前状态**：把 `-Mode remove` 换成 `-Mode status`。

## 使用

**桌面启动**：双击桌面上的 DSH 图标。它会启动服务（若未运行）、打开无边框窗口、出现托盘图标。

**托盘菜单**：右键托盘图标 —— 打开 DSH / 重启 DSH / 查看状态 / 退出。

**chat 分屏**：

| 想做什么 | 怎么做 |
|---|---|
| 打开分屏 | 点侧边栏 **DeepSeek** 按钮 |
| 收起 chat（DSH 全屏） | `Ctrl+Alt+D` |
| 拉出 chat（恢复分屏） | 再按 `Ctrl+Alt+D` |
| 真正关闭 chat | 再点一次按钮（此时文字是「关闭 chat.deepseek」） |

第一次打开会稍慢（要冷启动浏览器窗口并等页面渲染完），**这是刻意的**：
插件等 chat 渲染好才让 DSH 让出空间，所以**你不会看到白屏或者空白区域**。

## 为什么要开独立窗口，而不是嵌在 DSH 里

`chat.deepseek.com` 返回 `content-security-policy: frame-ancestors 'none'`，
**浏览器会强制拒绝任何页面把它 iframe 进来**。所以"在 DSH 内嵌一个面板"这条路在技术上不存在。

这个插件的做法是：两个独立窗口，但可见区域精确贴合，看起来像一个整体的两栏。

## ⚠️ 它会做什么（装之前请读）

插件分两半：**客户端半**是页面上的按钮；**宿主半跑在 DSH 的宿主进程里，以你的权限执行**。
DSH 的工具审批**不会沙箱化插件代码**。宿主半具体会：

| 行为 | 细节 |
|---|---|
| **改你的桌面和注册表** | 创建 `桌面\DSH.lnk`，写 `HKCU\Software\Classes\dshsplit`（都在上面的「撤销」里可一键清除） |
| **启动 PowerShell 进程** | 执行 `lib/window.ps1`、`lib/desktop.ps1`、`launcher/DSH-Tray.ps1`（都随包发布，可自行审阅） |
| **操作窗口** | 通过 `user32.dll` 移动 / 缩放 / 显示隐藏窗口，并写入窗口的 `AppUserModelID` 属性以合并任务栏按钮 |
| **打开浏览器** | 用 Edge/Chrome 打开 `chat.deepseek.com`，使用**独立 profile**（`~/.dsh/edge-deepseek-profile`），与你的日常浏览器配置隔离 |
| **启动 DSH 服务** | 托盘在服务未运行时执行 `dsh web --no-open` |
| **读写本地文件** | 往 `~/.dsh/` 写状态文件 `dsh-chat-panel.state` 和日志 `dsh-chat-panel.log` |
| **监听热键** | 通过 `RegisterHotKey` 占用全局 `Ctrl+Alt+D`（**只在 chat 开着时**，关闭后立即释放） |

**它不会**：读取或上传你的任何文件内容、访问除 `chat.deepseek.com` 以外的网络地址、触碰你的日常浏览器 profile、修改 DSH 安装目录。

**它不能**：在 DSH 里嵌页面（CSP 禁止）、跨平台运行。

## 排错

| 现象 | 原因 / 处理 |
|---|---|
| 桌面图标没出现 | 跑一次 `lib\desktop.ps1 -Mode status` 看三项状态；`-Mode install` 可重跑（幂等） |
| 点了按钮没反应 | 看 `~/.dsh/dsh-chat-panel.log`，宿主把每次请求和脚本输出都写进去了 |
| 分屏四周有缝 | 窗口边框宽度会随窗口状态变化；把 DSH 最大化再点一次按钮即可重新计算 |
| 任务栏又出现两个图标 | 归组是在每次打开时施加的；关掉 chat 重开一次 |
| 按钮不见了 | DSH 侧边栏改版可能让 DOM 挂载点失效；刷新页面，或到「插件」页确认插件是启用状态 |
| `Ctrl+Alt+D` 不生效 | 被别的软件占了，看日志确认 |
| 托盘不出现 | 确认 `~/.dsh/dsh-oneclick-desktop/launcher/DSH-Tray.ps1` 存在；用 `-Mode install` 重装 |
| 提示找不到浏览器 | 装了 Edge 或 Chrome 吗？都在标准位置的话应该能自动找到 |

**一个已知行为**：插件**不干预你自己的窗口操作**。如果你手动把 DSH 最大化或拖到别处，
它不会自动纠正。按两次 `Ctrl+Alt+D`（收起再拉出）就能重新贴合。

## 卸载

```bash
dsh plugin --profile web remove dsh-oneclick-desktop
```

然后清掉桌面集成和残留：

```powershell
powershell -ExecutionPolicy Bypass -File ~\.dsh\plugins\dsh-oneclick-desktop\plugin\lib\desktop.ps1 -Mode remove
```

`~/.dsh/edge-deepseek-profile/`（chat 用的独立浏览器 profile）和
`~/.dsh/dsh-chat-panel.{state,log}` 可以手动删掉。

## 实现说明

想改代码或了解踩过的坑，看 [DEVELOPING.md](DEVELOPING.md) —— 里面记了每个设计决定和它对应的实测证据，
包括：窗口边框四边不等宽、Edge app 窗口没有 per-window AUMID、`Start-Sleep` 的 15.6ms 粒度、
为什么不能用 `spawn(..., {detached:true})`、以及 `$env:ProgramFiles(x86)` 必须写成
`${env:ProgramFiles(x86)}`。

## License

MIT
