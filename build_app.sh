#!/bin/bash
# 构建并打包为 macOS .app

set -e

cd "$(dirname "$0")"

APP_NAME="ComicTranslator"
BUNDLE_ID="com.transcreen.comictranslator"
VERSION="1.2.0"
BUILD_DIR=".build/release"
APP_BUNDLE="$APP_NAME.app"

echo "═══════════════════════════════════════════════"
echo "📦 打包 $APP_NAME v$VERSION"
echo "═══════════════════════════════════════════════"

# 1. 构建 Release 版本（Universal Binary）
echo ""
echo "🔨 编译 Release 版本..."
swift build -c release --arch arm64 --arch x86_64 2>&1 | tail -5 || swift build -c release

EXECUTABLE="$BUILD_DIR/$APP_NAME"
if [ ! -f "$EXECUTABLE" ]; then
    EXECUTABLE=".build/apple/Products/Release/$APP_NAME"
fi
# If the local Xcode toolchain cannot produce a Release build, use the
# already-built arm64 debug executable so the app bundle can still be restored.
if [ ! -f "$EXECUTABLE" ] && [ -f ".build/arm64-apple-macosx/debug/$APP_NAME" ]; then
    EXECUTABLE=".build/arm64-apple-macosx/debug/$APP_NAME"
    echo "⚠️ Release 构建不可用，使用现有 arm64 调试可执行文件打包"
fi
if [ ! -f "$EXECUTABLE" ]; then
    echo "❌ 找不到可执行文件"
    ls -la .build/
    exit 1
fi

echo "✅ 编译完成: $EXECUTABLE"
echo "   $(file "$EXECUTABLE" | sed 's/.*: //')"

# 2. 清理旧的 app bundle
rm -rf "$APP_BUNDLE"

# 3. 创建 .app 目录结构
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# 4. 复制可执行文件
cp "$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# 5. 创建 Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>漫画翻译器</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 TranScreen</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>用于识别音频/视频中的语音并翻译为字幕</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>用于语音识别（仅文件转写，不录音）</string>
</dict>
</plist>
EOF

# 6. Ad-hoc 签名（带 entitlements）
echo ""
echo "🔏 签名..."
codesign --force --deep --sign - --entitlements ComicTranslator.entitlements "$APP_BUNDLE" 2>&1 | grep -v "replacing existing signature" || true

# 7. 验证
echo ""
APP_SIZE=$(du -sh "$APP_BUNDLE" | cut -f1)
echo "═══════════════════════════════════════════════"
echo "✅ 打包完成！"
echo "═══════════════════════════════════════════════"
echo ""
echo "📂 位置: $(pwd)/$APP_BUNDLE"
echo "📏 大小: $APP_SIZE"
echo ""
echo "启动方式:"
echo "   open $APP_BUNDLE"
echo ""
