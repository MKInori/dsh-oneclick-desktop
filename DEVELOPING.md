# dsh-chat-panel

在 DSH 里一键把窗口分成 **DSH 左 2/3 + chat.deepseek.com 右 1/3**，关闭聊天窗口后 DSH 自动恢复最大化。

## 为什么需要宿主半

浏览器里的按钮**无法设置窗口自身的位置和大小**（`window.resizeTo` 对自己没打开的窗口无效）。所以真正的窗口操作由 `lib/window.ps1` 通过 Win32 API 完成，客户端只负责发一个请求。

## 三种启动方式

| 方式 | 怎么做 | 验证状态 |
|---|---|---|
| **侧边栏按钮** | 侧边栏「新对话」旁出现「DeepSeek / 关闭 chat.deepseek」开关 | ✅ 宿主日志确认（含 /close /state 路由） |
| **协议链接** | 任何地方打开 `dshsplit:open` | ✅ 已实测 |
| **命令行** | `powershell -File lib\window.ps1 -Mode open` | ✅ 已实测 |

## 任务栏：chat 与 DSH 共用一个按钮

Windows 决定哪些窗口共用**一个**任务栏按钮，靠的是比较窗口的 **AppUserModelID（AUMID）**。

### ❌ 试过但无效：给 Edge 传 `--app-id`

第一版给 chat 窗口加了 `--app-id=0819c3316b0fb8b33f8ac199a7be0833`
（`sha256("http://127.0.0.1:3080/")` 前 16 字节的十六进制，即 DSH URL 的 Chromium app id）。

**实测无效**：加上它之后任务栏上仍然有 **3 个** Edge 按钮（1 个已固定 + DSH 和 chat 各一个）。
已从启动参数里移除——留着一个不起作用的开关比没有更糟。

### ✅ 有效：直接写窗口的 AUMID

Edge 的 `--app=` 窗口**没有** per-window AUMID（实测两个窗口的属性存储里都是空，
Edge 用的是进程级 id，而两个 profile 是两个进程，所以天然是两个按钮）。

所以 `window.ps1` 用 `SHGetPropertyStoreForWindow` + `IPropertyStore::SetValue`
给**两个窗口都写上同一个 id**：

```powershell
k.fmtid = '{9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}'   # PKEY_AppUserModel_ID 的 fmtid
k.pid   = 5                                            # PKEY_AppUserModel_ID
v.vt    = 31                                           # VT_LPWSTR
v.p     = Marshal.StringToCoTaskMemUni('Aesier.DSH.ChatPane')
store.SetValue(ref k, ref v); store.Commit()
```

**两个窗口都要写**：它们各自都没有 id，只写一个没有可匹配的对象。

### 实测证据

用 UI Automation 枚举任务栏按钮（截图核对图标），全程不需要人肉观察：

| 状态 | Edge 按钮数 | 按钮标签 |
|---|---|---|
| 修改前 | **3** | `[已固定]` / `[1 个运行窗口]` / `[1 个运行窗口]` |
| 修改后 | **2** | `[已固定]` / **`[2 个运行窗口]`** |

合并后的按钮显示的是 **DSH 的女仆图标**，鲸鱼图标消失，只有一个按钮。

### 持久性

| 情况 | 结果 |
|---|---|
| 等待 18 秒 | ✅ 保持（Edge 不会重新覆盖） |
| 移动/缩放两个窗口 | ✅ 保持 |
| Ctrl+Alt+D 收起 / 拉出 | ✅ 保持 |
| chat 窗口被重建（新进程） | ✅ 监听循环检测到新句柄后**自动重新归组** |
| 关闭 chat | ✅ 组内只剩 DSH，仍是一个按钮 |

### 参数

| 参数 | 位置 | 作用 |
|---|---|---|
| `$TaskbarGroupId` | `window.ps1` param | 共享的 AUMID 字符串，空串禁用整个机制 |

### 怎么复查这件事

任务栏从窗口管理器里看不到，而"让人肉眼看一眼"不可扩展，所以插件带了一个验证脚本：

