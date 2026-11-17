#!/usr/bin/env bash

ROUNDS="${BENCHMARK_ROUNDS:-10}"

for ((i = 0; i < ROUNDS; i++)); do
    { time ./pipeline.sh > "benchmark_results/trace_round_$i"; } \
        2> "benchmark_results/time_round_$i"
    done
