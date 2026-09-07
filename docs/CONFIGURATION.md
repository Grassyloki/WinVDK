# Configuration reference

Everything that can be tuned, and where. `C:\Scripts\Panels.ps1` is the file you
will actually edit; the rest is here for when you need it.

---

## Panels.ps1 — settings

| Setting | Default | What it does |
|---|---|---|
| `$ScriptRoot` | `C:\Scripts` | where the board scripts live |
| `$LogDir` | `C:\Scripts\Logs` | logs and state files |
| `$LogRetentionDays` | `14` | logs older than this are pruned on every startup and watchdog pass |
| `$AhkExe` | `C:\Program Files\AutoHotkey\AutoHotkeyU64.exe` | the AutoHotkey **v1** interpreter |
| `$LaunchHelper` | `…\Setup-ProgramsOnVirtualDesktops.ahk` | switch-desktop-then-run helper |
| `$RotationScript` | `…\DesktopSwitchingFunctions.ahk` | the rotation loop |
| `$HeartbeatMaxAgeSec` | `420` | rotation heartbeat older than this counts as frozen |
| `$StartupGraceSec` | `900` | how long a `board.starting` marker is believed before it is treated as stale |
| `$BootGraceSec` | `240` | the watchdog ignores the board for this long after a reboot |
| `$TotalDesktops` | `8` | how many virtual desktops to create — includes the empty parking desktop |
| `$FirstDesktop` | `2` | first desktop in the rotation |
| `$LastDesktop` | `8` | last desktop in the rotation |
| `$LaunchTimeoutSec` | `90` | how long to wait for one panel's window before giving up on it |

The path settings are duplicated as literals inside the two `.ahk` files, which
cannot read PowerShell. If you move the install away from `C:\Scripts` you must
edit `DllPath`, `logDir` and the state-file paths at the top of
`DesktopSwitchingFunctions.ahk`, and `DllPath` in
`Setup-ProgramsOnVirtualDesktops.ahk`, to match.

---

## Panels.ps1 — the manifest

```powershell
$Panels = @(
    @{ Desktop        = 7
       Name           = 'MyRadar Pro'
       Program        = 'C:\Scripts\MyRadar.lnk'
       Arguments      = ''
       ProcessName    = 'MyRadar.Windows.Pro'
       FullScreenKeys = '{F11}' }
)
```

| Field | Required | Notes |
|---|---|---|
| `Desktop` | yes | 1-based virtual desktop number. Desktop 1 is the parking desktop; start at 2 |
| `Name` | yes | shown in logs and in the F3 picker. Free text |
| `Program` | yes | an executable on `PATH`, an absolute path, or a `.lnk` |
| `Arguments` | yes (may be `''`) | passed straight through |
| `ProcessName` | yes | what the watchdog expects to own a window there — the `Get-Process` name, no `.exe` |
| `FullScreenKeys` | yes (may be `''`) | AutoHotkey key syntax, e.g. `{F11}`. Leave empty for `--kiosk` browsers |

### Finding `ProcessName`

Start the app, then:

```powershell
Get-Process | Where-Object MainWindowTitle | Select-Object ProcessName, MainWindowTitle
```

For a Store/MSIX app the process name is often nothing like the app's display
name (MyRadar Pro runs as `MyRadar.Windows.Pro`). Get this wrong and the watchdog
will relaunch a panel that is perfectly healthy, every five minutes.

### Launching an MSIX / Store app

Store apps have no readable target path. Make a shortcut to it, drop the `.lnk`
in `C:\Scripts`, and point `Program` at the shortcut — that is what the MyRadar
example does. Launching it through a PowerShell wrapper also works but flashes a
console window onto the wall, which is why it is not done here.

### The three-place rule

Adding, removing or reordering a panel touches:

1. `$Panels` in `Panels.ps1`;
2. `$TotalDesktops` and `$LastDesktop` in `Panels.ps1`;
3. `lastDesktop`, and any `refreshEvery` / `refreshKeys` entries, in
   `DesktopSwitchingFunctions.ahk`.

Point 3 is the one that bites: those arrays are keyed by **desktop number**, so
inserting a panel in the middle silently moves someone else's refresh key onto
the wrong panel.

