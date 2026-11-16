#!/usr/bin/env bash
set -euo pipefail

# stdin = the router's cumulative trace (or $TRACE_FILE if set).
# Keep the task (drop the router's lines), dispatch to sql-writer,
# and tee its trace to a linear file.

# env for the specialist: set only if the worker vars are non-empty
env_args=()
[[ -n "${WORKER_MODEL:-}"    ]] && env_args+=("SLYM_MODEL=${WORKER_MODEL}")
[[ -n "${WORKER_ENDPOINT:-}" ]] && env_args+=("SLYM_ENDPOINT=${WORKER_ENDPOINT}")

cat "${TRACE_FILE:--}" \
  | env "${env_args[@]}" \
  "$SLYM_BIN"  --tag sql bundles/sql-writer \
  | tee "${SLYM_TRACE_DIR:-.}/sql-writer.jsonl" \
  && echo "WORK DONE"

