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

echo "==> 打包 DMG + ZIP"
VER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
mkdir -p dist

# DMG：内含 App + /Applications 快捷方式，拖拽即装
STAGE="$BUILD/dmg-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "dist/ScreenLink-$VER.dmg"
hdiutil create -volname ScreenLink -srcfolder "$STAGE" -ov -format UDZO "dist/ScreenLink-$VER.dmg" >/dev/null

# ZIP：ditto 保留 bundle 结构，不产生 __MACOSX / 资源分叉
rm -f "dist/ScreenLink-$VER.zip"
ditto -c -k --keepParent "$APP" "dist/ScreenLink-$VER.zip"

hdiutil verify "dist/ScreenLink-$VER.dmg" >/dev/null && echo "==> DMG 校验通过"
shasum -a 256 "dist/ScreenLink-$VER.dmg" "dist/ScreenLink-$VER.zip"

echo "==> 完成：$(pwd)/$APP（产物见 dist/）"
