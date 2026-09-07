; Setup-ProgramsOnVirtualDesktops.ahk
; Switches to a virtual desktop, launches one program there, and waits for its
; window to actually appear before exiting. The caller blocks on this script, so
; panels are never launched into a desktop that is still mid-switch.
;
; Usage:  AutoHotkeyU64.exe Setup-ProgramsOnVirtualDesktops.ahk <desktop> "<program>" "<args>" "<fskeys>"
; Passing an EMPTY <program> means "repair only": do not launch anything, just
; make an EXISTING window full screen. In that mode <args> is the target window's
; HWND. The watchdog uses this to fix a panel that came up windowed, without
; disturbing what it is showing. The handle is passed explicitly rather than
; guessed from the desktop, because the rotation can switch desktops mid-repair
; and "largest window here" then measures the wrong window and reports success.
; <fskeys> are optional AHK keystrokes that put the new window full screen -
; MyRadar is a plain WinUI window and only goes full screen when sent {F11}.
; These keys are almost always a TOGGLE, so the window is measured first and the
; keys are only sent while it is not already full screen.
; Exit:   0 = ok, 1 = DLL load failed, 2 = Run failed, 3 = no window appeared,
;         4 = window is up but would not go full screen

#NoEnv
#SingleInstance Off      ; several of these run back to back - they must not kill each other
SetBatchLines, -1

DllPath      := "C:\Scripts\VirtualDesktopAccessor.dll"   ; virtual desktop switching DLL
timeoutMs    := 75000                                      ; how long to wait for the window (ms)
switchSettle := 1000                                       ; pause after switching desktops (ms)
windowSettle := 1500                                       ; pause after the window appears (ms)
fsSettle     := 4000                                       ; let the app settle before touching it (ms)
fsVerify     := 2500                                       ; wait before re-checking full screen (ms)
fsAttempts   := 5                                          ; how many times to try the fullscreen key

if !DllCall("LoadLibrary", "Str", DllPath)
    ExitApp, 1

desktopIndex := A_Args[1]
program      := A_Args[2]
args         := A_Args[3]
fsKeys       := A_Args[4]

; Switch first, so whatever we launch is born on the right desktop.
DllCall("VirtualDesktopAccessor\GoToDesktopNumber", "UInt", desktopIndex - 1)
Sleep, %switchSettle%

if (program = "")
{
    ; Repair-only mode: <args> carries the HWND to operate on.
    newWin := args + 0
    if (!newWin || !WinExist("ahk_id " . newWin))
        ExitApp, 3
}
else
{
    before := SnapshotWindows()

    cmd := """" . program . """"
    if (args != "")
        cmd .= " " . args
    Run, % cmd, , UseErrorLevel
    if (ErrorLevel = "ERROR")
        ExitApp, 2

    ; Firefox delegates '-new-window' to the already-running instance and the
    ; process we spawned exits immediately, so waiting on our own PID would never
    ; match. Watch for any new top-level window instead.
    newWin := WaitForNewWindow(before, timeoutMs)
    if (!newWin)
        ExitApp, 3

    Sleep, %windowSettle%
}

if (fsKeys != "")
{
    ; The window exists but may not be ready for input yet, so focus it and
    ; give it a moment before sending anything.
    WinActivate, ahk_id %newWin%
    WinWaitActive, ahk_id %newWin%, , 10
    if (ErrorLevel)
        ExitApp, 4

    ; Two things make this fiddly. The key is a TOGGLE, so sending it blindly can
    ; switch an already-fullscreen window back out of it. And MyRadar re-applies
    ; its remembered maximised state a few seconds after the window first
    ; appears, which silently undid an earlier keypress. So: let it settle, then
    ; only send while it is not full screen, and confirm the change sticks.
    Sleep, %fsSettle%

    Loop, %fsAttempts%
    {
        if (IsFullScreen(newWin))
        {
            Sleep, %fsVerify%
            if (IsFullScreen(newWin))    ; still full screen, so it held
                break
        }
        WinActivate, ahk_id %newWin%
        Sleep, 500
        Send, % fsKeys
        Sleep, %fsVerify%
    }
    if (!IsFullScreen(newWin))
        ExitApp, 4
}

ExitApp, 0


; True only for a genuinely full-screen window. A *maximised* window is
; deliberately excluded: it sits a few pixels off-screen (e.g. -13,-13) and still
; shows its title bar, which is not what we want on a wall display.
IsFullScreen(hwnd) {
    WinGetPos, x, y, w, h, ahk_id %hwnd%
    return (Abs(x) <= 2 && Abs(y) <= 2 && w >= A_ScreenWidth - 2 && h >= A_ScreenHeight - 2)
}


; Build a "|id|id|...|" string of the currently visible top-level windows.
SnapshotWindows() {
    list := "|"
    WinGet, ids, List
    Loop, %ids%
    {
        id := ids%A_Index%
        list .= id . "|"
    }
    return list
}

; Poll until a substantial new titled window appears, and return the largest one.
; Taking simply the *first* new window is wrong: MyRadar also spawns a 40x40
; "PopupHost" helper window, and sending the fullscreen key to that did nothing
; while the real window stayed maximised.
WaitForNewWindow(before, timeoutMs) {
    start   := A_TickCount
    minArea := (A_ScreenWidth * A_ScreenHeight) // 16    ; ignore anything tiny
    Loop
    {
        best     := 0
        bestArea := 0
        WinGet, ids, List
        Loop, %ids%
        {
            id := ids%A_Index%
            if InStr(before, "|" . id . "|")
                continue
            WinGetTitle, title, ahk_id %id%
            if (title = "")
                continue
            WinGetPos, , , w, h, ahk_id %id%
            area := w * h
            if (area > bestArea)
            {
                bestArea := area
                best     := id
            }
        }
        if (best && bestArea >= minArea)
            return best
        if (A_TickCount - start > timeoutMs)
            return best        ; nothing big enough; hand back whatever we saw
        Sleep, 250
    }
}
