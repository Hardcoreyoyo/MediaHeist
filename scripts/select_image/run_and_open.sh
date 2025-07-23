#!/usr/bin/env bash
# run_and_open.sh -- start FastAPI image selector via pipenv and open default browser.
# Usage: ./run_and_open.sh BASE_DIR [PORT]
# BASE_DIR : directory containing images.
# PORT     : optional port (default 8000)
# This script starts the server in background, waits until it is ready, then
# opens http://127.0.0.1:PORT/ via the macOS `open` command.
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 BASE_DIR [PORT]" >&2
  exit 1
fi

BASE_DIR="$1"
PORT="${2:-8000}"

# Start server (background)
pipenv run python select_image.py --base-dir "$BASE_DIR" --port "$PORT" &
SERVER_PID=$!

echo "Server PID: $SERVER_PID, waiting for readiness on port $PORT ..."

# Wait until the port is accepting connections
for i in {1..30}; do
  if curl -s "http://127.0.0.1:${PORT}/" >/dev/null 2>&1; then
    echo "Server is up. Opening browser ..."
    open "http://127.0.0.1:${PORT}/"
    wait "$SERVER_PID"
    exit 0
  fi
  sleep 1
done

echo "Timed out waiting for server to start." >&2
kill "$SERVER_PID" 2>/dev/null || true
exit 1
