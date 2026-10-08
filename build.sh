#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="弹出硬盘"
BUILD_DIR="$PROJECT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "==> 清理旧产物"
rm -rf "$APP_BUNDLE" "$BUILD_DIR/DiskEjector"

echo "==> 编译"
mkdir -p "$BUILD_DIR"
/usr/bin/swiftc -O -o "$BUILD_DIR/DiskEjector" "$PROJECT_DIR/Sources/main.swift"

echo "==> 组装 App Bundle"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/DiskEjector" "$APP_BUNDLE/Contents/MacOS/DiskEjector"

# 从系统图标库取一个硬盘图标
ICON_SRC="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/DiskImage.icns"
[ -f "$ICON_SRC" ] && cp "$ICON_SRC" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>弹出硬盘</string>
    <key>CFBundleDisplayName</key>     <string>弹出硬盘</string>
    <key>CFBundleExecutable</key>      <string>DiskEjector</string>
    <key>CFBundleIdentifier</key>      <string>local.disk.ejector</string>
    <key>CFBundleVersion</key>         <string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>  <string>11.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>LSApplicationCategoryType</key><string>public.utilities</string>
    <!--纯菜单栏工具：不占程序坞、不进「最近使用的应用程序」-->
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

cat > "$APP_BUNDLE/Contents/PkgInfo" <<'EOF'
APPL????
EOF

echo "==> Ad-hoc 签名（避免重启后被 Gatekeeper 拦）"
codesign --force --deep --sign - "$APP_BUNDLE" 2>&1 | sed 's/^/    /'
codesign --verify --verbose=1 "$APP_BUNDLE" 2>&1 | sed 's/^/    /'

echo "==> 清除隔离属性"
xattr -cr "$APP_BUNDLE" 2>/dev/null || true

echo ""
echo "✅ 构建完成: $APP_BUNDLE"