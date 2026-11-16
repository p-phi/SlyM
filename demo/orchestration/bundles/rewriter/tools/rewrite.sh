#!/usr/bin/env bash
set -euo pipefail
# The rewriter's LLM does the rewriting via SKILL.md; the tool passes the
# request through so the harness records it as a tool result.
req=$(jq -r '.request' <<<"$(cat)")
[[ -n "$req" ]] || { echo "error: missing 'request'" >&2; exit 1; }
printf '%s' "$req"
