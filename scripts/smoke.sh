#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -x dist/Lume.app/Contents/MacOS/Lume ]] || ./scripts/build.sh
PROFILE=$(mktemp -d "${TMPDIR:-/tmp}/lume-smoke.XXXXXX")
python3 scripts/fixture-server.py "$PROFILE/port" > .build/fixture-server.log 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT
for attempt in {1..30}; do
  if [[ -s "$PROFILE/port" ]]; then break; fi
  kill -0 "$SERVER_PID" 2>/dev/null || { echo 'Fixture server failed to start.' >&2; exit 1; }
  sleep 0.1
done
PORT=$(cat "$PROFILE/port")
curl --fail --silent "http://127.0.0.1:$PORT/first.html" >/dev/null
LUME_PROFILE_DIR="$PROFILE" LUME_TEST_URL="http://127.0.0.1:$PORT" \
  LUME_SMOKE_REPORT="$(pwd)/.build/smoke-report.json" \
  dist/Lume.app/Contents/MacOS/Lume --smoke-test
echo "Isolated test profile: $PROFILE"
