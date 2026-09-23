#!/bin/bash
# Process-level CLI checks. This script never creates a display.
set -euo pipefail
binary=${1:-.build/debug/vdisplay}
mode=${2:-}
if [[ -n "$mode" && "$mode" != --no-display ]]; then
    echo 'Usage: test-cli.sh [BINARY] [--no-display]' >&2
    exit 2
fi
if [[ ! -x "$binary" ]]; then
    echo "Build vdisplay before running this script." >&2
    exit 1
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
"$binary" --help > "$work/help" 2> "$work/error"
grep -q 'Usage:' "$work/help"
[[ ! -s "$work/error" ]]
"$binary" presets > "$work/presets"
grep -q '4k-hidpi' "$work/presets"
for arguments in 'run missing-preset' 'run --config /nonexistent/vdisplay-test.json' 'unknown' 'run --width 0 --height 1080' 'run --width 1920 --height 1080 --refresh 120'; do
    set +e
    # Intentionally split these fixed test arguments; no user input is evaluated.
    "$binary" $arguments > "$work/output" 2> "$work/error"
    status=$?
    set -e
    [[ "$status" -eq 2 ]]
    [[ ! -s "$work/output" ]]
    [[ -s "$work/error" ]]
done
if [[ "$mode" != --no-display ]]; then
    "$binary" list --json > "$work/displays.json" 2> "$work/error"
    jq -e 'type == "array" and all(.[]; (.displayID | type) == "number")' "$work/displays.json" > /dev/null
    [[ ! -s "$work/error" ]]
fi
echo "CLI process checks passed. No display was created."
