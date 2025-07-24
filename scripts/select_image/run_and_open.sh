#!/usr/bin/env bash
# run_and_open.sh -- start FastAPI image selector via pipenv and open default browser.
# Usage: ./run_and_open.sh BASE_DIR TRANSCRIPT
# BASE_DIR : directory containing images.
# TRANSCRIPT : transcript file path
# This script starts the server in background, waits until it is ready, then
# opens http://127.0.0.1:8000/ via the macOS `open` command.
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 BASE_DIR TRANSCRIPT" >&2
  exit 1
fi

BASE_DIR="$1"
TRANSCRIPT="$2"

# Start server (background)
pipenv run python select_image.py --base-dir "$BASE_DIR" --transcript "$TRANSCRIPT" &
SERVER_PID=$!

echo "Server PID: $SERVER_PID, waiting for readiness on port 8000 ..."

# Wait until the port is accepting connections
for i in {1..30}; do
  if curl -s "http://127.0.0.1:8000/" >/dev/null 2>&1; then
    echo "Server is up. Opening browser ..."
    open "http://127.0.0.1:8000/"
    wait "$SERVER_PID"
    exit 0
  fi
  sleep 1
done

echo "Timed out waiting for server to start." >&2
kill "$SERVER_PID" 2>/dev/null || true
exit 1
