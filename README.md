# dsh-chat-panel

在 DSH 里一键把窗口分成两半：**DSH 占左 2/3，`chat.deepseek.com` 占右 1/3** —— 一边跑 agent，一边随时问官方网页。

> **Windows only.** 这个插件用 Win32 API 摆布真实窗口，macOS / Linux 上不会工作（装上去会给出明确提示，不会静默失败）。

```
┌────────────────────────┬──────────────┐
│                        │              │
│      DSH  (左 2/3)     │  chat.deep   │
│                        │  seek (右 1/3)│
│                        │              │
└────────────────────────┴──────────────┘
   点侧边栏按钮出现 →  Ctrl+Alt+D 收起 / 拉出
```

## 它做什么

- 在 DSH 侧边栏加一个**开关按钮**：「DeepSeek」↔「关闭 chat.deepseek」
- 点一下：把 DSH 窗口缩到左 2/3，在右边 1/3 打开一个 `chat.deepseek.com` 的独立浏览器窗口，**四边严丝合缝、中间无缝**
- `Ctrl+Alt+D`：**收起 / 拉出**。收起时 chat 滑出屏幕外、DSH 铺满；再按一次滑回来
- 两个窗口**共用一个任务栏按钮** —— chat 不会在任务栏多出一个图标
- 关掉 chat 窗口：DSH 自动平滑恢复全屏

## 为什么要开独立窗口，而不是嵌在 DSH 里

`chat.deepseek.com` 返回 `content-security-policy: frame-ancestors 'none'`，
**浏览器会强制拒绝任何页面把它 iframe 进来**。所以"在 DSH 内嵌一个面板"这条路在技术上不存在。

这个插件的做法是：两个独立窗口，但可见区域精确贴合，看起来像一个整体的两栏。

## 安装

前提：**Windows**，装有 **Microsoft Edge** 或 **Google Chrome**，DSH ≥ `0.2.0-rc.2`。

在 DSH 侧边栏的「插件」页点 **Add plugin**，填入：

```
dsh-chat-panel
```

或者用命令行：

```bash
dsh plugin --profile web add dsh-chat-panel
```

也可以从 git 安装：

```bash
dsh plugin --profile web add github:<your-user>/dsh-chat-panel
```

装完刷新页面（`Ctrl+Shift+R`），侧边栏「新对话」旁边就会出现按钮。

## 使用

| 想做什么 | 怎么做 |
|---|---|
| 打开分屏 | 点侧边栏 **DeepSeek** 按钮 |
| 收起 chat（DSH 全屏） | `Ctrl+Alt+D` |
| 拉出 chat（恢复分屏） | 再按 `Ctrl+Alt+D` |
| 真正关闭 chat | 再点一次按钮（此时文字是「关闭 chat.deepseek」） |

第一次打开会稍慢（要冷启动一个浏览器窗口并等页面渲染完），**这是刻意的**：
插件等 chat 渲染好才让 DSH 让出空间，所以**你不会看到白屏或者空白区域**。

如果 `Ctrl+Alt+D` 被别的软件占用，日志里会出现 `warn: could not register Ctrl+Alt+D`，
其余功能不受影响。

## ⚠️ 它会做什么（装之前请读）

插件分两半：**客户端半**只是页面上的一个按钮；**宿主半跑在 DSH 的宿主进程里，以你的权限执行**。
DSH 的工具审批**不会沙箱化插件代码**。宿主半具体会：

| 行为 | 细节 |
|---|---|
| **启动 PowerShell 进程** | 执行 `lib/window.ps1`（本插件自带，随包发布，可自行审阅） |
| **操作窗口** | 通过 `user32.dll` 移动 / 缩放 / 显示隐藏窗口，并写入窗口的 `AppUserModelID` 属性以合并任务栏按钮 |
| **打开浏览器** | 用 Edge/Chrome 打开 `chat.deepseek.com`，使用**独立 profile**（`~/.dsh/edge-deepseek-profile`），与你的日常浏览器配置隔离 |
| **读写本地文件** | 往 `~/.dsh/` 写状态文件 `dsh-chat-panel.state` 和日志 `dsh-chat-panel.log` |
| **监听热键** | 通过 `RegisterHotKey` 占用全局 `Ctrl+Alt+D`（**只在 chat 开着时**，关闭后立即释放） |

**它不会**：读取或上传你的任何文件内容、访问除 `chat.deepseek.com` 以外的网络地址、触碰你的日常浏览器 profile、修改 DSH 安装目录。

**它不能**：在 DSH 里嵌页面（CSP 禁止）、跨平台运行。

## 排错

| 现象 | 原因 / 处理 |
|---|---|
| 点了按钮没反应 | 看 `~/.dsh/dsh-chat-panel.log`，宿主把每次请求和脚本输出都写进去了 |
| 分屏四周有缝 | 窗口边框宽度会随窗口状态变化；把 DSH 最大化再点一次按钮即可重新计算 |
| 任务栏又出现两个图标 | 归组是在每次打开时施加的；关掉 chat 重开一次 |
| 按钮不见了 | DSH 侧边栏改版可能让 DOM 挂载点失效；刷新页面，或到「插件」页确认插件是启用状态 |
| `Ctrl+Alt+D` 不生效 | 被别的软件占了，看日志确认 |
| 提示找不到浏览器 | 装了 Edge 或 Chrome 吗？都在标准位置的话应该能自动找到 |

**一个已知行为**：插件**不干预你自己的窗口操作**。如果你手动把 DSH 最大化或拖到别处，
它不会自动纠正。按两次 `Ctrl+Alt+D`（收起再拉出）就能重新贴合。

## 卸载

在 DSH 侧边栏「插件」页里移除，或：

```bash
dsh plugin --profile web remove dsh-chat-panel
```

`~/.dsh/edge-deepseek-profile/`（chat 用的独立浏览器 profile）和
`~/.dsh/dsh-chat-panel.{state,log}` 可以手动删掉。

## 实现说明

想改代码或了解踩过的坑，看 [DEVELOPING.md](DEVELOPING.md) —— 里面记了每个设计决定和它对应的实测证据，
包括：窗口边框四边不等宽、Edge app 窗口没有 per-window AUMID、`Start-Sleep` 的 15.6ms 粒度、
以及为什么不能用 `spawn(..., {detached:true})`。

## License

MIT
