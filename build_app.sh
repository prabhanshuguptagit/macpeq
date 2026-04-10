#!/bin/bash
set -e

APP_NAME="MacPEQ"
BUILD_DIR=".build/debug"
APP_BUNDLE="${APP_NAME}.app"

echo "Building ${APP_NAME}..."
swift build

echo "Creating app bundle..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# Copy binary
cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/"

# Create Info.plist
cat > "${APP_BUNDLE}/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.macpeq.MacPEQ</string>
    <key>CFBundleName</key>
    <string>MacPEQ</string>
    <key>CFBundleExecutable</key>
    <string>MacPEQ</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>MacPEQ needs to capture system audio to apply EQ effects.</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

# Codesign with entitlements (ad-hoc signing is fine for local testing)
echo "Codesigning..."
codesign --force --sign - --entitlements MacPEQ.entitlements "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

echo "App bundle created: ${APP_BUNDLE}"
echo ""
echo "To run:"
echo "  open ${APP_BUNDLE}"
echo ""
echo "Note: If you need to reset permissions:"
echo "  tccutil reset ScreenCapture"
