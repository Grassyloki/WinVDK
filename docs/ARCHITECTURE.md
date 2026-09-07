# Architecture

How WinVDDB fits together, and why it is shaped the way it is. Most of what
follows is the record of something that went wrong on a real wall display and
the fix that made it stop.

---

## 1. The boot chain

```
Power on
  └─ Winlogon autologon  (AutoAdminLogon=1, kiosk account)
       └─ Scheduled Task "Start VDDB"  (at logon)
            └─ powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Launcher.ps1
                 └─ Start-Process → Run-VirtualDesktopsDisplayBoard.ps1   (fire and forget)
                      ├─ writes Logs\board.starting   (watchdog stands down while this exists)
                      ├─ dot-sources Panels.ps1        (config + manifest + helpers)
                      ├─ writes Logs\panels.index      (panel names, for the AHK picker)
                      ├─ Import-Module VirtualDesktop → create N desktops
                      ├─ for each panel: Open-OnDesktop ──blocks on──▶ Setup-ProgramsOnVirtualDesktops.ahk
                      │                                                   ├─ VDA GoToDesktopNumber(n-1)
                      │                                                   ├─ snapshot windows, Run <program>
                      │                                                   ├─ wait for a NEW window to appear
                      │                                                   └─ optionally send FullScreenKeys
                      ├─ hands off ──▶ DesktopSwitchingFunctions.ahk   ◀── the long-lived rotation
                      └─ removes Logs\board.starting

Scheduled Task "VDDB Watchdog"      every 5 min ──▶ Watchdog-DisplayBoard.ps1  (one pass, then exits)
Scheduled Task "VDDB Daily Reboot"  daily 04:00 ──▶ DailySystemReboot.ps1
```

`Launcher.ps1` is deliberately thin — it starts the board and returns, so a slow
startup never holds the scheduled task open.

Panels are launched by **blocking on the helper until its window actually
appears**. There are no guessed `Start-Sleep` values between panels, which is why
startup takes as long as it takes and no longer: a cold boot reaches a fully
populated board in well under two minutes.

---

## 2. Supervision

Three things watch the board, and none of them is a `while` loop that has to
survive all day. That is the whole design:

* **Task Scheduler** supervises the watchdog — a single pass every five minutes
  that runs and exits — so the watchdog itself cannot silently die. A long-lived
  supervisor process is just one more thing that can wedge.
* **The watchdog** supervises the rotation script and the panels.
* **The rotation script** writes `Logs\rotation.heartbeat` on every tick, so a
  process that is *alive but frozen* is distinguishable from a healthy one. The
  heartbeat keeps ticking while paused with F2 or while a panel is held, so a
  deliberate pause is never mistaken for a hang.

### What one watchdog pass does

1. Recreate virtual desktops if fewer than `$TotalDesktops` exist.
2. Confirm the rotation process is running **and** its heartbeat is fresher than
   `$HeartbeatMaxAgeSec`; restart it otherwise (killing the frozen one first).
3. Walk every panel: is a window owned by the expected `ProcessName` still on
   that desktop? Relaunch if not.
4. For panels with `FullScreenKeys`, is that window still genuinely full screen?
   Repair it **in place** rather than relaunching, so the panel does not lose
   whatever state it had.

Two pieces of restraint, both learned from real misfires:

* The pass returns immediately if system uptime is under `$BootGraceSec`
  (4 minutes). The launch task and the watchdog can otherwise fire in the same
  second after a reboot, before the startup marker has been written. Uptime is
  the one signal that is already true at that instant.
* If **every** panel looks missing, it logs an error and relaunches **nothing**.
  Seven panels do not die simultaneously; window or desktop detection broke, and
  relaunching everything every five minutes would thrash the display. The nightly
  reboot is the backstop for that case.

---

## 3. Launching a panel

`Setup-ProgramsOnVirtualDesktops.ahk` does one job: switch to a desktop, run one
program there, wait for its window, and optionally make it full screen.

```
AutoHotkeyU64.exe Setup-ProgramsOnVirtualDesktops.ahk <desktop> "<program>" "<args>" "<fskeys>"
```

