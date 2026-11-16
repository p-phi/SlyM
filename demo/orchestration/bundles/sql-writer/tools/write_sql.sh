#!/usr/bin/env bash
set -euo pipefail
# The sql-writer's LLM does the writing via SKILL.md; the tool echoes the
# task so the harness records it. Replace with a model call if you want the
# tool itself to generate.
task=$(jq -r '.task // empty' <<<"$(cat)")
[[ -n "$task" ]] || { echo "error: missing 'task'" >&2; exit 1; }
printf '%s' "$task"
