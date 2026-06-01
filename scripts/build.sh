#!/bin/bash
set -euo pipefail

# MatlabLauncher build and install script
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"

echo "=== Matlab Launcher Build Script ==="

# Ensure xcodegen is available
if ! command -v xcodegen &>/dev/null; then
    XCODEGEN_PATH="$(eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null)" && which xcodegen 2>/dev/null || true)"
    if [ -z "$XCODEGEN_PATH" ]; then
        echo "Error: xcodegen not found. Install with: brew install xcodegen"
        exit 1
    fi
fi

# Generate Xcode project if needed
if [ ! -d "$ROOT_DIR/MatlabLauncher.xcodeproj" ]; then
    echo "Generating Xcode project..."
    cd "$ROOT_DIR" && xcodegen generate
fi

# Build app
echo "Building MatlabLauncher.app..."
xcodebuild -project "$ROOT_DIR/MatlabLauncher.xcodeproj" \
    -scheme MatlabLauncher \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    build 2>&1 | grep -E "(BUILD|error:)" || true

APP_PATH="$BUILD_DIR/Build/Products/Release/MatlabLauncher.app"
if [ ! -d "$APP_PATH" ]; then
    echo "Error: Build failed — app not found at $APP_PATH"
    exit 1
fi
echo "✅ App built: $APP_PATH"

# Build CLI
echo "Building mlm CLI..."
xcodebuild -project "$ROOT_DIR/MatlabLauncher.xcodeproj" \
    -scheme mlm \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    build 2>&1 | grep -E "(BUILD|error:)" || true

MLM_PATH="$BUILD_DIR/Build/Products/Release/mlm"
if [ ! -f "$MLM_PATH" ]; then
    echo "Error: CLI build failed"
    exit 1
fi
echo "✅ CLI built: $MLM_PATH"

# Install
echo ""
echo "=== Installation ==="

# Copy app to /Applications (optional)
read -p "Install MatlabLauncher.app to /Applications? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    cp -R "$APP_PATH" /Applications/
    echo "✅ App installed to /Applications/MatlabLauncher.app"
fi

# Symlink CLI
INSTALL_DIR="$HOME/bin"
mkdir -p "$INSTALL_DIR"
ln -sf "$MLM_PATH" "$INSTALL_DIR/mlm"
echo "✅ CLI symlinked to $INSTALL_DIR/mlm"

# Check PATH
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    echo ""
    echo "⚠️  $INSTALL_DIR is not in your PATH."
    echo "   Add this to your ~/.zshrc:"
    echo "   export PATH=\"\$HOME/bin:\$PATH\""
fi

echo ""
echo "=== Done ==="
echo "Launch: open /Applications/MatlabLauncher.app  (or from build dir)"
echo "CLI:    mlm --help"
