#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
vk99_binary="$project_dir/dist/VK99 macOS.app/Contents/MacOS/VK99"
if [[ ! -x "$vk99_binary" ]]; then
    echo "Build the app first with scripts/build-app.sh" >&2
    exit 1
fi
if [[ $# -ne 1 && $# -ne 3 ]] || [[ ${1:-} != --confirm ]]; then
    echo "Usage: scripts/diagnose-clock.sh --confirm [--screen-index 1|2|3]" >&2
    echo "This sends the same four clock-sync reports used by the app." >&2
    exit 2
fi

output_dir="$project_dir/analysis/diagnostics"
mkdir -p "$output_dir"
stamp="$(date '+%Y%m%d-%H%M%S')"
prefix="$output_dir/clock-$stamp"
"$vk99_binary" scan > "$prefix-scan.json"
"$vk99_binary" read-feature > "$prefix-before.txt" || true
"$vk99_binary" clock-diagnose "$@" > "$prefix-trace.json"
"$vk99_binary" read-feature > "$prefix-after.txt" || true

python3 - "$prefix-trace.json" <<'PY'
import json, sys
path = sys.argv[1]
trace = json.load(open(path, encoding="utf-8"))
print("Trace:", path)
print("USB device:", trace["product"], "screen index:", trace["screenIndex"])
for step in trace["steps"]:
    print("-", step["name"], "SET", step["setReportStatus"],
          "GET", step.get("getReportStatus"),
          "response byte 3", step.get("responseByte3"),
          "Windows ACK", step.get("matchesWindowsAckCheck"),
          "write echo", step.get("isWriteEcho"))
    if step["name"] == "local time":
        packet = bytes.fromhex(step["sentHex"])
        print("  Sent local clock: %04d-%02d-%02d %02d:%02d:%02d" %
              (2000 + packet[3], packet[4], packet[5], packet[6], packet[7], packet[8]))
print("Compare the keyboard's displayed seconds with the Mac immediately after this run.")
print("A successful SET transfer or a write echo does not prove the keyboard clock changed.")
PY
