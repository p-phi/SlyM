#!/usr/bin/env bash
# Start llama.cpp's OpenAI-compatible server on 11434.
set -euo pipefail

: "${SLYM_MODEL_PATH:?SLYM_MODEL_PATH is not set}"

if [[ ! -f "$SLYM_MODEL_PATH" ]]; then
  echo "error: model not found: $SLYM_MODEL_PATH" >&2
  exit 1
fi

exec llama-server \
  -m "$SLYM_MODEL_PATH" \
  --host 127.0.0.1 --port 11434 \
  -c 1024 --parallel 1 \
  --no-webui \
  --log-disable
