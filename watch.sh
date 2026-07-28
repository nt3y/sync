#!/bin/bash
# ============================================================
#  LoL Game Args Checker (macOS)
#  - Waits for the real game process
#  - Captures cmdline + info
#  - Kills the process
#  - Prints JSON to terminal
# ============================================================

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
GOLD='\033[0;33m'
SUBTLE='\033[0;90m'
RESET='\033[0m'
BOLD='\033[1m'

echo ""
echo -e "${GOLD}${BOLD}==============================================${RESET}"
echo -e "${GOLD}${BOLD}  LoL Game Args Checker (macOS)${RESET}"
echo -e "${GOLD}${BOLD}==============================================${RESET}"
echo -e "${SUBTLE}Waiting for League of Legends GAME process...${RESET}"
echo -e "${SUBTLE}(Client / RiotClient are ignored)${RESET}"
echo ""

# Keywords that identify the real game process
GAME_KEYWORDS=("LeagueofLegends" "League of Legends")
# Things we must never match
EXCLUDE=("LeagueClient" "LeagueClientUx" "RiotClient" "RiotClientServices" "RiotClientUx" "CrashHandler" "patcher")

found_pid=""
found_name=""

# ── Wait loop ────────────────────────────────────────────────
while true; do
    # Get all processes with their command
    while IFS= read -r line; do
        pid=$(echo "$line" | awk '{print $1}')
        cmd=$(echo "$line" | cut -d' ' -f2-)

        # Skip if any exclude keyword is present
        skip=false
        for ex in "${EXCLUDE[@]}"; do
            if echo "$cmd" | grep -qi "$ex"; then
                skip=true
                break
            fi
        done
        $skip && continue

        # Check if it looks like the real game
        for kw in "${GAME_KEYWORDS[@]}"; do
            if echo "$cmd" | grep -qi "$kw"; then
                # Extra safety: real game usually has many args and a server IP-looking token
                arg_count=$(ps -p "$pid" -o args= 2>/dev/null | wc -w | tr -d ' ')
                if [[ "$arg_count" -ge 6 ]]; then
                    found_pid="$pid"
                    found_name=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
                    break 2
                fi
            fi
        done
    done < <(ps -axo pid=,command= 2>/dev/null)

    if [[ -n "$found_pid" ]]; then
        break
    fi

    sleep 0.8
done

echo -e "${GREEN}${BOLD}Game process found!${RESET}"
echo -e "  PID  : ${CYAN}${found_pid}${RESET}"
echo -e "  Name : ${CYAN}${found_name}${RESET}"
echo ""

# ── Capture info ─────────────────────────────────────────────
# Full command line (best effort)
full_cmd=$(ps -p "$found_pid" -o args= 2>/dev/null || true)

# Executable path
exe_path=$(ps -p "$found_pid" -o comm= 2>/dev/null || true)
# Better exe path via lsof / proc (macOS)
if [[ -e "/proc/$found_pid/exe" ]]; then
    exe_path=$(readlink "/proc/$found_pid/exe" 2>/dev/null || echo "$exe_path")
else
    # macOS way
    exe_path=$(lsof -p "$found_pid" 2>/dev/null | awk '/txt/ {print $9; exit}' || echo "$exe_path")
fi

# Working directory (best effort)
cwd=$(lsof -a -d cwd -p "$found_pid" 2>/dev/null | awk 'NR==2 {print $9}' || echo "")

# Build argument array from the command line
# (ps args= gives one long string; we split carefully)
# Using python for reliable JSON + arg splitting if available
if command -v python3 &>/dev/null; then
    json_output=$(python3 - <<EOF
import json, os, signal, subprocess, sys, time

pid = $found_pid

info = {
    "pid": pid,
    "name": """$found_name""",
    "exe": None,
    "cwd": None,
    "cmdline": [],
    "environ_count": 0,
    "killed": False,
    "kill_method": None,
}

try:
    # cmdline via ps
    out = subprocess.check_output(["ps", "-p", str(pid), "-o", "args="], text=True).strip()
    # Simple split (good enough for LoL args)
    if out:
        # First token is usually the exe
        parts = out.split()
        info["cmdline"] = parts
        info["exe"] = parts[0] if parts else None
except Exception as e:
    info["error_cmdline"] = str(e)

# Try to get better exe with lsof
try:
    lsof = subprocess.check_output(["lsof", "-p", str(pid)], text=True, stderr=subprocess.DEVNULL)
    for line in lsof.splitlines():
        if " txt " in line:
            info["exe"] = line.split()[-1]
            break
        if line.strip().endswith("cwd"):
            continue
except Exception:
    pass

# cwd
try:
    lsof_cwd = subprocess.check_output(["lsof", "-a", "-d", "cwd", "-p", str(pid)],
                                       text=True, stderr=subprocess.DEVNULL)
    lines = lsof_cwd.strip().splitlines()
    if len(lines) >= 2:
        info["cwd"] = lines[1].split()[-1]
except Exception:
    pass

# Kill the process
kill_method = None
try:
    os.kill(pid, signal.SIGTERM)
    time.sleep(1.5)
    # check if still alive
    try:
        os.kill(pid, 0)
        os.kill(pid, signal.SIGKILL)
        kill_method = "SIGKILL (forced)"
    except ProcessLookupError:
        kill_method = "SIGTERM (graceful)"
except ProcessLookupError:
    kill_method = "already dead"
except PermissionError:
    # try sudo kill
    try:
        subprocess.run(["sudo", "kill", "-9", str(pid)], check=True, capture_output=True)
        kill_method = "sudo kill -9"
    except Exception as e:
        kill_method = f"failed: {e}"

info["killed"] = True
info["kill_method"] = kill_method

print(json.dumps(info, indent=2, ensure_ascii=False))
EOF
)
    echo -e "${GOLD}${BOLD}────────────── JSON OUTPUT ──────────────${RESET}"
    echo "$json_output"
    echo -e "${GOLD}${BOLD}─────────────────────────────────────────${RESET}"
else
    # Fallback without python
    echo -e "${YELLOW}python3 not found – printing raw info${RESET}"
    echo "PID:       $found_pid"
    echo "Name:      $found_name"
    echo "EXE:       $exe_path"
    echo "CWD:       $cwd"
    echo "Full CMD:  $full_cmd"
    echo ""
    echo "Killing process..."
    kill "$found_pid" 2>/dev/null || kill -9 "$found_pid" 2>/dev/null || true
    echo "Done."
fi

echo ""
echo -e "${GREEN}Process closed. Copy the JSON above and send it.${RESET}"
echo ""
