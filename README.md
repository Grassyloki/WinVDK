# WinVDDB — Windows Virtual Desktop Display Board

An unattended wall-display kiosk built out of Windows virtual desktops. It boots,
logs in, opens one full-screen dashboard per virtual desktop, and rotates through
them forever. If a panel dies it is relaunched; if the rotation freezes it is
restarted; every morning the machine reboots itself so nothing gets to rot.

It is aimed at the screen bolted to a wall in an office or a lab — the one that
shows Grafana, a weather radar, a flight map, a status board — where nobody logs
in, nobody clicks anything, and the failure mode that actually matters is *a
frozen picture nobody notices for three weeks*.

```
  Desktop 1   parking desktop - empty, taskbar visible   (F2 lands here)
  Desktop 2   Grafana - infrastructure overview          120 s
  Desktop 3   Grafana - WAN monitor stats                120 s
  Desktop 4   Grafana - firewall and IPS                 120 s
  Desktop 5   Grafana - reverse proxy                    120 s
  Desktop 6   Windy satellite                            120 s   <- {F5} every 8th visit
  Desktop 7   MyRadar - a native app, {F11} to go full screen
  Desktop 8   FlightRadar24                              120 s

  seven panels x 120 s = a 14-minute cycle
```

Those panels are the shipped **example** manifest. Point them wherever you like:
anything that opens in a window can be a panel.

---

## What makes it different from a browser tab loop

* **Real virtual desktops, not tabs.** Each panel owns a desktop and keeps its
  own full-screen window, so a page that misbehaves cannot resize or cover
  another one, and a native application is just as easy to show as a web page.
* **It is supervised.** Task Scheduler runs a watchdog pass every five minutes;
  the watchdog restarts a dead or *frozen* rotation and relaunches missing
  panels. The rotation writes a heartbeat, so "alive but wedged" is detectable —
  which is the failure that actually happens.
* **It launches deterministically.** Panels are started by blocking until each
  window genuinely appears, not by sleeping a guessed number of seconds. A cold
  boot reaches a populated board in well under two minutes.
* **It has controls.** `F2` parks the board on an empty desktop with the taskbar
  showing so somebody can actually use the machine; `F3` opens a full-screen
  picker to hold one panel for a chosen number of hours. Both work remotely too.
* **One file to edit.** `Panels.ps1` holds the whole manifest and is shared by
  the launcher and the watchdog, so the two can never disagree about what is
  supposed to be on screen.

---

## Requirements

