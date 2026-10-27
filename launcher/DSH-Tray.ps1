# ============================================================================
#  DSH Tray Controller
#
#  GENERATED FILE - see the generator that wrote it before hand-editing.
#  Deliberately PURE ASCII: Windows PowerShell 5.1 decodes a BOM-less .ps1
#  with the system ANSI code page, so literal CJK would be mangled. Chinese
#  labels are assembled at runtime from [char]0xXXXX codes.
#
#  Behaviour
#    * starts "dsh web --no-open" hidden, so no extra default-browser window
#    * opens ONE maximised chrome-less window (Edge --app=)
#    * tray icon with menu: open / restart / status / exit
#    * single-instance guard via a named mutex
#
#  Window mode note: this uses --app=, NOT a PWA. A PWA window would carry the
#  app's own taskbar identity, but it also installs itself into the browser and
#  the user preferred the plain chrome-less window. Do not reintroduce
#  --app-id without asking.
# ============================================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$ErrorActionPreference = 'Stop'

$script:URL = 'http://127.0.0.1:3080/'

# Both paths are located at runtime so the plugin works on any machine.
# ${env:ProgramFiles(x86)} needs the braces: PowerShell would otherwise read
# "$env:ProgramFiles(x86)" as $env:ProgramFiles plus the literal text "(x86)".
function Find-Browser {
  foreach ($c in @(
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
  )) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
  return ''
}

function Find-DshCommand {
  # Only an executable launcher will do: Start-Process cannot run a .ps1, and
  # "Get-Command dsh" resolves to dsh.ps1 on this machine. Ask for the .cmd /
  # .exe shims explicitly, then fall back to the usual install locations.
  foreach ($name in @('dsh.cmd', 'dsh.exe', 'dsh.bat')) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }
  }
  foreach ($c in @(
    "$env:APPDATA\npm\dsh.cmd",
    "$env:LOCALAPPDATA\pnpm\dsh.cmd",
    "$env:ProgramFiles\nodejs\dsh.cmd"
  )) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
  return 'dsh.cmd'
}

$script:EDGE    = Find-Browser
$script:DSH_CMD = Find-DshCommand
# Derived from this script's own folder, so the kit can be moved or copied
# without editing paths. Everything else here is machine-specific on purpose.
$script:ICON    = Join-Path $PSScriptRoot 'dsh.ico'
$script:Marker  = 'DeepSeek Harness'

# ------------------------------------------------------------ single inst ---
$script:Mutex   = New-Object System.Threading.Mutex($false, 'Global\DSH-Tray-Controller')
$script:GotLock = $false
try { $script:GotLock = $script:Mutex.WaitOne(0, $false) } catch { $script:GotLock = $true }
if (-not $script:GotLock) { exit 0 }

Add-Type -Namespace Dsh -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);
'@

# ---------------------------------------------------------------- server ---
function Test-Server {
  try {
    $req = New-Object -ComObject MSXML2.ServerXMLHTTP.6.0
    $req.SetTimeouts(1500, 1500, 1500, 3000)
    $req.Open('GET', $script:URL, $false)
    $req.Send()
    return $true          # any status, including 401, proves the server is up
  } catch { return $false }
}

function Start-Server {
  if (Test-Server) { return }
  Start-Process -FilePath $script:DSH_CMD -ArgumentList 'web', '--no-open' -WindowStyle Hidden
  for ($i = 0; $i -lt 90; $i++) {
    Start-Sleep -Seconds 1
    if (Test-Server) { return }
  }
  throw 'DSH did not become ready within 90 seconds.'
}

function Stop-Server {
  $pids = @()
  try {
    $pids = Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction Stop |
            Select-Object -ExpandProperty OwningProcess -Unique
  } catch {
    $line = (netstat -ano | Select-String ':3080\s+.*LISTENING' | Select-Object -First 1)
    if ($line) {
      $tok = ($line -split '\s+') | Where-Object { $_ -match '^\d+$' }
      if ($tok) { $pids = @([int]$tok[-1]) }
    }
  }
  foreach ($p in $pids) {
    if ($p -and $p -gt 0) { try { Stop-Process -Id $p -Force -ErrorAction Stop } catch { } }
  }
  for ($i = 0; $i -lt 20; $i++) {
    if (-not (Test-Server)) { return }
    Start-Sleep -Milliseconds 500
  }
}

# ---------------------------------------------------------------- window ---
function Get-AppWindow {
  Get-Process msedge -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowTitle -ne '' -and $_.MainWindowTitle -like "*$($script:Marker)*" } |
    Select-Object -First 1
}

