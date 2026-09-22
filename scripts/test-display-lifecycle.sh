#!/bin/bash
# Opt-in hardware integration test: temporarily creates one extended display.
# Existing window positions may change when macOS adds/removes the display.
set -euo pipefail
binary=${1:-.build/debug/vdisplay}
width=${2:-1920}
height=${3:-1080}
scale=${4:-1}
command -v jq > /dev/null
work=$(mktemp -d)
child=''
cleanup() {
    if [[ -n "$child" ]] && kill -0 "$child" 2>/dev/null; then
        kill -TERM "$child"
        for ((attempt=0; attempt<70; attempt++)); do
            kill -0 "$child" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "$child" 2>/dev/null; then kill -KILL "$child"; fi
        wait "$child" 2>/dev/null || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT
"$binary" list --json > "$work/before.json"
"$binary" run --name 'vdisplay Lifecycle Test' --width "$width" --height "$height" --scale "$scale" > "$work/ready.json" 2> "$work/log" &
child=$!
ready=false
for ((attempt=0; attempt<100; attempt++)); do
    if [[ -s "$work/ready.json" ]] && jq -e '.displayID > 0' "$work/ready.json" > /dev/null 2>&1; then
        ready=true
        break
    fi
    if ! kill -0 "$child" 2>/dev/null; then break; fi
    sleep 0.1
done
if [[ "$ready" != true ]]; then
    cat "$work/log" >&2
    echo 'Display did not report readiness.' >&2
    exit 1
fi
id=$(jq -r '.displayID' "$work/ready.json")
jq -e --argjson width "$width" --argjson height "$height" --argjson scale "$scale" '
    .ownership == "this-process" and
    .mode.pixelWidth == $width and .mode.pixelHeight == $height and
    .mode.logicalWidth == ($width / $scale) and .mode.logicalHeight == ($height / $scale)
' "$work/ready.json" > /dev/null
"$binary" list --json > "$work/during.json"
jq -e --argjson id "$id" 'any(.[]; .displayID == $id)' "$work/during.json" > /dev/null
kill -TERM "$child"
for ((attempt=0; attempt<70; attempt++)); do
    kill -0 "$child" 2>/dev/null || break
    sleep 0.1
done
if kill -0 "$child" 2>/dev/null; then
    cat "$work/log" >&2
    echo 'Display owner did not exit after SIGTERM.' >&2
    exit 1
fi
wait "$child"
child=''
"$binary" list --json > "$work/after.json"
jq -e --argjson id "$id" 'all(.[]; .displayID != $id)' "$work/after.json" > /dev/null
jq -e -s '([.[0][].displayID] | sort) == ([.[1][].displayID] | sort)' "$work/before.json" "$work/after.json" > /dev/null
cat "$work/ready.json"
cat "$work/log" >&2
echo "Lifecycle check passed: ${width}x${height}, scale ${scale}; initial display IDs restored."
