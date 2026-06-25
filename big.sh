#!/usr/bin/env bash
# LoL Game Relay — SENDER (macOS) — NO DEPENDENCIES
# Watches for League of Legends game process, captures launch args + env,
# sends over TCP to Windows receiver, then kills local process.
# Requirements: macOS with bash 3.2+ (pre-installed), no extra installs needed.

# ── Config ────────────────────────────────────────────────────────────────────
DEFAULT_RECEIVER_IP="192.168.1.XXX"
DEFAULT_RECEIVER_PORT="54321"
POLL_INTERVAL=1
CMDLINE_WAIT_TIMEOUT=10
MIN_ARGS=5

# ── Colors ────────────────────────────────────────────────────────────────────
RESET="\033[0m"; BOLD="\033[1m"; RED="\033[91m"; GREEN="\033[92m"
YELLOW="\033[93m"; CYAN="\033[96m"; GOLD="\033[33m"; SUBTLE="\033[90m"; WHITE="\033[97m"

# ── State ─────────────────────────────────────────────────────────────────────
WATCHING=0
TRANSFERS=0
declare -A SEEN_PIDS

# ── Logging ───────────────────────────────────────────────────────────────────
log() {
    local msg="$1" color="${2:-}" bold="${3:-}"
    local ts; ts=$(date +%H:%M:%S)
    local style="${bold:+$BOLD}${color}"
    printf "${SUBTLE}[%s]${RESET}  ${style}%s${RESET}\n" "$ts" "$msg"
}

banner() {
    echo
    printf "${GOLD}${BOLD}%s${RESET}\n" "========================================================"
    printf "${GOLD}${BOLD}  ⚡  LoL RELAY  ·  SENDER  [macOS]  —  SHELL${RESET}\n"
    printf "${GOLD}${BOLD}%s${RESET}\n" "========================================================"
    printf "${SUBTLE}  Host: %s${RESET}\n" "$(hostname)"
    echo
}

