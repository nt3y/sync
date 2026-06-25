#!/bin/bash

# LoL Game Relay — SENDER (macOS)
# ====================================================
# Pure Bash version for macOS.
# Requires: jq (brew install jq)

# --- ANSI Colors ---
RESET="\033[0m"
BOLD="\033[1m"
RED="\033[91m"
GREEN="\033[92m"
YELLOW="\033[93m"
CYAN="\033[96m"
GOLD="\033[33m"
SUBTLE="\033[90m"
WHITE="\033[97m"

# --- Defaults ---
DEFAULT_RECEIVER_IP="192.168.1.XXX"
DEFAULT_RECEIVER_PORT=54321
POLL_INTERVAL=1.0

GAME_KEYWORDS="leagueoflegends league of legends"
EXCLUDE_KEYWORDS="leagueclient leagueclientux riotclientservices riotclientux patcher crashhandler"

MIN_ARGS=5
CMDLINE_WAIT_TIMEOUT=10
CMDLINE_POLL=0.3

# --- Globals ---
_WATCHING=false
_SEEN_PIDS=""
_TRANSFERS=0

# --- Logging ---
log() {
    local msg="$1"
    local color="$2"
    local bold="$3"
    local ts=$(date +"%H:%M:%S")
    local style=""
    [ "$bold" = "true" ] && style="$BOLD"
    echo -e "${SUBTLE}[${ts}]${RESET}  ${style}${color}${msg}${RESET}"
}

banner() {
    echo -e "\n${GOLD}${BOLD}========================================================${RESET}"
    echo -e "${GOLD}${BOLD}  ⚡  LoL RELAY  ·  SENDER  [macOS]  —  TERMINAL${RESET}"
    echo -e "${GOLD}${BOLD}========================================================${RESET}"
    echo -e "${SUBTLE}  Host: $(hostname)${RESET}\n"
}

# --- Process helpers ---
is_game_process() {
    local pid="$1"
    local name=$(ps -p "$pid" -o comm= 2>/dev/null | tr '[:upper:]' '[:lower:]')
    local cmdline=$(ps -p "$pid" -o command= 2>/dev/null | tr '[:upper:]' '[:lower:]')
    local identity="$name $cmdline"

    local is_game=false
    for k in $GAME_KEYWORDS; do
        if [[ "$identity" == *"$k"* ]]; then
            is_game=true
            break
        fi
    done

    [ "$is_game" = "false" ] && return 1

    for k in $EXCLUDE_KEYWORDS; do
        if [[ "$identity" == *"$k"* ]]; then
            return 1
        fi
    done

    return 0
}

wait_for_full_cmdline() {
    local pid="$1"
    local start=$(date +%s)
    local deadline=$((start + CMDLINE_WAIT_TIMEOUT))

    while [ $(date +%s) -lt $deadline ]; do
        local current_cmdline=$(ps -p "$pid" -o command= 2>/dev/null)
        [ -z "$current_cmdline" ] && break
        
        local num_args=$(echo "$current_cmdline" | wc -w)
        if [ "$num_args" -ge $MIN_ARGS ]; then
            local elapsed=$(($(date +%s) - start))
            echo "$current_cmdline|$elapsed"
            return 0
        fi
        log "  Waiting for args … (${num_args} so far)" "$SUBTLE"
        sleep "$CMDLINE_POLL"
    done
    echo "|$CMDLINE_WAIT_TIMEOUT"
    return 1
}

collect_info() {
    local pid="$1"
    local full_cmdline="$2"
    
    local name=$(ps -p "$pid" -o comm= 2>/dev/null)
    local exe=$(ps -p "$pid" -o command= 2>/dev/null | awk '{print $1}')
    local cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')
    
    # Simple env capture
    local environ_json="{}"
    local ps_env=$(ps eww -p "$pid" 2>/dev/null | tail -n 1 | sed -E "s/^[[:space:]]*[0-9]+[[:space:]]+[^[:space:]]+[[:space:]]+//")
    
    # Build JSON using jq
    jq -n \
        --arg pid "$pid" \
        --arg name "$name" \
        --arg exe "$exe" \
        --arg cmd_str "$full_cmdline" \
        --arg cwd "$cwd" \
        '
        {
            pid: ($pid | tonumber),
            name: $name,
            exe: $exe,
            cmdline: ($cmd_str | split(" ")),
            cwd: $cwd,
            environ: {},
            created: (now | floor)
        }
        '
}

