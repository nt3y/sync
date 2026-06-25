#!/usr/bin/env bash
# LoL Game Relay — SENDER (macOS) — NO EXTRA DEPENDENCIES
# Uses only tools built into macOS: bash, ps, lsof, awk, python3 (pre-installed)

DEFAULT_RECEIVER_IP="192.168.1.XXX"
DEFAULT_RECEIVER_PORT="54321"
POLL_INTERVAL=1
CMDLINE_WAIT_TIMEOUT=10
MIN_ARGS=5

RESET="\033[0m"; BOLD="\033[1m"; RED="\033[91m"; GREEN="\033[92m"
YELLOW="\033[93m"; CYAN="\033[96m"; GOLD="\033[33m"; SUBTLE="\033[90m"; WHITE="\033[97m"

WATCHING=0
TRANSFERS=0
declare -A SEEN_PIDS

log() {
    local ts; ts=$(date +%H:%M:%S)
    local style="${3:+$BOLD}${2:-}"
    printf "${SUBTLE}[%s]${RESET}  ${style}%s${RESET}\n" "$ts" "$1"
}

banner() {
    echo
    printf "${GOLD}${BOLD}%s${RESET}\n" "========================================================"
    printf "${GOLD}${BOLD}  ⚡  LoL RELAY  ·  SENDER  [macOS]${RESET}\n"
    printf "${GOLD}${BOLD}%s${RESET}\n" "========================================================"
    printf "${SUBTLE}  Host: %s${RESET}\n" "$(hostname)"
    echo
}

find_game_pids() {
    ps aux 2>/dev/null | awk '
        tolower($0) ~ /leagueoflegends/ &&
        tolower($0) !~ /leagueclient/ &&
        tolower($0) !~ /leagueclientux/ &&
        tolower($0) !~ /riotclientservices/ &&
        tolower($0) !~ /riotclientux/ &&
        tolower($0) !~ /patcher/ &&
        tolower($0) !~ /crashhandler/ &&
        $0 !~ /awk/ &&
        $0 !~ /lol_sender/ {print $2}'
}

get_cmdline() { ps -p "$1" -o command= 2>/dev/null; }
get_exe()     { ps -p "$1" -o comm=    2>/dev/null; }
get_cwd()     { lsof -p "$1" -a -d cwd -Fn 2>/dev/null | awk '/^n/{sub(/^n/,""); print; exit}'; }
count_args()  { echo "$1" | awk '{print NF}'; }

wait_for_full_cmdline() {
    local pid="$1"
    local deadline=$((SECONDS + CMDLINE_WAIT_TIMEOUT))
    while [[ $SECONDS -lt $deadline ]]; do
        local cmdline; cmdline=$(get_cmdline "$pid")
        local n; n=$(count_args "$cmdline")
        if [[ $n -ge $MIN_ARGS ]]; then echo "$cmdline"; return 0; fi
        log "  Waiting for args … ($n so far)" "$SUBTLE"
        sleep 0.3
    done
    return 1
}

kill_process() {
    local pid="$1"
    kill -0 "$pid" 2>/dev/null || { echo "already gone"; return; }
    kill -TERM "$pid" 2>/dev/null
    for _ in $(seq 1 10); do
        sleep 0.5
        kill -0 "$pid" 2>/dev/null || { echo "SIGTERM — graceful"; return; }
    done
    kill -KILL "$pid" 2>/dev/null && { echo "SIGKILL — forced"; return; }
    sudo kill -9 "$pid" 2>/dev/null && { echo "killed via sudo"; return; }
    echo "ACCESS DENIED — try: sudo bash lol_sender.sh"
}

