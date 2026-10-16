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
'  The window manager it launches lives in the plugin, which DSH itself loads
'  from its own plugin directory -- so the path is resolved relative to the
'  kit (launchers\..\plugin\...), with the installed location as a fallback.
' ============================================================
Option Explicit

Dim sh, fso, HERE, KIT, SCRIPT, FALLBACK
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

HERE     = fso.GetParentFolderName(WScript.ScriptFullName)   ' ...\dsh-desktop-kit\launchers
KIT      = fso.GetParentFolderName(HERE)                     ' ...\dsh-desktop-kit
SCRIPT   = fso.BuildPath(KIT, "plugin\lib\window.ps1")
FALLBACK = "C:\Users\Aesier\.dsh\plugins\dsh-chat-panel\lib\window.ps1"

If Not fso.FileExists(SCRIPT) Then SCRIPT = FALLBACK

If Not fso.FileExists(SCRIPT) Then
  MsgBox "Window manager not found:" & vbCrLf & SCRIPT, 16, "DSH split"
  WScript.Quit 1
End If

sh.Run "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & SCRIPT & """ -Mode open", 0, False

