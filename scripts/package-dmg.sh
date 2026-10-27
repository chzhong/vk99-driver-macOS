#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
"$project_dir/scripts/build-app.sh"

app_dir="$project_dir/dist/VK99 macOS.app"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app_dir/Contents/Info.plist")"
dmg_path="$project_dir/dist/VK99-macOS-$version.dmg"
staging_dir="$(mktemp -d "$project_dir/.build/dmg-staging.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT

ditto "$app_dir" "$staging_dir/VK99 macOS.app"
ln -s /Applications "$staging_dir/Applications"
hdiutil create -volname "VK99 macOS" -srcfolder "$staging_dir" -format UDZO -ov "$dmg_path"
hdiutil verify "$dmg_path"
printf 'Created: %s\n' "$dmg_path"
