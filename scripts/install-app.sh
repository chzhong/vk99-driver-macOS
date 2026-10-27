#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
source_app="$project_dir/dist/VK99 macOS.app"
destination_app="$HOME/Applications/VK99 macOS.app"

if [ ! -d "$source_app" ]; then
    echo "Build the app first with scripts/build-app.sh" >&2
    exit 1
fi

mkdir -p "$HOME/Applications"
ditto "$source_app" "$destination_app"
codesign --verify "$destination_app"
open "$destination_app"
printf 'Installed and opened: %s\n' "$destination_app"
printf '%s\n' 'Check the app window for the macOS login-item status.'