Exit codes, which `Open-OnDesktop` turns into log lines:

| Code | Meaning |
|---|---|
| 0 | panel is up (and full screen, if keys were given) |
| 1 | `VirtualDesktopAccessor.dll` would not load |
| 2 | `Run` failed — bad program path |
| 3 | no window appeared within the timeout |
| 4 | the window is up but would not go full screen |

Passing an **empty program** puts it in *repair-only* mode: it does not launch
anything and instead makes an existing window full screen, with the target
window's `HWND` passed in place of the arguments. The watchdog uses this. The
handle is passed explicitly rather than re-derived from the desktop number,
because the rotation can switch desktops mid-repair — "the largest window on the
current desktop" then measures the wrong window and cheerfully reports success.

### Why it waits for *any* new window, not its own process

Firefox delegates `-new-window` to the already-running instance and the process
you spawned exits immediately, so waiting on your own PID never matches. The
helper snapshots the visible top-level windows before launching and waits for a
new one to appear.

### Why it takes the *largest* new window

Applications spawn helper windows. MyRadar, for example, also creates a 40×40
`PopupHost` window with a title — and the fullscreen key sent to that did
precisely nothing while the real window stayed maximised. Anything smaller than a
sixteenth of the screen is ignored.

### Why fullscreen is measure-then-send, with retries

A fullscreen key is almost always a **toggle**, and an app that restored its own
full-screen state will be switched straight back *out* of it by a blind keypress.
Worse, some apps re-apply their remembered window state a few seconds after the
window first appears, silently undoing an early keypress. So the helper settles
for four seconds, sends only while the window is *not* full screen, then
re-checks after 2.5 s and retries up to a few times.

**Maximised is not full screen.** A maximised window on a 3840×2160 display
measures `3866×2186 at -13,-13` — borders off-screen, caption bar still visible.
True full screen is `3840×2160 at 0,0`. The check requires the origin to be
within 2 px of `0,0` exactly so a maximised window does not pass.

---

## 4. The rotation script

`DesktopSwitchingFunctions.ahk` is the only long-lived process. Every
`displayTime` milliseconds it:

1. does nothing but heartbeat if the F3 menu is open;
2. expires a hold whose deadline has passed;
3. if a hold is active, re-asserts that desktop and applies its refresh key;
4. otherwise advances to the next desktop in `firstDesktop..lastDesktop` and
   applies that desktop's refresh key;
5. writes the heartbeat and the status snapshot.

### Refresh keys

`refreshEvery[n]` / `refreshKeys[n]` are keyed by **desktop number**, so they must
follow a panel when it moves. Panels whose URL already carries a refresh interval
need no entry.

The keys are stored **bare** (`{F5}`) and sent with expression syntax
(`Send, % refreshKeys[d]`). An earlier version stored the whole statement as the
string `"Send, {F5}"` and ran `Send, %action%`, which expanded to
`Send, Send, {F5}` — AutoHotkey typed the literal characters `Send, ` into the
kiosk window before pressing F5.

### The picker UI

Three AutoHotkey details this depends on, each of which breaks it quietly rather
than loudly:

* The GUIs are created with **`-DPIScale`**. AutoHotkey otherwise scales every
  Gui coordinate by the display DPI, which on a 200 % display produced a
  `7680×4320` window with most of the controls off screen.
* The hours field is forced single-line with **`-0x4`** (clearing `ES_MULTILINE`).
  AutoHotkey turns a tall Edit into a multi-line one, and a multi-line Edit
  **swallows Enter** instead of passing it to the default button.
* `GetLiveTitle()` turns on **`DetectHiddenWindows`**. Windows sitting on a
  virtual desktop other than the current one are cloaked, so without it the
  picker could only ever show a live title for the desktop you were standing on.

The digit hotkeys are registered **globally** while the menu is open and disabled
the moment it closes. Scoping them to the picker window proved unreliable — any
loss of focus made the keys silently do nothing.

### Holds

A hold is recorded in `Logs\hold.state` (`desktop`, `forever`, `until`) and:

