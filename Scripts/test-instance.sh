#!/bin/bash
set -euo pipefail
LUMA_PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$LUMA_PROJECT_ROOT/build/TestCache"
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$LUMA_PROJECT_ROOT/build/TestCache" \
  "$LUMA_PROJECT_ROOT/Luma/Models.swift" "$LUMA_PROJECT_ROOT/Luma/InstanceLock.swift" \
  "$LUMA_PROJECT_ROOT/Tests/InstanceTests.swift" -o "$LUMA_PROJECT_ROOT/build/LumaInstanceTests"
"$LUMA_PROJECT_ROOT/build/LumaInstanceTests"
