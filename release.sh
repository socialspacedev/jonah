#!/bin/bash
#
# Build a universal (Apple silicon + Intel) Jonah.app and zip it for a GitHub release.
#
#   ./release.sh        # → dist/Jonah-<version>.zip
#
# Builds each architecture separately and joins them with lipo, since a single
# multi-arch `swift build` needs full Xcode rather than the Command Line Tools.
#
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Jonah"
APP="dist/${APP_NAME}.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"
ZIP="dist/${APP_NAME}-${VERSION}.zip"

for ARCH in arm64 x86_64; do
    echo "▶ Building ${ARCH}…"
    swift build -c release --triple "${ARCH}-apple-macosx14.0"
done

echo "▶ Assembling ${APP} ${VERSION}…"
rm -rf "$APP" "$ZIP"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
lipo -create -output "${APP}/Contents/MacOS/${APP_NAME}" \
    ".build/arm64-apple-macosx/release/${APP_NAME}" ".build/x86_64-apple-macosx/release/${APP_NAME}"
cp Info.plist "${APP}/Contents/Info.plist"
cp AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

# No extended attributes: `unzip` would otherwise leave them as ._ files that break the signature.
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$APP" "$ZIP"
lipo -info "${APP}/Contents/MacOS/${APP_NAME}"
echo "✓ ${ZIP}"
