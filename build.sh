#!/bin/bash
# Builds CertyPie.app into ./build
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/CertyPie"
APP="build/Certy Pie.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/CertyPie"
cp Resources/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp -R Resources/en.lproj Resources/it.lproj "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built: $APP"
