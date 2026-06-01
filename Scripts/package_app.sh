#!/bin/bash
# Builds CodexBarLite.app -- a double-clickable, menu-bar (LSUIElement) app bundle.
set -euo pipefail

cd "$(dirname "$0")/.."

APP="CodexBarLite.app"
BIN_NAME="CodexBarLite"

echo "==> Building release binary..."
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${BIN_NAME}"
if [[ ! -f "${BIN_PATH}" ]]; then
    echo "error: built binary not found at ${BIN_PATH}" >&2
    exit 1
fi

echo "==> Assembling ${APP}..."
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN_PATH}" "${APP}/Contents/MacOS/${BIN_NAME}"
cp "Resources/Info.plist" "${APP}/Contents/Info.plist"
cp "Resources/AppIcon.icns" "${APP}/Contents/Resources/AppIcon.icns"

echo "==> Ad-hoc code signing..."
codesign --force --sign - "${APP}"

echo "==> Done: $(pwd)/${APP}"
echo "    Move it to /Applications and double-click, or run: make install"
