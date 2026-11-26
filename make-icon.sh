#!/bin/sh
# 生成 CloakRecorder 应用图标 AppIcon.icns（放到 recorder/Resources/）
set -e
cd "$(dirname "$0")"
mkdir -p .build

# 1. 用 Swift 脚本渲染 1024×1024 母图
swift dev/make-icon.swift .build/AppIcon-1024.png

# 2. 生成 iconset（多尺寸）
ICONSET=.build/AppIcon.iconset
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
sips -z 16 16   .build/AppIcon-1024.png --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32   .build/AppIcon-1024.png --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32   .build/AppIcon-1024.png --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64   .build/AppIcon-1024.png --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 .build/AppIcon-1024.png --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 .build/AppIcon-1024.png --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 .build/AppIcon-1024.png --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 .build/AppIcon-1024.png --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 .build/AppIcon-1024.png --out "$ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 .build/AppIcon-1024.png --out "$ICONSET/icon_512x512@2x.png" >/dev/null

# 3. 打包成 .icns
mkdir -p recorder/Resources
iconutil -c icns "$ICONSET" -o recorder/Resources/AppIcon.icns
echo "图标已生成: recorder/Resources/AppIcon.icns"