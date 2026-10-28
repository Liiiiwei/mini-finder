#!/bin/zsh
# 編譯迷你 Finder 並裝到 ~/Applications
set -e
cd "$(dirname "$0")"
APP="$HOME/Applications/迷你 Finder.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/MiniFinder" MiniFinder.swift
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.liweisia.mini-finder</string>
  <key>CFBundleName</key><string>迷你 Finder</string>
  <key>CFBundleDisplayName</key><string>迷你 Finder</string>
  <key>CFBundleExecutable</key><string>MiniFinder</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>讀取與設定登入項目，讓「登入時自動開啟」的打勾狀態和系統設定一致。</string>
</dict>
</plist>
PLIST
# 用固定憑證簽名，重新編譯後輔助使用權限不必重勾
# 憑證名稱寫在 .sign-identity（不進版控）；沒有這個檔就用臨時簽名，每次重編要重勾權限
SIGN_ID="-"
[[ -f .sign-identity ]] && SIGN_ID=$(<.sign-identity)
codesign --force --sign "$SIGN_ID" "$APP"
echo "已安裝：$APP"
