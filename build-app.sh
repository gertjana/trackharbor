#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ARM_BUILD_DIR="$ROOT/.build-arm64/out/Products/Release"
INTEL_BUILD_DIR="$ROOT/.build-x86_64/out/Products/Release"
APP_DIR="$ROOT/TrackHarbor.app"
ICON_SOURCE="$ROOT/Assets/AppIcon.png"
ICONSET_DIR="$ROOT/.build/AppIcon.iconset"

swift build -c release --triple arm64-apple-macosx13.0 --scratch-path "$ROOT/.build-arm64"
swift build -c release --triple x86_64-apple-macosx13.0 --scratch-path "$ROOT/.build-x86_64"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
lipo -create "$ARM_BUILD_DIR/TrackHarbor" "$INTEL_BUILD_DIR/TrackHarbor" -output "$APP_DIR/Contents/MacOS/TrackHarbor"
cp "$ROOT/Info.plist" "$APP_DIR/Contents/Info.plist"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" "$ICON_SOURCE" --out "$ICONSET_DIR/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    sips -z "$DOUBLE" "$DOUBLE" "$ICON_SOURCE" --out "$ICONSET_DIR/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET_DIR" -o "$APP_DIR/Contents/Resources/TrackHarbor.icns"
codesign --force --deep --sign - "$APP_DIR"
lipo -info "$APP_DIR/Contents/MacOS/TrackHarbor"
echo "Built $APP_DIR"
