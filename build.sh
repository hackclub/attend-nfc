#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "Building Attend NFC Bridge..."
swift build -c release

echo ""
echo "Build complete!"
echo "Binary: $(pwd)/.build/release/AttendNFCBridge"
echo ""
echo "To run: .build/release/AttendNFCBridge"
echo "The app will appear in your menu bar."