```powershell
powershell -File tools\taskbar-check.ps1          # 报告按钮数和标签
powershell -File tools\taskbar-check.ps1 -Capture # 顺便把图标截出来
```

它用 **UI Automation** 枚举任务栏按钮。判断标准很简单：

```
OK:  the two panes share one button     ← 存在一个「2 个运行窗口」的按钮
```

脚本会 `SetProcessDPIAware()` —— 不调它的话，UIA 报的是物理像素坐标，而截图用的坐标系会被虚拟化，图标就截偏了。

> 从 Git Bash 里调用时，按钮标签的中文会显示成乱码（PowerShell 输出 GBK，bash 按 UTF-8 解码），
> 但判定结果本身是 ASCII，不受影响。直接在 PowerShell 里跑就没有这个问题。

> 关闭 chat 后**不还原** DSH 的 AUMID：组内只剩它自己，按钮外观不变，
> 而留着这个 id 反而让下次打开 chat 时不需要额外处理。

## 单实例保护

`-Mode open` 开头持有一个命名互斥量 `Global\DSH-Chat-Panel-Manager`：

```powershell
$singleton = New-Object System.Threading.Mutex($true, 'Global\DSH-Chat-Panel-Manager', [ref]$createdNew)
if (-not $createdNew) { Write-Host 'another manager is already running; exiting (single instance)'; exit 0 }
```

**没有它之前**：快速连点按钮会并行 spawn 多个 open 脚本——每个都执行一次分屏动画，
只有第一个抢到 Ctrl+Alt+D 热键，其余的全在跑空的监听循环（实测一次连点留下 3 个 watcher）。

互斥量随进程结束自动释放；`-Mode close` / `restore` 不持有它（它们是一次性动作，
必须在 watcher 存活期间也能执行）。

## 实测结果（宿主半完整验证）

```
初始:        DSH 1721x1033（最大化）
点击后:      DSH  1139x1019 at 0,0        ← 左 2/3
             Chat  568x1019 at 1139,0     ← 右 1/3
关闭 Chat:   DSH 1721x1033 at -7,-7       ← 自动恢复最大化
```

工作区是 1707x1019，按 2:1 精确切分。

## 触发机制

### A. 插件路由（侧边栏按钮用这个）

```
POST /dsh-chat-panel/open       打开切分
POST /dsh-chat-panel/restore    只恢复 DSH 最大化
```

**信任边界**（全部 fail-closed）：Host 必须是回环地址（或用 `DSH_CHAT_PANEL_HOSTS` 显式声明）、拒绝 `Sec-Fetch-Site: cross-site`、带 `Origin` 时必须与 Host 同源。

### B. `dshsplit:` 协议处理器

注册在 `HKCU\Software\Classes\dshsplit`，指向：

```
~/.dsh/launchers/open-dsh-chat-split.vbs
```

**这条路的优点**：完全不依赖 DSH 插件系统——不改 bundle、DSH 升级不会失效。

## 关闭检测机制

聊天窗口用的是**独立 Edge 配置**（`~/.dsh/edge-deepseek-profile`），所以不算浏览器普通窗口，不会和日常 Edge 混淆，登录态也隔离。

**关键在于：判定"聊天是否打开"看的是「有没有窗口」，不是「有没有进程」。**

这是个踩过的坑：**Edge 关掉窗口后后台进程仍然存活**，所以按进程数判断会得出"还开着"的错误结论，导致脚本跳过启动、然后一直空等——表现就是**点了按钮什么也没发生**。

## 设计原则：只做分屏，不干预你的窗口操作

监听循环**只监听一件事：聊天窗口消失**。除此之外它不碰任何窗口。

这一点是改过一轮的。曾经加过一个「拖到顶部就自动重新分屏」的逻辑——监听两个窗口的宽度，任一被最大化就强行拉回 2:1。那是对需求的误解：你要的是**分屏之后的那个效果**（两个窗口严丝合缝按比例铺满），而不是一个自定义手势。那段逻辑会**劫持你自己的窗口管理**——你想把某个窗口最大化看内容，它会把窗口拉回去。

现在的行为边界很明确：

