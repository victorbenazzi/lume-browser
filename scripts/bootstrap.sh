#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo 'Lume currently requires native macOS ARM64. Rosetta is not supported.' >&2
  exit 1
fi
xcrun --find swiftc >/dev/null
xcrun --find clang++ >/dev/null
mkdir -p vendor .tools .build
python3 scripts/fetch-cef.py
if [[ ! -x .tools/python/bin/cmake ]]; then
  python3 -m venv .tools/python
  .tools/python/bin/python -m pip install 'cmake==4.1.0'
fi
echo 'Dependencies ready. Run ./scripts/build.sh'
