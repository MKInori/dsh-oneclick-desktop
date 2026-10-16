# ============================================================================
#  dsh-oneclick-desktop -- Windows window manager
#
#  Modes:
#    open    : shrink DSH to the left 2/3, open chat.deepseek.com in the right
#              1/3 (isolated Edge profile), then watch that WINDOW and restore
#              DSH to maximised once it closes.
#    restore : just maximise the DSH window.
#
#  Three rules learned the hard way -- do not regress them:
#
#  1. Enumerate windows with EnumWindows, never with Get-Process. PowerShell's
#     Get-Process exposes ONE MainWindowHandle per process, so when Edge owns
#     several windows the DSH window can be invisible to it and lookups fail.
#     Verified on this machine: one msedge process owned both the DSH window
#     and a separate bilibili window.
#
#  2. Identify the chat windows by PID bound to our dedicated --user-data-dir,
#     never by window title. Title matching once matched the user's ordinary
#     Edge window showing a DeepSeek search result, and moved the wrong window.
#
#  3. "Chat is open" means A WINDOW EXISTS, not "processes exist". Edge keeps
#     background processes alive after its last window closes, so a process
#     count stays non-zero while nothing is on screen. Testing the process
#     count made the launcher skip opening and then watch forever -- the button
#     appeared to do nothing.
#
#  Pure ASCII: Windows PowerShell 5.1 reads a BOM-less .ps1 with the system ANSI
#  code page, so literal CJK here would break parsing.
# ============================================================================

param(
  [ValidateSet('open', 'close', 'restore')]
  [string]$Mode = 'open',

  [string]$ChatUrl = 'https://chat.deepseek.com/',

  # Host-specific paths. Left empty they are resolved at runtime from the
  # environment (see "host paths" below) so the plugin works on any machine;
  # pass them explicitly only to override.
  [string]$EdgePath = '',
  [string]$ProfileDir = '',
  [string]$StateFile = '',

  [string]$Marker = 'DeepSeek Harness',

  # Shared taskbar identity. Windows groups taskbar buttons by AppUserModelID
  # (AUMID), and Edge --app= windows from two different Edge profiles carry
  # different ids, so the chat pane would get its own taskbar icon. The id is
  # NOT set per window by Edge, so writing it ourselves is what makes both panes
  # share one button -- hovering that button then lists both windows.
  #
  # Passing --app-id to Edge does NOT achieve this: verified with three Edge
  # buttons on the taskbar while it was set. Only this property write groups.
  # Empty string disables the whole mechanism.
  [string]$TaskbarGroupId = 'DSH.ChatPane',

  [double]$DshShare = 0.667,
  [int]$AppearTimeoutSec = 45,
  [int]$WatchSeconds = 43200
)

$ErrorActionPreference = 'Continue'

# ------------------------------------------------------------------ host ---
# This plugin drives Windows windows through Win32, so anything else gets a
# clear message instead of a confusing failure somewhere in the middle.
if ($env:OS -ne 'Windows_NT') {
  Write-Host "error: dsh-oneclick-desktop arranges windows with Win32 APIs and only runs on Windows (detected OS '$env:OS')."
  exit 1
}

# Host paths are resolved here rather than in the param block, so the same
# script works on any machine: nothing under the author's home directory is
# baked in. $env:DSH_HOME wins when a deployment sets it.
$dshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
if (-not $ProfileDir) { $ProfileDir = Join-Path $dshHome 'edge-deepseek-profile' }
if (-not $StateFile)  { $StateFile  = Join-Path $dshHome 'dsh-oneclick-desktop.state' }

function Find-Browser {
  # First Chromium browser that exists, most preferred first. Edge is preferred
  # because the DSH launcher opens DSH in Edge, and the taskbar grouping only
  # merges the two panes when they come from the same browser family.
  #
  # ${env:ProgramFiles(x86)} needs the braces: PowerShell would otherwise read
  # "$env:ProgramFiles(x86)" as $env:ProgramFiles followed by the literal text
  # "(x86)", producing a path with no separator that never resolves.
  $candidates = @(
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
  )
  foreach ($c in $candidates) {
    if ($c -and (Test-Path -LiteralPath $c)) { return $c }
  }
  return ''
}

if (-not $EdgePath) { $EdgePath = Find-Browser }

