#!/bin/sh
# Installs Clanker Tracker to ~/Applications and sets up usage tracking for Codex and Claude Code.
# Run it from a clone of the repo: scripts/install.sh
#   Builds from source when Swift 6.2+ is installed, otherwise downloads the latest release
#   (FROM_RELEASE=1 forces the download). Undo the Claude Code part with --remove-collector.
set -eu
cd "$(dirname "$0")/.."
APP="$HOME/Applications/ClankerTracker.app"
BIN="$APP/Contents/MacOS/ClankerTracker"

macos=$(sw_vers -productVersion)
[ "${macos%%.*}" -ge 26 ] || { echo "Clanker Tracker needs macOS 26 or later; this Mac has $macos."; exit 1; }
command -v jq >/dev/null || { echo "Claude Code tracking needs jq: brew install jq"; exit 1; }

swift_ok() {
  v=$(swift --version 2>/dev/null | sed -nE 's/.*Swift version ([0-9]+)\.([0-9]+).*/\1 \2/p' | head -1)
  [ -n "$v" ] || return 1
  set -- $v
  [ "$1" -gt 6 ] || { [ "$1" -eq 6 ] && [ "$2" -ge 2 ]; }
}

if [ "${FROM_RELEASE:-0}" != 1 ] && swift_ok; then
  echo "Building from source…"
  scripts/build-app.sh
else
  command -v gh >/dev/null || { echo "Needs either Swift 6.2 (Xcode 26) to build, or the GitHub CLI (gh) to download a release."; exit 1; }
  echo "Downloading the latest release…"
  tmp=$(mktemp -d)
  gh release download --repo iipanda/clanker-tracker --pattern 'ClankerTracker-*.zip' --dir "$tmp"
  pkill -x ClankerTracker 2>/dev/null && sleep 1 || true
  mkdir -p "$HOME/Applications"
  rm -rf "$APP"
  ditto -x -k "$tmp"/ClankerTracker-*.zip "$HOME/Applications/"
  rm -rf "$tmp"
  # gh downloads aren't quarantined; this only matters if the zip came from a browser.
  xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
  open "$APP"
  echo "Installed and opened $APP"
fi

echo
sessions="${CODEX_HOME:-$HOME/.codex}/sessions"
if [ -d "$sessions" ]; then
  echo "Codex: tracking from $(find "$sessions" -name '*.jsonl' | wc -l | tr -d ' ') session logs in $sessions (no setup needed)."
else
  echo "Codex: no sessions on this Mac yet; tracking starts with your first Codex session."
fi

echo "Claude Code:"
"$BIN" --install-collector

echo
echo "Done. Click the ring in the menu bar to see your limits. Allow notifications when macOS asks;"
echo "Open at login is in Settings → General. To undo the Claude Code setup: $BIN --remove-collector"
