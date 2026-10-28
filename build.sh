#!/bin/zsh
# 編譯迷你 Finder 並裝到 ~/Applications
set -e
cd "$(dirname "$0")"
APP="$HOME/Applications/迷你 Finder.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/MiniFinder" MiniFinder.swift
cp Info.plist "$APP/Contents/Info.plist"
# 用固定憑證簽名，重新編譯後輔助使用權限不必重勾
# 憑證名稱寫在 .sign-identity（不進版控）；沒有這個檔就用臨時簽名，每次重編要重勾權限
SIGN_ID="-"
[[ -f .sign-identity ]] && SIGN_ID=$(<.sign-identity)
codesign --force --sign "$SIGN_ID" "$APP"
echo "已安裝：$APP"
