#!/usr/bin/env bash
# Builds CodexBarLite.app — a double-clickable, menu-bar (LSUIElement) bundle.
# Output: <repo>/.build/app/CodexBarLite.app
#
# Env:
#   BUILD_ARCHS        space-separated arch list, e.g. "arm64" or "arm64 x86_64"
#                      (default: arm64). When multiple, binaries are lipo'd.
#   SIGNING_IDENTITY   codesign identity; "-" = ad-hoc (default)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/.build/app/CodexBarLite.app"
BIN_NAME="CodexBarLite"
RESOURCES="$ROOT/Resources"
BUILD_ARCHS="${BUILD_ARCHS:-arm64}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"

if [[ "$BUILD_ARCHS" == *" "* ]]; then
    UNIVERSAL_DIR="$ROOT/.build/universal"
    mkdir -p "$UNIVERSAL_DIR"
    BINARIES=()
    for arch in $BUILD_ARCHS; do
        echo "==> Building release binary ($arch)..."
        swift build -c release --arch "$arch"
        # `--show-bin-path` can report a unified path (identical for every arch)
        # on current toolchains, so copy each arch's freshly-built binary out
        # immediately — before the next arch overwrites that directory — instead
        # of collecting paths and lipo'ing at the end (which would dup one arch).
        STAGED="$UNIVERSAL_DIR/$BIN_NAME.$arch"
        cp "$(swift build -c release --arch "$arch" --show-bin-path)/$BIN_NAME" "$STAGED"
        BINARIES+=("$STAGED")
    done

    echo "==> Creating universal binary..."
    lipo -create -output "$UNIVERSAL_DIR/$BIN_NAME" "${BINARIES[@]}"
    BIN_PATH="$UNIVERSAL_DIR/$BIN_NAME"
else
    echo "==> Building release binary ($BUILD_ARCHS)..."
    swift build -c release --arch "$BUILD_ARCHS"
    BIN_PATH="$(swift build -c release --arch "$BUILD_ARCHS" --show-bin-path)/$BIN_NAME"
fi

if [[ ! -f "$BIN_PATH" ]]; then
    echo "error: built binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "==> Assembling ${APP#$ROOT/}..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$BIN_NAME"
cp "$RESOURCES/Info.plist" "$APP/Contents/Info.plist"
cp "$RESOURCES/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "==> Code signing (${SIGNING_IDENTITY})..."
codesign --force --sign "$SIGNING_IDENTITY" "$APP"

echo "$APP"
