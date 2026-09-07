; DesktopSwitchingFunctions.ahk
; Rotates the wall display through the panel desktops. This is the only
; long-lived process of the display board.
;
;   F2  pause/resume. Pausing parks the board on desktop 1 and shows the taskbar.
;   F3  pause and open the panel picker: choose a panel, then how long to hold it.
;
; A heartbeat file is refreshed on every tick so the watchdog can tell a frozen
; rotation apart from a healthy one. An active hold is written to hold.state so
; DailySystemReboot.ps1 can skip the nightly reboot while a panel is held.

#NoEnv
#SingleInstance, force
SetBatchLines, -1

; --- Configuration -----------------------------------------------------------
firstDesktop  := 2                                          ; first desktop in the rotation
lastDesktop   := 8                                          ; last desktop in the rotation
maxPanel      := 10                                         ; highest desktop the F3 picker offers
displayTime   := 120000                                     ; ms each desktop stays on screen
DllPath       := "C:\Scripts\VirtualDesktopAccessor.dll"    ; virtual desktop switching DLL
logDir        := "C:\Scripts\Logs"                          ; where state files live
heartbeatFile := "C:\Scripts\Logs\rotation.heartbeat"       ; touched on every rotation tick
holdFile      := "C:\Scripts\Logs\hold.state"               ; describes an active hold, if any
panelIndex    := "C:\Scripts\Logs\panels.index"             ; desktop|name, written by Panels.ps1
requestFile   := "C:\Scripts\Logs\hold.request"             ; remote command drop-box (the od helper writes it)
resultFile    := "C:\Scripts\Logs\hold.result"              ; outcome of the last remote command
statusFile    := "C:\Scripts\Logs\rotation.status"          ; paused/hold snapshot, for remote tools
switchSettle  := 2000                                       ; pause after switching desktops (ms)
pickerTimeout := 60000                                      ; auto-cancel the F3 menu after this (ms)
requestPoll   := 2000                                       ; ms between checks for a remote command

if !DllCall("LoadLibrary", "Str", DllPath)
{
    MsgBox, 16, Display Board, Failed to load VirtualDesktopAccessor.dll
    ExitApp, 1
}

FileCreateDir, %logDir%

; --- State -------------------------------------------------------------------
paused       := false     ; F2 pause (parked on desktop 1)
desktopIndex := firstDesktop
holdDesktop  := 0         ; 0 = no hold; otherwise the desktop being held
holdUntil    := ""        ; YYYYMMDDHH24MISS expiry, empty when holding forever
holdForever  := false
menuOpen     := false
rotBusy      := false     ; true while a rotation tick is switching desktops
resumeNow    := false     ; set by a remote command; the tick is kicked from global scope
wasPaused    := false
pickDesktop  := 0         ; panel chosen in step 1, awaiting a duration
hPicker      := 0
hDur         := 0

panelName := {}
LoadPanelIndex()

; Visit counters and per-desktop refresh keys. refreshEvery[n] = press
; refreshKeys[n] on every n-th visit. Panels whose URL already carries a refresh
; interval need no entry here.
visitCount   := {}
refreshEvery := {}
refreshKeys  := {}
Loop, %maxPanel%
    visitCount[A_Index] := 0
; Keyed by DESKTOP NUMBER, so these must move when panels are reordered in
; Panels.ps1. Only panels with no self-refresh need an entry - every Grafana
; panel carries &refresh=... in its URL and refreshes itself.
refreshEvery[6] := 8         ; desktop 6, Windy satellite, has no self-refresh
refreshKeys[6]  := "{F5}"

Hotkey, F2, TogglePause
Hotkey, F3, OpenPicker

SetTaskbarAutoHide(true)
RestoreHold()                ; a hold survives a restart of this script
Heartbeat()
GoSub, RotateDesktops        ; show the first panel immediately
SetTimer, RotateDesktops, %displayTime%
SetTimer, CheckRequest, %requestPoll%
return


; =============================================================================
;  Rotation
; =============================================================================
RotateDesktops:
if (menuOpen)
{
    Heartbeat()
    return
}

rotBusy := true              ; a remote command must not land mid-switch

; An expired hold falls through into normal rotation on this same tick.
if (holdDesktop > 0 && !holdForever && HoldSecondsRemaining() <= 0)
    EndHold("expired")

