#!/bin/sh
# 构建 Luma88（AppKit 单文件 GUI，无 Xcode 工程）
# 产物: dist/Luma88.app（本地可直接双击；对外分发需自行 codesign + notarization）
set -eu

cd "$(dirname "$0")/.."
APP="dist/Luma88.app"
BIN="$APP/Contents/MacOS/Luma88"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist

# 键位表来自官方 XML（生成文件，不进手改）
python3 scripts/gen_keymap.py

swiftc -O \
  -o "$BIN" \
  gui/Luma88.swift gui/generated/KeyLayout.swift src/T88Protocol.swift \
  -framework AppKit -framework IOKit -framework Foundation

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Luma88</string>
    <key>CFBundleDisplayName</key>
    <string>Luma88</string>
    <key>CFBundleIdentifier</key>
    <string>local.luma88.app</string>
    <key>CFBundleExecutable</key>
    <string>Luma88</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.2.0</string>
    <key>CFBundleVersion</key>
    <string>2</key>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>
    <string>Luma88 — T88 protocol notes in docs/protocol.md</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "构建完成: $APP"
echo "运行: open $APP"
