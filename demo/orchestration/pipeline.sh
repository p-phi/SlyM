#!/usr/bin/env bash

export TRACE_FILE
TRACE_FILE=$(mktemp)
export SLYM_BIN="../../slym.sh"
# rewriter → triage (System 1) → specialist, each trace tee'd

# preprocess → route (the router's tool does the rest)
SLYM_ENDPOINT="http://localhost:11434/v1/chat/completions" \
SLYM_MODEL="granite4.1:3b" \
"$SLYM_BIN" bundles/rewriter --tag rewriter --run "uhh show me users who signed up last month" \
  | tee "$TRACE_FILE" \
  | SLYM_ENDPOINT="http://localhost:11434/v1/systemone" \
    SLYM_MODEL="turintech/kev-4b-artemis:2.5gb" \
    WORKER_ENDPOINT="http://localhost:11434/v1/chat/completions" \
    WORKER_MODEL="granite4.1:3b" \
    "$SLYM_BIN" --tag router --provider system-one bundles/triage \
  | tee router-trace.jsonl