| 你做的事 | 脚本的反应 |
|---|---|
| 点「网页对话」按钮 | 分屏：DSH 左 2/3、chat 右 1/3 |
| 关闭 chat 窗口 | DSH 恢复最大化 |
| 自己拖窗口、Win+方向键、悬停最大化按钮选贴靠布局 | **完全不干预** |
| 手动最大化任一窗口 | **不干预**（想回到分屏就再点一次按钮） |

> 实现上对窗口**先 `SW_RESTORE` 再 `MoveWindow`**。漏掉 restore 是个真实 bug——最大化状态的窗口会忽略 `MoveWindow` 的几何参数，结果是 DSH 那侧正确、chat 那侧仍然是满屏。

## 侧边栏按钮是一个开关

按钮文字跟随**真实状态**：

| 状态 | 按钮文字 | 点击后 |
|---|---|---|
| chat 未打开 | **DeepSeek** | 打开 chat（分屏） |
| chat 已打开 | **关闭 chat.deepseek** | 见下面的关闭时序 |

状态**不是本地记忆的**，而是每 2 秒向宿主轮询 `GET /dsh-chat-panel/state`。本地记忆一旦遇到"用 X 关掉聊天"或"Ctrl+Alt+D 收起"就会失真。

状态通道是一个文件 `~/.dsh/dsh-chat-panel.state`（内容 `open` / `closed`），由 `window.ps1` 在打开和关闭时写入，宿主路由直接读它。

### 点「关闭 chat.deepseek」的时序

```
1. DSH 平滑铺满整个工作区        ← 此时它已经盖住 chat
2. Raise-Window(dsh)            ← 确保真的在最上层
3. chat 移到屏幕外              ← 仍然藏在 DSH 后面，看不见
4. 才真正关闭 chat 窗口          ← WM_CLOSE，失败则终止该 profile 的进程
```

**顺序就是重点**：先关再动画的话，动画期间右侧会露出一条**光秃秃的桌面**。把"移走"和"关闭"都放在被盖住之后做，用户看到的只是 DSH 平滑铺满、聊天消失。

关闭只针对带 `--user-data-dir=edge-deepseek-profile` 的进程，**绝不碰你日常的 Edge**。

## 快捷键：Ctrl+Alt+D 收起 / 拉出

鼠标点按钮打开 chat 之后，用 **`Ctrl+Alt+D`** 来回切换：

| 状态 | DSH | chat |
|---|---|---|
| **拉出**（默认） | 左 2/3 | 右 1/3 |
| **收起**（按一下） | **铺满全屏** | 滑出屏幕外 |

收起时 chat **没有被最小化**，也没有被关闭——只是移到屏幕外，窗口本身仍然可见。这样它不会在任务栏留一个最小化条目，而且"chat 是否关闭"的检测仍然有效。想真正关掉就用按钮。

热键用 `RegisterHotKey` 注册在脚本自己的线程消息队列上（`hWnd = 0`），由监听循环用 `PeekMessage` 非阻塞地取——**不需要额外的常驻进程**。chat 窗口关闭时脚本会 `UnregisterHotKey` 并退出。

> 如果 `Ctrl+Alt+D` 被别的程序占了，启动日志里会出现 `warn: could not register Ctrl+Alt+D`，此时快捷键不生效，其余功能不受影响。

### 两个窗口必须各自独立地移动

两个窗口由**同一个插值循环**驱动（`Move-PanesSmooth`），不能一先一后。

第一版是"先移 DSH，睡 250ms，再移 chat"，结果是：DSH 已经缩小、而 chat 还在屏幕外，**右侧三分之一短暂空着**。同一个循环里一起插值，这个空洞就消失了。

但**每个窗口必须带自己的 top / height**，不能共用一个：

```powershell
# $dshFrom/$dshTo/$chatFrom/$chatTo 都是 @(left, top, width, height)
Move-PanesSmooth $dshH $dshFrom $dshTo $chatH $chatFrom $chatTo
```

原因见下一节——两个窗口的边框不一样。

隐藏时也**不用 `SW_MAXIMIZE`**，而是直接设成全屏尺寸——让两个方向走同一条代码路径，避免最大化/还原在滑动中途造成跳变。

