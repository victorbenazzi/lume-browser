#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -m)" != arm64 ]]; then
  echo 'Use an ARM64 terminal, without Rosetta.' >&2
  exit 1
fi
if [[ ! -f vendor/cef/include/cef_app.h || ! -x .tools/python/bin/cmake ]]; then
  ./scripts/bootstrap.sh
fi
mkdir -p .build/objects .build/module-cache dist
.tools/python/bin/cmake -S vendor/cef -B .build/cef -DPROJECT_ARCH=arm64 \
  -DCMAKE_BUILD_TYPE=Release -DUSE_SANDBOX=ON > .build/cef-configure.log
.tools/python/bin/cmake --build .build/cef --target libcef_dll_wrapper -j "${LUME_BUILD_JOBS:-6}" \
  > .build/cef-wrapper.log 2>&1
CEF_WRAPPER=.build/cef/libcef_dll_wrapper/libcef_dll_wrapper.a
xcrun clang++ -std=c++20 -arch arm64 -mmacosx-version-min=14.0 -O2 -fobjc-arc \
  -DCEF_USE_SANDBOX -I vendor/cef -c src/Engine/CEFBridge.mm -o .build/objects/CEFBridge.o
xcrun clang++ -std=c++20 -arch arm64 -mmacosx-version-min=14.0 -O2 \
  -DCEF_USE_SANDBOX -I vendor/cef src/Engine/HelperMain.cpp "$CEF_WRAPPER" \
  -framework AppKit -framework Cocoa -framework IOSurface -o .build/LumeHelper
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 -O -g \
  -module-cache-path .build/module-cache -module-name Lume \
  -import-objc-header src/Engine/CEFBridge.h \
  src/Core/*.swift src/Engine/CEFEngine.swift src/UI/*.swift src/App/*.swift \
  .build/objects/CEFBridge.o "$CEF_WRAPPER" \
  -Xlinker -lc++ -framework AppKit -framework Cocoa -framework IOSurface \
  -o .build/Lume
python3 scripts/package.py
echo "Built: $(pwd)/dist/Lume.app"
