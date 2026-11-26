#!/bin/sh
# 构建 CloakRecorder.app（universal arm64 + x86_64）
# 版本号改这里即可（release 的 tag 应与之一致，如 v1.0.0）
VERSION="1.0.0"
set -e
cd "$(dirname "$0")"
mkdir -p dist .build
SRC="recorder/RecorderEngine.swift recorder/CloakRecorderApp.swift recorder/ContentView.swift"
for arch in arm64 x86_64; do
  xcrun swiftc -parse-as-library -swift-version 5 -O \
    -target $arch-apple-macosx13.0 $SRC -o .build/CloakRecorder-$arch
done
lipo -create .build/CloakRecorder-arm64 .build/CloakRecorder-x86_64 -output .build/CloakRecorder

# 生成应用图标（若无则由 make-icon.sh 自动生成）
if [ ! -f recorder/Resources/AppIcon.icns ]; then
  ./make-icon.sh
fi

APP=dist/CloakRecorder.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/CloakRecorder "$APP/Contents/MacOS/CloakRecorder"
cp recorder/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>CloakRecorder</string>
    <key>CFBundleDisplayName</key><string>CloakRecorder 录屏隐身</string>
    <key>CFBundleIdentifier</key><string>io.github.wjlin0.cloakrecorder</string>
    <key>CFBundleExecutable</key><string>CloakRecorder</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 wjlin0. MIT License.</string>
</dict>
</plist>
EOF
codesign --force --deep -s - "$APP"
echo "构建完成: $APP"