## 分屏几何（两个窗口要分开测量）

### 四条边的边框并不相同

窗口矩形**包含一圈不可见的调整边框**。`SetWindowPos` 设的是这个**外框**，所以直接把外框边界对接，可见内容之间就会空出两条边框的宽度。

而四条边宽度还**各不相同**。本机 150% DPI 实测 DSH 窗口：

```
insets = 7 / 0 / 8 / 7     左 / 上 / 右 / 下
```

**顶部是 0**。第一版按水平差值算出一个统一的 `frame`（8）并四边都用它，结果把窗口**向上顶出屏幕 8px**，顶部内容被裁掉、底部又差一截没到任务栏。

所以由 `Get-FrameInsets` **每边各测一次**，四个方向分别补偿。

### ⚠️ 两个窗口的边框不一样

**这是本项目第二个隐蔽的坑。** 实测同一台机器上：

| 窗口 | insets |
|---|---|
| DSH 窗口 | `7 / 0 / 8 / 7` |
| Edge `--app=` 窗口（带 `--window-position` 启动） | **`0 / 0 / 0 / 0`** |

早期版本用 DSH 的 insets 去补偿 chat 窗口，于是 chat 偏了 8px（`middle=-8`、`right=-8`，还超出了屏幕右边缘）。

**现在每个窗口测自己的**，几何也各自成立：

```powershell
$insDsh  = Get-FrameInsets $dsh.Handle          # 7/0/8/7
$dshRect = @(工作区左 - insDsh[0],
             工作区顶 - insDsh[1],
             ($splitVisible + insDsh[2]) - $dshX,
             (工作区底 + insDsh[3]) - $dshTop)

# chat 的窗口在创建之前不存在，所以它的 insets 只能在窗口出现之后测
$insChat  = Get-FrameInsets $chat.Handle        # 0/0/0/0
$chatRect = @($splitVisible - $insChat[0], ...)
```

本机工作区 1707×1019，实测四条缝隙：

```
left=0   middle=-1   right=0   top=0   bottom=-1
```

（`-1` 表示 1px 重叠，视觉上就是严丝合缝。）

### ⚠️ 边框宽度还依赖窗口的**状态**

同一个窗口，**最大化**时和**恢复后**测出来的边框不一样。实测 DSH 窗口：

| 测量时机 | insets |
|---|---|
| 还处于最大化 | `7 / 7 / 8 / 8` |
| 恢复成普通窗口之后 | `7 / 0 / 8 / 7` ← 真实值 |

按最大化时的值补偿会多推 7px，**把窗口顶出屏幕、内容顶部被裁掉**。

所以测量要放在**恢复窗口之后**。`window.ps1` 的做法是测两次：

```powershell
$insDsh = Get-FrameInsets $dsh.Handle          # 先测一次（可能不准）
$dshRects = Get-DshRects $insDsh
...
Restore-ForMove ...                             # 先恢复状态
Update-DshGeometry $dsh.Handle                  # 再测一次，不一致就重算矩形
Move-PanesSmooth ... $dshRect ...
```

`Update-DshGeometry` 发现差异时会在日志里留一行，方便确认有没有触发：

```
dsh insets corrected after restore: 7/7/8/8 -> 7/0/8/9
```

同样的处理也用在了 `close` 模式和 `Ctrl+Alt+D` 的拉出分支——因为用户可能在
面板隐藏期间自己把 DSH 最大化了。

> **别只看"有没有缝"**：正数缝隙说明两个面板没贴住；**负数意味着被推出了屏幕**，
> 内容被裁掉。`tools/taskbar-check.ps1` 管任务栏，几何要交给 `verify.ps1`——
> 它要求每条缝隙都落在 `[-1, +1]`。

## 动画与时序

### 帧率：必须用 Stopwatch，不能用 Start-Sleep

**这是本项目踩过最隐蔽的一个坑。**

`Start-Sleep` 只能按**系统时钟粒度（15.6 ms）**唤醒。本机实测：

```
Start-Sleep -Milliseconds  6  ->  实际睡了 15.79 ms
Start-Sleep -Milliseconds 16  ->  实际睡了 29.17 ms
```