* **re-asserts itself every tick**, so a watchdog panel relaunch that switches
  desktops is pulled back within one tick — the two components need no direct
  coordination;
* **still refreshes** the held panel if it has a refresh key;
* **survives a restart of the rotation script**, which matters because the
  watchdog restarts it whenever the heartbeat goes stale;
* **suppresses the nightly reboot** — `DailySystemReboot.ps1` reads the same file.

---

## 5. Remote control, and Session 0

An SSH session on Windows lands in **Session 0**, the services session, which is
isolated from the interactive desktop. Over SSH you cannot enumerate the kiosk's
windows, send keystrokes, take a screenshot, or start anything that appears on
screen — `Get-Process ... MainWindowTitle` comes back empty. This is not a
permissions problem and no amount of elevation fixes it. (Sudo for Windows also
refuses to run in Session 0, for the same architectural reason.)

So `tools/vddbctl.sh` does not try. It writes a one-shot command file into the
log folder and the rotation script — which *is* in the interactive session —
polls for it every two seconds:

```
hold.request     id=<token> cmd=hold|release|pause|resume|status
                 desktop=<n> hours=<n|forever>
hold.result      id=<token> ok=0|1 msg=<text> time=<ts>
rotation.status  time / paused / hold / forever / until / name / summary
```

The request is written to a temporary name and then **renamed** into place, so
the poller can never read a half-written file, and it is **consumed before it is
executed**, so a malformed request cannot loop. Requests are refused while the F3
picker is open: whoever is standing at the keyboard wins. Every remote command
maps onto something F2/F3 already do — `hold` calls the very same `StartHold()`
the duration prompt calls — so remote and console behaviour cannot drift.

`rotation.status` exists because "paused" and "rotating" used to live only in the
AutoHotkey script's memory, where nothing else could see them.

Commands are sent as PowerShell `-EncodedCommand`, because the display's sshd
shell is already PowerShell and a plain command string gets parsed twice, which
mangles nested quotes.

---

## 6. State files

All under `C:\Scripts\Logs\`.

| File | Written by | Read by | Meaning |
|---|---|---|---|
| `<source>-<yyyymmdd>.log` | everything | humans | `board`, `watchdog`, `reboot`, `rotation`; pruned after 14 days |
| `rotation.heartbeat` | rotation | watchdog | timestamp of the last tick |
| `rotation.status` | rotation | `vddbctl` | paused / hold / summary snapshot |
| `board.starting` | board script | watchdog | exists only during startup |
| `hold.state` | rotation | rotation, reboot task | the active hold |
| `panels.index` | `Write-PanelIndex` | rotation | `desktop\|name` — how the AHK picker learns panel names without duplicating the manifest |
| `hold.request` | `vddbctl` | rotation | one-shot remote command |
| `hold.result` | rotation | `vddbctl` | its reply |

`panels.index` exists for one reason: the rotation script is AutoHotkey and
cannot read `Panels.ps1`, but the panel names must not be defined in two places.
Both the launcher and the watchdog rewrite it from the manifest.

---

## 7. Why some obvious things are not done

**Why not one script with a `while` loop?** Because that is exactly the failure
this design exists to avoid. A single unsupervised process that owns the whole
board means a crashed panel stays dead until somebody walks over and reboots the
machine, and nothing is written down about why.

**Why two virtual-desktop mechanisms?** The PowerShell module creates desktops;
the DLL switches them. Neither does both well from the place it is needed — the
AutoHotkey side needs a synchronous switch call, the PowerShell side needs to
create and count. It is the main outstanding wart: two unofficial dependencies on
an undocumented COM interface, either of which can break on a Windows update.

**Why does the board hand off to AutoHotkey at all?** Sending keystrokes to a
specific window and driving virtual desktops from the interactive session is what
AutoHotkey is good at, and the alternative is a pile of P/Invoke in PowerShell
that would still have to run in the same session anyway.

**Why is desktop 1 left empty?** So there is always somewhere to park. F2 lands
on it and shows the taskbar, which turns a locked-down wall display back into a
usable Windows machine for as long as somebody needs it.
