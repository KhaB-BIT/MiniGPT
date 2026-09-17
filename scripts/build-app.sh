#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="MiniGPT"
PRODUCT_NAME="ChatBMK"
APP_VERSION="${VERSION:-0.1.3}"
DIST_DIR="$PROJECT_ROOT/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
ZIP_PATH="$DIST_DIR/$APP_NAME-$APP_VERSION-macos-universal.zip"
ARM64_BUILD_DIR="$PROJECT_ROOT/.build-arm64"
X86_64_BUILD_DIR="$PROJECT_ROOT/.build-x86_64"

cd "$PROJECT_ROOT"

echo "Building arm64 release..."
swift build --scratch-path "$ARM64_BUILD_DIR" -c release --arch arm64
ARM64_BIN_DIR="$(swift build --scratch-path "$ARM64_BUILD_DIR" -c release --arch arm64 --show-bin-path)"

echo "Building x86_64 release..."
swift build --scratch-path "$X86_64_BUILD_DIR" -c release --arch x86_64
X86_64_BIN_DIR="$(swift build --scratch-path "$X86_64_BUILD_DIR" -c release --arch x86_64 --show-bin-path)"

rm -rf "$APP_BUNDLE"
rm -f "$ZIP_PATH"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleShortVersionString -string "$APP_VERSION" \
  "$APP_BUNDLE/Contents/Info.plist"

/usr/bin/lipo -create \
  "$ARM64_BIN_DIR/$PRODUCT_NAME" \
  "$X86_64_BIN_DIR/$PRODUCT_NAME" \
  -output "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod 755 "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Ký ad-hoc để bundle nhất quán. Phát hành không cảnh báo Gatekeeper vẫn cần
# Developer ID Application và notarization từ Apple.
/usr/bin/codesign --force --deep --sign - --timestamp=none "$APP_BUNDLE"

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

echo
echo "Created: $APP_BUNDLE"
echo "Created: $ZIP_PATH"
/usr/bin/lipo -info "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
