#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/tests .build/module-cache
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 \
  -module-cache-path .build/module-cache src/Core/*.swift tests/CoreTests.swift \
  -o .build/tests/CoreTests
.build/tests/CoreTests
