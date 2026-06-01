#!/usr/bin/env bash
set -euo pipefail

# One-shot build (Release) and package script for MatlabLauncher
# Usage:
#   ./scripts/release_package.sh             # build Release and produce zip + dmg (default)
#   ./scripts/release_package.sh --skip-build  # package existing Release app
#   ./scripts/release_package.sh --skip-build --no-dmg  # package without dmg

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
PROJECT="$ROOT_DIR/MatlabLauncher.xcodeproj"
SCHEME="MatlabLauncher"
CONFIGURATION="Release"
DERIVED_DATA="$BUILD_DIR"
APP_PATH="$BUILD_DIR/Build/Products/$CONFIGURATION/MatlabLauncher.app"
OUT_DIR="$BUILD_DIR/release_artifacts"
DATE_TAG="$(date -u +%Y%m%dT%H%M%SZ)"
ZIP_NAME="MatlabLauncher-${DATE_TAG}-${CONFIGURATION}.zip"

# Default: do build; can be disabled with --skip-build
SKIP_BUILD=0
# Default: create a DMG alongside the zip (change with --no-dmg)
MAKE_DMG=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) SKIP_BUILD=1; shift ;;
    --dmg) MAKE_DMG=1; shift ;;
    --no-dmg) MAKE_DMG=0; shift ;;
    -h|--help) echo "Usage: $0 [--skip-build] [--dmg|--no-dmg]"; exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ $SKIP_BUILD -eq 0 ]]; then
  echo "Building Release (${CONFIGURATION})..."
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO build
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "Error: Release app not found at: $APP_PATH" >&2
  exit 2
fi

mkdir -p "$OUT_DIR"

echo "Packaging $APP_PATH → $OUT_DIR/$ZIP_NAME"
# Use ditto to create a ZIP preserving macOS metadata
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$OUT_DIR/$ZIP_NAME"

echo "Package created: $OUT_DIR/$ZIP_NAME"
echo
echo "Notes:" 
echo "- The build here disables code signing (CODE_SIGNING_ALLOWED=NO)."
echo "- For local use you do NOT need a Developer ID to run the app; macOS Gatekeeper may show a warning for unsigned apps — right-click → Open to allow." 
echo "- For distribution outside your machine, consider signing and notarizing the app." 

echo "Suggested next steps to share or test:" 
echo "  open $OUT_DIR"
echo "  unzip -l $OUT_DIR/$ZIP_NAME" 

# Optionally create a simple DMG for drag-to-/Applications UX
if [[ "$MAKE_DMG" -eq 1 ]]; then
  echo "Preparing DMG..."
  # Ensure no quarantine metadata is present on the app that would propagate
  echo "Removing com.apple.quarantine (if present) from app before DMG..."
  xattr -dr com.apple.quarantine "$APP_PATH" || true

  STAGING_DIR="$(mktemp -d -t matlablauncher.dmg)"
  trap 'rm -rf "$STAGING_DIR"' EXIT
  mkdir -p "$STAGING_DIR"
  cp -R "$APP_PATH" "$STAGING_DIR/"
  # Create Applications link for nicer UX when mounting
  ln -s /Applications "$STAGING_DIR/Applications"

  DMG_PATH="$OUT_DIR/MatlabLauncher-${DATE_TAG}.dmg"
  echo "Creating DMG at $DMG_PATH..."
  hdiutil create -volname "MatlabLauncher" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"
  echo "DMG created: $DMG_PATH"
fi

echo
echo "If macOS reports the app as 'damaged' after installation, run this on the target machine to remove quarantine:" 
echo "  xattr -dr com.apple.quarantine /Applications/MatlabLauncher.app"

exit 0
