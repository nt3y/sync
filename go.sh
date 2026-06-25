#!/bin/bash

# --- CONFIGURATION ---
RECEIVER_IP="192.168.1.XXX"  # <--- CHANGE THIS
RECEIVER_PORT=54321
POLL_INTERVAL=1

# --- COLORS ---
G="\033[32m"; Y="\033[33m"; R="\033[31m"; C="\033[36m"; N="\033[0m"

echo -e "${C}⚡ LoL Relay [macOS] Started${N}"
echo -e "${Y}Target: $RECEIVER_IP:$RECEIVER_PORT${N}"
echo -e "${Y}Watching for League of Legends...${N}"

SEEN_PIDS=""

while true; do
    # Find PIDs of processes containing "League" (case-insensitive)
    PIDS=$(ps ax | grep -i "League" | grep -v "grep" | awk '{print $1}')

    for PID in $PIDS; do
        # Skip if we already handled this PID
        if [[ ! " $SEEN_PIDS " =~ " $PID " ]]; then
            
            # Get command line arguments
            CMDLINE=$(ps -p $PID -o command= 2>/dev/null)
            
            # Check if it's the actual game (not the client)
            # Game usually has many arguments, Client has few.
            ARG_COUNT=$(echo "$CMDLINE" | wc -w)
            
            if [[ "$CMDLINE" == *"League of Legends"* ]] && [ "$ARG_COUNT" -gt 10 ]; then
                echo -e "${G}Found Game Process: $PID${N}"
                SEEN_PIDS="$SEEN_PIDS $PID"

                # 1. Collect Info
                NAME=$(ps -p $PID -o comm=)
                EXE=$(echo "$CMDLINE" | awk '{print $1}')
                CWD=$(lsof -a -p $PID -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')
                
                # 2. Build JSON using Python (built-in on macOS) to avoid 'jq' dependency
                JSON_DATA=$(python3 -c "
import json, sys, time
data = {
    'pid': $PID,
    'name': '$NAME',
    'exe': '$EXE',
    'cmdline': sys.argv[1].split(' '),
    'cwd': '$CWD',
    'environ': {},
    'created': int(time.time())
}
print(json.dumps(data))
" "$CMDLINE")

                # 3. Kill Process
                kill -9 $PID 2>/dev/null
                echo -e "${R}Killed local process $PID${N}"

                # 4. Send over TCP using Python to ensure correct 8-byte header
                echo -e "${C}Sending to receiver...${N}"
                python3 -c "
import socket, sys
payload = sys.stdin.read().encode('utf-8')
header = len(payload).to_bytes(8, 'big')
try:
    with socket.create_connection(('$RECEIVER_IP', $RECEIVER_PORT), timeout=5) as s:
        s.sendall(header + payload)
    print('DONE')
except Exception as e:
    print(f'ERROR: {e}')
" <<< "$JSON_DATA"
                
                echo -e "${G}Transfer Complete!${N}"
            fi
        fi
    done
    sleep $POLL_INTERVAL
done
