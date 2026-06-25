#!/bin/bash

echo "Watching for League of Legends game..."

while true; do
    # Look for the actual game process (not the launcher/client)
    pids=$(pgrep -if "League of Legends")

    if [ -n "$pids" ]; then
        for pid in $pids; do
            cmd=$(ps -p "$pid" -o command=)

            # Ignore Riot Client / League Client processes
            if [[ "$cmd" != *"LeagueClient"* ]] && \
               [[ "$cmd" != *"Riot Client"* ]] && \
               [[ "$cmd" != *"RiotClientServices"* ]]; then

                echo "Killing game process (PID $pid)"
                kill -9 "$pid" 2>/dev/null
            fi
        done
    fi

    sleep 1
done