# ── Process helpers ───────────────────────────────────────────────────────────
find_game_pids() {
    # Returns PIDs of LoL game process (not client/launcher)
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

get_cmdline() {
    local pid="$1"
    # macOS: use ps to get full command line
    ps -p "$pid" -o command= 2>/dev/null
}

get_exe() {
    local pid="$1"
    ps -p "$pid" -o comm= 2>/dev/null
}

get_cwd() {
    local pid="$1"
    # lsof can get cwd on macOS
    lsof -p "$pid" -a -d cwd -Fn 2>/dev/null | awk '/^n/{sub(/^n/,""); print; exit}'
}

count_args() {
    # Count space-separated tokens in cmdline (rough)
    local cmdline="$1"
    echo "$cmdline" | awk '{print NF}'
}

wait_for_full_cmdline() {
    local pid="$1"
    local deadline=$((SECONDS + CMDLINE_WAIT_TIMEOUT))
    local cmdline arg_count

    while [[ $SECONDS -lt $deadline ]]; do
        cmdline=$(get_cmdline "$pid")
        arg_count=$(count_args "$cmdline")
        if [[ $arg_count -ge $MIN_ARGS ]]; then
            echo "$cmdline"
            return 0
        fi
        log "  Waiting for args … ($arg_count so far)" "$SUBTLE"
        sleep 0.3
    done
    return 1
}

kill_process() {
    local pid="$1"
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "already gone"
        return
    fi
    if kill -TERM "$pid" 2>/dev/null; then
        local i
        for i in $(seq 1 10); do
            sleep 0.5
            kill -0 "$pid" 2>/dev/null || { echo "SIGTERM — graceful"; return; }
        done
    fi
    if kill -KILL "$pid" 2>/dev/null; then
        sleep 0.5
        echo "SIGKILL — forced"
    else
        # Try sudo if permission denied
        if sudo kill -9 "$pid" 2>/dev/null; then
            echo "killed via sudo kill -9"
        else
            echo "ACCESS DENIED — try: sudo bash lol_sender.sh"
        fi
    fi
}

# ── JSON builder (no jq needed) ───────────────────────────────────────────────
json_escape() {
    # Escape a string for JSON
    local s="$1"
    s="${s//\\/\\\\}"   # backslash
    s="${s//\"/\\\"}"   # double quote
    s="${s//$'\n'/\\n}" # newline
    s="${s//$'\r'/\\r}" # carriage return
    s="${s//$'\t'/\\t}" # tab
    echo "$s"
}

build_json() {
    local pid="$1" name="$2" exe="$3" cmdline="$4" cwd="$5"
    local esc_name esc_exe esc_cmdline esc_cwd
    esc_name=$(json_escape "$name")
    esc_exe=$(json_escape "$exe")
    esc_cmdline=$(json_escape "$cmdline")
    esc_cwd=$(json_escape "$cwd")

    # Build cmdline JSON array from space-separated args
    local args_json="["
    local first=1
    # Use eval to split on spaces respecting quotes
    while IFS= read -r arg; do
        [[ -z "$arg" ]] && continue
        local esc_arg; esc_arg=$(json_escape "$arg")
        [[ $first -eq 0 ]] && args_json+=","
        args_json+="\"${esc_arg}\""
        first=0
    done < <(echo "$cmdline" | tr ' ' '\n')
    args_json+="]"

    # Collect env vars for this process via /proc equivalent on macOS
    # macOS doesn't expose /proc, use `ps eww` for env
    local env_json="{}"
    local env_raw
    env_raw=$(ps eww -p "$pid" 2>/dev/null | tail -1)
    if [[ -n "$env_raw" ]]; then
        # Extract KEY=VALUE pairs after the command section
        # ps eww output: cmd args   KEY=VAL KEY=VAL ...
        # This is approximate — get env vars after first KEY= pattern
        local env_section
        env_section=$(echo "$env_raw" | grep -oE '[A-Z_][A-Z0-9_]*=[^ ]+' | head -50)
        if [[ -n "$env_section" ]]; then
            env_json="{"
            local efirst=1
            while IFS= read -r pair; do
                [[ -z "$pair" ]] && continue
                local k="${pair%%=*}"
                local v="${pair#*=}"
                local ek; ek=$(json_escape "$k")
                local ev; ev=$(json_escape "$v")
                [[ $efirst -eq 0 ]] && env_json+=","
                env_json+="\"${ek}\":\"${ev}\""
                efirst=0
            done <<< "$env_section"
            env_json+="}"
        fi
    fi

    cat <<EOF
{"pid":${pid},"name":"${esc_name}","exe":"${esc_exe}","cmdline":${args_json},"cwd":"${esc_cwd}","environ":${env_json}}
EOF
}

# ── Network: send over TCP using /dev/tcp (bash built-in) ────────────────────
send_payload() {
    local ip="$1" port="$2" payload="$3"
    local byte_len=${#payload}

    # Encode length as 8-byte big-endian using printf + xxd trick
    # We'll send length as a plain text prefix "LEN:<n>\n" since
    # the receiver needs to be updated to match anyway.
    # If your receiver expects the original 8-byte binary prefix, use python3 -c below.

    # Try /dev/tcp first (bash built-in, works on macOS)
    {
        # Build the 8-byte big-endian length header the original receiver expects
        # Use python3 (built-in on macOS) just for this one line
        python3 -c "import sys; n=${byte_len}; sys.stdout.buffer.write(n.to_bytes(8,'big'))" 2>/dev/null
        printf '%s' "$payload"
    } > /dev/tcp/"$ip"/"$port" 2>/dev/null

    local status=$?
    if [[ $status -eq 0 ]]; then
        echo "ok"
    else
        echo "fail"
    fi
}

# ── Capture & relay ───────────────────────────────────────────────────────────
capture_and_relay() {
    local pid="$1" ip="$2" port="$3"

    local name; name=$(get_exe "$pid")
    log "Game process found:  PID=$pid  Name=$name" "$GREEN" "bold"
    log "Waiting for process to fully load args (max ${CMDLINE_WAIT_TIMEOUT}s) …" "$YELLOW"

    local cmdline
    if ! cmdline=$(wait_for_full_cmdline "$pid"); then
        log "⚠  Timeout waiting for args — process may have exited or args are restricted." "$RED"
        return
    fi

    local arg_count; arg_count=$(count_args "$cmdline")
    log "Args ready:  $arg_count tokens captured" "$GREEN"

    local exe; exe=$(get_exe "$pid")
    local cwd; cwd=$(get_cwd "$pid")

    log "── Launch Arguments ──" "$GOLD" "bold"
    local i=0
    while IFS= read -r arg; do
        [[ -z "$arg" ]] && continue
        local color="$WHITE"
        [[ $i -eq 0 ]] && color="$GOLD"
        log "  [$i]  $arg" "$color"
        ((i++))
    done < <(echo "$cmdline" | tr ' ' '\n')

    local json
    json=$(build_json "$pid" "$name" "$exe" "$cmdline" "$cwd")

    local json_len=${#json}
    log "── JSON payload: $json_len bytes ──" "$SUBTLE"

    # Kill local process
    local kill_result; kill_result=$(kill_process "$pid")
    log "Local process killed: $kill_result" "$YELLOW"

    # Send
    log "Sending to $ip:$port …" "$CYAN"
    local result; result=$(send_payload "$ip" "$port" "$json")

    if [[ "$result" == "ok" ]]; then
        log "✓  Sent $json_len bytes to $ip:$port" "$GREEN" "bold"
        ((TRANSFERS++))
        log "Total transfers this session: $TRANSFERS" "$GREEN"
    else
        log "✗  Failed to connect to $ip:$port — is the receiver running?" "$RED" "bold"
    fi
}

# ── Watch loop ────────────────────────────────────────────────────────────────
watch_loop() {
    local ip="$1" port="$2"
    log "Watcher started — waiting for game …" "$YELLOW" "bold"

    while [[ $WATCHING -eq 1 ]]; do
        local pids
        pids=$(find_game_pids)

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

# ── Cleanup ───────────────────────────────────────────────────────────────────
cleanup() {
    WATCHING=0
    echo
    log "Interrupted — exiting." "$YELLOW"
    # Kill any background subshells
    kill 0 2>/dev/null
    exit 0
}
trap cleanup SIGINT SIGTERM

# ── Main ──────────────────────────────────────────────────────────────────────
banner

printf "${GOLD}── Configuration ──────────────────────────────${RESET}\n"
printf "${CYAN}Receiver IP  (Windows PC LAN IP)${RESET} [${SUBTLE}%s${RESET}]: " "$DEFAULT_RECEIVER_IP"
read -r input_ip
RECEIVER_IP="${input_ip:-$DEFAULT_RECEIVER_IP}"

printf "${CYAN}Receiver Port${RESET} [${SUBTLE}%s${RESET}]: " "$DEFAULT_RECEIVER_PORT"
read -r input_port
RECEIVER_PORT="${input_port:-$DEFAULT_RECEIVER_PORT}"

echo
log "Target:  $RECEIVER_IP:$RECEIVER_PORT" "$CYAN" "bold"
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
            fi
            ;;
        stop)
            if [[ $WATCHING -eq 1 ]]; then
                WATCHING=0
                [[ -n "$WATCH_PID" ]] && kill "$WATCH_PID" 2>/dev/null
                WATCH_PID=""
            else
                log "Not watching." "$SUBTLE"
            fi
            ;;
        status)
            if [[ $WATCHING -eq 1 ]]; then
                printf "${SUBTLE}[$(date +%H:%M:%S)]${RESET}  Status: ${GREEN}${BOLD}WATCHING${RESET}  |  Transfers: ${TRANSFERS}\n"
            else
                printf "${SUBTLE}[$(date +%H:%M:%S)]${RESET}  Status: ${RED}${BOLD}IDLE${RESET}  |  Transfers: ${TRANSFERS}\n"
            fi
            ;;
        help)
            printf "  ${GREEN}s${RESET}      — start watching\n"
            printf "  ${RED}stop${RESET}   — stop watching\n"
            printf "  ${CYAN}status${RESET} — show current status\n"
            printf "  ${RED}q${RESET}      — quit\n"
            ;;
        q|quit|exit)
            WATCHING=0
            [[ -n "$WATCH_PID" ]] && kill "$WATCH_PID" 2>/dev/null
            log "Goodbye." "$SUBTLE"
            break
            ;;
        "")
            ;;
        *)
            log "Unknown command '$cmd'. Type 'help' for commands." "$SUBTLE"
            ;;
    esac
done
