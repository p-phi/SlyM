#!/usr/bin/env bash

ROUNDS="${RELIABILITY_RUN_ROUNDS:-10}"

for ((i = 0; i < ROUNDS; i++)); do
    { time ./pipeline.sh > "reliability_runs/trace_round_$i"; } \
        2> "reliability_runs/time_round_$i"
    done
