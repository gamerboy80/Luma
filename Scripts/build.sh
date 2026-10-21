#!/bin/bash
set -euo pipefail
LUMA_PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LUMA_BUILD_ROOT="$LUMA_PROJECT_ROOT/build"
mkdir -p "$LUMA_BUILD_ROOT"
# This local build is unsandboxed, explicitly approved for executing the user's
# SteamCMD installation. Use --sandboxed for a build with Terminal-only downloads.
LUMA_SANDBOX=NO
if [[ "${1:-}" == "--sandboxed" ]]; then LUMA_SANDBOX=YES
elif [[ -n "${1:-}" ]]; then printf 'Usage: %s [--sandboxed]\n' "$0" >&2; exit 2; fi
if [[ "$LUMA_SANDBOX" == YES ]]; then
cat > "$LUMA_BUILD_ROOT/Luma.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.network.client</key><true/>
<key>com.apple.security.files.user-selected.read-write</key><true/>
<key>com.apple.security.files.user-selected.executable</key><true/>
<key>com.apple.security.files.bookmarks.app-scope</key><true/>
</dict></plist>
PLIST
else
cat > "$LUMA_BUILD_ROOT/Luma.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.automation.apple-events</key><true/>
</dict></plist>
PLIST
fi
xcodebuild -project "$LUMA_PROJECT_ROOT/Luma.xcodeproj" -scheme Luma -configuration Release -destination 'platform=macOS' -derivedDataPath "$LUMA_BUILD_ROOT" \
  SUPPORTED_PLATFORMS=macosx SDKROOT=macosx MACOSX_DEPLOYMENT_TARGET=14.0 \
  SWIFT_DEFAULT_ACTOR_ISOLATION=nonisolated SWIFT_STRICT_CONCURRENCY=targeted \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGN_ENTITLEMENTS="$LUMA_BUILD_ROOT/Luma.entitlements" \
  ENABLE_APP_SANDBOX="$LUMA_SANDBOX" ENABLE_HARDENED_RUNTIME=YES build
printf '\nBuilt: %s\n' "$LUMA_BUILD_ROOT/Build/Products/Release/Luma.app"