# ------------------------------------------------------------------ single ---
# Only ONE open/watch manager may run. Rapid double-clicks used to spawn several
# open scripts side by side: each one widened/narrowed the panes, and only the
# first got the Ctrl+Alt+D hotkey, while the rest kept a full watch loop alive
# for nothing. The mutex is held for the process lifetime and released when the
# script exits; close/restore run freely (they are one-shot and must work while
# a manager watches).
if ($Mode -eq 'open') {
  $createdNew = $false
  $singleton = New-Object System.Threading.Mutex($true, 'Global\DSH-Chat-Panel-Manager', [ref]$createdNew)
  if (-not $createdNew) {
    Write-Host 'another manager is already running; exiting (single instance)'
    exit 0
  }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -Namespace DshChatWin -Name Api -MemberDefinition @'
public delegate bool EnumProc(System.IntPtr h, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr GetWindow(System.IntPtr h, uint cmd);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern int GetWindowTextLength(System.IntPtr h);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool GetClientRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool ClientToScreen(System.IntPtr h, ref POINT p);
[DllImport("user32.dll")] public static extern bool MoveWindow(System.IntPtr h, int x, int y, int w, int hh, bool repaint);
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool IsZoomed(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr hWnd, System.IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
[DllImport("user32.dll")] public static extern System.IntPtr SendMessage(System.IntPtr hWnd, uint msg, System.IntPtr wParam, System.IntPtr lParam);
[DllImport("user32.dll")] public static extern bool RegisterHotKey(System.IntPtr hWnd, int id, uint fsModifiers, uint vk);
[DllImport("user32.dll")] public static extern bool UnregisterHotKey(System.IntPtr hWnd, int id);
[DllImport("user32.dll")] public static extern bool PeekMessage(out MSG lpMsg, System.IntPtr hWnd, uint min, uint max, uint remove);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
[StructLayout(LayoutKind.Sequential)] public struct MSG { public System.IntPtr hwnd; public uint message; public System.IntPtr wParam; public System.IntPtr lParam; public uint time; public int ptX; public int ptY; }

// ---- taskbar grouping -----------------------------------------------------
// Windows decides which windows share one taskbar button by comparing their
// AppUserModelID. Edge gives every --app= window an id derived from its profile,
// so a chat pane in its own profile lands on a separate button. The shell reads
// the per-window id from the window's property store; setting it here is the
// only thing that reliably merges the two panes.
//
// Verified on this machine: with --app-id passed to Edge the taskbar still had
// three Edge buttons (one pinned, plus DSH and chat separately). After writing
// this property to both windows, the taskbar showed two -- the pinned one and a
// single button labelled "2 个运行窗口". The write survives window moves and
// does not get overwritten by Edge.
[StructLayout(LayoutKind.Sequential)] public struct PKEY { public System.Guid fmtid; public uint pid; }
[StructLayout(LayoutKind.Sequential)] public struct PVAR {
  public ushort vt; public ushort r1; public ushort r2; public ushort r3; public System.IntPtr p;
}
[System.Runtime.InteropServices.ComImport, System.Runtime.InteropServices.Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), System.Runtime.InteropServices.InterfaceType(System.Runtime.InteropServices.ComInterfaceType.InterfaceIsIUnknown)]
public interface IPropStore {
  void GetCount(out uint c);
  void GetAt(uint i, out PKEY k);
  void GetValue(ref PKEY k, out PVAR v);
  void SetValue(ref PKEY k, ref PVAR v);
  void Commit();
}
[DllImport("shell32.dll")]
public static extern int SHGetPropertyStoreForWindow(System.IntPtr hwnd, ref System.Guid riid, out IPropStore store);

public static bool SetTaskbarGroupId(System.IntPtr hwnd, string id) {
  if (hwnd == System.IntPtr.Zero) return false;
  if (string.IsNullOrEmpty(id)) return false;
  var iid = new System.Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
  IPropStore st;
  int hr = SHGetPropertyStoreForWindow(hwnd, ref iid, out st);
  if (hr != 0 || st == null) return false;
  var k = new PKEY();
  k.fmtid = new System.Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
  k.pid = 5;                                    // PKEY_AppUserModel_ID
  var v = new PVAR();
  v.vt = 31;                                    // VT_LPWSTR
  v.p = System.Runtime.InteropServices.Marshal.StringToCoTaskMemUni(id);
  try { st.SetValue(ref k, ref v); st.Commit(); return true; }
  catch { return false; }
  finally { System.Runtime.InteropServices.Marshal.FreeCoTaskMem(v.p); }
}
'@

$SW_RESTORE  = 9
$SW_MAXIMIZE = 3
$GW_OWNER    = 4

# Z-order helpers. The reveal/hide sequences depend on which pane is on top:
# revealing wants the chat pane above DSH while it settles, hiding wants DSH
# above the chat pane so the chat can be parked off-screen unseen.
$HWND_TOP        = [System.IntPtr]::Zero
$SWP_NOACTIVATE  = 0x0010

# Global toggle hotkey: Ctrl+Alt+D. Registered on this thread's message queue
# (hWnd = 0) and pumped with PeekMessage from the watch loop below.
$HOTKEY_ID    = 1
$MOD_CTRL_ALT = 0x0003
$VK_D         = 0x44
$WM_HOTKEY    = 0x0312
$PM_REMOVE    = 0x0001

function Get-TopWindows {
  # Every visible, owner-less top-level window: handle, owning pid, title.
  $acc = New-Object System.Collections.ArrayList
  $cb = [DshChatWin.Api+EnumProc]{
    param($h, $l)
    try {
      if ([DshChatWin.Api]::IsWindowVisible($h)) {
        if ([DshChatWin.Api]::GetWindow($h, $GW_OWNER) -eq [System.IntPtr]::Zero) {
          $len = [DshChatWin.Api]::GetWindowTextLength($h)
          if ($len -gt 0) {
            $sb = New-Object System.Text.StringBuilder ($len + 2)
            [void][DshChatWin.Api]::GetWindowText($h, $sb, $sb.Capacity)
            $owner = [uint32]0
            [void][DshChatWin.Api]::GetWindowThreadProcessId($h, [ref]$owner)
            [void]$acc.Add([pscustomobject]@{ Handle = $h; Pid = [int]$owner; Title = $sb.ToString() })
          }
        }
      }
    } catch { }
    return $true
  }
  [void][DshChatWin.Api]::EnumWindows($cb, [System.IntPtr]::Zero)
  return $acc
}

function Get-ChatPids {
  @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -like "*$ProfileDir*" } |
      Select-Object -ExpandProperty ProcessId)
}