| | |
|---|---|
| OS | Windows 10 or 11 with virtual desktop support (developed on Windows 11 IoT Enterprise LTSC 24H2) |
| Shell | Windows PowerShell 5.1 (PowerShell 7 is not required) |
| Automation | **AutoHotkey v1.1** — `AutoHotkeyU64.exe`. **Not v2**: every script here is v1 syntax |
| Desktop creation | [`VirtualDesktop`](https://www.powershellgallery.com/packages/VirtualDesktop) PowerShell module (installed for you) |
| Desktop switching | `VirtualDesktopAccessor.dll` (vendored in `scripts/`) |
| Browser | any browser with a kiosk flag; the examples use Firefox `--kiosk` |
| Account | a local account that autologons, e.g. `Kiosk` |

> **AutoHotkey version warning.** winget's `AutoHotkey.AutoHotkey` package tracks
> v2. These scripts are v1 and a `winget upgrade --all` can rearrange the install
> underneath them. Install v1.1 from
> [autohotkey.com/download/1.1](https://www.autohotkey.com/download/1.1/) and pin it.
> v1 and v2 coexist happily.

---

## Install

On the display machine, in an **elevated** PowerShell:

```powershell
git clone https://github.com/Grassyloki/WinVDDB.git
cd WinVDDB
Set-ExecutionPolicy -Scope Process Bypass -Force
.\install\Install-WinVDDB.ps1 -KioskUser 'Kiosk'
```

The installer copies `scripts\*` to `C:\Scripts`, installs the `VirtualDesktop`
module for all users, and registers three scheduled tasks:

| Task | Trigger | Runs as | Does |
|---|---|---|---|
| `Start VDDB` | at logon | kiosk user, interactive | `Launcher.ps1` — starts the board |
| `VDDB Watchdog` | every 5 min, and 3 min after logon | kiosk user, interactive | one `Watchdog-DisplayBoard.ps1` health pass |
| `VDDB Daily Reboot` | daily 04:00 | SYSTEM | `DailySystemReboot.ps1` |

Re-running the installer is safe — it is idempotent, and it will **not** clobber
a `Panels.ps1` you have already edited unless you pass `-OverwriteConfig`. So an
upgrade is `git pull` followed by another run.

Then:

1. **Edit `C:\Scripts\Panels.ps1`** — see [Configuring the wall](#configuring-the-wall).
2. **Set up autologon** with [Sysinternals Autologon](https://learn.microsoft.com/sysinternals/downloads/autologon).
   The installer deliberately does not do this: enabling autologon stores a
   password in the registry, and that should be a decision you make on purpose.
3. Reboot, or start it now with `Start-ScheduledTask -TaskName 'Start VDDB'`.

To remove it: `.\install\Uninstall-WinVDDB.ps1` (add `-RemoveFiles` to delete
`C:\Scripts` as well).

---

## Configuring the wall

Everything lives in **`C:\Scripts\Panels.ps1`**. One hashtable per desktop:

```powershell
@{ Desktop        = 2
   Name           = 'Grafana - infrastructure overview'   # shown in logs and the F3 picker
   Program        = 'firefox.exe'
   Arguments      = '-new-window --kiosk http://grafana.example.lan:3000/d/000000001/overview?kiosk&refresh=1m'
   ProcessName    = 'firefox'                             # what the watchdog expects to find there
   FullScreenKeys = '' }                                  # '{F11}' for apps that need it
```

**Adding, removing or reordering a panel touches three places.** They are keyed
by desktop *number*, so an entry has to follow its panel when it moves:

1. the `$Panels` array in `Panels.ps1`;
2. `$TotalDesktops` and `$LastDesktop`, also in `Panels.ps1`;
3. `lastDesktop` and any `refreshEvery` / `refreshKeys` entries in
   `DesktopSwitchingFunctions.ahk`.

### Refreshing a panel

A page that already refreshes itself (Grafana's `&refresh=1m`) needs nothing. For
one that does not, send it a key every *n*th visit, in `DesktopSwitchingFunctions.ahk`:

```autohotkey
refreshEvery[6] := 8         ; desktop 6 gets refreshed on every 8th visit
refreshKeys[6]  := "{F5}"
```

### Getting the chrome off a Grafana panel

This is the part everyone gets half-right, so it is worth spelling out. There are
**two** independent layers of chrome and you need both gone:

* **Firefox `--kiosk`** removes the *browser* frame — tabs, address bar.
* On the **Grafana URL**, `&kiosk` removes the nav bar, side menu and dashboard
  header — **but not the controls row**. On a real wall, `&kiosk` alone still
  left a variable picker and `Last 6 hours / Refresh 1m` across the top.

| URL flag | Removes |
|---|---|
| `&kiosk` | nav bar, side menu, dashboard header (use `?kiosk` if it is the first parameter) |
| `&_dash.hideTimePicker=true` | the time-range and refresh control |
| `&_dash.hideVariables=true` | the template-variable pickers |
| `&refresh=1m` | *(not chrome)* makes Grafana re-query itself, so the panel needs no `{F5}` |

`&kiosk=tv` is the older half-way mode that keeps the top bar — not what you
want. Hiding a variable picker does not *unset* the variable, so `&var-...=` in
the URL still applies.

### Panels that are not browsers

A native window will not be full screen just because you launched it. Set
`FullScreenKeys = '{F11}'` and the launcher will:

* pick the **largest** new window, because apps often spawn tiny helper windows
  alongside the real one;
* **measure before sending**, because a fullscreen key is a *toggle* and an app
  that remembered its state would be toggled straight back out;
* **settle, send, then re-check** up to three times, because some apps re-apply
  their remembered window state a few seconds after they first appear.

Note that *maximised is not full screen*: a maximised window sits a few pixels
off-screen and keeps its title bar. The check requires the origin to be within
2 px of `0,0` precisely so a maximised window does not pass.

---

## Controls

At the keyboard in front of the display:

* **F2** — pause and park on desktop 1 with the taskbar showing, so the machine
  is usable. Press again to resume. F2 also cancels an active hold.
* **F3** — pause and open the **panel picker**: a full-screen dark menu listing
  every configured desktop with its name *and its live window title*, so you can
  see what is genuinely on each one. Pick a panel (number key or click), then a
  duration — 1 / 2 / 4 / 8 / 48 hours, Forever, or any typed number of hours.
  Esc cancels at either step, and the menu self-cancels after 60 s so it can
  never strand the board.

While a panel is held the rotation timer keeps running but re-asserts the held
desktop every tick, so a watchdog relaunch that switches desktops is pulled back
automatically. A held panel still honours its refresh key.

**A hold suppresses the nightly reboot.** `DailySystemReboot.ps1` reads the same
hold file and stands down, so a 48-hour hold really does keep that panel up. The
flip side: a `Forever` hold stops the board rebooting indefinitely until it is
released.

---

## Remote control

`tools/vddbctl.sh` drives the same F2/F3 behaviour from a Linux or macOS shell
over SSH:

```bash
export VDDB_HOST=192.168.1.50 VDDB_USER=kiosk
alias vddb=/path/to/WinVDDB/tools/vddbctl.sh

vddb                        # interactive picker: status, panel list, hold/release/pause
vddb status                 # what the board is doing right now
vddb hold 7 4               # hold desktop 7 for 4 hours ("forever" also works)
vddb release                # release the hold, resume rotating
vddb pause                  # park on desktop 1 with the taskbar showing
```

It does **not** drive the desktop directly, and it cannot: an SSH session on
Windows lands in Session 0, which is isolated from the interactive desktop —
over SSH you cannot enumerate the kiosk's windows, send keys or take a
screenshot. Instead it writes a one-shot command file into the board's log
folder, and the rotation script's 2-second poller picks it up and answers in
`hold.result`. Every command maps onto something F2/F3 already do, so a remote
hold behaves exactly like a console one, nightly-reboot suppression included.

Requests are refused while the F3 picker is open at the console: whoever is
standing at the keyboard wins. "No reply from the rotation script" means the
rotation is dead or frozen — `vddb status` will say so outright.

---

## Supervision, logs and state

Three things watch the board, and none of them is a `while` loop that has to
survive all day:

* **Task Scheduler** supervises the watchdog — one pass every five minutes that
  exits — so the watchdog itself cannot silently die.
* **The watchdog** supervises the rotation script and the panels: it recreates
  missing virtual desktops, restarts a rotation whose heartbeat has gone stale,
  relaunches a panel whose window has vanished, and repairs a panel that came up
  windowed instead of full screen.
* **The rotation script** writes a heartbeat on every tick — including while
  paused or held, so a deliberate pause is never read as a hang.

Everything lands in `C:\Scripts\Logs\<source>-<yyyymmdd>.log` (`board`,
`watchdog`, `reboot`, `rotation`), pruned after 14 days. Alongside them:

| File | Meaning |
|---|---|
| `rotation.heartbeat` | timestamp of the last rotation tick |
| `rotation.status` | machine-readable `paused` / `hold` / `summary` snapshot |
| `board.starting` | exists only during startup; tells the watchdog to stand down |
| `hold.state` | the active hold — read by the rotation script on restart and by the reboot task |
| `panels.index` | `desktop\|name`, published from the manifest so the AutoHotkey picker knows the panel names |
| `hold.request` / `hold.result` | the remote command drop-box and its reply |

Two deliberate pieces of restraint in the watchdog, both learned the hard way:

* it ignores the board for the **first four minutes of uptime**, because the
  launch task and the watchdog can otherwise fire in the same second after a
  reboot;
* if it ever sees **every** panel missing it logs an error and does **nothing** —
  that pattern means window detection broke, not that seven panels died at once,
  and relaunching all of them every five minutes would thrash the display.

---

## Repository layout

```
scripts/
  Panels.ps1                          config + panel manifest + shared helpers  ← edit this
  Launcher.ps1                        thin entry point for the "Start VDDB" task
  Run-VirtualDesktopsDisplayBoard.ps1 creates desktops, launches panels, hands off
  Setup-ProgramsOnVirtualDesktops.ahk switch desktop → run program → wait for its window
  DesktopSwitchingFunctions.ahk       the rotation loop, F2/F3, the picker, the request poller
  Watchdog-DisplayBoard.ps1           one health-check pass, run by Task Scheduler
  DailySystemReboot.ps1               nightly reboot, skipped while a panel is held
  VirtualDesktopAccessor.dll          desktop-switching DLL
install/
  Install-WinVDDB.ps1                 copies scripts, installs deps, registers the tasks
  Uninstall-WinVDDB.ps1               unregisters the tasks, optionally removes the files
tools/
  vddbctl.sh                          remote control over SSH, from Linux/macOS
docs/
  ARCHITECTURE.md                     how it fits together, and why it is shaped this way
  CONFIGURATION.md                    full manifest and tuning reference
  TROUBLESHOOTING.md                  symptoms → causes
```

---

## Known limitations

* **Two different virtual-desktop mechanisms.** The PowerShell `VirtualDesktop`
  module *creates* desktops; `VirtualDesktopAccessor.dll` *switches* them. Both
  are unofficial, and both can break when a Windows build changes the
  undocumented COM interface behind virtual desktops.
* **AutoHotkey v1 on a v2 world.** The scripts are v1 syntax; the package manager
  will happily upgrade you to v2 and break the board.
* **Paths are hard-coded to `C:\Scripts`** in the two `.ahk` files and in
  `Panels.ps1`. Installing elsewhere means editing those.
* **Autologon means a password in the registry.** That is inherent to an
  unattended kiosk; keep the account unprivileged and the machine on a segment
  you are comfortable with.
* **Panels with no refresh go stale** until the nightly reboot — and a `Forever`
  hold removes even that bound.

---

## Credits and license

Virtual desktop switching uses
[VirtualDesktopAccessor](https://github.com/Ciantic/VirtualDesktopAccessor) by
Jari Pennanen; desktop creation uses the
[VirtualDesktop](https://github.com/MScholtes/PSVirtualDesktop) PowerShell module
by Markus Scholtes.

Licensed under the **GNU General Public License v3.0** — see [LICENSE](LICENSE).
