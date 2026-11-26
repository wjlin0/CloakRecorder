#!/bin/sh
# 打包 CloakRecorder 为 DMG（内含 CloakRecorder.app + 指向 /Applications 的快捷方式）
set -e
cd "$(dirname "$0")"

# 确保 .app 已构建
if [ ! -d dist/CloakRecorder.app ]; then
  ./build-recorder.sh
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" dist/CloakRecorder.app/Contents/Info.plist)
DMG="dist/CloakRecorder-$VERSION.dmg"
STAGING=".build/dmg-stage"

rm -f "$DMG"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R dist/CloakRecorder.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "CloakRecorder" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
echo "DMG 已生成: $DMG"