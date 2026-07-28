#!/bin/bash
# ============================================================
#  LoL Game Args Checker (macOS) — AGGRESSIVE VERSION
# ============================================================

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
echo -e "${SUBTLE}Watching for any League-related process...${RESET}"
echo -e "${SUBTLE}Will print candidates every few seconds.${RESET}"
echo ""

EXCLUDE_REGEX="LeagueClient|LeagueClientUx|RiotClient|RiotClientServices|RiotClientUx|CrashHandler|Helper|Agent|reporter|patcher"

found_pid=""

while true; do
    echo -e "${SUBTLE}----- scan $(date +%H:%M:%S) -----${RESET}"

    # Show interesting processes so we can see the real name
    ps -axo pid=,comm=,args= | while IFS= read -r line; do
        pid=$(echo "$line" | awk '{print $1}')
        # skip if excluded
        if echo "$line" | grep -Eqi "$EXCLUDE_REGEX"; then
            continue
        fi
        # show anything that looks related to League / Riot / game
        if echo "$line" | grep -Eqi "league|riot|lol|game"; then
            echo -e "  ${YELLOW}CANDIDATE${RESET} $line"
        fi
    done

    # Now try to lock onto the real game process
    # Real game almost always has a lot of arguments and contains an IP + token style string
    while IFS= read -r line; do
        pid=$(echo "$line" | awk '{print $1}')
        args=$(echo "$line" | cut -d' ' -f3-)

        if echo "$line" | grep -Eqi "$EXCLUDE_REGEX"; then
            continue
        fi

        # Strong signals that this is the actual game process
        if echo "$args" | grep -Eqi "\-Product=LoL|\-GameID=|\-PlayerID=|\-RiotClientPort=|\-GameBaseDir="; then
            found_pid="$pid"
            break
        fi

        # Fallback: process name contains LeagueofLegends or similar and has many args
        arg_count=$(echo "$args" | wc -w | tr -d ' ')
        if [[ "$arg_count" -ge 8 ]] && echo "$line" | grep -Eqi "LeagueofLegends|League of Legends"; then
            found_pid="$pid"
            break
        fi
    done < <(ps -axo pid=,comm=,args= 2>/dev/null)

    if [[ -n "$found_pid" ]]; then
        break
    fi

    sleep 2
done

echo ""
echo -e "${GREEN}${BOLD}>>> GAME PROCESS FOUND  PID=$found_pid${RESET}"
echo ""

# ── Capture + kill + JSON with python3 ───────────────────────
python3 - <<EOF
import json, os, signal, subprocess, time, sys

pid = $found_pid

info = {
    "pid": pid,
    "name": None,
    "exe": None,
    "cwd": None,
    "cmdline": [],
    "cmdline_raw": None,
    "killed": False,
    "kill_method": None,
}

# Name
try:
    info["name"] = subprocess.check_output(["ps", "-p", str(pid), "-o", "comm="], text=True).strip()
except Exception:
    pass

# Full args
try:
    raw = subprocess.check_output(["ps", "-p", str(pid), "-o", "args="], text=True).strip()
    info["cmdline_raw"] = raw
    info["cmdline"] = raw.split()
    if info["cmdline"]:
        info["exe"] = info["cmdline"][0]
except Exception as e:
    info["error"] = str(e)

# Better exe via lsof
try:
    lsof = subprocess.check_output(["lsof", "-p", str(pid)], text=True, stderr=subprocess.DEVNULL)
    for line in lsof.splitlines():
        if " txt " in line:
            info["exe"] = line.split()[-1]
            break
except Exception:
    pass

# cwd
try:
    out = subprocess.check_output(["lsof", "-a", "-d", "cwd", "-p", str(pid)],
                                  text=True, stderr=subprocess.DEVNULL)
    lines = out.strip().splitlines()
    if len(lines) >= 2:
        info["cwd"] = lines[1].split()[-1]
except Exception:
    pass

print("── Process info before kill ──")
print(json.dumps(info, indent=2, ensure_ascii=False))
print()

# Kill
method = None
try:
    os.kill(pid, signal.SIGTERM)
    time.sleep(1.2)
    try:
        os.kill(pid, 0)          # still alive?
        os.kill(pid, signal.SIGKILL)
        method = "SIGKILL"
    except ProcessLookupError:
        method = "SIGTERM"
except ProcessLookupError:
    method = "already dead"
except PermissionError:
    try:
        subprocess.run(["sudo", "kill", "-9", str(pid)], check=True, capture_output=True)
        method = "sudo kill -9"
    except Exception as e:
        method = f"failed: {e}"

info["killed"] = True
info["kill_method"] = method

print("── Final JSON ──")
print(json.dumps(info, indent=2, ensure_ascii=False))
EOF

echo ""
echo -e "${GREEN}Done. Copy the JSON above and send it.${RESET}"
echo ""
