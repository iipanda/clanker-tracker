#!/bin/sh
# Builds ClankerTracker.app, signs it, and (unless INSTALL=0) installs it to ~/Applications and opens it.
#   scripts/build-app.sh             release build + install + launch
#   INSTALL=0 scripts/build-app.sh   build only (build/ClankerTracker.app)
#   CODESIGN_ID="Clanker Dev" ...    sign with a stable identity so notification and login-item
#                                    permissions survive rebuilds (default: ad-hoc "-")
set -eu
cd "$(dirname "$0")/.."

swift build -c release --product ClankerTracker
BIN="$(swift build -c release --show-bin-path)/ClankerTracker"

APP=build/ClankerTracker.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClankerTracker"
cp Support/Info.plist "$APP/Contents/Info.plist"
[ -f build/AppIcon.icns ] || swift scripts/make-icon.swift build
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign "${CODESIGN_ID:--}" --identifier io.github.iipanda.clankertracker "$APP"
echo "Built $APP"

if [ "${INSTALL:-1}" = 1 ]; then
  DEST="$HOME/Applications/ClankerTracker.app"
  pkill -x ClankerTracker 2>/dev/null && sleep 1 || true
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  open "$DEST"
  echo "Installed and opened $DEST"
fi