function Get-DshWindow {
  Get-TopWindows | Where-Object { $_.Title -like "*$Marker*" } | Select-Object -First 1
}

function Get-ChatWindow {
  # A visible top-level window owned by one of our chat-profile processes.
  $pids = Get-ChatPids
  if ($pids.Count -eq 0) { return $null }
  Get-TopWindows | Where-Object { $pids -contains $_.Pid -and $_.Title -notlike "*$Marker*" } | Select-Object -First 1
}

function Get-FrameInsets($handle) {
  # Invisible resize frame per side, as @(left, top, right, bottom).
  #
  # The frame is NOT symmetric. Measured on this machine at 150% DPI, the Edge
  # app window has 8 px left/right and 7 px bottom, but NO top frame (0 px).
  # Averaging them into one number (the first version computed a single width
  # from the horizontal difference) pushed both panes 8 px above the top of the
  # work area, clipping their content. Measure each side separately.
  $fallback = @(8, 8, 8, 8)
  if (-not $handle -or $handle -eq [System.IntPtr]::Zero) { return $fallback }
  $wr = New-Object DshChatWin.Api+RECT
  $cr = New-Object DshChatWin.Api+RECT
  if (-not [DshChatWin.Api]::GetWindowRect($handle, [ref]$wr)) { return $fallback }
  if (-not [DshChatWin.Api]::GetClientRect($handle, [ref]$cr)) { return $fallback }
  $tl = New-Object DshChatWin.Api+POINT; $tl.X = $cr.Left;  $tl.Y = $cr.Top
  $br = New-Object DshChatWin.Api+POINT; $br.X = $cr.Right; $br.Y = $cr.Bottom
  [void][DshChatWin.Api]::ClientToScreen($handle, [ref]$tl)
  [void][DshChatWin.Api]::ClientToScreen($handle, [ref]$br)
  $l = $tl.X - $wr.Left
  $t = $tl.Y - $wr.Top
  $r = $wr.Right - $br.X
  $b = $wr.Bottom - $br.Y
  foreach ($v in @($l, $t, $r, $b)) {
    if ($v -lt 0 -or $v -gt 60) { return $fallback }   # implausible: keep known values
  }
  return @([int]$l, [int]$t, [int]$r, [int]$b)
}

function Start-Chat($parkX, $top, $chatW, $chatH) {
  # --window-size / --window-position ARE honoured by Edge (verified: asked for
  # 500x400 at 1200,150 and got exactly that). Launching straight into the
  # parking spot just off the right edge of the screen is what makes the window
  # invisible from its very first painted frame. Without this the window appears
  # wherever Edge feels like putting it, is painted there, and only then gets
  # moved -- that blink is what the user saw.
  $a = @(
    "--app=$ChatUrl",
    "--user-data-dir=$ProfileDir",
    '--no-first-run',
    '--no-default-browser-check',
    "--window-size=$chatW,$chatH",
    "--window-position=$parkX,$top"
  )
  # No --app-id here on purpose: it was tried and does NOT group the buttons
  # (three Edge buttons remained on the taskbar while it was set). Grouping is
  # done by Set-TaskbarGroup below, which writes the window's AppUserModelID.
  # -WindowStyle Normal is REQUIRED, not cosmetic. The host spawns this script
  # with `-WindowStyle Hidden`, and Start-Process lets the child inherit that
  # window state -- so the chat window would be created HIDDEN: invisible on
  # screen, absent from the visible-window enumeration, and therefore
  # indistinguishable from "the chat window is already closed". The launcher
  # would then open nothing, conclude the chat had closed, maximise DSH and
  # exit, which looks exactly like the button doing nothing.
  Start-Process -FilePath $EdgePath -ArgumentList $a -WindowStyle Normal | Out-Null
}

function Get-WinGeom($handle) {
  # @(left, top, width, height) of a window's OUTER rect, or $null.
  #
  # Full rects, not just left/width: the two panes do NOT share a frame. On this
  # machine the DSH window carries insets 7/0/8/7 while an Edge --app= window
  # launched with --window-position carries 0/0/0/0, so their top and height
  # legitimately differ and each has to be animated on its own.
  if ($handle -eq [System.IntPtr]::Zero) { return $null }
  $r = New-Object DshChatWin.Api+RECT
  if (-not [DshChatWin.Api]::GetWindowRect($handle, [ref]$r)) { return $null }
  return @([int]$r.Left, [int]$r.Top, [int]($r.Right - $r.Left), [int]($r.Bottom - $r.Top))
}

