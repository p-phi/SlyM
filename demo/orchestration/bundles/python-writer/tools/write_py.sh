#!/usr/bin/env bash
set -euo pipefail
task=$(jq -r '.task // empty' <<<"$(cat)")
[[ -n "$task" ]] || { echo "error: missing 'task'" >&2; exit 1; }
printf '%s' "$task"
