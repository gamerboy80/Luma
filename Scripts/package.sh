#!/bin/bash
set -euo pipefail
LUMA_PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LUMA_APP="$LUMA_PROJECT_ROOT/build/Build/Products/Release/Luma.app"
codesign --verify --deep --strict "$LUMA_APP"
mkdir -p "$LUMA_PROJECT_ROOT/dist"
ditto -c -k --keepParent "$LUMA_APP" "$LUMA_PROJECT_ROOT/dist/Luma.zip"
printf 'Packaged: %s\n' "$LUMA_PROJECT_ROOT/dist/Luma.zip"