function Open-Window {
  # Reuse an existing window instead of opening a second one.
  $w = Get-AppWindow
  if ($w) {
    $h = $w.MainWindowHandle
    try {
      # A minimised window has to come back first. SW_RESTORE on its own is
      # not enough for the visible case -- on a maximised window it RESTORES it
      # to its normal size, which looked exactly like "open stopped maximising".
      if ([Dsh.Win]::IsIconic($h)) { [Dsh.Win]::ShowWindow($h, 9) | Out-Null }   # SW_RESTORE
      [Dsh.Win]::ShowWindow($h, 3) | Out-Null                                    # SW_MAXIMIZE
      [Dsh.Win]::SetForegroundWindow($h) | Out-Null
      return
    } catch { }
  }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $script:EDGE
  # --app             : no address bar, no tabs
  # --start-maximized : fills the work area, keeps the title bar,
  #                     does not cover the taskbar
  $psi.Arguments = '--app=' + $script:URL + ' --start-maximized --no-first-run --no-default-browser-check'
  $psi.UseShellExecute = $false
  [void][System.Diagnostics.Process]::Start($psi)
    # --start-maximized is only a hint: an Edge --app window restores the
    # geometry the profile remembers and can ignore the flag, which is why a
    # cold start came up not maximised while reusing a window maximised fine.
    # Wait for it to appear, then ask explicitly.
    for ($i = 0; $i -lt 60; $i++) {
      Start-Sleep -Milliseconds 250
      $n = Get-AppWindow
      if ($n) {
        $nh = $n.MainWindowHandle
        if ([Dsh.Win]::IsIconic($nh)) { [Dsh.Win]::ShowWindow($nh, 9) | Out-Null }   # SW_RESTORE
        [Dsh.Win]::ShowWindow($nh, 3) | Out-Null                                    # SW_MAXIMIZE
        [Dsh.Win]::SetForegroundWindow($nh) | Out-Null
        break
      }
    }
}

# ------------------------------------------------------------------ tray ---
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon    = New-Object System.Drawing.Icon($script:ICON)
$notify.Text    = 'DSH'
$notify.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miOpen     = $menu.Items.Add([char]0x6253 + [char]0x5F00 + [char]0x7A97 + [char]0x53E3)
$miRestart  = $menu.Items.Add([char]0x91CD + [char]0x542F)
$miStatus   = $menu.Items.Add([char]0x72B6 + [char]0x6001)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miExit     = $menu.Items.Add([char]0x9000 + [char]0x51FA + [char]0xFF08 + [char]0x505C + [char]0x6B62 + [char]0x0020 + [char]0x0044 + [char]0x0053 + [char]0x0048 + [char]0xFF09)

$notify.ContextMenuStrip = $menu
$miOpen.Font         = New-Object System.Drawing.Font($miOpen.Font, [System.Drawing.FontStyle]::Bold)
$miOpen.ForeColor    = [System.Drawing.Color]::FromArgb(32, 49, 112)
$miRestart.ForeColor = [System.Drawing.Color]::FromArgb(32, 49, 112)
$miExit.ForeColor    = [System.Drawing.Color]::FromArgb(180, 30, 30)

$mRunning   = ([char]0x670D + [char]0x52A1 + [char]0x8FD0 + [char]0x884C + [char]0x4E2D)
$mStopped   = ([char]0x670D + [char]0x52A1 + [char]0x672A + [char]0x8FD0 + [char]0x884C)
$mRestarted = ([char]0x91CD + [char]0x542F + [char]0x5B8C + [char]0x6210)

function Show-Balloon([string]$title, [string]$body) {
  $notify.BalloonTipTitle = $title
  $notify.BalloonTipText  = $body
  $notify.BalloonTipIcon  = [System.Windows.Forms.ToolTipIcon]::Info
  $notify.ShowBalloonTip(4000)
}

$miOpen.Add_Click({
  try { Open-Window } catch { Show-Balloon 'DSH' ("Open failed: " + $_.Exception.Message) }
})

$miRestart.Add_Click({
  try {
    Stop-Server
    Start-Server
    Start-Sleep -Milliseconds 800
    Open-Window
    Show-Balloon 'DSH' $mRestarted
  } catch { Show-Balloon 'DSH' ("Restart failed: " + $_.Exception.Message) }
})

$miStatus.Add_Click({
  if (Test-Server) { Show-Balloon 'DSH' $mRunning } else { Show-Balloon 'DSH' $mStopped }
})

$miExit.Add_Click({
  Stop-Server
  $notify.Visible = $false
  $notify.Dispose()
  [System.Windows.Forms.Application]::Exit()
})

$notify.Add_MouseDoubleClick({ try { Open-Window } catch { } })

# --------------------------------------------------------------- startup ---
try {
  Start-Server
  Start-Sleep -Milliseconds 800
  Open-Window
} catch {
  $notify.Text = 'DSH - start failed'
  Show-Balloon 'DSH' $_.Exception.Message
}

[System.Windows.Forms.Application]::Run()
