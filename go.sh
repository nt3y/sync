#!/bin/bash

# LoL Game Relay — SENDER (macOS) — TERMINAL VERSION
# ====================================================
# This script attempts to replicate the functionality of the Python script
# for sending League of Legends game launch arguments and basic process info
# over TCP to a receiver. Due to limitations of shell scripting on macOS,
# especially regarding comprehensive environment variable capture for arbitrary
# processes, this version will focus on command-line arguments and core relay logic.

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
DEFAULT_RECEIVER_IP="192.168.1.XXX" # <<< CHANGE THIS TO YOUR RECEIVER IP
DEFAULT_RECEIVER_PORT=54321
POLL_INTERVAL=1.0

GAME_KEYWORDS=("leagueoflegends" "league of legends")
EXCLUDE_KEYWORDS=("leagueclient" "leagueclientux" "riotclientservices" \
                  "riotclientux" "patcher" "crashhandler")

MIN_ARGS=5
CMDLINE_WAIT_TIMEOUT=10.0
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
    if [ "$bold" = "true" ]; then
        style="$BOLD"
    fi
    echo -e "${SUBTLE}[${ts}]${RESET}  ${style}${color}${msg}${RESET}"
}

banner() {
    echo -e "\n${GOLD}${BOLD}========================================================${RESET}"
    echo -e "${GOLD}${BOLD}  ⚡  LoL RELAY  ·  SENDER  [macOS]  —  TERMINAL${RESET}"
    echo -e "${GOLD}${BOLD}========================================================${RESET}"
    echo -e "${SUBTLE}  Host: $(hostname)${RESET}"
    echo -e "\n"
}

print_status() {
    local label="$1"
    local color="$2"
    echo -e "\r${color}${BOLD}  ● STATUS: ${label}${RESET}          "
}

# --- Process helpers ---
is_game_process() {
    local pid="$1"
    local name=$(ps -p "$pid" -o comm=)
    local cmdline=$(ps -p "$pid" -o command=)
    local identity="${name,,} ${cmdline,,}"

    local is_game=false
    for keyword in "${GAME_KEYWORDS[@]}"; do
        if [[ "$identity" =~ "${keyword,,}" ]]; then
            is_game=true
            break
        fi
    done

    if [ "$is_game" = "false" ]; then
        return 1 # Not a game process
    fi

    for keyword in "${EXCLUDE_KEYWORDS[@]}"; do
        if [[ "$identity" =~ "${keyword,,}" ]]; then
            return 1 # Excluded process
        fi
    done

    return 0 # Is a game process
}

wait_for_full_cmdline() {
    local pid="$1"
    local deadline=$(($(date +%s) + CMDLINE_WAIT_TIMEOUT))
    local start=$(date +%s)
    local current_cmdline=""
    local elapsed=0

    while [ $(date +%s) -lt "$deadline" ]; do
        current_cmdline=$(ps -p "$pid" -o command= 2>/dev/null)
        if [ -z "$current_cmdline" ]; then
            # Process might have exited
            break
        fi
        # Count arguments (simple space split, not perfect but good enough for this context)
        local num_args=$(echo "$current_cmdline" | wc -w)
        if [ "$num_args" -ge "$MIN_ARGS" ]; then
            elapsed=$(($(date +%s) - start))
            echo "$current_cmdline" "$elapsed"
            return 0
        fi
        log "  Waiting for args … (${num_args} so far)" "$SUBTLE"
        sleep "$CMDLINE_POLL"
    done
    echo "" "$CMDLINE_WAIT_TIMEOUT"
    return 1
}

