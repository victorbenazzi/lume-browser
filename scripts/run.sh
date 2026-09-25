#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -x dist/Lume.app/Contents/MacOS/Lume ]]; then ./scripts/build.sh; fi
if [[ $# -gt 0 || -n "${LUME_PROFILE_DIR:-}" ]]; then
  exec dist/Lume.app/Contents/MacOS/Lume "$@"
fi
open dist/Lume.app