function Move-PanesSmooth($dshH, $dshFrom, $dshTo, $chatH, $chatFrom, $chatTo) {
  # $dshFrom/$dshTo/$chatFrom/$chatTo are @(left, top, width, height).
  #
  # Each pane carries its OWN top and height because the two windows do not share
  # a frame: the DSH window measured insets 7/0/8/7 on this machine while an
  # Edge --app= window launched with --window-position measured 0/0/0/0. Sharing
  # one top/height made the chat pane sit 8 px low and 8 px wide.
  #
  # SetWindowPos with SWP_NOZORDER|SWP_NOACTIVATE instead of MoveWindow.
  # MoveWindow re-asserts the window's Z position and can activate the window,
  # which flickers when two panes are animating together. This only changes
  # geometry and leaves stacking alone.
  #
  # Timing is driven by a Stopwatch, not Start-Sleep.
  #
  # Start-Sleep can only wake on the 15.6 ms system clock tick: measured on this
  # machine, "-Milliseconds 6" really slept 15.8 ms and "-Milliseconds 16" slept
  # 29.2 ms. So the earlier "30 frames x 6 ms" build actually ran for ~474 ms,
  # not 180 -- slow AND steppy, which is exactly what it felt like. Here each
  # frame has a hard deadline; we sleep off all but the last 1.5 ms and spin out
  # the remainder, so the frame rate is real and CPU use stays low.
  $FLAGS  = 0x0004 -bor 0x0010     # SWP_NOZORDER | SWP_NOACTIVATE
  $FPS    = 60
  $frameMs = 1000.0 / $FPS
  $DURATION = 280                  # total animation length, ms
  $FRAMES = [Math]::Max(8, [int][Math]::Round($DURATION * $FPS / 1000.0))
  $clock  = [System.Diagnostics.Stopwatch]::StartNew()

  for ($i = 1; $i -le $FRAMES; $i++) {
    $e = 1 - [Math]::Pow(1 - ($i / $FRAMES), 3)   # ease-out cubic: quick, then settle
    foreach ($pane in @(
        @{ H = $dshH;  From = $dshFrom;  To = $dshTo  },
        @{ H = $chatH; From = $chatFrom; To = $chatTo })) {
      if ($pane.H -eq [System.IntPtr]::Zero -or -not $pane.From -or -not $pane.To) { continue }
      $x = [int]($pane.From[0] + ($pane.To[0] - $pane.From[0]) * $e)
      $y = [int]($pane.From[1] + ($pane.To[1] - $pane.From[1]) * $e)
      $w = [int]($pane.From[2] + ($pane.To[2] - $pane.From[2]) * $e)
      $h = [int]($pane.From[3] + ($pane.To[3] - $pane.From[3]) * $e)
      [void][DshChatWin.Api]::SetWindowPos($pane.H, [System.IntPtr]::Zero, $x, $y, $w, $h, $FLAGS)
    }
    # Wait until this frame's deadline. Sleep off all but the last ~1.5 ms, then
    # spin: the scheduler can only wake on 15.6 ms boundaries, so a pure sleep
    # would overshoot every deadline by most of a frame. Measured with these
    # margins: 283.7 ms for a 280 ms animation, i.e. 59.9 fps.
    $target = $i * $frameMs
    $remain = $target - $clock.Elapsed.TotalMilliseconds
    if ($remain -gt 0) {
      if ($remain -gt 2.0) { Start-Sleep -Milliseconds ([int][Math]::Floor($remain - 1.5)) }
      while ($clock.Elapsed.TotalMilliseconds -lt $target) { }
    }
  }
  $clock.Stop()
  # Land exactly on the targets: integer rounding above can leave a pixel or two.
  $LAND = 0x0004 -bor 0x0010
  foreach ($pane in @(
      @{ H = $dshH;  To = $dshTo  },
      @{ H = $chatH; To = $chatTo })) {
    if ($pane.H -eq [System.IntPtr]::Zero -or -not $pane.To) { continue }
    [void][DshChatWin.Api]::SetWindowPos($pane.H, [System.IntPtr]::Zero, $pane.To[0], $pane.To[1], $pane.To[2], $pane.To[3], $LAND)
  }
}

function Restore-ForMove($handle, $fullX, $top, $fullW, $height) {
  # A maximised window ignores MoveWindow, so it must be restored first -- but
  # restoring alone snaps it to its old floating size, which looks like a jolt
  # right before the slide. Restore and immediately re-apply full-screen
  # geometry in the same breath, so the animation starts from what the user
  # currently sees.
  if ($handle -eq [System.IntPtr]::Zero) { return }
  if ([DshChatWin.Api]::IsZoomed($handle)) {
    [void][DshChatWin.Api]::ShowWindow($handle, $SW_RESTORE)
    Start-Sleep -Milliseconds 40
    [void][DshChatWin.Api]::MoveWindow($handle, $fullX, $top, $fullW, $height, $true)
    Start-Sleep -Milliseconds 30
  }
}

function Maximize-Dsh {
  $w = Get-DshWindow
  if ($w) { [void][DshChatWin.Api]::ShowWindow($w.Handle, $SW_MAXIMIZE); return $true }
  return $false
}

function Set-State($value) {
  # Publish "open" / "closed" for the host route to read, so the sidebar button
  # can render the right label. Best-effort: a failure here must not affect the
  # window work.
  try { [System.IO.File]::WriteAllText($StateFile, $value) } catch { }
}

function Close-Chat {
  # Ask the chat windows to close politely. WM_CLOSE lets the page run its own
  # teardown; if that is ignored, fall back to terminating the profile's
  # processes. Only processes carrying our dedicated --user-data-dir are
  # touched, so the user's ordinary Edge is never affected.
  $WM_CLOSE = 0x0010
  $wins = @(Get-TopWindows | Where-Object { (Get-ChatPids) -contains $_.Pid })
  foreach ($w in $wins) {
    [void][DshChatWin.Api]::SendMessage($w.Handle, $WM_CLOSE, [System.IntPtr]::Zero, [System.IntPtr]::Zero)
  }
  if ($wins.Count -gt 0) { Start-Sleep -Milliseconds 700 }
  foreach ($procId in @(Get-ChatPids)) {
    try { Stop-Process -Id $procId -Force -ErrorAction Stop } catch { }
  }
}

