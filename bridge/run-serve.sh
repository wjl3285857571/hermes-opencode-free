#!/bin/bash
# Runs `opencode serve` and pins its randomly-generated password into a file the
# bridge reads, so both halves survive restarts without hand-copying credentials.
# opencode 2.x ignores OPENCODE_SERVER_PASSWORD, so the password has to come from
# the server's own startup banner.
#
# Implementation note: a `cmd | tee log | while read` pipeline does NOT work under
# launchd — the while-loop never sees the lines, so the password file stays empty
# and the bridge 401s. Redirecting to the log and polling it from a background
# loop does work.
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PW_FILE="$DIR/serve_password"
LOG="$DIR/serve.log"
CLI="${OPENCODE_CLI:-/Applications/OpenCode.app/Contents/Resources/opencode-cli}"

: > "$PW_FILE"
rm -f "$LOG"

"$CLI" serve --port 4600 --hostname 127.0.0.1 --print-logs > "$LOG" 2>&1 &
SERVE_PID=$!

(
  for _ in $(seq 1 60); do
    [ -s "$PW_FILE" ] && exit 0
    line=$(grep -m1 '^server password ' "$LOG" 2>/dev/null || true)
    if [ -n "$line" ]; then
      printf '%s' "${line#server password }" > "$PW_FILE"
      chmod 600 "$PW_FILE"
      exit 0
    fi
    kill -0 "$SERVE_PID" 2>/dev/null || exit 0
    sleep 0.5
  done
) &

wait "$SERVE_PID"
