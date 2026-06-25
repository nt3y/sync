#!/bin/bash

set -e

if ! command -v node >/dev/null 2>&1; then
    echo "Installing Node.js is required."
    exit 1
fi

WORKDIR="$(mktemp -d)"
JSFILE="$WORKDIR/app.js"

awk '/^__NODE__$/ {found=1; next} found {print}' "$0" > "$JSFILE"

if [ ! -f "$WORKDIR/package.json" ]; then
cat > "$WORKDIR/package.json" <<EOF
{
  "type": "module",
  "dependencies": {
    "ps-list": "^9.0.0"
  }
}
EOF
fi

cd "$WORKDIR"
npm install --silent

exec node "$JSFILE" "$@"

exit 0

__NODE__
#!/usr/bin/env node

console.log("Hello from embedded Node.js");

// paste the rest of your JavaScript here
