#!/usr/bin/env bash
# Builds build/BoostVolume.app from the Swift package.
# Ad-hoc signed by default; set SIGN_IDENTITY to a valid code-signing identity
# so macOS keeps the audio-capture permission across rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/BoostVolume.app"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/BoostVolume"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/BoostVolume"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
