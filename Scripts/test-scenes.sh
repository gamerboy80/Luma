#!/bin/bash
set -euo pipefail
LUMA_PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$LUMA_PROJECT_ROOT/build/TestCache"
xcrun swiftc -swift-version 5 -module-cache-path "$LUMA_PROJECT_ROOT/build/TestCache" \
 "$LUMA_PROJECT_ROOT/Luma/Models.swift" "$LUMA_PROJECT_ROOT/Luma/SceneLockScreenFallback.swift" "$LUMA_PROJECT_ROOT/Luma/SceneHost.swift" "$LUMA_PROJECT_ROOT/Luma/SceneScriptReview.swift" \
 "$LUMA_PROJECT_ROOT/Luma/MediaEncoder.swift" "$LUMA_PROJECT_ROOT/Tests/SceneTests.swift" \
 -o "$LUMA_PROJECT_ROOT/build/LumaSceneTests"
"$LUMA_PROJECT_ROOT/build/LumaSceneTests" "$LUMA_PROJECT_ROOT/Luma/Resources"
