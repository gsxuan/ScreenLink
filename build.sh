#!/bin/bash
# build.sh — 编译并打包 ScreenLink.app
set -e
cd "$(dirname "$0")"
APP="ScreenLink.app"
BUILD="build"

rm -rf "$BUILD" "$APP"
mkdir -p "$BUILD"

echo "==> 编译主程序"
swiftc -O -o "$BUILD/ScreenLink" app/main.swift app/Core.swift

echo "==> 生成图标"
swiftc -O -o "$BUILD/genicon" icon/main.swift
"$BUILD/genicon" "$BUILD/icon-1024.png" >/dev/null

ICONSET="$BUILD/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 64 128 256 512; do
  sips -z $s $s "$BUILD/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
done
sips -z 32 32 "$BUILD/icon-1024.png" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 64 64 "$BUILD/icon-1024.png" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 256 256 "$BUILD/icon-1024.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 512 512 "$BUILD/icon-1024.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
cp "$BUILD/icon-1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$BUILD/AppIcon.icns"

echo "==> 组装 bundle"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/ScreenLink" "$APP/Contents/MacOS/ScreenLink"
cp app/Info.plist "$APP/Contents/Info.plist"
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> ad-hoc 签名"
codesign --force --sign - "$APP" 2>/dev/null || echo "(codesign skipped)"

echo "==> 完成：$(pwd)/$APP"
