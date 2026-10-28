#!/bin/zsh
# 打包發布用的 dmg：Apple 晶片＋Intel 通用版，臨時簽名（沒有經過 Apple 公證）
# 用法：./release.sh → dist/MiniFinder-<版本>.dmg
set -e
cd "$(dirname "$0")"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
DMG="dist/MiniFinder-$VERSION.dmg"
WORK=$(mktemp -d)
APP="$WORK/stage/迷你 Finder.app"
mkdir -p "$APP/Contents/MacOS" dist

# 兩種晶片各編一次，再合成一個執行檔
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos13.0" -o "$WORK/MiniFinder-$arch" MiniFinder.swift
done
lipo -create -output "$APP/Contents/MacOS/MiniFinder" "$WORK/MiniFinder-arm64" "$WORK/MiniFinder-x86_64"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

# dmg 裡放程式和「應用程式」資料夾的捷徑，打開後拖過去就裝好
ln -s /Applications "$WORK/stage/Applications"
hdiutil create -volname "迷你 Finder" -srcfolder "$WORK/stage" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
echo "已輸出：$DMG（$(du -h "$DMG" | cut -f1)）"
