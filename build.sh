#!/bin/bash
set -e

APP="MacPEQ"
BUNDLE_ID="com.macpeq.MacPEQ"

echo "Building $APP..."
swift build

echo "Creating app bundle..."
rm -rf "$APP.app"
mkdir -p "$APP.app/Contents/MacOS"
cp ".build/debug/$APP" "$APP.app/Contents/MacOS/"

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
echo "Built $APP.app"
echo "Run: open $APP.app"
echo "Then grant permission in System Settings -> Privacy & Security -> Screen & System Audio Recording"