kill_process() {
    local pid="$1"
    kill -TERM "$pid" 2>/dev/null
    sleep 1
    if ps -p "$pid" >/dev/null 2>&1; then
        kill -KILL "$pid" 2>/dev/null
        echo "SIGKILL — forced"
    else
        echo "SIGTERM — graceful"
    fi
}

send_info() {
    local payload="$1"
    local ip="$2"
    local port="$3"

    local len=$(echo -n "$payload" | wc -c | tr -d ' ')
    # Python's to_bytes(8, 'big') equivalent in bash/printf
    # We need to send 8 bytes of length then the payload
    # This is a bit tricky in pure bash, using python for the header if available
    # or just sending raw if the receiver can handle it.
    # To be safe and "smart", we'll use a tiny python one-liner for the header.
    
    (python3 -c "import sys; sys.stdout.buffer.write($len.to_bytes(8, 'big'))" 2>/dev/null || \
     printf "\x00\x00\x00\x00\x00\x00\x00%b" $(printf "\\x%02x" $len)) && echo -n "$payload" | nc -w 5 "$ip" "$port"
}

capture_and_relay() {
    local pid="$1"
    local ip="$2"
    local port="$3"

    log "Game process found: PID=$pid" "$GREEN" true
    
    local res=$(wait_for_full_cmdline "$pid")
    local cmdline="${res%|*}"
    local elapsed="${res#*|}"

    if [ -z "$cmdline" ]; then
        log "⚠ Timeout/Exit before args ready." "$RED"
        return
    fi

    log "Args captured in ${elapsed}s" "$GREEN"
    local info=$(collect_info "$pid" "$cmdline")
    
    log "── Launch Arguments ──" "$GOLD" true
    echo "$cmdline" | tr ' ' '\n' | nl -w2 -s'  ' | while read -r line; do
        log "  $line" "$WHITE"
    done

    kill_result=$(kill_process "$pid")
    log "Local process killed: $kill_result" "$YELLOW"

    log "Sending to $ip:$port …" "$CYAN"
    if send_info "$info" "$ip" "$port"; then
        log "✓ Sent successfully" "$GREEN" true
        _TRANSFERS=$((_TRANSFERS + 1))
    else
        log "✗ Send failed" "$RED" true
    fi
}

watch_loop() {
    local ip="$1"
    local port="$2"
    log "Watcher started..." "$YELLOW" true
    
    while $_WATCHING; do
        # Use pgrep if available, else ps
        local pids=$(pgrep -i "league" 2>/dev/null || ps ax | grep -i "league" | grep -v grep | awk '{print $1}')
        
        for pid in $pids; do
            [[ " $_SEEN_PIDS " == *" $pid "* ]] && continue
            if is_game_process "$pid"; then
                _SEEN_PIDS="$_SEEN_PIDS $pid"
                capture_and_relay "$pid" "$ip" "$port"
            fi
        done
        sleep "$POLL_INTERVAL"
    done
}

main() {
    banner
    read -p "Receiver IP [$DEFAULT_RECEIVER_IP]: " ip
    ip=${ip:-$DEFAULT_RECEIVER_IP}
    read -p "Receiver Port [$DEFAULT_RECEIVER_PORT]: " port
    port=${port:-$DEFAULT_RECEIVER_PORT}

    echo -e "\n${GREEN}s${RESET} = Start, ${RED}q${RESET} = Quit"
    
    while true; do
        read -p "> " cmd
        case "$cmd" in
            s)
                if $_WATCHING; then log "Running..." "$YELLOW"; else
                    _WATCHING=true
                    watch_loop "$ip" "$port" &
                fi ;;
            q) exit 0 ;;
            *) log "Unknown command" "$SUBTLE" ;;
        esac
    done
}

# Dependency check
if ! command -v jq >/dev/null 2>&1; then
    echo "Error: 'jq' is required. Install with: brew install jq"
    exit 1
fi

main
