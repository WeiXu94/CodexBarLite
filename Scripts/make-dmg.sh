#!/usr/bin/env bash
# Builds CodexBarLite.app and packages it as a DMG.
#
# Env:
#   BUILD_ARCHS        space-separated arch list (default: arm64)
#   ARCH_LABEL         suffix for the DMG filename (default: derived from BUILD_ARCHS)
#   VERSION            version for the filename; defaults to CFBundleShortVersionString
#   SIGNING_IDENTITY   codesign identity; "-" = ad-hoc (default)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ARCHS="${BUILD_ARCHS:-arm64}"
ARCH_LABEL="${ARCH_LABEL:-${BUILD_ARCHS// /-}}"
APP="$ROOT/.build/app/CodexBarLite.app"
STAGING="$ROOT/.build/dmg/CodexBarLite"
DIST="$ROOT/.build/dist"

"$ROOT/Scripts/build-app.sh" >/dev/null

VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")}"
DMG="$DIST/CodexBarLite-v$VERSION-$ARCH_LABEL.dmg"

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING" "$DIST"
cp -R "$APP" "$STAGING/CodexBarLite.app"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
    -volname "CodexBar Lite" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG" >/dev/null

rm -rf "$STAGING"

echo "$DMG"
