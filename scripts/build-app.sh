#!/bin/sh
# Builds ClankerTracker.app, signs it, and (unless INSTALL=0) installs it to ~/Applications and opens it.
#   scripts/build-app.sh             release build + install + launch
#   INSTALL=0 scripts/build-app.sh   build only (build/ClankerTracker.app)
#   UNIVERSAL=1                      build for Apple Silicon and Intel
#   VERSION=0.2.0                    version shown in the app (default: the one in Support/Info.plist)
#   CODESIGN_ID="Clanker Dev"        sign with a stable identity so notification and login-item
#                                    permissions survive rebuilds (default: ad-hoc "-")
#   DEVELOPER_ID="Developer ID Application: …"
#                                    sign for distribution (hardened runtime + timestamp), for notarizing
set -eu
cd "$(dirname "$0")/.."

if [ "${UNIVERSAL:-0}" = 1 ]; then
  swift build -c release --arch arm64 --arch x86_64 --product ClankerTracker
  BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/ClankerTracker"
else
  swift build -c release --product ClankerTracker
  BIN="$(swift build -c release --show-bin-path)/ClankerTracker"
fi

APP=build/ClankerTracker.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClankerTracker"
cp Support/Info.plist "$APP/Contents/Info.plist"
if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 1)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
[ -f build/AppIcon.icns ] || swift scripts/make-icon.swift build
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [ -n "${DEVELOPER_ID:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" --identifier io.github.iipanda.clankertracker "$APP"
else
  codesign --force --sign "${CODESIGN_ID:--}" --identifier io.github.iipanda.clankertracker "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/ClankerTracker"))"

if [ "${INSTALL:-1}" = 1 ]; then
  DEST="$HOME/Applications/ClankerTracker.app"
  pkill -x ClankerTracker 2>/dev/null && sleep 1 || true
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  open "$DEST"
  echo "Installed and opened $DEST"
fi