---

## DesktopSwitchingFunctions.ahk — settings

| Setting | Default | What it does |
|---|---|---|
| `firstDesktop` | `2` | first desktop in the rotation — must match `$FirstDesktop` |
| `lastDesktop` | `8` | last desktop in the rotation — must match `$LastDesktop` |
| `maxPanel` | `10` | highest desktop number the F3 picker will offer |
| `displayTime` | `120000` | milliseconds each panel stays on screen |
| `switchSettle` | `2000` | pause after a desktop switch, to let the animation finish |
| `pickerTimeout` | `60000` | auto-cancel the F3 menu after this, so it can never strand the board |
| `requestPoll` | `2000` | how often to check for a remote command |

### Refresh keys

```autohotkey
refreshEvery[6] := 8         ; on every 8th visit to desktop 6…
refreshKeys[6]  := "{F5}"    ; …send F5
```

Only panels with no self-refresh need an entry. Anything with `&refresh=` in its
URL refreshes itself. `refreshEvery[n] := 0` (or no entry) means never.

The cycle length matters here: with seven panels at 120 s, every 8th visit is
roughly every 112 minutes.

---

## Setup-ProgramsOnVirtualDesktops.ahk — timings

| Setting | Default | What it does |
|---|---|---|
| `timeoutMs` | `75000` | how long to wait for a panel's window to appear |
| `switchSettle` | `1000` | pause after switching desktops, before launching |
| `windowSettle` | `1500` | pause after the window appears |
| `fsSettle` | `4000` | let the app settle before touching it — apps re-apply their remembered window state a few seconds in |
| `fsVerify` | `2500` | wait before re-checking that full screen stuck |
| `fsAttempts` | `5` | how many times to try the fullscreen key |

Keep `$LaunchTimeoutSec` in `Panels.ps1` comfortably above `timeoutMs` plus the
fullscreen budget, or the caller will abandon a helper that was about to succeed.

---

## Scheduled tasks

Set at install time, changeable with installer parameters or in Task Scheduler.

| Task | Trigger | Principal | Why that principal |
|---|---|---|---|
| `Start VDDB` | at logon | kiosk user, interactive, highest | it creates windows |
| `VDDB Watchdog` | every 5 min + 3 min after logon | kiosk user, interactive, highest | it creates windows too — running it as SYSTEM puts it in Session 0, where it can see nothing |
| `VDDB Daily Reboot` | daily 04:00 | SYSTEM | it only reads a file and reboots |

```powershell
.\install\Install-WinVDDB.ps1 -KioskUser 'Kiosk' -RebootTime '03:30' -WatchdogMinutes 10
```

Pick a reboot time that is not when people arrive. A hold set with F3 (or
`vddbctl hold`) suppresses that night's reboot.

---

## The remote control

`tools/vddbctl.sh` reads its settings from the environment, so the script itself
needs no editing:

| Variable | Default | Meaning |
|---|---|---|
| `VDDB_HOST` | `192.168.1.50` | the display's address or hostname |
| `VDDB_USER` | `kiosk` | SSH user on the display |
| `VDDB_LOGDIR` | `C:\Scripts\Logs` | where the board keeps its state files |

It needs key-based SSH to the display (it runs with `BatchMode=yes` and will
never sit at a password prompt) and `python3` on the machine you run it from.

```bash
export VDDB_HOST=display.example.lan VDDB_USER=kiosk
alias vddb=/opt/WinVDDB/tools/vddbctl.sh
```

---

## Hardening notes

* **Autologon puts a password in the registry.** That is inherent to an
  unattended kiosk. Keep the account unprivileged, and do not reuse the password
  anywhere else.
* **The kiosk account does not need to be an administrator.** Only the installer
  does. If you make the account a standard user, check that the scheduled tasks
  still register (the installer will tell you) and that the `VirtualDesktop`
  module was installed for **AllUsers**, which is what the installer does.
* **Scope your remote access.** If you enable SSH, VNC or RDP on a wall display,
  bind or firewall them to a management network rather than every interface.
* **Machine-wide `Set-ExecutionPolicy Unrestricted` is not needed.** Every task
  already passes `-ExecutionPolicy Bypass`, which is scoped to that process.