collect_info() {
    local pid="$1"
    local full_cmdline="$2"
    local info_json="{}"

    local name=$(ps -p "$pid" -o comm= 2>/dev/null)
    local exe=$(ps -p "$pid" -o command= | awk 

    # Try to get CWD (lsof might require sudo or fail for some processes)
    local cwd=$(lsof -p "$pid" | grep cwd | awk 

    # Environment variables are very difficult to get comprehensively in shell on macOS
    # without specific tools or root access. We'll provide a placeholder.
    local environ_json="{}"
    # Attempt to get some env vars if available via ps (often truncated)
    local ps_env=$(ps eww -p "$pid" | tail -n 1)
    if [[ "$ps_env" =~ ^[[:space:]]*[[:digit:]]+[[:space:]]+ ]]; then
        # Remove PID and command from ps eww output to isolate env vars
        ps_env=$(echo "$ps_env" | sed -E 's/^[[:space:]]*[[:digit:]]+[[:space:]]+[^[:space:]]+[[:space:]]+//')
        # Basic parsing for key=value pairs
        IFS=' ' read -ra env_array <<< "$ps_env"
        for item in "${env_array[@]}"; do
            if [[ "$item" =~ = ]]; then
                key=$(echo "$item" | cut -d'=' -f1)
                value=$(echo "$item" | cut -d'=' -f2-)
                # Escape double quotes in value for JSON
                value=$(echo "$value" | sed 's/"/\\"/g')
                environ_json=$(echo "$environ_json" | jq --arg k "$key" --arg v "$value" '.[$k] = $v')
            fi
        done
    fi

    info_json=$(echo "$info_json" | jq \
        --argjson pid "$pid" \
        --arg name "$name" \
        --arg exe "$exe" \
        --argjson cmdline "$(echo "$full_cmdline" | jq -R 'split(" ")')" \
        --arg cwd "$cwd" \
        --argjson environ "$environ_json" \
        '.pid = $pid | .name = $name | .exe = $exe | .cmdline = $cmdline | .cwd = $cwd | .environ = $environ'
    )

    echo "$info_json"
}

kill_process() {
    local pid="$1"
    if kill -TERM "$pid" 2>/dev/null; then
        sleep 1 # Give it a moment to terminate
        if ! ps -p "$pid" > /dev/null; then
            echo "SIGTERM — graceful"
            return 0
        fi
    fi

    if kill -KILL "$pid" 2>/dev/null; then
        sleep 1 # Give it a moment to kill
        if ! ps -p "$pid" > /dev/null; then
            echo "SIGKILL — forced"
            return 0
        fi
    fi

    if ps -p "$pid" > /dev/null; then
        echo "Failed to kill process $pid"
        return 1
    else
        echo "already gone"
        return 0
    fi
}

send_info() {
    local info_json="$1"
    local ip="$2"
    local port="$3"

    # Check if nc is available
    if ! command -v nc &> /dev/null; then
        log "✗  netcat (nc) not found. Please install it (e.g., 'brew install netcat')." "$RED" true
        return 1
    fi

    # Prepend length to payload (8 bytes big-endian)
    local payload_len=$(echo -n "$info_json" | wc -c | tr -d ' ')
    local len_bytes=$(printf '%016x' "$payload_len" | xxd -r -p)

    # Send data using netcat
    if echo -n "$len_bytes$info_json" | nc -w 10 "$ip" "$port"; then
        log "✓  Sent ${payload_len} bytes to ${ip}:${port}" "$GREEN" true
        return 0
    else
        log "✗  Failed to send data to ${ip}:${port} — is the receiver running?" "$RED" true
        return 1
    fi
}

capture_and_relay() {
    local proc_pid="$1"
    local proc_name="$2"
    local ip="$3"
    local port="$4"

    log "Game process found:  PID=${proc_pid}  Name=${proc_name}" "$GREEN" true
    log "Waiting for process to fully load args (max ${CMDLINE_WAIT_TIMEOUT}s) …" "$YELLOW"

    local cmdline_output
    cmdline_output=$(wait_for_full_cmdline "$proc_pid")
    local full_cmdline=$(echo "$cmdline_output" | awk '{print substr($0, 1, length($0)-length($NF)-1)}')
    local elapsed=$(echo "$cmdline_output" | awk '{print $NF}')

    if [ -z "$full_cmdline" ]; then
        log "⚠  Timeout waiting for args after ${CMDLINE_WAIT_TIMEOUT}s — " \
            "process may have exited early or args are restricted." "$RED"
        return
    fi

    local num_args=$(echo "$full_cmdline" | wc -w)
    log "Args ready:  ${num_args} tokens captured in ${elapsed}s" "$GREEN"

    local info_json
    info_json=$(collect_info "$proc_pid" "$full_cmdline")

    # Print args
    log "── Launch Arguments ──" "$GOLD" true
    echo "$full_cmdline" | tr ' ' '\n' | nl -w2 -s'  ' | while read -r line; do
        local arg_num=$(echo "$line" | awk '{print $1}')
        local arg_val=$(echo "$line" | awk '{print substr($0, index($0,$2))}')
        local color="$WHITE"
        if [ "$arg_num" -eq 1 ]; then # First arg is often the executable path
            color="$GOLD"
        fi
        log "  [$(printf "%02d" $((arg_num-1)))]  ${arg_val}" "$color"
    done

    local env_count=$(echo "$info_json" | jq '.environ | length')
    log "── Environment: ${env_count} vars captured (limited in shell) ──" "$SUBTLE"

    # Kill
    local kill_result
    kill_result=$(kill_process "$proc_pid")
    log "Local process killed: ${kill_result}" "$YELLOW"

    # Send
    log "Sending to ${ip}:${port} …" "$CYAN"
    if send_info "$info_json" "$ip" "$port"; then
        _TRANSFERS=$((_TRANSFERS + 1))
        log "Total transfers this session: ${_TRANSFERS}" "$GREEN"
    fi
}

# --- Watch loop ---
watch_loop() {
    local ip="$1"
    local port="$2"
    log "Watcher started — waiting for game …" "$YELLOW" true
    print_status "WATCHING" "$YELLOW"

    while $_WATCHING; do
        # Find all processes that might be a game
        local pids_to_check=$(ps aux | grep -i "leagueoflegends" | grep -v "grep" | awk '{print $2}')

        for pid in $pids_to_check; do
            if [ "$_WATCHING" = "false" ]; then
                break
            fi

            # Check if PID has already been seen this session
            if [[ " $_SEEN_PIDS " =~ " $pid " ]]; then
                continue
            fi

            if is_game_process "$pid"; then
                _SEEN_PIDS="$_SEEN_PIDS $pid"
                # Run capture and relay in background to not block the watcher
                (capture_and_relay "$pid" "$(ps -p "$pid" -o comm=)" "$ip" "$port") &
            fi
        done
        sleep "$POLL_INTERVAL"
    done

    log "Watcher stopped." "$SUBTLE"
    print_status "IDLE" "$RED"
}

# --- Main ---
get_input() {
    local prompt="$1"
    local default="$2"
    local val
    read -rp "${CYAN}${prompt}${RESET} [${SUBTLE}${default}${RESET}]: " val
    if [ -z "$val" ]; then
        echo "$default"
    else
        echo "$val"
    fi
}

main() {
    banner

    # Config
    echo -e "${GOLD}── Configuration ──────────────────────────────${RESET}"
    RECEIVER_IP=$(get_input "Receiver IP  (Windows PC LAN IP)" "$DEFAULT_RECEIVER_IP")
    RECEIVER_PORT_STR=$(get_input "Receiver Port" "$DEFAULT_RECEIVER_PORT")
    
    # Basic port validation
    if ! [[ "$RECEIVER_PORT_STR" =~ ^[0-9]+$ ]] || [ "$RECEIVER_PORT_STR" -lt 1 ] || [ "$RECEIVER_PORT_STR" -gt 65535 ]; then
        echo -e "${RED}Invalid port, using default ${DEFAULT_RECEIVER_PORT}${RESET}"
        RECEIVER_PORT="$DEFAULT_RECEIVER_PORT"
    else
        RECEIVER_PORT="$RECEIVER_PORT_STR"
    fi

    echo -e "\n"
    log "Target:  ${RECEIVER_IP}:${RECEIVER_PORT}" "$CYAN" true
    log "Host:    $(hostname)" "$CYAN"
    echo -e "\n"

    # Signal handler for clean Ctrl+C exit
    trap '{
        echo -e "\n"
        log "Interrupt received — stopping …" "$YELLOW"
        _WATCHING=false
        exit 0
    }' SIGINT

    # Interactive command loop
    echo -e "${GOLD}── Commands ────────────────────────────────────${RESET}"
    echo -e "  ${GREEN}s${RESET} → Start watching"
    echo -e "  ${RED}q${RESET} → Quit"
    echo -e "  ${SUBTLE}Press Ctrl+C at any time to exit${RESET}"
    echo -e "\n"

    while true; do
        read -rp "${GOLD}>${RESET} " cmd
        cmd=$(echo "$cmd" | tr '[:upper:]' '[:lower:]') # Convert to lowercase

        case "$cmd" in
            s)
                if $_WATCHING; then
                    log "Already watching!" "$YELLOW"
                else
                    _WATCHING=true
                    _SEEN_PIDS="" # Reset seen PIDs on start
                    watch_loop "$RECEIVER_IP" "$RECEIVER_PORT" &
                fi
                ;;
            q)
                _WATCHING=false
                log "Goodbye." "$SUBTLE"
                break
                ;;
            stop)
                if $_WATCHING; then
                    _WATCHING=false
                else
                    log "Not watching." "$SUBTLE"
                fi
                ;;
            status)
                local state="${RED}IDLE${RESET}"
                if $_WATCHING; then
                    state="${GREEN}WATCHING${RESET}"
                fi
                log "Status: ${state}  |  Transfers: ${_TRANSFERS}" "$CYAN"
                ;;
            help)
                echo -e "  ${GREEN}s${RESET}      — start watching"
                echo -e "  ${RED}stop${RESET}   — stop watching"
                echo -e "  ${CYAN}status${RESET} — show current status"
                echo -e "  ${RED}q${RESET}      — quit"
                ;;
            "")
                # Ignore empty input
                ;;
            *)
                log "Unknown command '${cmd}'. Type 'help' for commands." "$SUBTLE"
                ;;
        esac
    done
}

# Check for dependencies
if ! command -v jq &> /dev/null; then
    log "✗  jq not found. Please install it (e.g., 'brew install jq')." "$RED" true
    exit 1
fi

main
