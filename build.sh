#!/bin/bash
set -e

APP="MacPEQ"
BUNDLE_ID="com.macpeq.MacPEQ"

# Parse arguments
CONFIG="debug"
BUILD_DIR="debug"
if [[ "$1" == "--release" || "$1" == "-r" ]]; then
    CONFIG="release"
    BUILD_DIR="release"
fi

echo "Building $APP ($CONFIG)..."
swift build -c $CONFIG

echo "Creating app bundle..."
rm -rf "$APP.app"
mkdir -p "$APP.app/Contents/MacOS"
cp ".build/$BUILD_DIR/$APP" "$APP.app/Contents/MacOS/"

cat > "$APP.app/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP</string>
    <key>CFBundleExecutable</key>
    <string>$APP</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>MacPEQ needs to capture system audio to apply EQ effects.</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

echo "Signing..."
codesign --force --sign - --entitlements MacPEQ.entitlements "$APP.app/Contents/MacOS/$APP"

echo "Resetting permission..."
tccutil reset ScreenCapture "$BUNDLE_ID" 2>/dev/null || tccutil reset ScreenCapture

echo ""
echo "Built $APP.app ($CONFIG)"
if [[ "$CONFIG" == "debug" ]]; then
    echo "For production build: ./build.sh --release"
fi
echo "Run: open $APP.app"
echo "Then grant permission in System Settings -> Privacy & Security -> Screen & System Audio Recording"
