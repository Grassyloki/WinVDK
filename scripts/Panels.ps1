# Panels.ps1 - shared configuration, panel manifest and helpers for WinVDDB.
# Dot-sourced by Run-VirtualDesktopsDisplayBoard.ps1 and by
# Watchdog-DisplayBoard.ps1 so the two can never drift out of sync.
#
# THIS IS THE FILE TO EDIT to change what appears on the wall.

# --- Configuration (edit here) -----------------------------------------------
$ScriptRoot         = 'C:\Scripts'                                      # where board scripts live
$LogDir             = 'C:\Scripts\Logs'                                 # log output directory
$LogRetentionDays   = 14                                                # delete logs older than this
$AhkExe             = 'C:\Program Files\AutoHotkey\AutoHotkeyU64.exe'   # AutoHotkey v1 interpreter
$LaunchHelper       = 'C:\Scripts\Setup-ProgramsOnVirtualDesktops.ahk'  # switch-desktop-then-run helper
$RotationScript     = 'C:\Scripts\DesktopSwitchingFunctions.ahk'        # the rotation loop
$HeartbeatFile      = 'C:\Scripts\Logs\rotation.heartbeat'              # rotation liveness marker
$HoldStateFile      = 'C:\Scripts\Logs\hold.state'                      # set while a panel is held via F3
$PanelIndexFile     = 'C:\Scripts\Logs\panels.index'                    # desktop|name, read by the rotation script
$StartupMarker      = 'C:\Scripts\Logs\board.starting'                  # set while the board is booting
$HeartbeatMaxAgeSec = 420                                               # stale rotation threshold, seconds (7 min)
$StartupGraceSec    = 900                                               # how long a startup marker stays valid (15 min)
$BootGraceSec       = 240                                               # ignore the board for this long after a reboot (4 min)
$TotalDesktops      = 8                                                 # virtual desktops to create (desktop 1 stays idle)
$FirstDesktop       = 2                                                 # first desktop in the rotation
$LastDesktop        = 8                                                 # last desktop in the rotation
$LaunchTimeoutSec   = 90                                                # max wait for one panel window to appear