function Raise-Window($handle) {
  # Bring a window to the top WITHOUT activating it, so focus stays where the
  # user left it. Geometry is untouched (SWP_NOMOVE | SWP_NOSIZE).
  if ($handle -eq [System.IntPtr]::Zero) { return }
  $flags = 0x0001 -bor 0x0002 -bor $SWP_NOACTIVATE     # NOSIZE | NOMOVE | NOACTIVATE
  [void][DshChatWin.Api]::SetWindowPos($handle, $HWND_TOP, 0, 0, 0, 0, $flags)
}

function Sink-Window($handle) {
  # Push a window to the bottom of the Z order without activating it. Used to
  # tuck the chat pane behind the still-full-width DSH window while it paints
  # its first frame, so the loading page is never visible.
  if ($handle -eq [System.IntPtr]::Zero) { return }
  $HWND_BOTTOM = [System.IntPtr]1
  $flags = 0x0001 -bor 0x0002 -bor $SWP_NOACTIVATE     # NOSIZE | NOMOVE | NOACTIVATE
  [void][DshChatWin.Api]::SetWindowPos($handle, $HWND_BOTTOM, 0, 0, 0, 0, $flags)
}

function Set-TaskbarGroup($dshH, $chatH) {
  # Give both panes the same AppUserModelID so Windows shows ONE taskbar button
  # for them ("2 个运行窗口" on hover) instead of one per window.
  #
  # Both windows must be written: neither carries a per-window id on its own, so
  # there is nothing to match against until both are given the same value.
  # Writing the DSH window changes only that window -- its taskbar identity is
  # already separate from the pinned browser button.
  #
  # Returns the number of windows that accepted the write, for the log.
  if (-not $TaskbarGroupId) { return 0 }
  $n = 0
  foreach ($h in @($dshH, $chatH)) {
    if ($h -eq [System.IntPtr]::Zero) { continue }
    if (-not [DshChatWin.Api]::IsWindow($h)) { continue }
    if ([DshChatWin.Api]::SetTaskbarGroupId($h, $TaskbarGroupId)) { $n++ }
  }
  return $n
}

function Wait-ChatReady($handle, $settleMs) {
  # There is no "the page has painted" signal available from outside the
  # browser, so this waits for the window to exist and then gives the compositor
  # a short settle. The point is ordering: DSH must not start shrinking before
  # the chat pane has something to show, otherwise the right third of the screen
  # flashes empty for the length of the animation.
  if ($handle -eq [System.IntPtr]::Zero) { return }
  $deadline = (Get-Date).AddMilliseconds(4000)
  while ((Get-Date) -lt $deadline) {
    if ([DshChatWin.Api]::IsWindow($handle)) { break }
    Start-Sleep -Milliseconds 50
  }
  if ($settleMs -gt 0) { Start-Sleep -Milliseconds $settleMs }
}

if ($Mode -eq 'restore') {
  if (Maximize-Dsh) { Write-Host 'restored' } else { Write-Host 'warn: DSH window not found' }
  exit 0
}

# ------------------------------------------------------------------ open ---
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea

if (-not $EdgePath -or -not (Test-Path -LiteralPath $EdgePath)) {
  Write-Host "error: no Chromium browser found."
  Write-Host "       Looked for Edge and Chrome in their standard install locations."
  Write-Host "       Pass -EdgePath <path to msedge.exe or chrome.exe> to override."
  exit 1
}

# Visible split point, measured from the left of the work area.
$splitVisible = $wa.X + [int][Math]::Round($wa.Width * $DshShare)
$screenRight  = $wa.X + $wa.Width
$screenBottom = $wa.Y + $wa.Height

# DSH geometry. Its own four frame insets are measured, and each visible edge
# gets exactly its own side's allowance -- that is what makes the pane reach the
# left, top and bottom edges of the work area and stop precisely at the split.
#
# The insets depend on the window's STATE, so this is measured once now and
# again after Restore-ForMove below. A maximised window reports a different top
# inset than a restored one: measured 7/7/8/8 while maximised versus the real
# 7/0/8/7, and that 7 px error pushed the top of the DSH pane off-screen
# (observed: client top at y=-7, the top 7 px of the page clipped).
$dsh = Get-DshWindow

# Rects for a given inset set, so they can be recomputed when the state changes.
function Get-DshRects($ins) {
  $top = $wa.Y - $ins[1]
  $h   = ($screenBottom + $ins[3]) - $top
  $x   = $wa.X - $ins[0]
  $w   = ($splitVisible + $ins[2]) - $x
  $fullW = ($screenRight + $ins[2]) - $x
  return @{
    Split = @($x, $top, $w, $h)
    Full  = @($x, $top, $fullW, $h)
  }
}

# Call this AFTER a window has changed state (un-maximised). Re-measures the
# insets and rewrites the top-level $dshRect / $dshFullRect if they moved.
function Update-DshGeometry($handle) {
  if ($handle -eq [System.IntPtr]::Zero) { return }
  $now = Get-FrameInsets $handle
  if (($now -join '/') -eq ($script:insDsh -join '/')) { return }
  Write-Host ("dsh insets corrected after restore: " + ($script:insDsh -join '/') + " -> " + ($now -join '/'))
  $script:insDsh = $now
  $r = Get-DshRects $now
  $script:dshRect     = $r.Split
  $script:dshFullRect = $r.Full
}

