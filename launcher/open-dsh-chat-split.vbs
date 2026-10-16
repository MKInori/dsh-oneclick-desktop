' ============================================================
'  dshsplit: protocol handler
'
'  Registered under HKCU as the "dshsplit" URL protocol, so any
'  browser link to  dshsplit:open  triggers this script instead of
'  navigating. That gives DSH (or any app) a one-click way to ask
'  the desktop to arrange the DSH + chat windows.
'
'  Writes nothing to DSH. Pure ASCII (wscript reads .vbs as ANSI).
'
'  The window manager it launches lives in the plugin. The path is resolved
'  relative to this script only -- first the kit layout, then a copy sitting
'  beside it -- so nothing here depends on where anyone installed anything.
' ============================================================
Option Explicit

Dim sh, fso, HERE, KIT, SCRIPT, FALLBACK
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

HERE     = fso.GetParentFolderName(WScript.ScriptFullName)
KIT      = fso.GetParentFolderName(HERE)
SCRIPT   = fso.BuildPath(KIT, "plugin\lib\window.ps1")

' Two layouts reach this script, and neither needs a hard-coded path:
'   * straight out of the kit   -> <kit>\plugin\lib\window.ps1
'   * installed by desktop.ps1  -> <stable>\launcher\window.ps1, a copy
'     dropped next to this script so a package update cannot break it.
If Not fso.FileExists(SCRIPT) Then SCRIPT = fso.BuildPath(HERE, "window.ps1")

If Not fso.FileExists(SCRIPT) Then
  MsgBox "Window manager not found:" & vbCrLf & SCRIPT, 16, "DSH split"
  WScript.Quit 1
End If

sh.Run "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & SCRIPT & """ -Mode open", 0, False

