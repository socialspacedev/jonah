#!/bin/bash
#
# Build a universal (Apple silicon + Intel) Jonah.app and package it as a DMG
# for a GitHub release.
#
#   ./release.sh        # → dist/Jonah-<version>.dmg
#
# Builds each architecture separately and joins them with lipo, since a single
# multi-arch `swift build` needs full Xcode rather than the Command Line Tools.
#
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Jonah"
APP="dist/${APP_NAME}.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"
DMG="dist/${APP_NAME}-${VERSION}.dmg"
STAGE="dist/dmg-staging"

for ARCH in arm64 x86_64; do
    echo "▶ Building ${ARCH}…"
    swift build -c release --triple "${ARCH}-apple-macosx14.0"
done

echo "▶ Assembling ${APP} ${VERSION}…"
rm -rf "$APP"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
lipo -create -output "${APP}/Contents/MacOS/${APP_NAME}" \
    ".build/arm64-apple-macosx/release/${APP_NAME}" ".build/x86_64-apple-macosx/release/${APP_NAME}"
cp Info.plist "${APP}/Contents/Info.plist"
cp AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

# The app beside an /Applications shortcut: the usual drag-to-install window.
echo "▶ Building ${DMG}…"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "${STAGE}/${APP_NAME}.app"
ln -s /Applications "${STAGE}/Applications"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

lipo -info "${APP}/Contents/MacOS/${APP_NAME}"
echo "✓ ${DMG}  ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