$insDsh = if ($dsh) { Get-FrameInsets $dsh.Handle } else { @(0, 0, 0, 0) }
$dshRects = Get-DshRects $insDsh
$dshRect     = $dshRects.Split
$dshFullRect = $dshRects.Full
$dshTop = $dshRect[1]
$dshX   = $dshRect[0]
$dshW   = $dshRect[2]
$dshH   = $dshRect[3]
$dshFullX = $dshFullRect[0]
$dshFullW = $dshFullRect[2]

# The chat pane is parked fully off the right edge, with a margin so not even its
# shadow is on screen. Its real geometry cannot be computed yet -- see below.
$chatParkX = $screenRight + 20
$chatWGuess = $screenRight - $splitVisible
$chatHGuess = $wa.Height

Write-Host ("workarea={0}x{1} dshInsets={2} dsh={3}@{4},{5} split={6}" -f $wa.Width, $wa.Height, ($insDsh -join '/'), $dshW, $dshX, $dshTop, $splitVisible)

# ----------------------------------------------------------- close (X) ---
# Triggered by the sidebar button when the chat pane is already open. The order
# is the whole point, and matches the hint the button gives the user:
#
#   1. widen DSH over the entire work area  -- it now covers the chat pane
#   2. raise DSH, so it really is on top
#   3. park the chat pane off-screen        -- still invisible behind DSH
#   4. only now close the chat window
#
# Because steps 3 and 4 happen while the chat pane is covered, the user sees
# only a smooth DSH widen and then the chat simply gone. Closing first would
# expose a bare strip of desktop for the duration of the animation.
if ($Mode -eq 'close') {
  $dshHandle = if ($dsh) { $dsh.Handle } else { [System.IntPtr]::Zero }
  if ($dshHandle -ne [System.IntPtr]::Zero) {
    # SetWindowPos is a no-op on a maximised window, and the insets it reports
    # differ, so normalise the state and re-derive the rects first.
    Restore-ForMove $dshHandle $dshFullX $dshTop $dshFullW $dshH
    Update-DshGeometry $dshHandle
    $from = Get-WinGeom $dshHandle
    if (-not $from) { $from = $dshRect }
    Move-PanesSmooth $dshHandle $from $dshFullRect ([System.IntPtr]::Zero) $null $null
    Raise-Window $dshHandle
    Write-Host 'close: DSH widened to full screen'
  } else {
    Write-Host 'warn: DSH window not found'
  }

  Start-Sleep -Milliseconds 120
  $chat = Get-ChatWindow
  if ($chat) {
    $insChat = Get-FrameInsets $chat.Handle
    $chatTop = $wa.Y - $insChat[1]
    $chatH   = ($screenBottom + $insChat[3]) - $chatTop
    # Park it beyond the right edge first, so the close itself is unobservable.
    [void][DshChatWin.Api]::SetWindowPos($chat.Handle, [System.IntPtr]::Zero,
            $chatParkX, $chatTop, ($screenRight - $splitVisible), $chatH, (0x0004 -bor 0x0010))
    Start-Sleep -Milliseconds 90
    Close-Chat
    Write-Host 'close: chat window closed off-screen'
  } else {
    Write-Host 'close: no chat window to close'
  }

  Set-State 'closed'
  exit 0
}

# 1) Get a chat WINDOW first. A non-zero process count with no window still
#    needs a launch: Edge reuses its background instance and opens the app one.
#    It is launched straight into the parking spot, off-screen, with
#    --window-position -- verified to be honoured -- so it is never painted
#    anywhere the user can see.
if (Get-ChatWindow) {
  Write-Host 'chat window already open'
} else {
  Write-Host 'no chat window; launching off-screen'
  Start-Chat $chatParkX $wa.Y $chatWGuess $chatHGuess
}

# 2) Put the chat pane in place and let it be ready BEFORE DSH gives up space.
#    Revealing in this order means the right third is never empty: the chat pane
#    is already showing when DSH starts to narrow. It is raised above DSH first
#    so it is visible while it settles, rather than being clipped by the
#    full-width DSH window sitting on top of it.
$placed = $false
$chat = $null
$chatHandle = [System.IntPtr]::Zero
$chatRect = $null
$chatParkRect = $null
$deadline = (Get-Date).AddSeconds($AppearTimeoutSec)
while ((Get-Date) -lt $deadline) {
  $chat = Get-ChatWindow
  if ($chat) { break }
  Start-Sleep -Milliseconds 250
  if (-not (Get-ChatWindow)) { Start-Chat $chatParkX $wa.Y $chatWGuess $chatHGuess }
}

if ($chat) {
  $chatHandle = $chat.Handle
  # Now that the window exists, measure ITS frame insets. They are not the same
  # as DSH's -- on this machine the DSH window measured 7/0/8/7 while an Edge
  # --app= window launched with --window-position measured 0/0/0/0 -- so the
  # chat pane computes its own geometry instead of borrowing DSH's compensation.
  $insChat = Get-FrameInsets $chatHandle
  $chatTop = $wa.Y - $insChat[1]
  $chatH   = ($screenBottom + $insChat[3]) - $chatTop
  $chatX   = $splitVisible - $insChat[0]
  $chatW   = ($screenRight + $insChat[2]) - $chatX
  $chatRect     = @($chatX, $chatTop, $chatW, $chatH)
  $chatParkRect = @($chatParkX, $chatTop, $chatW, $chatH)
  Write-Host ("chat insets={0} w={1} @x{2},y{3}" -f ($insChat -join '/'), $chatW, $chatX, $chatTop)

  # Move it into the right pane while DSH still covers the whole screen, keeping
  # it behind DSH. It is therefore never visible until DSH narrows: not at its
  # startup position, and not while it paints its first frame.
  [void][DshChatWin.Api]::SetWindowPos($chatHandle, [System.IntPtr]::Zero,
          $chatX, $chatTop, $chatW, $chatH, (0x0004 -bor 0x0010))
  Sink-Window $chatHandle
  Wait-ChatReady $chatHandle 900
  $placed = $true
} else {
  Write-Host 'warn: chat window never appeared'
}