# --- Panel manifest ----------------------------------------------------------
# One entry per virtual desktop. Desktop 1 is deliberately left empty: it is the
# landing/parking desktop that F2 shows with the taskbar, so there is always a
# way back to a usable Windows session.
#
# Desktop        : which virtual desktop this panel owns (1-based)
# Name           : human label - shown in logs and in the F3 panel picker
# Program        : executable or shortcut to run
# Arguments      : command line for it ('' if none)
# ProcessName    : process the watchdog expects to own a window on that desktop
# FullScreenKeys : keys that put the window full screen ('' for none). Browser
#                  panels launched with --kiosk need nothing; a plain desktop app
#                  such as MyRadar only goes full screen when sent {F11}. The
#                  launcher measures the window first and only sends these while
#                  it is not already full screen, because the key is a TOGGLE.
#
# IMPORTANT: adding, removing or reordering a panel touches THREE places -
#   1. this $Panels array,
#   2. $TotalDesktops / $LastDesktop above,
#   3. lastDesktop and the refreshEvery/refreshKeys entries in
#      DesktopSwitchingFunctions.ahk, which are keyed by DESKTOP NUMBER and so
#      must follow a panel when it moves.
#
# --- Grafana: getting the chrome off the wall --------------------------------
# A Grafana dashboard URL renders with the top nav, the side menu and the
# dashboard controls unless you ask it not to. Append to the URL:
#
#     &kiosk                 hides the nav bar, the side menu and the dashboard
#                            header. Required, but NOT sufficient on its own -
#                            it leaves the controls row (time picker, refresh,
#                            and any template-variable pickers) on screen.
#                            Use ?kiosk instead if it is the FIRST parameter.
#     &kiosk=tv              older half-way mode that KEEPS the top bar - not this.
#     &_dash.hideTimePicker=true   removes the time range + refresh control.
#     &_dash.hideVariables=true    removes the template-variable pickers, i.e.
#                            the "Interface: wan0 wan1" style row. Only needed on
#                            dashboards that actually have variables. Hiding a
#                            picker does NOT unset the variable, so the
#                            &var-...= values in the URL still apply.
#     &refresh=1m            how often Grafana re-queries (30s, 1m, 5m, auto...).
#                            A panel with this needs no {F5} entry in the
#                            rotation script - it refreshes itself.
#
# Measured on a real wall: &kiosk alone still showed the variable picker and the
# time controls; adding the two _dash flags is what gives a genuinely bare panel.
#
# Note that Firefox's own --kiosk is a SEPARATE thing: that removes the *browser*
# chrome (tabs, address bar). Both are needed - browser kiosk alone still leaves
# Grafana's own UI on screen.
#
# The entries below are EXAMPLES. Replace the hosts, dashboard UIDs and
# coordinates with your own.
$Panels = @(
    @{ Desktop     = 2
       Name        = 'Grafana - infrastructure overview'
       Program     = 'firefox.exe'
       Arguments   = '-new-window --kiosk http://grafana.example.lan:3000/d/000000001/infrastructure-overview?orgId=1&from=now-5m&to=now&timezone=browser&refresh=5s&kiosk&_dash.hideTimePicker=true'
       ProcessName = 'firefox'
       FullScreenKeys = '' }

    @{ Desktop     = 3
       Name        = 'Grafana - WAN monitor stats'
       Program     = 'firefox.exe'
       Arguments   = '-new-window --kiosk http://grafana.example.lan:3000/d/000000002/wan-monitor-stats?orgId=1&from=now-6h&to=now&timezone=browser&refresh=auto&kiosk&_dash.hideTimePicker=true'
       ProcessName = 'firefox'
       FullScreenKeys = '' }

    @{ Desktop     = 4
       Name        = 'Grafana - firewall and IPS'
       Program     = 'firefox.exe'
       Arguments   = '-new-window --kiosk http://grafana.example.lan:3000/d/000000003/firewall-and-ips?orgId=1&from=now-6h&to=now&timezone=browser&var-iface=wan0&var-iface=wan1&refresh=1m&kiosk&_dash.hideTimePicker=true&_dash.hideVariables=true'
       ProcessName = 'firefox'
       FullScreenKeys = '' }

    @{ Desktop     = 5
       Name        = 'Grafana - reverse proxy'
       Program     = 'firefox.exe'
       Arguments   = '-new-window --kiosk http://grafana.example.lan:3000/d/000000004/reverse-proxy?orgId=1&from=now-24h&to=now&timezone=browser&var-site=$__all&refresh=1m&kiosk&_dash.hideTimePicker=true&_dash.hideVariables=true'
       ProcessName = 'firefox'
       FullScreenKeys = '' }

    @{ Desktop     = 6
       Name        = 'Windy - satellite'
       Program     = 'firefox.exe'
       Arguments   = '-new-window --kiosk https://www.windy.com/-Satellite-satellite?satellite,39.828,-98.579,5'
       ProcessName = 'firefox'
       FullScreenKeys = '' }

    @{ Desktop     = 7
       Name        = 'MyRadar Pro'
       Program     = 'C:\Scripts\MyRadar.lnk'
       Arguments   = ''
       ProcessName = 'MyRadar.Windows.Pro'
       FullScreenKeys = '{F11}' }

    @{ Desktop     = 8
       Name        = 'FlightRadar24'
       Program     = 'firefox.exe'
       Arguments   = '-new-window --kiosk https://www.flightradar24.com/39.83,-98.58/8'
       ProcessName = 'firefox'
       FullScreenKeys = '' }
)

# --- Logging -----------------------------------------------------------------
# Writes to C:\Scripts\Logs\<source>-<date>.log and echoes in the house colours.
function Write-BoardLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'VAR')][string]$Level = 'INFO',
        [string]$Source = 'board'
    )
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $file = Join-Path $LogDir ('{0}-{1}.log' -f $Source, (Get-Date -Format 'yyyyMMdd'))
    try { Add-Content -Path $file -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
    $colour = switch ($Level) {
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'VAR'   { 'Magenta' }
        default { 'Cyan' }
    }
    Write-Host $line -ForegroundColor $colour
}

# Echo the effective configuration in purple, per house convention.
function Write-BoardConfig {
    param([string]$Source = 'board')
    Write-BoardLog "ScriptRoot       = $ScriptRoot"       'VAR' $Source
    Write-BoardLog "LogDir           = $LogDir"           'VAR' $Source
    Write-BoardLog "AhkExe           = $AhkExe"           'VAR' $Source
    Write-BoardLog "TotalDesktops    = $TotalDesktops"    'VAR' $Source
    Write-BoardLog "Rotation range   = $FirstDesktop..$LastDesktop" 'VAR' $Source
    Write-BoardLog "LaunchTimeoutSec = $LaunchTimeoutSec" 'VAR' $Source
    Write-BoardLog "Panels defined   = $($Panels.Count)"  'VAR' $Source
}

