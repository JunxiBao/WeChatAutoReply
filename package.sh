#!/bin/bash
set -e
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/.build"
APP_NAME="WeChatAutoReply"
DMG_NAME="${APP_NAME}.dmg"

# Ensure we have the built app
if [ ! -d "$BUILD_DIR/$APP_NAME.app" ]; then
    echo "App not found, please build first."
    exit 1
fi

# Create a staging directory
STAGING_DIR="$BUILD_DIR/dmg_staging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

# Copy the app to the staging directory
cp -R "$BUILD_DIR/$APP_NAME.app" "$STAGING_DIR/"

# Create a symlink to Applications
ln -s /Applications "$STAGING_DIR/Applications"

# Force set the icon for the packaged App to avoid Finder cache issues
if [ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
    echo "Setting icon for packaged App..."
    swift -e "import Cocoa; NSWorkspace.shared.setIcon(NSImage(contentsOfFile: \"$PROJECT_DIR/Resources/AppIcon.icns\")!, forFile: \"$STAGING_DIR/$APP_NAME.app\", options: [])" 2>/dev/null
    
    # Also set the volume icon for the DMG itself
    cp "$PROJECT_DIR/Resources/AppIcon.icns" "$STAGING_DIR/.VolumeIcon.icns"
    # Wait for the file to be written, sometimes SetFile fails if it's too fast
    sleep 1
    SetFile -c icnC "$STAGING_DIR/.VolumeIcon.icns" || true
    SetFile -a C "$STAGING_DIR" || true
fi

# Remove old DMG if it exists
rm -f "$PROJECT_DIR/$DMG_NAME"

# Create the DMG
echo "Creating $DMG_NAME..."
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "$PROJECT_DIR/$DMG_NAME"

# Clean up staging directory
rm -rf "$STAGING_DIR"

echo "Done! Installer is ready at $PROJECT_DIR/$DMG_NAME"