# 3) Narrow DSH into the left pane, revealing the chat pane where it already is.
if ($dsh) {
  Restore-ForMove $dsh.Handle $dshFullX $dshTop $dshFullW $dshH
  # The restore above can change the frame insets (a maximised window measures
  # differently), so re-derive the target rects before animating into them.
  Update-DshGeometry $dsh.Handle
  $dshFrom = Get-WinGeom $dsh.Handle
  if (-not $dshFrom) { $dshFrom = $dshFullRect }
  Move-PanesSmooth $dsh.Handle $dshFrom $dshRect ([System.IntPtr]::Zero) $null $null
  Write-Host 'dsh narrowed to the left pane'
} else {
  Write-Host 'warn: DSH window not found'
}
Set-State 'open'

# 4) Watch the chat WINDOW and restore DSH once it closes. Background processes
#    do not count as open -- only a window does.
#
#    Deliberately passive. An earlier version also watched for either window
#    being maximised and re-applied the split, on the theory that a drag-to-top
#    should behave as a split gesture. That was a misreading of the request: the
#    user wanted the resulting side-by-side look, not a custom gesture, and the
#    extra logic hijacked their own window management. Windows Snap, Win+Arrow
#    and edge/top drags must all stay under the user's control, so this loop
#    touches nothing except the one event it owns -- the chat window closing.
$dshHandle  = if ($dsh) { $dsh.Handle } else { [System.IntPtr]::Zero }

# Fold the two windows onto a single taskbar button. Done here, after both
# windows exist and have their final geometry, because the write needs live
# handles. `$groupedChat` remembers which chat handle is already grouped so the
# watch loop can re-apply when the chat window is recreated (a new Edge window
# comes up with Edge's own id and would otherwise get its own button again).
$groupedChat = [System.IntPtr]::Zero
$n = Set-TaskbarGroup $dshHandle $chatHandle
if ($n -gt 0) {
  $groupedChat = $chatHandle
  Write-Host ("taskbar: grouped {0} window(s) under '{1}'" -f $n, $TaskbarGroupId)
} elseif ($TaskbarGroupId) {
  Write-Host 'warn: taskbar grouping failed'
}

# Ctrl+Alt+D toggles the chat pane. Registered on this thread's queue (hWnd = 0)
# and pumped below with PeekMessage, so no extra process is needed.
$hotkeyOk = $false
try {
  $hotkeyOk = [DshChatWin.Api]::RegisterHotKey([System.IntPtr]::Zero, $HOTKEY_ID, $MOD_CTRL_ALT, $VK_D)
} catch { }
if ($hotkeyOk) { Write-Host 'hotkey ready: Ctrl+Alt+D toggles the chat pane' }
else { Write-Host 'warn: could not register Ctrl+Alt+D (already in use?)' }

