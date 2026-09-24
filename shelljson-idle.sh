#!/bin/bash
# shelljson-idle.sh — set the idle block of ~/.config/omarchy/shell.json.
#
# The Omarchy 4.x plugin API exposes no idle.* surface to third-party
# services (barConfig only; the scoped mutateShellConfig covers the bar
# block alone), so the idle timings are written through the same file the
# user and the first-party idle service read. The shell hot-reloads
# shell.json on save; the idle service picks the new timeouts up live.
#
# Usage: shelljson-idle.sh <screensaver-seconds|null> <lock-seconds|null>
# A null/empty argument leaves that key untouched.
set -euo pipefail

screensaver="${1:-}"
lock="${2:-}"

[[ -n "$screensaver" || -n "$lock" ]] || { echo "usage: $0 <screensaver|null> <lock|null>" >&2; exit 1; }

path="$HOME/.config/omarchy/shell.json"

[[ -f "$path" ]] || { echo "shell.json not found: $path" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not found" >&2; exit 1; }

[[ "$screensaver" == "null" ]] && screensaver=""
[[ "$lock" == "null" ]] && lock=""

# Read-modify-write: jq merges only the requested keys; everything else is
# preserved. Indentation matches the shell's own
# JSON.stringify(payload, null, 2) + "\n" output.
tmp="$(mktemp "$path.tmp.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

filter='.'
[[ -n "$screensaver" ]] && filter="$filter | .idle = (.idle // {}) | .idle.screensaver = $screensaver"
[[ -n "$lock" ]] && filter="$filter | .idle = (.idle // {}) | .idle.lock = $lock"

jq --argjson screensaver "${screensaver:-0}" --argjson lock "${lock:-0}" "$filter" "$path" > "$tmp" \
  || { echo "jq transform failed" >&2; exit 1; }

# Sanity: the result must still be valid JSON containing an idle block.
jq -e '.idle | type == "object"' "$tmp" >/dev/null || { echo "refusing to write: idle block missing" >&2; exit 1; }

mv "$tmp" "$path"
trap - EXIT
echo "ok"
