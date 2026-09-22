#!/usr/bin/env bash
# Builds LLMUsageMonitor.app from the SwiftPM executable.
# No Xcode project needed. Pass --install to copy it to /Applications.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/LLMUsageMonitor.app"
BIN_NAME="LLMUsageMonitor"

echo "==> Building release binary"
swift build -c release --package-path "$ROOT" --product "$BIN_NAME"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/$BIN_NAME" "$APP/Contents/MacOS/$BIN_NAME"
cp "$ROOT/apps/MacApp/Info.plist" "$APP/Contents/Info.plist"

# Ad-hoc signature. Required for SMAppService ("Start at login") to work.
echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

if [[ "${1:-}" == "--install" ]]; then
    echo "==> Installing to /Applications"
    pkill -f "$BIN_NAME" 2>/dev/null || true
    rm -rf "/Applications/LLMUsageMonitor.app"
    cp -R "$APP" /Applications/
    echo "    installed: /Applications/LLMUsageMonitor.app"
    open -a "/Applications/LLMUsageMonitor.app"
    echo "    launched"
else
    echo "==> Done: $APP"
    echo "    run:     open '$APP'"
    echo "    install: scripts/build-app.sh --install"
fi
