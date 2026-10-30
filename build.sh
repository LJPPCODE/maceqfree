#!/bin/bash
# Baut build/MacEQfree.app nur mit den Command Line Tools (kein Xcode nötig).
set -euo pipefail
cd "$(dirname "$0")"

APP=build/MacEQfree.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.2" \
    Sources/*.swift -o "$APP/Contents/MacOS/MacEQfree"

cp Info.plist "$APP/Contents/Info.plist"
cp -R Resources/ui "$APP/Contents/Resources/ui"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
codesign --force --sign - "$APP"

echo "Fertig: $APP"
