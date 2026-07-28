#!/bin/bash

TARGET="/Applications/League of Legends/Contents/LoL/Game/League of Legends"

echo "Watching: $TARGET"

while true; do
    if [ -e "$TARGET" ]; then
        rm -f "$TARGET"
        echo "$(date '+%H:%M:%S') Deleted."
    fi

    # 3 milliseconds
    sleep 0.003
done