# ── Collect process info and build JSON ───────────────────────────────────────
capture_and_relay() {
    local pid="$1" ip="$2" port="$3"
    local name; name=$(get_exe "$pid")

    log "Game process found:  PID=$pid  Name=$name" "$GREEN" bold
    log "Waiting for full args (max ${CMDLINE_WAIT_TIMEOUT}s) …" "$YELLOW"

    local cmdline
    if ! cmdline=$(wait_for_full_cmdline "$pid"); then
        log "⚠  Timeout — process may have exited or args are restricted." "$RED"
        return
    fi

    local n; n=$(count_args "$cmdline")
    log "Args ready: $n tokens" "$GREEN"

    log "── Launch Arguments ──" "$GOLD" bold
    local i=0
    while IFS= read -r arg; do
        [[ -z "$arg" ]] && continue
        local c="$WHITE"; [[ $i -eq 0 ]] && c="$GOLD"
        log "  [$i]  $arg" "$c"
        ((i++))
    done < <(echo "$cmdline" | tr ' ' '\n')

    local exe;  exe=$(get_exe "$pid")
    local cwd;  cwd=$(get_cwd "$pid")

    # Write raw values to temp files so Python reads them safely (no shell escaping issues)
    local tmpdir; tmpdir=$(mktemp -d)
    printf '%s' "$cmdline" > "$tmpdir/cmdline.txt"
    printf '%s' "$name"    > "$tmpdir/name.txt"
    printf '%s' "$exe"     > "$tmpdir/exe.txt"
    printf '%s' "$cwd"     > "$tmpdir/cwd.txt"
    printf '%d' "$pid"     > "$tmpdir/pid.txt"

    # Build JSON — reads everything from temp files, no argv string passing
    local json
    json=$(python3 <<PYEOF
import json, subprocess, shlex, os

tmpdir  = "$tmpdir"
pid     = int(open(tmpdir+"/pid.txt").read().strip())
name    = open(tmpdir+"/name.txt").read()
exe     = open(tmpdir+"/exe.txt").read()
cwd     = open(tmpdir+"/cwd.txt").read()
raw_cmd = open(tmpdir+"/cmdline.txt").read()

try:
    cmdline = shlex.split(raw_cmd)
except ValueError:
    cmdline = raw_cmd.split()

environ = {}
try:
    out = subprocess.check_output(["ps", "eww", "-p", str(pid)], text=True, stderr=subprocess.DEVNULL)
    for line in out.splitlines()[1:]:
        for token in line.split():
            if '=' in token:
                k, _, v = token.partition('=')
                if k.replace('_','').isalnum():
                    environ[k] = v
except Exception:
    pass

payload = {"pid": pid, "name": name, "exe": exe, "cmdline": cmdline, "cwd": cwd, "environ": environ}
print(json.dumps(payload))
PYEOF
)

    rm -rf "$tmpdir"

    local json_bytes=${#json}
    log "── Payload: $json_bytes bytes ──" "$SUBTLE"

    if [[ -z "$json" || "$json" == "null" ]]; then
        log "✗  Failed to build JSON payload" "$RED" bold
        return
    fi

    local kill_result; kill_result=$(kill_process "$pid")
    log "Local process killed: $kill_result" "$YELLOW"

    log "Sending to $ip:$port …" "$CYAN"

    # Write JSON to temp file so Python send script reads it safely too
    local jsontmp; jsontmp=$(mktemp)
    printf '%s' "$json" > "$jsontmp"

    local result
    result=$(python3 <<PYEOF
import socket, os, sys

ip      = "$ip"
port    = $port
jsontmp = "$jsontmp"

with open(jsontmp, "rb") as f:
    data = f.read()

try:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(10)
        s.connect((ip, port))
        s.sendall(len(data).to_bytes(8, "big") + data)
    print("ok")
except ConnectionRefusedError:
    print("fail:Connection refused — is the receiver running on {}:{}?".format(ip, port))
except socket.timeout:
    print("fail:Timeout connecting to {}:{}".format(ip, port))
except OSError as e:
    print("fail:{}".format(e))
PYEOF
)
    rm -f "$jsontmp"

    if [[ "$result" == "ok" ]]; then
        log "✓  Sent $json_bytes bytes to $ip:$port" "$GREEN" bold
        ((TRANSFERS++))
        log "Total transfers this session: $TRANSFERS" "$GREEN"
    else
        local errmsg="${result#fail:}"
        log "✗  Send failed — $errmsg" "$RED" bold
    fi
}

# ── Watch loop ────────────────────────────────────────────────────────────────
watch_loop() {
    local ip="$1" port="$2"
    log "Watcher started — waiting for game …" "$YELLOW" bold

    while [[ $WATCHING -eq 1 ]]; do
        local pids; pids=$(find_game_pids)
        if [[ -n "$pids" ]]; then
            while IFS= read -r pid; do
                [[ -z "$pid" ]] && continue
                if [[ -z "${SEEN_PIDS[$pid]:-}" ]]; then
                    SEEN_PIDS[$pid]=1
                    capture_and_relay "$pid" "$ip" "$port" &
                fi
            done <<< "$pids"
        fi
        sleep "$POLL_INTERVAL"
    done
    log "Watcher stopped." "$SUBTLE"
}

cleanup() {
    WATCHING=0; echo
    log "Interrupted — exiting." "$YELLOW"
    kill 0 2>/dev/null; exit 0
}
trap cleanup SIGINT SIGTERM

# ── Main ──────────────────────────────────────────────────────────────────────
banner

printf "${GOLD}── Configuration ──────────────────────────────${RESET}\n"
printf "${CYAN}Receiver IP  (Windows PC LAN IP)${RESET} [${SUBTLE}%s${RESET}]: " "$DEFAULT_RECEIVER_IP"
read -r input_ip;   RECEIVER_IP="${input_ip:-$DEFAULT_RECEIVER_IP}"

printf "${CYAN}Receiver Port${RESET} [${SUBTLE}%s${RESET}]: " "$DEFAULT_RECEIVER_PORT"
read -r input_port; RECEIVER_PORT="${input_port:-$DEFAULT_RECEIVER_PORT}"

echo
log "Target:  $RECEIVER_IP:$RECEIVER_PORT" "$CYAN" bold
log "Host:    $(hostname)" "$CYAN"
echo

printf "${GOLD}── Commands ────────────────────────────────────${RESET}\n"
printf "  ${GREEN}s${RESET}      → Start watching\n"
printf "  ${CYAN}status${RESET} → Show status\n"
printf "  ${RED}q${RESET}      → Quit\n"
printf "  ${SUBTLE}Press Ctrl+C at any time to exit${RESET}\n"
echo

WATCH_PID=""

while true; do
    printf "${GOLD}>${RESET} "
    read -r cmd
    case "$cmd" in
        s|start)
            if [[ $WATCHING -eq 1 ]]; then
                log "Already watching!" "$YELLOW"
            else
                WATCHING=1
                declare -A SEEN_PIDS=()
                watch_loop "$RECEIVER_IP" "$RECEIVER_PORT" &
                WATCH_PID=$!
            fi ;;
        stop)
            if [[ $WATCHING -eq 1 ]]; then
                WATCHING=0
                [[ -n "$WATCH_PID" ]] && kill "$WATCH_PID" 2>/dev/null
                WATCH_PID=""
            else
                log "Not watching." "$SUBTLE"
            fi ;;
        status)
            local_state="${RED}${BOLD}IDLE${RESET}"
            [[ $WATCHING -eq 1 ]] && local_state="${GREEN}${BOLD}WATCHING${RESET}"
            printf "${SUBTLE}[$(date +%H:%M:%S)]${RESET}  Status: ${local_state}  |  Transfers: ${TRANSFERS}\n" ;;
        help)
            printf "  ${GREEN}s${RESET}      — start watching\n"
            printf "  ${RED}stop${RESET}   — stop watching\n"
            printf "  ${CYAN}status${RESET} — show current status\n"
            printf "  ${RED}q${RESET}      — quit\n" ;;
        q|quit|exit)
            WATCHING=0
            [[ -n "$WATCH_PID" ]] && kill "$WATCH_PID" 2>/dev/null
            log "Goodbye." "$SUBTLE"; break ;;
        "") ;;
        *) log "Unknown command '$cmd'. Type 'help'." "$SUBTLE" ;;
    esac
done
