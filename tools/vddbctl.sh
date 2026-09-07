#!/usr/bin/env bash
# vddbctl.sh - WinVDDB remote control, run from a Linux/macOS box over SSH.
#
# The display's F2/F3 hotkeys only exist at the keyboard in front of it, and an
# SSH session to Windows lands in Session 0, which cannot touch the interactive
# desktop. So this drops a command file in the board's log folder and the
# rotation script's request poller (DesktopSwitchingFunctions.ahk) picks it up
# within ~2 s and answers in hold.result. Every command maps onto something
# F2/F3 already do - this adds a way in, not new behaviour.
#
#   vddbctl                          interactive picker
#   vddbctl status                   what the board is doing right now
#   vddbctl hold <desktop> [hours]   hold one panel (hours may be a number or "forever"; default 4)
#   vddbctl release                  release the hold / resume rotation
#   vddbctl pause                    park on desktop 1 with the taskbar showing
#   vddbctl resume                   same as release
#
# Requires: ssh with key-based auth to the display, and python3 locally.
# Every setting below can be overridden from the environment, so you can keep
# the script unmodified and export VDDB_HOST / VDDB_USER in your shell instead.
set -uo pipefail

# --- Configuration -----------------------------------------------------------
KIOSK_HOST="${VDDB_HOST:-192.168.1.50}"   # the display's address or hostname, e.g. 192.168.1.50
KIOSK_USER="${VDDB_USER:-kiosk}"          # SSH user on the display, e.g. kiosk
LOG_DIR="${VDDB_LOGDIR:-C:\\Scripts\\Logs}"    # where the board keeps its state files, e.g. C:\Scripts\Logs
FIRST_PANEL=2                       # lowest desktop that can hold a panel, e.g. 2
MAX_PANEL=10                        # highest desktop the picker offers, e.g. 10
REPLY_TIMEOUT=12                    # seconds to wait for the board to answer, e.g. 12
DEFAULT_HOURS=4                     # hold length used when none is given, e.g. 4
SSH_OPTS=(-n -o BatchMode=yes -o ConnectTimeout=5)   # ssh flags: no stdin, fail fast, never prompt

# --- Colours (house convention) ----------------------------------------------
C_INFO=$'\e[36m'    # cyan    - info
C_WARN=$'\e[33m'    # yellow  - warning
C_OK=$'\e[32m'      # green   - success
C_ERR=$'\e[31m'     # red     - failure
C_TXT=$'\e[37m'     # white   - normal text
C_VAR=$'\e[35m'     # magenta - variable echo
C_DIM=$'\e[90m'
C_RST=$'\e[0m'

# --- State filled in by fetch_status -----------------------------------------
declare -A PANEL_NAME=()
ST_SUMMARY=""; ST_HOLD=0; ST_PAUSED=0; ST_HEARTBEAT=-1; ST_ROTATION=0; ST_REACHABLE=0

# Run a PowerShell script on the display. Sent as -EncodedCommand because the
# kiosk's sshd shell is already PowerShell, so a plain command string gets
# parsed twice and nested quotes are mangled.
ps_run() {
    local script="$1" enc
    script="${script//@LOGDIR@/$LOG_DIR}"
    enc=$(printf '%s' "$script" | python3 -c \
        "import sys,base64;print(base64.b64encode(sys.stdin.read().encode('utf-16-le')).decode())") || return 1
    ssh "${SSH_OPTS[@]}" "${KIOSK_USER}@${KIOSK_HOST}" "powershell -NoProfile -EncodedCommand $enc" 2>/dev/null
}

# Ask the board what it is doing, and for the panel names, in one round trip.
fetch_status() {
    local out section line
    out=$(ps_run "$(cat <<'PS'
$ErrorActionPreference = 'SilentlyContinue'
$log = '@LOGDIR@'
Write-Output '<<heartbeat>>'
$hb = Join-Path $log 'rotation.heartbeat'
if (Test-Path $hb) { [int]((Get-Date) - (Get-Item $hb).LastWriteTime).TotalSeconds } else { '-1' }
Write-Output '<<rotation>>'
@(Get-CimInstance Win32_Process -Filter "Name = 'AutoHotkeyU64.exe'" |
    Where-Object { $_.CommandLine -like '*DesktopSwitchingFunctions*' }).Count
Write-Output '<<status>>'
Get-Content (Join-Path $log 'rotation.status')
Write-Output '<<panels>>'
Get-Content (Join-Path $log 'panels.index')
PS
)") || return 1

    PANEL_NAME=(); ST_SUMMARY=""; ST_HOLD=0; ST_PAUSED=0; ST_HEARTBEAT=-1; ST_ROTATION=0
    ST_REACHABLE=1; section=""
    while IFS= read -r line; do
        line="${line%$'\r'}"
        case "$line" in
            '<<'*'>>') section="${line//[<>]/}"; continue ;;
        esac
        [[ -z $line ]] && continue
        case "$section" in
            heartbeat) ST_HEARTBEAT="$line" ;;
            rotation)  ST_ROTATION="$line" ;;
            status)
                case "$line" in
                    summary=*) ST_SUMMARY="${line#summary=}" ;;
                    hold=*)    ST_HOLD="${line#hold=}" ;;
                    paused=*)  ST_PAUSED="${line#paused=}" ;;
                esac ;;
            panels)
                [[ $line == *"|"* ]] && PANEL_NAME["${line%%|*}"]="${line#*|}" ;;
        esac
    done <<< "$out"
    return 0
}