$hidden = $false
$waited = 0
$seenChat = $placed
while ($waited -lt $WatchSeconds) {
  Start-Sleep -Milliseconds 150
  $waited += 0.15

  # --- toggle hotkey -------------------------------------------------------
  if ($hotkeyOk) {
    $msg = New-Object DshChatWin.Api+MSG
    while ([DshChatWin.Api]::PeekMessage([ref]$msg, [System.IntPtr]::Zero, 0, 0, $PM_REMOVE)) {
      if ($msg.message -ne $WM_HOTKEY) { continue }
      if ([int]$msg.wParam -ne $HOTKEY_ID) { continue }

      # Re-derive the chat pane's geometry on EVERY toggle. The frame insets are
      # per-window AND depend on the window's state, so a rect measured at open
      # time can be several pixels out by the time the user toggles -- observed
      # as a 7 px gap in the middle after the DSH window had been maximised and
      # restored in between. Measuring here is two cheap Win32 calls.
      $c = Get-ChatWindow
      if ($c) {
        $chatHandle = $c.Handle
        $insChat = Get-FrameInsets $chatHandle
        $chatTop = $wa.Y - $insChat[1]
        $chatH   = ($screenBottom + $insChat[3]) - $chatTop
        $chatX   = $splitVisible - $insChat[0]
        $chatW   = ($screenRight + $insChat[2]) - $chatX
        $chatRect     = @($chatX, $chatTop, $chatW, $chatH)
        $chatParkRect = @($chatParkX, $chatTop, $chatW, $chatH)
      }

      if (-not $hidden) {
        # HIDE. Order matters. Widen DSH over the whole work area FIRST, raise it
        # so it covers the chat pane, and only then park the chat pane
        # off-screen. The chat therefore travels while it is already hidden
        # behind DSH, and the user never sees it slide away.
        $dFrom = Get-WinGeom $dshHandle
        if (-not $dFrom) { $dFrom = $dshRect }
        Move-PanesSmooth $dshHandle $dFrom $dshFullRect ([System.IntPtr]::Zero) $null $null
        Raise-Window $dshHandle
        Start-Sleep -Milliseconds 90
        if ($chatHandle -ne [System.IntPtr]::Zero -and $chatParkRect -and [DshChatWin.Api]::IsWindow($chatHandle)) {
          [void][DshChatWin.Api]::SetWindowPos($chatHandle, [System.IntPtr]::Zero,
                  $chatParkRect[0], $chatParkRect[1], $chatParkRect[2], $chatParkRect[3], (0x0004 -bor 0x0010))
        }
        $hidden = $true
        Write-Host 'toggled: hidden (DSH full screen, chat parked behind it)'
      } else {
        # SHOW. Reverse order. Put the chat pane back and tuck it behind DSH,
        # let it settle, and only then narrow DSH -- so the right third always
        # has something in it. Narrowing DSH first left it visibly empty while
        # the chat was still coming up.
        if ($chatHandle -ne [System.IntPtr]::Zero -and $chatRect -and [DshChatWin.Api]::IsWindow($chatHandle)) {
          [void][DshChatWin.Api]::SetWindowPos($chatHandle, [System.IntPtr]::Zero,
                  $chatRect[0], $chatRect[1], $chatRect[2], $chatRect[3], (0x0004 -bor 0x0010))
          # Behind DSH, not above it: DSH is still full-width, so the chat pane
          # is uncovered by geometry rather than by stacking, and nothing of the
          # chat ever paints over DSH while it settles.
          Sink-Window $chatHandle
          Wait-ChatReady $chatHandle 450
        }
        # The user may have maximised DSH while the pane was hidden, which makes
        # SetWindowPos a no-op and changes the insets -- normalise before moving.
        Restore-ForMove $dshHandle $dshFullX $dshTop $dshFullW $dshH
        Update-DshGeometry $dshHandle
        $dFrom = Get-WinGeom $dshHandle
        if (-not $dFrom) { $dFrom = $dshFullRect }
        Move-PanesSmooth $dshHandle $dFrom $dshRect ([System.IntPtr]::Zero) $null $null
        $hidden = $false
        Write-Host 'toggled: shown (split restored)'
      }
    }
  }

  # --- chat closed? --------------------------------------------------------
  #
  # Trust the window handle we already hold before re-enumerating. Get-ChatPids
  # shells out to WMI, and one transient WMI hiccup makes it return empty --
  # which was read as "the chat window closed", maximising DSH and exiting
  # mid-session. A handle that IsWindow still accepts is proof the window
  # exists, and unlike an enumeration it cannot fail intermittently.
  $c = Get-ChatWindow
  if ($c) {
    $chatHandle = $c.Handle
    $seenChat = $true
    # A recreated chat window carries Edge's own AppUserModelID again and would
    # appear as a second taskbar button, so re-apply the shared id for it.
    if ($chatHandle -ne $groupedChat) {
      $n = Set-TaskbarGroup $dshHandle $chatHandle
      if ($n -gt 0) {
        $groupedChat = $chatHandle
        Write-Host ("taskbar: re-grouped {0} window(s) after the chat window changed" -f $n)
      }
    }
    continue
  }
  if ($chatHandle -ne [System.IntPtr]::Zero -and [DshChatWin.Api]::IsWindow($chatHandle)) {
    $seenChat = $true
    continue
  }

  # Never saw the window yet: keep waiting instead of concluding it closed.
  # Without this guard a slow first paint was read as "already closed", so the
  # script restored DSH and exited seconds after having opened nothing.
  if (-not $seenChat) { continue }

  # Require several consecutive misses before believing it: a WMI blip is not a
  # close. Also re-check the handle each round, since it is the reliable signal.
  $misses = 0
  for ($k = 0; $k -lt 4; $k++) {
    Start-Sleep -Milliseconds 900
    if (Get-ChatWindow) { break }
    if ($chatHandle -ne [System.IntPtr]::Zero -and [DshChatWin.Api]::IsWindow($chatHandle)) { break }
    $misses++
  }
  if ($misses -ge 4) {
    if ($hotkeyOk) { try { [void][DshChatWin.Api]::UnregisterHotKey([System.IntPtr]::Zero, $HOTKEY_ID) } catch { } }
    Set-State 'closed'
    # The chat pane is genuinely gone (its own X button, most likely). Do NOT
    # snap DSH to maximised -- that jolt is what closing the chat used to feel
    # like. Widen DSH with the same interpolation the toggle uses, so closing
    # the chat and pressing Ctrl+Alt+D read identically.
    if ($dshHandle -ne [System.IntPtr]::Zero -and [DshChatWin.Api]::IsWindow($dshHandle)) {
      $dFrom = Get-WinGeom $dshHandle
      if (-not $dFrom) { $dFrom = $dshRect }
      Move-PanesSmooth $dshHandle $dFrom $dshFullRect ([System.IntPtr]::Zero) $null $null
      Raise-Window $dshHandle
      Write-Host 'chat closed; DSH widened to full screen'
    } elseif (Maximize-Dsh) {
      Write-Host 'chat closed; DSH maximised'
    } else {
      Write-Host 'chat closed; DSH window not found'
    }
    exit 0
  }
}
if ($hotkeyOk) { try { [void][DshChatWin.Api]::UnregisterHotKey([System.IntPtr]::Zero, $HOTKEY_ID) } catch { } }
Write-Host 'watch timed out'
