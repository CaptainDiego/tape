#!/usr/bin/env bash
# Builds Tape.app. Pass --install to copy it into /Applications, or --dmg to
# make dist/Tape-<version>.dmg to send to people.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Tape"
BUNDLE_ID="com.diego.tape"
VERSION="0.4.0"
APP="$ROOT/dist/$APP_NAME.app"

echo "==> Building release binary"
swift build -c release --package-path "$ROOT"
BIN="$(swift build -c release --package-path "$ROOT" --show-bin-path)/$APP_NAME"

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
strip -rSTx "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true

echo "==> Drawing icon"
swift "$ROOT/Tools/make-icon.swift" "$APP/Contents/Resources/AppIcon.icns" >/dev/null 2>&1 \
  || echo "    (icon skipped)"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>           <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>            <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>            <string>${BUNDLE_ID}</string>
    <key>CFBundleIconFile</key>              <string>AppIcon</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>${VERSION}</string>
    <key>CFBundleVersion</key>               <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>        <string>15.0</string>
    <key>LSUIElement</key>                   <true/>
    <key>NSCameraUsageDescription</key>
    <string>Tape shows your camera in a bubble on screen so it's part of your recording.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Tape records your voice along with your screen.</string>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc, hardened runtime)"
codesign --force --sign - --options runtime --entitlements "$ROOT/Tape.entitlements" \
    --identifier "$BUNDLE_ID" "$APP"
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'
echo "==> Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    echo "==> Installing to /Applications"
    pkill -x "$APP_NAME" 2>/dev/null && sleep 1 || true
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" "/Applications/$APP_NAME.app"
    # Each build is ad-hoc signed, so macOS treats it as a new app and old
    # permission entries silently stop working. Start clean; Tape asks again.
    echo "==> Resetting privacy permissions"
    for service in Camera Microphone ScreenCapture; do
        tccutil reset "$service" "$BUNDLE_ID" >/dev/null 2>&1 || true
    done
    echo "==> Installed. Launch with: open -a $APP_NAME"
fi

if [[ "${1:-}" == "--dmg" ]]; then
    DMG="$ROOT/dist/$APP_NAME-$VERSION.dmg"
    STAGE="$(mktemp -d)"
    echo "==> Making $DMG"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    cat > "$STAGE/How to open Tape.txt" <<TXT
1. Drag Tape onto the Applications folder.
2. Open Tape. macOS says it can't verify the developer: click Done.
3. Open System Settings, go to Privacy & Security, scroll down and click
   "Open Anyway" next to Tape, then confirm.
4. Tape lives in the menu bar (the record icon at the top of the screen).
   Allow camera, microphone and screen recording when it asks, then quit
   and reopen Tape once.

Needs macOS 15 or later on an Apple silicon Mac.
TXT
    rm -f "$DMG"
    hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
    rm -rf "$STAGE"
    echo "==> Built $DMG ($(du -h "$DMG" | cut -f1))"
fi
