#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="WeChatAutoReply"
BUILD_DIR="$PROJECT_DIR/.build"
MACOS_DIR="$BUILD_DIR/$APP_NAME.app/Contents/MacOS"
RESOURCES_DIR="$BUILD_DIR/$APP_NAME.app/Contents/Resources"
HASH_FILE="$BUILD_DIR/.source_hash"

echo "=== Building $APP_NAME ==="

# Compute hash of all source files (to detect real code changes)
CURRENT_HASH=$(find "$PROJECT_DIR/Sources" -name "*.swift" -exec cat {} + | shasum -a 256 | cut -d' ' -f1)
PREV_HASH=""
if [ -f "$HASH_FILE" ]; then
    PREV_HASH=$(cat "$HASH_FILE")
fi

# Clean
rm -rf "$BUILD_DIR/$APP_NAME.app"

# Create bundle structure
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Find all Swift sources
SOURCES=()
while IFS= read -r -d '' file; do
    SOURCES+=("$file")
done < <(find "$PROJECT_DIR/Sources" -name "*.swift" -print0)

echo "Sources: ${#SOURCES[@]} files"
for src in "${SOURCES[@]}"; do
    echo "  - $(basename "$src")"
done

# Compile
echo ""
echo "Compiling..."

SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
TARGET="arm64-apple-macos15.0"

swiftc \
    -sdk "$SDK_PATH" \
    -target "$TARGET" \
    -framework SwiftUI \
    -framework AppKit \
    -framework Carbon \
    -framework ApplicationServices \
    -framework Combine \
    -parse-as-library \
    -O \
    -o "$MACOS_DIR/$APP_NAME" \
    "${SOURCES[@]}"

echo "Compilation successful!"

# Copy Info.plist
cp "$PROJECT_DIR/Resources/Info.plist" "$RESOURCES_DIR/Info.plist"

# Copy App Icon
if [ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

# Create PkgInfo
echo "APPL????" > "$BUILD_DIR/$APP_NAME.app/Contents/PkgInfo"

# Code signing — only force re-sign if source actually changed
echo ""
if [ "$CURRENT_HASH" = "$PREV_HASH" ] && [ -n "$PREV_HASH" ]; then
    echo "Source unchanged → preserving existing signature (accessibility permission safe)"
    # Still need to sign the new binary, but do it lightly
    codesign --deep --sign - "$BUILD_DIR/$APP_NAME.app" 2>/dev/null || \
    codesign --force --deep --sign - "$BUILD_DIR/$APP_NAME.app"
else
    echo "Source changed → re-signing (may need to re-grant accessibility permission)"
    codesign --force --deep --sign - "$BUILD_DIR/$APP_NAME.app"
fi

# Save hash for next comparison
echo "$CURRENT_HASH" > "$HASH_FILE"

echo ""
echo "=== Build complete ==="
echo "App: $BUILD_DIR/$APP_NAME.app"

# Copy to /Applications if requested
if [[ "${1:-}" == "--install" ]]; then
    echo ""
    echo "Installing to /Applications..."
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$BUILD_DIR/$APP_NAME.app" "/Applications/"
    echo "Installed to /Applications/$APP_NAME.app"
    
    # Set custom icon (survives rebuilds since it's in resource fork)
    if [ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
        ICON_PATH="$PROJECT_DIR/Resources/AppIcon.icns"
    elif [ -f "/Users/junxibao/Desktop/Subject.png" ]; then
        ICON_PATH="/Users/junxibao/Desktop/Subject.png"
    fi
    if [ -n "${ICON_PATH:-}" ]; then
        swift -e "import Cocoa; NSWorkspace.shared.setIcon(NSImage(contentsOfFile: \"$ICON_PATH\")!, forFile: \"/Applications/$APP_NAME.app\", options: [])" 2>/dev/null
        echo "Icon set from $ICON_PATH"
    fi
    
    if [ "$CURRENT_HASH" != "$PREV_HASH" ] || [ -z "$PREV_HASH" ]; then
        echo ""
        echo "⚠️  Source changed — if you already granted permission, it should survive."
        echo "   If not: System Settings → Privacy → Accessibility → WeChatAutoReply"
    fi
fi