if (holdDesktop > 0)
{
    ; Re-assert the held desktop. A watchdog panel relaunch switches desktops,
    ; so this is what pulls the board back without the two needing to coordinate.
    if (CurrentDesktop() != holdDesktop)
        GoToDesktop(holdDesktop)
    ApplyRefresh(holdDesktop)   ; a held panel should still refresh if configured
    rotBusy := false
    Heartbeat()
    return
}

if (!paused)
{
    GoToDesktop(desktopIndex)
    ApplyRefresh(desktopIndex)
    desktopIndex := (desktopIndex >= lastDesktop) ? firstDesktop : desktopIndex + 1
}
rotBusy := false
Heartbeat()                  ; ticks even while paused or held, so neither reads as frozen
return


ApplyRefresh(d) {
    global visitCount, refreshEvery, refreshKeys
    visitCount[d] := visitCount[d] + 1
    if (refreshEvery.HasKey(d) && refreshEvery[d] > 0 && visitCount[d] >= refreshEvery[d])
    {
        visitCount[d] := 0
        Send, % refreshKeys[d]   ; expression syntax: sends the value, not the text
    }
}


; =============================================================================
;  F2 - pause on desktop 1 / resume
; =============================================================================
TogglePause:
if (menuOpen)
    return
if (holdDesktop > 0)
    EndHold("cancelled with F2")
paused := !paused
if (paused)
{
    GoToDesktop(1)
    SetTaskbarAutoHide(false)
    TrayTip, Desktop Rotation, Paused on desktop 1 - F2 resumes / F3 holds a panel, 1, 1
    LogLine("F2: paused on desktop 1")
}
else
{
    SetTaskbarAutoHide(true)
    TrayTip, Desktop Rotation, Rotation resumed., 1, 1
    LogLine("F2: rotation resumed")
    desktopIndex := firstDesktop
    GoSub, RotateDesktops
}
return


; =============================================================================
;  F3 - pick a panel, then a duration
; =============================================================================
OpenPicker:
if (menuOpen)
    return
menuOpen  := true
wasPaused := paused
LogLine("F3: picker opened")
LoadPanelIndex()
BuildPickerGui()
SetTimer, PickerTimedOut, % -pickerTimeout
return


