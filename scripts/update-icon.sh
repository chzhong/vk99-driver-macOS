#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
source_png="$project_dir/Resources/VK99-icon-source.png"
iconset_dir="$project_dir/.build/VK99.iconset"
mkdir -p "$iconset_dir" "$project_dir/Resources"
swift "$project_dir/scripts/make-icon.swift" "$source_png" "$iconset_dir"
iconutil -c icns -o "$project_dir/Resources/VK99.icns" "$iconset_dir"