所以早先写的"30 帧 × 6ms ≈ 180ms"**实际上跑了 474ms**——比设计值慢 2.6 倍。用户感受就是"又慢又顿"。

现在由 `Stopwatch` 给每一帧定死截止时间，**只把最后 1.5ms 留给自旋**：

```powershell
$FPS = 60;  $frameMs = 1000.0 / $FPS;  $DURATION = 280
$FRAMES = [Math]::Max(8, [int][Math]::Round($DURATION * $FPS / 1000.0))   # 17 帧
$clock  = [System.Diagnostics.Stopwatch]::StartNew()
...
$target = $i * $frameMs
$remain = $target - $clock.Elapsed.TotalMilliseconds
if ($remain -gt 2.0) { Start-Sleep -Milliseconds ([int][Math]::Floor($remain - 1.5)) }
while ($clock.Elapsed.TotalMilliseconds -lt $target) { }
```

**实测 283.7 ms / 59.9 fps**（目标是 280 ms / 60 fps）。

> 自旋是为了补上睡眠的粒度误差。全程自旋也能精确，但会占满一个核；只自旋最后 1.5ms 既准又几乎不耗 CPU。

### 曲线

ease-out cubic，快起慢停：

```powershell
$e = 1 - [Math]::Pow(1 - ($i / $FRAMES), 3)
```

循环结束后再精确落一次目标位置，抵消整数取整留下的 1–2px 误差。

### 用 `SetWindowPos` 而不是 `MoveWindow`

```powershell
$FLAGS = 0x0004 -bor 0x0010     # SWP_NOZORDER | SWP_NOACTIVATE
```

`MoveWindow` 会**重新确认窗口的 Z 序并可能激活窗口**——两个窗口同时动画时这会闪。`SetWindowPos` 带这两个标志**只改几何**，不碰层叠关系，也不抢焦点。

### 时序一：首次打开 —— 窗口直接开在屏幕外

**关键点：不让用户看到任何中间画面。**

第一次尝试是"先让 Edge 在默认位置开窗，再把它挪到右 1/3"，结果用户看到**窗口闪一下**。两个来源：

1. 窗口在 Edge 默认位置被**创建并绘制**出来；
2. 旧的 `Place-Chat` 里还有一句 `Start-Sleep -Milliseconds 250` —— 在"恢复窗口"和"移动窗口"之间，窗口**在默认位置可见地停留了四分之一秒**。

**真正的修法是让窗口一开始就不在屏幕里。**

实测确认 Edge **确实遵守**这两个参数（要 500x400 @ 1200,150，得到的就是 500x400 @ 1200,150）：

```powershell
"--window-size=$chatW,$chatH",
"--window-position=$parkX,$top"     # $parkX = 屏幕右边缘 + 20
```

于是完整流程是：

```
1. Edge 直接把窗口创建在屏幕外（--window-position）
   → 从第一帧起就不可见，没有任何闪烁
2. 窗口出现后，测出它自己的 insets，算出 $chatRect
3. SetWindowPos 把它放进右 1/3，并 Sink-Window 压到 DSH 后面
   → DSH 此时仍是全屏，完全盖住它
4. Wait-ChatReady(chat, 900)   ← 等它画完第一帧
5. DSH 平滑缩回左 2/3          → chat 被"露"出来，此时已有内容
```

**是「几何暴露」而不是「层叠暴露」**：不是把 chat 提到上层盖住 DSH，而是让 DSH 让开位置。所以既没有白屏，也没有 chat 压在 DSH 上的怪异感，更没有任何窗口在错位置出现过。

> 顺带修正一个更早的错误判断：我曾以为 `--window-position` 被 Edge 忽略，所以只用了 `--window-size`。实际两个参数都生效——那次测试的结论是错的。


### 时序二：收起 —— DSH 先盖住，chat 再偷偷移走

```
1. DSH 平滑放大铺满
2. Raise-Window(dsh)           ← 确保 DSH 盖在 chat 上面
3. 等 90ms
4. chat 移到屏幕外             ← 它已经在 DSH 后面了，用户看不到它滑走
```

