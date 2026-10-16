# taskbar-check -- verify the chat pane is folded into DSH's taskbar button.
#
# The taskbar cannot be inspected from the window manager, and asking a human to
# look at it does not scale, so this enumerates the taskbar through UI
# Automation: Windows groups buttons by AppUserModelID, so if DSH and the chat
# pane share an id there is exactly ONE un-pinned Edge button, labelled
# "2 个运行窗口" (2 running windows) instead of two buttons labelled
# "1 个运行窗口".
#
# Usage:
#   powershell -File tools\taskbar-check.ps1
#   powershell -File tools\taskbar-check.ps1 -Capture     # also save the icons
#
# Pure ASCII source: Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI, so
# literal non-ASCII here would break parsing.
param(
  [switch]$Capture,
  [string]$OutDir = "$env:TEMP\dsh-taskbar"
)

$ErrorActionPreference = 'Continue'

Add-Type -Namespace TC -Name U -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern System.IntPtr FindWindow(string cls, string win);
'@
# Without this, the coordinates UI Automation reports (physical px) would be
# virtualised when capturing, and the images would be offset.
[void][TC.U]::SetProcessDPIAware()

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
if ($Capture) { Add-Type -AssemblyName System.Drawing }

$tbH = [TC.U]::FindWindow('Shell_TrayWnd', $null)
if ($tbH -eq [System.IntPtr]::Zero) { Write-Host 'taskbar not found'; exit 1 }

$root = [System.Windows.Automation.AutomationElement]::FromHandle($tbH)
$cond = New-Object System.Windows.Automation.PropertyCondition(
  [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
  [System.Windows.Automation.ControlType]::Button)
$btns = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)

$edge = @()
foreach ($b in $btns) { if ($b.Current.Name -like '*Edge*') { $edge += $b } }

Write-Host ("Edge-related taskbar buttons: " + $edge.Count)
$i = 0
$merged = $false
foreach ($b in $edge) {
  $i++
  $r = $b.Current.BoundingRectangle
  $n = $b.Current.Name
  Write-Host ("  #" + $i + "  x=" + [int]$r.X + " w=" + [int]$r.Width + "  [" + $n + "]")
  if ($n -match '2 .+') { $merged = $true }
  if ($Capture) {
    $w = [int]$r.Width; $h = [int]$r.Height
    if ($w -gt 0 -and $h -gt 0) {
      if (-not (Test-Path $OutDir)) { [void](New-Item -ItemType Directory -Path $OutDir -Force) }
      $bmp = New-Object System.Drawing.Bitmap($w, $h)
      $g = [System.Drawing.Graphics]::FromImage($bmp)
      $g.CopyFromScreen([int]$r.X, [int]$r.Y, 0, 0, (New-Object System.Drawing.Size($w, $h)))
      $g.Dispose()
      $p = Join-Path $OutDir ("btn-" + $i + ".png")
      $bmp.Save($p, [System.Drawing.Imaging.ImageFormat]::Png)
      $bmp.Dispose()
      Write-Host ("       saved " + $p)
    }
  }
}

Write-Host ""
if ($merged) {
  Write-Host "OK: the two panes share one button (a '2 windows' label was found)."
} else {
  Write-Host "NOT MERGED: no button reports 2 windows -- the panes have separate buttons."
  Write-Host "Check the plugin log for a 'taskbar: grouped' line."
}
