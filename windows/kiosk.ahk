; Keeps Stremio running fullscreen and maps Fire TV remote buttons to Stremio keys.
#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

StremioDir := EnvGet("LOCALAPPDATA") "\Programs\Stremio"
StremioExe := StremioDir "\stremio-shell-ng.exe"
StremioWindow := "Stremio ahk_class NativeWindowsGuiWindow ahk_exe stremio-shell-ng.exe"
EnforceFullscreen := true
LastLaunch := 0
LastFullscreen := 0

Launch() {
    global LastLaunch
    if ProcessExist("stremio-shell-ng.exe") || A_TickCount - LastLaunch < 3000
        return
    LastLaunch := A_TickCount
    try Run '"' StremioExe '"', StremioDir
}

KeepFullscreen() {
    global LastFullscreen
    if !EnforceFullscreen || !WinExist(StremioWindow) || A_TickCount - LastFullscreen < 3000
        return
    if WinGetStyle(StremioWindow) & 0xC00000 {
        LastFullscreen := A_TickCount
        WinActivate StremioWindow
        if WinWaitActive(StremioWindow, , 2)
            Send "{F11}"
    }
}

; Closing the window (Alt+F4) hides Stremio to the tray instead of exiting.
ShowHidden() {
    if !ProcessExist("stremio-shell-ng.exe") || WinExist(StremioWindow)
        return
    DetectHiddenWindows true
    if hwnd := WinExist(StremioWindow) {
        WinShow hwnd
        WinActivate hwnd
    }
}

Watchdog() {
    Launch()
    ShowHidden()
    KeepFullscreen()
}

RestartStremio() {
    global LastLaunch := A_TickCount
    ProcessClose "stremio-shell-ng.exe"
    ProcessClose "stremio-runtime.exe"
}

; Rewind, fast forward, play and pause arrive as unhandled WM_APPCOMMANDs on Windows.
OnShellMessage(wParam, lParam, *) {
    static commands := Map(46, "{Space}", 47, "{Space}", 49, "{Right}", 50, "{Left}")
    if wParam != 12 || !WinActive(StremioWindow)
        return
    command := (lParam >> 16) & 0x0FFF
    if commands.Has(command)
        Send commands[command]
}

DllCall("RegisterShellHookWindow", "Ptr", A_ScriptHwnd)
OnMessage(DllCall("RegisterWindowMessage", "Str", "SHELLHOOK", "UInt"), OnShellMessage)
Watchdog()
SetTimer Watchdog, 1000

; Home: tap for Escape, hold ~1.5s to restart Stremio.
HomeDown := 0
Browser_Home:: {
    global HomeDown
    if HomeDown
        return
    HomeDown := A_TickCount
    SetTimer RestartStremio, -1500
}
Browser_Home up:: {
    global HomeDown
    SetTimer RestartStremio, 0
    if HomeDown && A_TickCount - HomeDown < 1500
        Send "{Esc}"
    HomeDown := 0
}
^!Backspace::RestartStremio()

#HotIf WinActive(StremioWindow)
Browser_Back::Esc
NumpadEnter::Enter
Media_Play_Pause::Space
AppsKey:: {
    global EnforceFullscreen := !EnforceFullscreen
    Send "{F11}"
}
#HotIf
