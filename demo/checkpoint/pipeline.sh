#!/usr/bin/env bash

# Demonstration of trace-based checkpoint handling.
# checkpoint.jsonl contains a recorded trace from a previous
# session with a different slym agent.
# The slym agent in this will attempt to resume from 
# the checkpoint file to generate the right answer.
export SLYM_THINK_BUFFER=0
export SLYM_BIN="${DEMO_SLYM_BIN:-../../slym.sh}"
export SLYM_SHOW_BIN="${DEMO_SLYM_BIN:-../../slym-show.sh}"


SLYM_ENDPOINT="http://localhost:11434/v1/chat/completions" \
SLYM_MODEL="granite4.1:3b" \
"$SLYM_BIN" bundles/night-or-day --tag day_night \
    < checkpoint.jsonl \
    | tee resume.jsonl \

