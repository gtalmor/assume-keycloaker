#!/bin/zsh
# Builds a zip to hand to colleagues: dist/AssumeKeycloaker-<version>.zip (+ .sha256).
# They unzip it into ~/Applications (or /Applications) and open it; Setup does the rest.
set -euo pipefail
cd "${0:A:h}/.."

./scripts/build-app.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" packaging/Info.plist)
mkdir -p dist
ZIP="dist/AssumeKeycloaker-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "build/Assume Keycloaker.app" "$ZIP"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
echo "Packaged $ZIP"
