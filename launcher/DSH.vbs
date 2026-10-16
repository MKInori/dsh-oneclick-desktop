' ============================================================
'  DSH one-click launcher
'
'  Starts the tray controller with NO console window:
'    - the controller starts the DSH server if it is not up
'    - it opens the chrome-less fullscreen app window
'    - it keeps a tray icon with Open / Restart / Settings / Exit
'
'  Paths are derived from this script's own location, so the whole
'  dsh-oneclick-desktop folder can be moved or copied without editing anything.
'
'  Only ASCII text: wscript reads .vbs as ANSI, so non-ASCII
'  here would come out as mojibake.
' ============================================================
Option Explicit

Dim POWERSHELL, sh, fso, HERE, PS1
POWERSHELL = "powershell.exe"

Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

' Absolute folder this .vbs lives in, then the controller beside it.
HERE = fso.GetParentFolderName(WScript.ScriptFullName)
PS1  = fso.BuildPath(HERE, "DSH-Tray.ps1")

If Not fso.FileExists(PS1) Then
  MsgBox "Controller script not found:" & vbCrLf & PS1, 16, "DSH"
  WScript.Quit 1
End If

' --diagnose records where this resolved to, which is the fastest way to find
' out that a moved or copied folder is pointing at the wrong place.
If WScript.Arguments.Named.Exists("diagnose") Then
  On Error Resume Next
  Dim f, lg
  lg = fso.BuildPath(HERE, "launcher.log")
  Set f = fso.OpenTextFile(lg, 8, True)
  f.WriteLine Now & "  HERE=" & HERE
  f.WriteLine Now & "  PS1=" & PS1
  f.Close
  On Error Goto 0
End If

' 0 = hidden window, False = do not wait for it to finish
sh.Run """" & POWERSHELL & """ -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & PS1 & """", 0, False

