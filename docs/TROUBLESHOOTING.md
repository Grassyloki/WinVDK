# Troubleshooting

Start here:

```powershell
Get-Content C:\Scripts\Logs\board-*.log     -Tail 40
Get-Content C:\Scripts\Logs\watchdog-*.log  -Tail 40
Get-Content C:\Scripts\Logs\rotation-*.log  -Tail 40
Get-Content C:\Scripts\Logs\rotation.status
```

`rotation.status` answers "what does the board think it is doing" in one file:
`paused`, `hold`, and a human `summary` line.

---

## The board never starts

**Nothing in the logs at all.** The launch task did not run. Check it:

```powershell
Get-ScheduledTask     -TaskName 'Start VDDB' | Select-Object State
Get-ScheduledTaskInfo -TaskName 'Start VDDB' | Select-Object LastRunTime, LastTaskResult
```

`LastTaskResult` of `0x1` usually means a bad path or a quoting error in the
task's argument string. Re-run the installer, which registers it correctly.

**`board-*.log` stops after "settling for 15 seconds".** The `VirtualDesktop`
module failed to import. Confirm it is visible *to the kiosk account*:

```powershell
Get-Module -ListAvailable -Name VirtualDesktop
```

If it is missing there but present for your admin account, it was installed
`-Scope CurrentUser` for the wrong user. Reinstall it for all users:

```powershell
Install-Module VirtualDesktop -Scope AllUsers -Force
```

