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

# ── Send JSON using python3 (built-in on macOS, handles the 8-byte header correctly) ──
send_payload() {
    local ip="$1" port="$2" json="$3"
    python3 - "$ip" "$port" "$json" <<'PYEOF'
import sys, socket, json as _json

ip   = sys.argv[1]
port = int(sys.argv[2])
data = sys.argv[3].encode("utf-8")

try:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(10)
        s.connect((ip, port))
        s.sendall(len(data).to_bytes(8, "big") + data)
    print("ok")
except ConnectionRefusedError:
    print(f"fail:refused")
except socket.timeout:
    print("fail:timeout")
except OSError as e:
    print(f"fail:{e}")
PYEOF
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

    # Build JSON using python3 for correct escaping
    local json
    json=$(python3 - "$pid" "$name" "$exe" "$cmdline" "$cwd" <<'PYEOF'
import sys, json, subprocess, shlex

pid     = int(sys.argv[1])
name    = sys.argv[2]
exe     = sys.argv[3]
cmdline = shlex.split(sys.argv[4])
cwd     = sys.argv[5]

# Try to grab env from ps eww (approximate on macOS)
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

payload = {
    "pid":     pid,
    "name":    name,
    "exe":     exe,
    "cmdline": cmdline,
    "cwd":     cwd,
    "environ": environ,
}
print(json.dumps(payload))
PYEOF
)

    log "── Payload: ${#json} bytes ──" "$SUBTLE"

    local kill_result; kill_result=$(kill_process "$pid")
    log "Local process killed: $kill_result" "$YELLOW"

    log "Sending to $ip:$port …" "$CYAN"
    local result; result=$(send_payload "$ip" "$port" "$json")

    if [[ "$result" == "ok" ]]; then
        log "✓  Sent ${#json} bytes to $ip:$port" "$GREEN" bold
        ((TRANSFERS++))
        log "Total transfers this session: $TRANSFERS" "$GREEN"
    else
        log "✗  Send failed — $result" "$RED" bold
        log "    Check: is the receiver running? Is the IP/port correct?" "$RED"
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
