# desktop.ps1 -- install or remove the Windows desktop integration.
#
# What "desktop integration" means here:
#   1. the launcher scripts are copied out of the plugin package into a stable
#      folder under the DSH home, so a plugin update (which replaces the package
#      directory) cannot break a shortcut that points at them
#   2. a desktop shortcut is written that starts DSH (tray controller, hidden)
#   3. the dshsplit: URL protocol is registered so a link can ask for the split
#
# The launcher itself is what makes DSH feel like an app: double-click the icon
# and the server starts, the chrome-less window opens, and a tray icon appears
# with Open / Restart / Status / Exit.
#
#   -Mode install   copy assets, write the shortcut, register the protocol
#   -Mode remove    undo all three
#   -Mode status    report what is currently in place
#
# Pure ASCII source: Windows PowerShell 5.1 reads a BOM-less .ps1 with the
# system ANSI code page, so literal non-ASCII here would break parsing.
param(
  [ValidateSet('install', 'remove', 'status')]
  [string]$Mode = 'status',

  # Plugin package root (the folder containing launcher/). Defaults to the
  # parent of this script's folder.
  [string]$PackageRoot = ''
)

$ErrorActionPreference = 'Continue'

if ($env:OS -ne 'Windows_NT') {
  Write-Host "error: desktop integration is Windows-only (detected '$env:OS')."
  exit 1
}

if (-not $PackageRoot) { $PackageRoot = Split-Path $PSScriptRoot -Parent }
$src = Join-Path $PackageRoot 'launcher'
$dshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
$dest = Join-Path $dshHome 'dsh-oneclick-desktop\launcher'
$lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'DSH.lnk'
$protoKey = 'HKCU:\Software\Classes\dshsplit'

function Write-Shortcut {
  $ws = New-Object -ComObject WScript.Shell
  $l = $ws.CreateShortcut($lnk)
  $l.TargetPath       = Join-Path $env:SystemRoot 'System32\wscript.exe'
  $l.Arguments        = '"' + (Join-Path $dest 'DSH.vbs') + '"'
  $l.WorkingDirectory = $dest
  $l.IconLocation     = (Join-Path $dest 'dsh.ico') + ',0'
  $l.Description      = 'DSH - one-click launcher'
  $l.Save()
}

function Write-Protocol {
  $cmd = '"' + (Join-Path $env:SystemRoot 'System32\wscript.exe') + '" "' + (Join-Path $dest 'open-dsh-chat-split.vbs') + '" "%1"'
  foreach ($k in @($protoKey, "$protoKey\shell", "$protoKey\shell\open", "$protoKey\shell\open\command")) {
    if (-not (Test-Path $k)) { [void](New-Item -Path $k -Force) }
  }
  Set-ItemProperty -Path $protoKey -Name '(default)' -Value 'URL:DSH Split Protocol'
  Set-ItemProperty -Path $protoKey -Name 'URL Protocol' -Value ''
  Set-ItemProperty -Path "$protoKey\shell\open\command" -Name '(default)' -Value $cmd
}

function Get-Status {
  $s = [ordered]@{
    assets    = (Test-Path (Join-Path $dest 'DSH.vbs'))
    shortcut  = (Test-Path $lnk)
    protocol  = (Test-Path "$protoKey\shell\open\command")
  }
  return $s
}

switch ($Mode) {

  'install' {
    if (-not (Test-Path $src)) { Write-Host ("error: launcher assets missing at " + $src); exit 1 }
    if (-not (Test-Path $dest)) { [void](New-Item -ItemType Directory -Path $dest -Force) }
    # window.ps1 rides along so open-dsh-chat-split.vbs finds the window
    # manager next to itself; an installed launcher then survives a plugin
    # update, which replaces the whole package folder.
    foreach ($f in @('DSH.vbs', 'DSH-Tray.ps1', 'open-dsh-chat-split.vbs', 'dsh.ico', 'window.ps1')) {
      $from = Join-Path $src $f
      if ($f -eq 'window.ps1') { $from = Join-Path (Split-Path $src -Parent) 'lib\window.ps1' }
      if (Test-Path $from) { Copy-Item -LiteralPath $from -Destination (Join-Path $dest $f) -Force }
    }
    Write-Host ("assets:   " + $dest)
    Write-Shortcut
    Write-Host ("shortcut: " + $lnk)
    Write-Protocol
    Write-Host "protocol: dshsplit:"
  }

  'remove' {
    if (Test-Path $lnk) { Remove-Item -LiteralPath $lnk -Force; Write-Host ("removed " + $lnk) }
    if (Test-Path $protoKey) { Remove-Item -Path $protoKey -Recurse -Force; Write-Host "removed dshsplit: registration" }
    if (Test-Path (Join-Path $dshHome 'dsh-oneclick-desktop')) {
      Remove-Item -LiteralPath (Join-Path $dshHome 'dsh-oneclick-desktop') -Recurse -Force
      Write-Host ("removed " + (Join-Path $dshHome 'dsh-oneclick-desktop'))
    }
  }

  'status' {
    $s = Get-Status
    Write-Host ("assets    : " + $s.assets + "   " + $dest)
    Write-Host ("shortcut  : " + $s.shortcut + "   " + $lnk)
    Write-Host ("protocol  : " + $s.protocol + "   dshsplit:")
  }
}