**"AutoHotkey not found at …"**. Either it is not installed, or you have v2 and
not v1. `AutoHotkeyU64.exe` is the v1 binary; v2's is `AutoHotkey64.exe`. Install
v1.1 from [autohotkey.com/download/1.1](https://www.autohotkey.com/download/1.1/)
and make `$AhkExe` in `Panels.ps1` point at it.

---

## The board starts but nothing appears on screen

**You started it over SSH.** An SSH session on Windows lands in Session 0, which
is isolated from the interactive desktop. Anything it launches runs invisibly.
This is architectural — elevation does not help. See
[restarting the board remotely](#restarting-the-board-without-a-reboot).

**The watchdog task is running as SYSTEM.** Same problem: Session 0. It must run
as the kiosk user with `LogonType Interactive`.

---

## A panel is missing, or on the wrong desktop

Look for `'<name>' failed:` in `board-*.log`. The helper's exit code says which
stage broke:

| Log line | Cause |
|---|---|
| `VirtualDesktopAccessor.dll would not load` | the DLL is missing from `C:\Scripts`, or a Windows update changed the COM interface it uses |
| `could not run '<program>'` | bad path in `Program`, or the `.lnk` is gone |
| `started but no window appeared` | the app took longer than `timeoutMs`, or it never opens a top-level window |
| `is up but would not go full screen` | see below |

**A panel lands on the wrong desktop.** Almost always a settle-time problem on a
slow machine: raise `switchSettle` in `Setup-ProgramsOnVirtualDesktops.ahk`.

**Windows collapsed all the desktops.** Some Windows updates reset virtual
desktops on reboot. The watchdog recreates them, but panels already running end
up wherever they end up — a reboot is the clean fix.

---

## The watchdog keeps relaunching a healthy panel

`ProcessName` in the manifest does not match what the app actually runs as.
Check, while the panel is up:

```powershell
Get-Process | Where-Object MainWindowTitle | Select-Object ProcessName, MainWindowTitle
```

Store/MSIX apps are the usual offenders — their process name rarely resembles
their display name.

---

## A panel is up but not full screen

For browser panels, make sure the kiosk flag is actually in `Arguments`
(`--kiosk` for Firefox and Chromium).

For native apps with `FullScreenKeys`, the watchdog repairs this in place and
logs `present but <w>x<h> at <x>,<y>`. If it never sticks:

* the key may not be that app's fullscreen key — check the app;
* the window may be **maximised**, which is deliberately not accepted: a
  maximised window sits a few pixels off-screen and keeps its title bar;
* the app may be re-applying a remembered window state later than `fsSettle`
  allows — raise `fsSettle` and `fsAttempts` in
  `Setup-ProgramsOnVirtualDesktops.ahk`.

---

## Grafana still shows its own toolbar

`&kiosk` alone is not enough. It removes the nav bar, side menu and dashboard
header but leaves the controls row. Add:

```
&_dash.hideTimePicker=true      removes the time range + refresh control
&_dash.hideVariables=true       removes the template-variable pickers
```

Use `?kiosk` if it is the first parameter in the URL. `&kiosk=tv` is the older
mode that keeps the top bar. Hiding a variable picker does not unset the
variable, so `&var-...=` in the URL still applies.

---

## The rotation is stuck on one desktop

**Something is held.** `Get-Content C:\Scripts\Logs\rotation.status` will say so.
Press F2 at the console, or `vddbctl release` remotely.

**The rotation script is dead or frozen.**

```powershell
Get-CimInstance Win32_Process -Filter "Name = 'AutoHotkeyU64.exe'" |
    Select-Object ProcessId, CommandLine
Get-Item C:\Scripts\Logs\rotation.heartbeat | Select-Object LastWriteTime
```

A heartbeat older than a couple of minutes means it is wedged. The watchdog will
restart it within five minutes on its own; to force it now, see below.

**Two rotation processes.** Should be impossible (`#SingleInstance, force`), but
if it happens the desktop will flick between two schedules. Kill both and let the
watchdog start one.

---

## Restarting the board without a reboot

Anything you start from SSH lands in Session 0 and will never appear on screen.
The watchdog task, however, runs in the interactive session even when *triggered*
from SSH — so drive it instead of trying to launch things yourself:

```powershell
Remove-Item C:\Scripts\Logs\rotation.heartbeat -Force   # make the rotation look dead
Start-ScheduledTask -TaskName 'VDDB Watchdog'           # it restarts rotation
```

To rebuild the whole board, from an **interactive** session (console, VNC or RDP):

```powershell
Get-Process AutoHotkeyU64, firefox -ErrorAction SilentlyContinue | Stop-Process -Force
& powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Run-VirtualDesktopsDisplayBoard.ps1
```

---

## The remote control does not answer

`vddbctl status` diagnoses itself — it reports whether the rotation process
exists and how old its heartbeat is before it reports anything else.

| Symptom | Cause |
|---|---|
| `Cannot reach <user>@<host> over SSH` | SSH, the address, or key-based auth. `vddbctl` runs with `BatchMode=yes` and will never prompt for a password |
| `No reply from the rotation script` | the rotation is dead or frozen — it is what polls for the request |
| `The picker is open at the console` | somebody is standing at the display using F3. By design, they win |
| `Desktop N has no panel configured` | `panels.index` is stale or N is outside the manifest. It is rewritten on every watchdog pass |
| a `hold.request` file that lingers | nothing is consuming requests: the rotation script is not running |

---

## The machine did not reboot last night

A hold suppresses the nightly reboot — that is deliberate, and `reboot-*.log`
records it:

```
desktop 7 is held until 2026-01-02 09:00 - skipping tonight's reboot
```

A `Forever` hold suppresses it indefinitely. Release it with F2, F3, or
`vddbctl release`.

If there is no log line at all, the task did not run:

```powershell
Get-ScheduledTaskInfo -TaskName 'VDDB Daily Reboot' | Select-Object LastRunTime, LastTaskResult
```

---

## After a Windows feature update

Virtual desktops are an undocumented COM interface, and both dependencies here
sit on top of it. If desktop switching stops working entirely after an update,
update [VirtualDesktopAccessor](https://github.com/Ciantic/VirtualDesktopAccessor)
and the [`VirtualDesktop`](https://github.com/MScholtes/PSVirtualDesktop) module —
a build that matches your Windows version is usually released within a few weeks.

Also re-check AutoHotkey: an update that swapped v1 for v2 will break every
script here, and the symptom is a rotation that exits immediately with a syntax
error.