# Drop one command and wait for the rotation script to answer it.
send_cmd() {
    local cmd="$1" desktop="${2:-0}" hours="${3:-0}" id out ok msg script
    id="od$(date +%s)$RANDOM"
    script="$(cat <<'PS'
$ErrorActionPreference = 'SilentlyContinue'
$log = '@LOGDIR@'
$req = Join-Path $log 'hold.request'
$tmp = Join-Path $log 'hold.request.tmp'
$res = Join-Path $log 'hold.result'
Remove-Item $res -Force -ErrorAction SilentlyContinue
Set-Content -Path $tmp -Encoding ASCII -Value @('id=@ID@','cmd=@CMD@','desktop=@DESKTOP@','hours=@HOURS@')
Move-Item -Path $tmp -Destination $req -Force     # rename, so the poller never reads a half-written file
$deadline = (Get-Date).AddSeconds(@TIMEOUT@)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 400
    if (Test-Path $res) {
        $r = Get-Content $res -Raw
        if ($r -match 'id=@ID@') { Write-Output $r; exit 0 }
    }
}
Write-Output 'ok=0'
Write-Output 'msg=No reply from the rotation script - is it running? (od status)'
exit 1
PS
)"
    script="${script//@ID@/$id}"
    script="${script//@CMD@/$cmd}"
    script="${script//@DESKTOP@/$desktop}"
    script="${script//@HOURS@/$hours}"
    script="${script//@TIMEOUT@/$REPLY_TIMEOUT}"

    out=$(ps_run "$script")
    if [[ -z $out ]]; then
        printf '%s\n' "${C_ERR}Could not reach ${KIOSK_USER}@${KIOSK_HOST}.${C_RST}" >&2
        return 1
    fi
    ok=0; msg="no message"
    while IFS= read -r line; do
        line="${line%$'\r'}"
        case "$line" in
            ok=*)  ok="${line#ok=}" ;;
            msg=*) msg="${line#msg=}" ;;
        esac
    done <<< "$out"

    if [[ $ok == 1 ]]; then
        printf '%s\n' "${C_OK}${msg}${C_RST}"
        return 0
    fi
    printf '%s\n' "${C_ERR}${msg}${C_RST}" >&2
    return 1
}

config_line() {
    printf '%s\n' "${C_VAR}${KIOSK_USER}@${KIOSK_HOST}  ${LOG_DIR}  panels ${FIRST_PANEL}-${MAX_PANEL}  reply timeout ${REPLY_TIMEOUT}s${C_RST}"
}

# One line on whether the rotation script is alive at all - every command here
# depends on it, and "no reply" is much clearer when you can see why.
health_line() {
    if (( ST_ROTATION < 1 )); then
        printf '%s\n' "${C_ERR}Rotation script is NOT running - no remote command will work.${C_RST}"
    elif (( ST_HEARTBEAT < 0 )); then
        printf '%s\n' "${C_WARN}Rotation is running but has never written a heartbeat.${C_RST}"
    elif (( ST_HEARTBEAT > 300 )); then
        printf '%s\n' "${C_WARN}Rotation heartbeat is ${ST_HEARTBEAT}s old - it looks frozen.${C_RST}"
    else
        printf '%s\n' "${C_INFO}Rotation healthy, heartbeat ${ST_HEARTBEAT}s ago.${C_RST}"
    fi
}

state_line() {
    local s="${ST_SUMMARY:-unknown (the board has not written rotation.status yet)}"
    if [[ $ST_HOLD != 0 ]]; then
        printf '%s\n' "${C_WARN}${s}${C_RST}"
    else
        printf '%s\n' "${C_TXT}${s}${C_RST}"
    fi
}

