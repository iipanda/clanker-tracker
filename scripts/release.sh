#!/bin/sh
# Builds a universal ClankerTracker.app, zips it, tags the current commit and publishes a GitHub release.
#   scripts/release.sh 0.1.0
#
# Without Apple credentials the app is ad-hoc signed, so people who download it have to allow it once in
# System Settings → Privacy & Security (the release notes explain how). With a Developer ID it's signed
# and notarized and opens without warnings:
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)"   certificate in your keychain
#   NOTARY_PROFILE=clanker                                   from `xcrun notarytool store-credentials clanker`
# DRY_RUN=1 builds and zips without tagging or publishing.
set -eu
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>, e.g. 0.1.0}"
TAG="v$VERSION"
REPO="${REPO:-iipanda/clanker-tracker}"
ZIP="build/ClankerTracker-$VERSION.zip"

if [ "${DRY_RUN:-0}" != 1 ]; then
  [ -z "$(git status --porcelain)" ] || { echo "Commit or stash your changes first."; exit 1; }
  git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "Tag $TAG already exists."; exit 1; }
fi

scripts/update-prices.py
if [ "${DRY_RUN:-0}" != 1 ] && [ -n "$(git status --porcelain Sources/ClankerCore/Spend/BundledPrices.swift)" ]; then
  git commit -q -m "Update built-in prices" Sources/ClankerCore/Spend/BundledPrices.swift
  echo "Committed refreshed built-in prices."
fi
swift test
UNIVERSAL=1 INSTALL=0 VERSION="$VERSION" scripts/build-app.sh

SIGNED=adhoc
if [ -n "${DEVELOPER_ID:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
  ditto -c -k --keepParent build/ClankerTracker.app "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple build/ClankerTracker.app
  SIGNED=notarized
fi
rm -f "$ZIP"
ditto -c -k --keepParent build/ClankerTracker.app "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
echo "Packaged $ZIP ($SIGNED, sha256 $SHA)"

NOTES=build/release-notes.md
{
  echo "Menu bar app that forecasts whether your Claude Code and Codex limits will last until they reset."
  echo "Universal build (Apple Silicon and Intel), macOS 26 or later."
  echo
  echo "## Install"
  echo
  echo "1. Download \`ClankerTracker-$VERSION.zip\`, unzip it, and move **ClankerTracker.app** to Applications."
  if [ "$SIGNED" = adhoc ]; then
    echo "2. Open it. macOS says it can't verify the app, because this build isn't notarized by Apple yet. Click **Done**."
    echo "3. Open **System Settings → Privacy & Security**, scroll down, click **Open Anyway** next to Clanker Tracker, and confirm with your password. You only do this once."
    echo
    echo "   Or in Terminal: \`xattr -dr com.apple.quarantine /Applications/ClankerTracker.app\`"
    echo "4. Click the ring in the menu bar → **Settings… → Data sources → Install collector** to track Claude Code. Codex needs no setup."
  else
    echo "2. Open it, then click the ring in the menu bar → **Settings… → Data sources → Install collector** to track Claude Code. Codex needs no setup."
  fi
  echo
  echo "SHA-256: \`$SHA\`"
} > "$NOTES"

if [ "${DRY_RUN:-0}" = 1 ]; then
  echo "Dry run: not tagging or publishing. Notes in $NOTES"
  exit 0
fi

git tag -a "$TAG" -m "Clanker Tracker $VERSION"
git push origin "$TAG"
gh release create "$TAG" "$ZIP" --repo "$REPO" --title "Clanker Tracker $VERSION" --notes-file "$NOTES"
