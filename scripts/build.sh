#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
mkdir -p dist/TouTou.app/Contents/MacOS
mkdir -p dist/TouTou.app/Contents/Resources
cp scripts/fetch_usage.py dist/TouTou.app/Contents/Resources/fetch_usage.py
cp .build/release/TouTou dist/TouTou.app/Contents/MacOS/TouTou
cp scripts/Info.plist dist/TouTou.app/Contents/Info.plist
codesign --force --sign - dist/TouTou.app
rm -f dist/TouTou.app.zip
ditto -c -k --keepParent dist/TouTou.app dist/TouTou.app.zip
printf 'Готово: %s/dist/TouTou.app (архив для Releases: dist/TouTou.app.zip)\n' "$PWD"
