#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "Building Attend NFC Bridge..."
swift build -c release

APP_DIR="dist/Attend NFC Bridge.app"

echo "Packaging app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp .build/release/AttendNFCBridge "$APP_DIR/Contents/MacOS/AttendNFCBridge"
cp Info.plist "$APP_DIR/Contents/Info.plist"

# Ad-hoc sign so Gatekeeper doesn't complain about a locally built binary
codesign --force --sign - "$APP_DIR"

echo ""
echo "Build complete!"
echo "App bundle: $(pwd)/$APP_DIR"
echo ""
echo "To run:  open \"$APP_DIR\""
echo "Or install:  cp -R \"$APP_DIR\" /Applications/"
echo "The app will appear in your menu bar."
