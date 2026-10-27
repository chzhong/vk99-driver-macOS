#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/ModuleCache"
export XDG_CACHE_HOME="$project_dir/.build/cache"

swift build --disable-sandbox --scratch-path "$project_dir/.build"
binary_dir="$(swift build --disable-sandbox --scratch-path "$project_dir/.build" --show-bin-path)"
app_dir="$project_dir/dist/VK99 macOS.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/vk99" "$app_dir/Contents/MacOS/VK99"
cp "$project_dir/Resources/VK99.icns" "$app_dir/Contents/Resources/VK99.icns"
cp "$project_dir/Resources/SettingsCatalog.yaml" "$app_dir/Contents/Resources/SettingsCatalog.yaml"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>VK99</string>
    <key>CFBundleIdentifier</key><string>dev.vk99.macos</string>
    <key>CFBundleName</key><string>VK99 macOS</string>
    <key>CFBundleIconFile</key><string>VK99.icns</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.3.0</string>
    <key>CFBundleVersion</key><string>3</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app_dir"
printf '%s\n' "$app_dir"
