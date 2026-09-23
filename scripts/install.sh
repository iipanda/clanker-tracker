#!/bin/sh
# Builds Clanker Tracker from source, installs it to ~/Applications, and runs its setup
# (Codex check, Claude Code collector, login item). For a normal install, use the release
# as described in the README; this is for working on the app.
#   OPEN_AT_LOGIN=0 scripts/install.sh   skip the login item
set -eu
cd "$(dirname "$0")/.."
scripts/build-app.sh
echo
if [ "${OPEN_AT_LOGIN:-1}" = 1 ]; then
  "$HOME/Applications/ClankerTracker.app/Contents/MacOS/ClankerTracker" --setup
else
  "$HOME/Applications/ClankerTracker.app/Contents/MacOS/ClankerTracker" --setup --no-open-at-login
fi