function Remove-OldBoardLogs {
    param([string]$Source = 'board')
    if (-not (Test-Path $LogDir)) { return }
    $cutoff = (Get-Date).AddDays(-$LogRetentionDays)
    Get-ChildItem $LogDir -Filter '*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object {
            Write-BoardLog "pruning old log $($_.Name)" 'INFO' $Source
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        }
}

# --- Launching ---------------------------------------------------------------
# Runs the AHK helper, which switches to the target desktop, starts the program
# and waits for its window to actually appear before exiting. We block on the
# helper rather than sleeping a guessed number of seconds.
function Open-OnDesktop {
    param(
        [Parameter(Mandatory = $true)][int]$Desktop,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Program,
        [string]$Arguments = '',
        [string]$FullScreenKeys = '',
        [string]$Source = 'board'
    )
    if (-not (Test-Path $AhkExe))       { Write-BoardLog "AutoHotkey not found at $AhkExe" 'ERROR' $Source; return $false }
    if (-not (Test-Path $LaunchHelper)) { Write-BoardLog "launch helper missing at $LaunchHelper" 'ERROR' $Source; return $false }

    $cmdArgs = '"{0}" {1} "{2}" "{3}" "{4}"' -f $LaunchHelper, $Desktop, $Program, $Arguments, $FullScreenKeys
    Write-BoardLog "launching '$Name' on desktop $Desktop" 'INFO' $Source
    try {
        $proc = Start-Process -FilePath $AhkExe -ArgumentList $cmdArgs -PassThru -ErrorAction Stop
    } catch {
        Write-BoardLog "failed to start helper for '$Name': $($_.Exception.Message)" 'ERROR' $Source
        return $false
    }

    if (-not $proc.WaitForExit($LaunchTimeoutSec * 1000)) {
        Write-BoardLog "'$Name' did not appear within ${LaunchTimeoutSec}s - abandoning helper" 'WARN' $Source
        try { $proc | Stop-Process -Force -ErrorAction SilentlyContinue } catch { }
        return $false
    }

    # Helper exit codes: 0 ok, 1 DLL load failed, 2 Run failed, 3 no window appeared
    switch ($proc.ExitCode) {
        0       { Write-BoardLog "'$Name' up on desktop $Desktop" 'OK' $Source; return $true }
        1       { Write-BoardLog "'$Name' failed: VirtualDesktopAccessor.dll would not load" 'ERROR' $Source }
        2       { Write-BoardLog "'$Name' failed: could not run '$Program'" 'ERROR' $Source }
        3       { Write-BoardLog "'$Name' started but no window appeared" 'WARN' $Source }
        4       { Write-BoardLog "'$Name' is up but would not go full screen" 'WARN' $Source }
        default { Write-BoardLog "'$Name' helper exited with code $($proc.ExitCode)" 'WARN' $Source }
    }
    return $false
}

# --- Window / desktop inspection ---------------------------------------------
# Firefox keeps every kiosk window under one process, so Get-Process
# MainWindowHandle only ever reports one of them. Enumerate top-level windows
# directly instead.
if (-not ('BoardWindows' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class BoardWindow {
    public IntPtr Handle;
    public uint Pid;
    public int X, Y, W, H;
}

public class BoardWindows {
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc cb, IntPtr p);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr h, out RECT r);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }

    public static BoardWindow[] TopLevel() {
        List<BoardWindow> found = new List<BoardWindow>();
        EnumWindows(delegate(IntPtr h, IntPtr p) {
            if (IsWindowVisible(h) && GetWindowTextLength(h) > 0) {
                uint pid;
                GetWindowThreadProcessId(h, out pid);
                RECT r;
                GetWindowRect(h, out r);
                BoardWindow w = new BoardWindow();
                w.Handle = h;
                w.Pid = pid;
                w.X = r.L; w.Y = r.T; w.W = r.R - r.L; w.H = r.B - r.T;
                found.Add(w);
            }
            return true;
        }, IntPtr.Zero);
        return found.ToArray();
    }
}
'@
}