BuildPickerGui() {
    global hPicker, panelName, firstDesktop, maxPanel
    ; Font sizes are points (they scale with the display's DPI on their own);
    ; only positions are derived from the screen size.
    leftX  := Round(A_ScreenWidth  * 0.06)
    colW   := A_ScreenWidth - (leftX * 2)
    rowH   := Round(A_ScreenHeight * 0.062)
    gap    := Round(A_ScreenHeight * 0.010)
    listY  := Round(A_ScreenHeight * 0.17)
    hdrY   := Round(A_ScreenHeight * 0.05)

    Gui, Picker:New, +AlwaysOnTop -Caption -DPIScale +HwndhPicker, Pick a panel
    Gui, Picker:Color, 1A1C1E
    Gui, Picker:Font, s30 bold cF7F7F8, Segoe UI
    Gui, Picker:Add, Text, % "x" leftX " y" hdrY " w" colW " BackgroundTrans", ROTATION PAUSED  -  pick a panel
    Gui, Picker:Font, s14 norm cA98CC4, Segoe UI
    Gui, Picker:Add, Text, % "x" leftX " y+10 w" colW " BackgroundTrans", Press the panel number or click a row.   Esc cancels and resumes rotation.

    yy := listY
    Loop, % maxPanel - firstDesktop + 1
    {
        d   := firstDesktop + A_Index - 1
        key := (d = 10) ? "0" : d
        if (panelName.HasKey(d))
        {
            cap := "[" . key . "]     " . panelName[d]
            live := GetLiveTitle(d)
            if (live != "")
                cap .= "`n           " . live
            ; Standard buttons ignore the GUI colour, so rows are Text controls
            ; with their own background - they still fire a g-label on click.
            Gui, Picker:Font, s17 norm cF7F7F8, Segoe UI
            Gui, Picker:Add, Text, % "x" leftX " y" yy " w" colW " h" rowH " Background2A2C2E gPickerClick", %cap%
            yy += rowH + gap
        }
        else
        {
            Gui, Picker:Font, s12 norm c6A6D70, Segoe UI
            Gui, Picker:Add, Text, % "x" leftX " y" yy " w" colW " h" Round(rowH * 0.4) " BackgroundTrans", [%key%]     not configured
            yy += Round(rowH * 0.45)
        }
    }

    Gui, Picker:Show, x0 y0 w%A_ScreenWidth% h%A_ScreenHeight%, Pick a panel
    WinActivate, ahk_id %hPicker%
    WinWaitActive, ahk_id %hPicker%, , 3
    PickerHotkeys("On")
}


; Digit hotkeys are global while the menu is up and disabled the moment it
; closes. Scoping them to the window proved unreliable - if the GUI lost focus
; for any reason the keys silently did nothing.
PickerHotkeys(state) {
    global firstDesktop, maxPanel
    Loop, % maxPanel - firstDesktop + 1
    {
        d   := firstDesktop + A_Index - 1
        key := (d = 10) ? "0" : d
        Hotkey, %key%, PickerKey, %state%
    }
    Hotkey, Escape, PickerEscape, %state%
}


PickerKey:
key := A_ThisHotkey
ChoosePanel((key = "0") ? 10 : key + 0)
return

PickerClick:
; No control variable, so A_GuiControl holds the caption: "[N]     Name..."
if (RegExMatch(A_GuiControl, "^\[(.)\]", m))
    ChoosePanel((m1 = "0") ? 10 : m1 + 0)
return

PickerEscape:
PickerGuiEscape:
PickerGuiClose:
CancelMenu()
return

PickerTimedOut:
if (menuOpen)
{
    TrayTip, Desktop Rotation, Menu timed out - rotation resumed., 1, 1
    CancelMenu()
}
return


ChoosePanel(d) {
    global panelName, pickDesktop
    if (!panelName.HasKey(d))
        return                                 ; unconfigured number: ignore
    pickDesktop := d
    LogLine("F3: chose desktop " . d)
    SetTimer, PickerTimedOut, Off
    DestroyPicker()
    BuildDurationGui()
    SetTimer, PickerTimedOut, % -60000
}


DestroyPicker() {
    global hPicker
    if (hPicker)
    {
        PickerHotkeys("Off")
        Gui, Picker:Destroy
        hPicker := 0
    }
}


; =============================================================================
;  Duration prompt
; =============================================================================
BuildDurationGui() {
    global hDur, pickDesktop, panelName, CustomHours
    leftX := Round(A_ScreenWidth  * 0.06)
    colW  := A_ScreenWidth - (leftX * 2)
    gap   := Round(A_ScreenWidth  * 0.012)
    btnW  := Round((colW - (gap * 5)) / 6)
    btnH  := Round(A_ScreenHeight * 0.10)
    hdrY  := Round(A_ScreenHeight * 0.05)

    Gui, Dur:New, +AlwaysOnTop -Caption -DPIScale +HwndhDur, Hold duration
    Gui, Dur:Color, 1A1C1E
    Gui, Dur:Font, s30 bold cF7F7F8, Segoe UI
    Gui, Dur:Add, Text, % "x" leftX " y" hdrY " w" colW " BackgroundTrans", % "Hold  " . panelName[pickDesktop] . "  for how long?"
    Gui, Dur:Font, s14 norm cA98CC4, Segoe UI
    Gui, Dur:Add, Text, % "x" leftX " y+10 w" colW " BackgroundTrans", Click a preset or type a number of hours and press Enter.   Esc cancels and resumes rotation.

    yy := Round(A_ScreenHeight * 0.25)
    Gui, Dur:Font, s17 norm, Segoe UI
    xx := leftX
    for i, label in ["1 hour", "2 hours", "4 hours", "8 hours", "48 hours", "Forever"]
    {
        Gui, Dur:Add, Button, % "x" xx " y" yy " w" btnW " h" btnH " gDurPreset", % label
        xx += btnW + gap
    }

    yy += btnH + Round(A_ScreenHeight * 0.10)
    ; AHK turns a tall Edit into a multi-line one, and a multi-line Edit eats the
    ; Enter key instead of passing it to the default button - so force single
    ; line (-0x4 clears ES_MULTILINE) and centre it against the OK button.
    editH := Round(btnH * 0.55)
    editY := yy + Round((btnH - editH) / 2)
    Gui, Dur:Font, s17 norm cD8D8D8, Segoe UI
    Gui, Dur:Add, Text, % "x" leftX " y" (editY + Round(editH * 0.15)) " w" btnW " BackgroundTrans", or hours:
    ex := leftX + btnW + gap
    Gui, Dur:Font, s17 norm c000000, Segoe UI
    Gui, Dur:Add, Edit, % "x" ex " y" editY " w" btnW " h" editH " -0x4 vCustomHours"
    ox := ex + btnW + gap
    Gui, Dur:Font, s17 norm, Segoe UI
    Gui, Dur:Add, Button, % "x" ox " y" yy " w" btnW " h" btnH " Default gDurCustom", OK

    Gui, Dur:Show, x0 y0 w%A_ScreenWidth% h%A_ScreenHeight%, Hold duration
    WinActivate, ahk_id %hDur%
    WinWaitActive, ahk_id %hDur%, , 3
    GuiControl, Dur:Focus, CustomHours
}


DurPreset:
; A_GuiControl is the caption: "1 hour", "48 hours", "Forever".
StartHold(pickDesktop, (A_GuiControl = "Forever") ? -1 : SubStr(A_GuiControl, 1, InStr(A_GuiControl, " ") - 1) + 0)
return

DurCustom:
Gui, Dur:Submit, NoHide
if CustomHours is not number
{
    LogLine("custom hours rejected (not a number): '" . CustomHours . "'")
    return
}
if (CustomHours + 0 <= 0)
{
    LogLine("custom hours rejected (not positive): '" . CustomHours . "'")
    return
}
StartHold(pickDesktop, CustomHours + 0)
return

DurEscape:
DurGuiEscape:
DurGuiClose:
CancelMenu()
return


DestroyDuration() {
    global hDur
    if (hDur)
    {
        Gui, Dur:Destroy
        hDur := 0
    }
}


CancelMenu() {
    global menuOpen, paused, wasPaused
    SetTimer, PickerTimedOut, Off
    DestroyPicker()
    DestroyDuration()
    menuOpen := false
    paused   := wasPaused
    LogLine("menu cancelled")
    if (!paused)
        GoSub, RotateDesktops
}


; =============================================================================
;  Holds
; =============================================================================
StartHold(d, hours) {
    global holdDesktop, holdUntil, holdForever, menuOpen, paused, panelName

    SetTimer, PickerTimedOut, Off
    DestroyPicker()
    DestroyDuration()
    menuOpen := false
    paused   := false

    holdDesktop := d
    if (hours < 0)
    {
        holdForever := true
        holdUntil   := ""
        msg := "Holding " . panelName[d] . " until released (F2 or F3)."
    }
    else
    {
        holdForever := false
        mins := Round(hours * 60)
        t := A_Now
        EnvAdd, t, %mins%, Minutes
        holdUntil := t
        FormatTime, pretty, %t%, yyyy-MM-dd HH:mm
        msg := "Holding " . panelName[d] . " until " . pretty . "."
    }

    WriteHold()
    LogLine("hold started on desktop " . d . " (" . (holdForever ? "forever" : holdUntil) . ")")
    GoToDesktop(d)
    Heartbeat()
    TrayTip, Desktop Rotation, %msg%, 1, 1
}


EndHold(reason) {
    global holdDesktop, holdUntil, holdForever, holdFile, desktopIndex, firstDesktop
    if (holdDesktop = 0)
        return
    holdDesktop := 0
    holdUntil   := ""
    holdForever := false
    FileDelete, %holdFile%
    desktopIndex := firstDesktop
    LogLine("hold " . reason)
    TrayTip, Desktop Rotation, Hold %reason% - rotation resumed., 1, 1
}


WriteHold() {
    global holdFile, holdDesktop, holdUntil, holdForever
    FileDelete, %holdFile%
    out := "desktop=" . holdDesktop . "`n"
    out .= "forever=" . (holdForever ? "1" : "0") . "`n"
    out .= "until=" . holdUntil . "`n"
    FileAppend, %out%, %holdFile%
}


; Restore a hold left behind by a previous run of this script (the watchdog
; restarts it if the heartbeat goes stale, and that must not silently drop a hold).
RestoreHold() {
    global holdFile, holdDesktop, holdUntil, holdForever, panelName
    if !FileExist(holdFile)
        return
    d := 0, f := 0, u := ""
    Loop, Read, %holdFile%
    {
        StringSplit, kv, A_LoopReadLine, =
        if (kv1 = "desktop")
            d := kv2 + 0
        else if (kv1 = "forever")
            f := kv2 + 0
        else if (kv1 = "until")
            u := kv2
    }
    if (d <= 0)
    {
        FileDelete, %holdFile%
        return
    }
    if (!f)
    {
        remain := u
        EnvSub, remain, %A_Now%, Seconds
        if (remain <= 0)
        {
            FileDelete, %holdFile%
            return
        }
    }
    holdDesktop := d
    holdForever := f ? true : false
    holdUntil   := u
    LogLine("restored hold on desktop " . d)
    TrayTip, Desktop Rotation, Restored hold on desktop %d%., 1, 1
}


HoldSecondsRemaining() {
    global holdUntil
    if (holdUntil = "")
        return 999999
    remain := holdUntil
    EnvSub, remain, %A_Now%, Seconds
    return remain
}


; =============================================================================
;  Remote commands
; =============================================================================
; The console has F2/F3, but nothing on this desktop is reachable over SSH - an
; SSH session lands in Session 0 and cannot see or touch the interactive
; desktop. So a remote helper drops a one-shot command file in the log folder
; and this timer picks it up. Every command is something F2/F3 already do; this
; adds a way in, not new behaviour.
;
;   hold.request   id=<token> cmd=hold|release|pause|resume|status
;                  desktop=<n> hours=<n|forever>
;   hold.result    id=<token> ok=0|1 msg=<text>   (written back, then read by the helper)
;   rotation.status  the current paused/hold state, refreshed on every heartbeat
CheckRequest:
if (!FileExist(requestFile) || rotBusy)
    return
FileRead, requestText, %requestFile%
FileDelete, %requestFile%        ; consume it first, so a bad request cannot loop
HandleRequest(requestText)
if (resumeNow)
{
    resumeNow := false
    GoSub, RotateDesktops    ; kicked from here, not from inside HandleRequest:
}                            ; a GoSub target called from a function runs in that
return                       ; function's local scope, and this tick needs the globals


HandleRequest(text) {
    global menuOpen, paused, holdDesktop, panelName, desktopIndex, firstDesktop, resumeNow

    cmd := "", id := "", hours := "", d := 0
    Loop, Parse, text, `n, `r
    {
        line := Trim(A_LoopField)
        pos  := InStr(line, "=")
        if (line = "" || !pos)
            continue
        k := Trim(SubStr(line, 1, pos - 1))
        v := Trim(SubStr(line, pos + 1))
        if (k = "cmd")
            cmd := v
        else if (k = "id")
            id := v
        else if (k = "desktop")
            d := v + 0
        else if (k = "hours")
            hours := v
    }
    LogLine("remote: cmd=" . cmd . " desktop=" . d . " hours=" . hours . " id=" . id)

    ; Never fight whoever is standing at the keyboard.
    if (menuOpen)
    {
        WriteResult(id, 0, "The picker is open at the console - try again in a moment.")
        return
    }

    if (cmd = "status")
    {
        WriteResult(id, 1, StateSummary())
        return
    }

    if (cmd = "hold")
    {
        LoadPanelIndex()             ; the manifest may have changed since startup
        if (!panelName.HasKey(d))
        {
            WriteResult(id, 0, "Desktop " . d . " has no panel configured.")
            return
        }
        if (hours = "forever" || hours = "-1")
            h := -1
        else
        {
            if hours is not number
            {
                WriteResult(id, 0, "Duration '" . hours . "' is not a number.")
                return
            }
            h := hours + 0
            if (h <= 0)
            {
                WriteResult(id, 0, "Duration must be greater than zero.")
                return
            }
        }
        StartHold(d, h)              ; same call the F3 duration prompt makes
        WriteResult(id, 1, StateSummary())
        return
    }

    if (cmd = "pause")
    {
        if (holdDesktop > 0)
            EndHold("cancelled remotely")
        paused := true
        GoToDesktop(1)
        SetTaskbarAutoHide(false)
        LogLine("remote: paused on desktop 1")
        WriteResult(id, 1, "Paused on desktop 1 - the taskbar is showing.")
        return
    }

    if (cmd = "release" || cmd = "resume")
    {
        if (holdDesktop = 0 && !paused)
        {
            WriteResult(id, 1, "Nothing was held - rotation is already running.")
            return
        }
        if (holdDesktop > 0)
            EndHold("released remotely")
        paused := false
        SetTaskbarAutoHide(true)
        desktopIndex := firstDesktop
        LogLine("remote: rotation resumed")
        WriteResult(id, 1, "Rotation resumed.")
        resumeNow := true          ; CheckRequest: does the actual tick
        return
    }

    WriteResult(id, 0, "Unknown command '" . cmd . "'.")
}


StateSummary() {
    global holdDesktop, holdForever, holdUntil, paused, panelName
    if (holdDesktop > 0)
    {
        who := panelName.HasKey(holdDesktop) ? panelName[holdDesktop] : ("desktop " . holdDesktop)
        if (holdForever)
            return "Holding " . who . " until released."
        FormatTime, pretty, %holdUntil%, yyyy-MM-dd HH:mm
        return "Holding " . who . " until " . pretty . "."
    }
    return paused ? "Paused on desktop 1." : "Rotating normally."
}


WriteResult(id, ok, msg) {
    global resultFile
    FormatTime, ts, , yyyy-MM-dd HH:mm:ss
    out := "id=" . id . "`nok=" . ok . "`nmsg=" . msg . "`ntime=" . ts . "`n"
    FileDelete, %resultFile%
    FileAppend, %out%, %resultFile%
    LogLine("remote result: ok=" . ok . " - " . msg)
    WriteStatus()
}


; A machine-readable snapshot of what the board is doing. hold.state only
; describes a hold; this also covers "paused" and "rotating", which until now
; existed nowhere outside this script's memory.
WriteStatus() {
    global statusFile, paused, holdDesktop, holdForever, holdUntil, panelName
    FormatTime, ts, , yyyy-MM-dd HH:mm:ss
    who := (holdDesktop > 0 && panelName.HasKey(holdDesktop)) ? panelName[holdDesktop] : ""
    out :=  "time=" . ts . "`n"
    out .= "paused=" . (paused ? "1" : "0") . "`n"
    out .= "hold=" . holdDesktop . "`n"
    out .= "forever=" . (holdForever ? "1" : "0") . "`n"
    out .= "until=" . holdUntil . "`n"
    out .= "name=" . who . "`n"
    out .= "summary=" . StateSummary() . "`n"
    FileDelete, %statusFile%
    FileAppend, %out%, %statusFile%
}


; =============================================================================
;  Helpers
; =============================================================================
LoadPanelIndex() {
    global panelName, panelIndex
    panelName := {}
    if !FileExist(panelIndex)
        return
    Loop, Read, %panelIndex%
    {
        line := A_LoopReadLine
        if (line = "")
            continue
        StringSplit, part, line, |
        if (part1 + 0 > 0)
            panelName[part1 + 0] := part2
    }
}


; The title of the window living on the given desktop. Windows on virtual
; desktops other than the current one are cloaked, so WinGet List skips them
; unless hidden windows are detected - without this only the desktop you are
; standing on ever showed a live title. Picks the largest window on that desktop
; so helper windows (MyRadar spawns a 40x40 "PopupHost") do not win.
GetLiveTitle(d) {
    global hPicker, hDur
    best     := ""
    bestArea := 0
    DetectHiddenWindows, On
    WinGet, ids, List
    Loop, %ids%
    {
        id := ids%A_Index%
        if (id = hPicker || id = hDur)
            continue
        if (DllCall("VirtualDesktopAccessor\GetWindowDesktopNumber", "Ptr", id, "Int") != d - 1)
            continue
        WinGetTitle, title, ahk_id %id%
        if (title = "")
            continue
        WinGetPos, , , w, h, ahk_id %id%
        area := w * h
        if (area > bestArea)
        {
            bestArea := area
            best     := title
        }
    }
    DetectHiddenWindows, Off
    return best
}


CurrentDesktop() {
    return DllCall("VirtualDesktopAccessor\GetCurrentDesktopNumber", "Int") + 1
}


GoToDesktop(desktopNumber) {
    global switchSettle
    DllCall("VirtualDesktopAccessor\GoToDesktopNumber", "UInt", desktopNumber - 1)
    Sleep, %switchSettle%
}


LogLine(msg) {
    global logDir
    FormatTime, ts, , yyyy-MM-dd HH:mm:ss
    FormatTime, day, , yyyyMMdd
    FileAppend, % ts . " [INFO ] " . msg . "`n", % logDir . "\rotation-" . day . ".log"
}


Heartbeat() {
    global heartbeatFile
    FormatTime, ts, , yyyy-MM-dd HH:mm:ss
    FileDelete, %heartbeatFile%
    FileAppend, %ts%, %heartbeatFile%
    WriteStatus()
}


SetTaskbarAutoHide(enable) {
    VarSetCapacity(APPBARDATA, A_PtrSize = 4 ? 36 : 48, 0)
    NumPut(A_PtrSize = 4 ? 36 : 48, APPBARDATA, 0, "uint")
    NumPut(enable ? 1 : 0, APPBARDATA, A_PtrSize = 4 ? 32 : 40, "int")
    DllCall("Shell32.dll\SHAppBarMessage", "uint", 0xA, "ptr", &APPBARDATA)
}