chat 是在**已经看不见的位置**移动的，视觉上就是"DSH 铺满，聊天消失了"。

### 时序三：点 chat 的 X 真正关闭

**不再瞬间 `SW_MAXIMIZE`**（那是生硬的跳变）。改成和快捷键完全相同的插值放大：

```
chat 消失 → DSH 用同样的 60fps 动画平滑铺满 → 退出
```

这样"点 X 关闭"和"按 Ctrl+Alt+D 收起"看起来是**同一个动作**，画面始终连贯、不会出现空白。

### 最大化状态的处理

如果 DSH 当前是**最大化**，`Restore-ForMove` 会先 `SW_RESTORE` **并立刻把它设回全屏尺寸**——动画从"用户当前看到的全屏"开始缩，而不是先闪一下浮动窗口再滑。

## 关闭检测：信任窗口句柄，而不是 WMI

`Get-ChatPids` 要查 WMI 拿进程命令行。**WMI 偶尔会瞬时返回空**，而旧版逻辑两次查不到就判定"chat 已关闭"，于是把 DSH 最大化并退出——用户会在会话中途突然被打断。

现在以**窗口句柄**为准：只要 `IsWindow($chatHandle)` 仍然成立，窗口就还在。这个判断不会间歇性失败。真正需要重查时才枚举，而且要**连续 4 次都失败**才认定关闭。

实测三条缝隙全部为 0。比例由 `-DshShare` 控制（默认 `0.667`）。

## 窗口识别的两条铁律

**1. 用 `EnumWindows`，不要用 `Get-Process`。**

PowerShell 的 `Get-Process` **每个进程只暴露一个 `MainWindowHandle`**。Edge 常有多个窗口，此时 DSH 窗口可能根本不在它报告的范围内，导致"找不到 DSH 窗口"。

本机实测：**同一个 `msedge.exe` 进程同时拥有 DSH 窗口和一个 bilibili 窗口**，`Get-Process` 只报告了后者。

**2. 用「带独立配置的 PID」认聊天窗口，不要用标题。**

曾经用标题匹配 `*DeepSeek*`，结果匹配到了你日常 Edge 里"AI - DeepSeek 搜索"那个窗口，差点把分屏几何套在它身上。现在只认带 `--user-data-dir=edge-deepseek-profile` 的进程所拥有的窗口。

## 排错

**按钮没出现？** 在 DSH 页面 URL 后加 `?dshchatdiag=1`，打开浏览器控制台，会看到：

- `[dsh-chat-panel] apply; services: {slots: true}` → 插件已加载
- `[dsh-chat-panel] entry mounted next to New Session` → 按钮已插入
- `[dsh-chat-panel] mount failed ...` → 插入失败，附原因

如果连第一条都没有，说明客户端半没被加载（需要检查 bundle 注册）。

**窗口切分不对？** 检查是否有多个 DSH 窗口——脚本取第一个标题含 `DeepSeek Harness` 的窗口。

## 已知限制

| 限制 | 原因 |
|---|---|
| 按钮位置固定在「新对话」旁 | DSH 的侧边栏没有可供第三方挂载的公共 slot，只能用 DOM 插入 |
| DSH 大改版可能让按钮消失 | 同上（匹配了 5 种文案做容错） |
| Edge 遵守 `--window-position` / `--window-size` | 已实测（要 500x400@1200,150，得到完全相同）。chat 直接在屏幕外创建，`MoveWindow` 只是后续微调 |
| 聊天窗口无法嵌在 DSH 内 | `chat.deepseek.com` 返回 `frame-ancestors 'none'`，iframe 被浏览器强制拒绝 |
| chat 与 DSH 共用一个任务栏按钮 | 由写入窗口 AUMID 实现（实测有效、可持久）。若某天 Windows 改为不读 per-window id，会退回两个按钮 |
| 合并后的按钮图标是 DSH 的 | 分组后任务栏取组内窗口的图标；实测显示的是 DSH 的女仆图标 |

## 卸载

```bash
dsh plugin --profile web remove dsh-chat-panel
# 协议处理器（可选）
reg delete "HKCU\Software\Classes\dshsplit" /f
```