print_panels() {
    local d marker
    for (( d=FIRST_PANEL; d<=MAX_PANEL; d++ )); do
        [[ -z ${PANEL_NAME[$d]:-} ]] && continue
        if [[ $ST_HOLD == "$d" ]]; then
            marker="${C_WARN}held${C_RST}"
        else
            marker=""
        fi
        printf '   %s[%s]%s %s%s%s %s\n' \
            "$C_INFO" "$([[ $d == 10 ]] && echo 0 || echo "$d")" "$C_RST" \
            "$C_TXT" "${PANEL_NAME[$d]}" "$C_RST" "$marker"
    done
}

# Second step of the picker: how long to hold it.
ask_duration() {
    local d="$1" key hours
    printf '\n%s\n' "${C_INFO}Hold ${C_TXT}${PANEL_NAME[$d]}${C_INFO} for how long?${C_RST}"
    printf '%s\n' "   ${C_INFO}[1]${C_RST} 1 h   ${C_INFO}[2]${C_RST} 2 h   ${C_INFO}[4]${C_RST} 4 h   ${C_INFO}[8]${C_RST} 8 h   ${C_INFO}[9]${C_RST} 48 h   ${C_INFO}[f]${C_RST} forever   ${C_INFO}[c]${C_RST} custom   ${C_INFO}[Esc]${C_RST} cancel"
    read -rsn1 key
    case "$key" in
        1) hours=1 ;;  2) hours=2 ;;  4) hours=4 ;;  8) hours=8 ;;  9) hours=48 ;;
        f|F) hours=forever ;;
        c|C) printf '%s' "${C_INFO}hours: ${C_RST}"; read -r hours ;;
        *)   printf '%s\n' "${C_DIM}cancelled${C_RST}"; return 1 ;;
    esac
    printf '%s\n' "${C_VAR}desktop=${d} hours=${hours}${C_RST}"
    send_cmd hold "$d" "$hours"
}

tui() {
    local key d
    while :; do
        clear
        printf '%s\n' "${C_INFO}WinVDDB${C_RST}"
        config_line
        if ! fetch_status; then
            printf '\n%s\n' "${C_ERR}Cannot reach ${KIOSK_USER}@${KIOSK_HOST} over SSH.${C_RST}"
            printf '%s\n' "${C_DIM}[s] retry   [q] quit${C_RST}"
            read -rsn1 key || return 1
            [[ $key == q ]] && return 1
            continue
        fi
        echo
        health_line
        state_line
        echo
        print_panels
        echo
        printf '%s\n' "${C_DIM}[2-9,0] hold a panel   [r] release/resume   [p] pause on desktop 1   [s] refresh   [q] quit${C_RST}"
        read -rsn1 key || return 0
        case "$key" in
            q|Q) return 0 ;;
            s|S|'') continue ;;
            r|R) send_cmd release; pause_for_key ;;
            p|P) send_cmd pause;   pause_for_key ;;
            0)   d=10; try_hold "$d" ;;
            [2-9]) d="$key"; try_hold "$d" ;;
        esac
    done
}

try_hold() {
    local d="$1"
    if [[ -z ${PANEL_NAME[$d]:-} ]]; then
        printf '\n%s\n' "${C_WARN}Desktop ${d} has no panel configured.${C_RST}"
        pause_for_key
        return
    fi
    ask_duration "$d"
    pause_for_key
}

pause_for_key() {
    printf '%s' "${C_DIM}-- any key --${C_RST}"
    read -rsn1
}

usage() {
    awk 'NR>2 && /^#/ { sub(/^# ?/, ""); print; next } NR>2 { exit }' "$0"
}

main() {
    case "${1:-}" in
        "") tui ;;
        status)
            config_line
            fetch_status || { printf '%s\n' "${C_ERR}Cannot reach ${KIOSK_USER}@${KIOSK_HOST}.${C_RST}" >&2; exit 1; }
            health_line; state_line ;;
        hold)
            [[ -n ${2:-} ]] || { printf '%s\n' "${C_ERR}hold needs a desktop number.${C_RST}" >&2; exit 2; }
            printf '%s\n' "${C_VAR}desktop=${2} hours=${3:-$DEFAULT_HOURS}${C_RST}"
            send_cmd hold "$2" "${3:-$DEFAULT_HOURS}" ;;
        release|resume) send_cmd release ;;
        pause)          send_cmd pause ;;
        -h|--help|help) usage ;;
        *) printf '%s\n' "${C_ERR}Unknown command '$1'.${C_RST}" >&2; usage >&2; exit 2 ;;
    esac
}

main "$@"
