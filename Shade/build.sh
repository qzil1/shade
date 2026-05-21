#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "Building Shade..."

# Copy Info.plist and icon resources
mkdir -p Shade.app/Contents/Resources
cp Sources/Shade/Info.plist Shade.app/Contents/Info.plist
cp Sources/Shade/AppIcon.icns Shade.app/Contents/Resources/

# Compile with Info.plist embedded into the Mach-O binary
swiftc Sources/Shade/*.swift \
    -o Shade.app/Contents/MacOS/Shade \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Sources/Shade/Info.plist \
    -framework Cocoa \
    -framework Carbon

echo "Cleaning extended attributes..."
xattr -cr Shade.app

echo "Signing app..."
codesign --remove-signature Shade.app 2>/dev/null || true
codesign --force --deep --sign - \
    --entitlements Shade.entitlements \
    Shade.app

echo ""
echo "✅ Shade.app 构建完成"
echo ""
echo "首次运行方式："
echo "  方式A - 终端命令（最可靠）："
echo "    open /Users/qizhi/Desktop/shade/Shade/Shade.app"
echo ""
echo "  方式B - 图形界面："
echo "    1. 右键点击 Shade.app"
echo "    2. 选择'打开'"
echo "    3. 在弹出的对话框中点击'打开'"
echo ""
echo "  方式C - 如果上面都不行："
echo "    1. 打开 系统设置 → 隐私与安全 → 安全性"
echo "    2. 找到'已阻止使用 Shade'，点击'仍要打开'"
echo ""
echo "提示："
echo "  • 应用启动后不会在 Dock 显示"
echo "  • 看屏幕顶部菜单栏找 ◐ 图标"
echo "  • 首次启动会弹出授权提示窗口"
echo "  • 如果看不到遮罩效果，去 系统设置 → 辅助功能 授权"
echo ""
