#!/bin/zsh
# Builds "build/Assume Cloaker.app".
#   --install   also copy it to ~/Applications and (re)launch it.
# TEAM_CONFIG=path/to/team.json bundles a team config (private builds only; public builds have none).
set -euo pipefail
cd "${0:A:h}/.."

APP_NAME="Assume Cloaker"
APP="build/$APP_NAME.app"

swift build -c release --product AssumeCloaker
BIN="$(swift build -c release --show-bin-path)/AssumeCloaker"

if [[ ! -f build/AppIcon.icns || packaging/make-icon.swift -nt build/AppIcon.icns ]]; then
  rm -rf build/AppIcon.iconset
  mkdir -p build
  swift packaging/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AssumeCloaker"
cp packaging/Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp shell/assume-cloaker.zsh "$APP/Contents/Resources/"
# Public builds carry no team config (colleagues join with an invite). TEAM_CONFIG=file bundles one
# for a private, hand-delivered build.
TEAM_CONFIG="${TEAM_CONFIG:-}"
if [[ -n "$TEAM_CONFIG" && -f "$TEAM_CONFIG" ]]; then
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$TEAM_CONFIG"
  cp "$TEAM_CONFIG" "$APP/Contents/Resources/team.json"
fi
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST="$HOME/Applications/$APP_NAME.app"
  if pkill -x AssumeCloaker 2>/dev/null; then sleep 1; fi
  mkdir -p "$HOME/Applications" "$HOME/.config/assume-cloaker"
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  open "$DEST"
  echo "Installed $DEST"
fi