# Returns a hashtable of desktop number (1-based) -> array of entries describing
# the windows there: @{ ProcessName; FullScreen }. Geometry is read in whatever
# coordinate space this process sees (PowerShell is DPI-unaware, so a 4K screen
# reports as 1920x1080) - that is fine because the screen bounds come from the
# same place, so the comparison stays consistent.
function Get-DesktopOccupancy {
    param([string]$Source = 'board')
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds

    $map = @{}
    $pidNames = @{}
    foreach ($p in Get-Process -ErrorAction SilentlyContinue) { $pidNames[[uint32]$p.Id] = $p.ProcessName }

    foreach ($w in [BoardWindows]::TopLevel()) {
        $name = $pidNames[$w.Pid]
        if (-not $name) { continue }
        try {
            $desk = Get-DesktopFromWindow -Hwnd $w.Handle -ErrorAction Stop
            $num  = (Get-DesktopIndex -Desktop $desk) + 1
        } catch { continue }

        # A *maximised* window sits a few pixels off-screen and keeps its title
        # bar, so requiring the origin to be within 2px of 0,0 excludes it.
        $full = ([Math]::Abs($w.X) -le 2 -and [Math]::Abs($w.Y) -le 2 -and
                 $w.W -ge ($screen.Width - 2) -and $w.H -ge ($screen.Height - 2))

        if (-not $map.ContainsKey($num)) { $map[$num] = @() }
        $map[$num] += [pscustomobject]@{ ProcessName = $name; FullScreen = $full; Handle = $w.Handle; Width = $w.W; Height = $w.H; X = $w.X; Y = $w.Y }
    }
    return $map
}

# Re-applies a panel's fullscreen key WITHOUT relaunching it, for a panel that
# came up windowed. Uses the launcher's repair-only mode (empty program).
function Repair-PanelFullScreen {
    param(
        [Parameter(Mandatory = $true)][int]$Desktop,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$FullScreenKeys,
        [Parameter(Mandatory = $true)][System.IntPtr]$Hwnd,
        [string]$Source = 'board'
    )
    # The handle is passed through so the helper acts on exactly this window.
    $cmdArgs = '"{0}" {1} "" "{2}" "{3}"' -f $LaunchHelper, $Desktop, [int64]$Hwnd, $FullScreenKeys
    Write-BoardLog "'$Name' on desktop $Desktop is not full screen - re-applying $FullScreenKeys" 'WARN' $Source
    try {
        $proc = Start-Process -FilePath $AhkExe -ArgumentList $cmdArgs -PassThru -ErrorAction Stop
    } catch {
        Write-BoardLog "could not start the fullscreen repair for '$Name': $($_.Exception.Message)" 'ERROR' $Source
        return $false
    }
    if (-not $proc.WaitForExit(60 * 1000)) {
        try { $proc | Stop-Process -Force -ErrorAction SilentlyContinue } catch { }
        Write-BoardLog "fullscreen repair for '$Name' timed out" 'WARN' $Source
        return $false
    }
    if ($proc.ExitCode -eq 0) { Write-BoardLog "'$Name' is full screen again" 'OK' $Source; return $true }
    Write-BoardLog "fullscreen repair for '$Name' failed (exit $($proc.ExitCode))" 'WARN' $Source
    return $false
}


# --- Panel index -------------------------------------------------------------
# The rotation script's F3 picker needs the panel names, but it is AutoHotkey and
# cannot read this file. Publish a simple "desktop|name" index for it so the
# manifest stays the single source of truth.
function Write-PanelIndex {
    param([string]$Source = 'board')
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $lines = foreach ($p in ($Panels | Sort-Object { $_.Desktop })) { '{0}|{1}' -f $p.Desktop, $p.Name }
    try {
        Set-Content -Path $PanelIndexFile -Value $lines -Encoding ASCII -ErrorAction Stop
        Write-BoardLog "panel index written ($($Panels.Count) panels)" 'INFO' $Source
    } catch {
        Write-BoardLog "could not write panel index: $($_.Exception.Message)" 'WARN' $Source
    }
}

# --- Hold state --------------------------------------------------------------
# Written by DesktopSwitchingFunctions.ahk when F3 holds a panel. Returns $null
# when nothing is held or the hold has already expired.
function Get-ActiveHold {
    if (-not (Test-Path $HoldStateFile)) { return $null }
    $kv = @{}
    foreach ($line in (Get-Content $HoldStateFile -ErrorAction SilentlyContinue)) {
        if ($line -match '^\s*([^=]+)=(.*)$') { $kv[$matches[1].Trim()] = $matches[2].Trim() }
    }
    if (-not $kv.ContainsKey('desktop')) { return $null }
    $forever = $kv['forever'] -eq '1'
    $until = $null
    if (-not $forever) {
        if (-not $kv['until']) { return $null }
        try { $until = [datetime]::ParseExact($kv['until'], 'yyyyMMddHHmmss', $null) } catch { return $null }
        if ($until -le (Get-Date)) { return $null }
    }
    return [pscustomobject]@{ Desktop = [int]$kv['desktop']; Forever = $forever; Until = $until }
}
