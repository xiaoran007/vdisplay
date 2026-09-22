#!/bin/bash
# Process-level CLI checks. This script never creates a display.
set -euo pipefail
binary=${1:-.build/debug/vdisplay}
if [[ ! -x "$binary" ]]; then
    echo "Build vdisplay before running this script." >&2
    exit 1
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
"$binary" --help > "$work/help" 2> "$work/error"
grep -q 'Usage:' "$work/help"
[[ ! -s "$work/error" ]]
for arguments in 'unknown' 'run --width 0 --height 1080' 'run --width 1920 --height 1080 --refresh 120'; do
    set +e
    # Intentionally split these fixed test arguments; no user input is evaluated.
    "$binary" $arguments > "$work/output" 2> "$work/error"
    status=$?
    set -e
    [[ "$status" -eq 2 ]]
    [[ ! -s "$work/output" ]]
    [[ -s "$work/error" ]]
done
"$binary" list --json > "$work/displays.json" 2> "$work/error"
jq -e 'type == "array" and all(.[]; (.displayID | type) == "number")' "$work/displays.json" > /dev/null
[[ ! -s "$work/error" ]]
echo "CLI process checks passed. No display was created."
