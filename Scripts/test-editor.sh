#!/bin/bash
set -euo pipefail
LUMA_PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$LUMA_PROJECT_ROOT/build/TestCache"
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$LUMA_PROJECT_ROOT/build/TestCache" \
 "$LUMA_PROJECT_ROOT/Luma/Models.swift" "$LUMA_PROJECT_ROOT/Luma/SceneLockScreenFallback.swift" "$LUMA_PROJECT_ROOT/Luma/LibraryStore.swift" "$LUMA_PROJECT_ROOT/Luma/WallperVideos.swift" \
 "$LUMA_PROJECT_ROOT/Luma/SceneEditor.swift" "$LUMA_PROJECT_ROOT/Luma/SceneEditorViews.swift" "$LUMA_PROJECT_ROOT/Luma/Workshop.swift" "$LUMA_PROJECT_ROOT/Luma/SceneHost.swift" "$LUMA_PROJECT_ROOT/Luma/SceneMediaProvider.swift" \
 "$LUMA_PROJECT_ROOT/Luma/SceneScriptReview.swift" "$LUMA_PROJECT_ROOT/Luma/MediaEncoder.swift" "$LUMA_PROJECT_ROOT/Luma/NativeLockScreen.swift" \
 "$LUMA_PROJECT_ROOT/Tests/EditorTests.swift" -o "$LUMA_PROJECT_ROOT/build/LumaEditorTests"
"$LUMA_PROJECT_ROOT/build/LumaEditorTests"
