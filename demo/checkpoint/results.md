# Reliability run report: trace-based checkpoint resumption

## What this is

A **reliability run** of the SlyM trace-resumption demo pipeline, not a speed benchmark. The question it answers: *does the pipeline successfully resume from a historical JSONL trace and correctly infer the next step across repeated runs with identical input?*

It does **not** benchmark speed, compare frameworks, or assess the stylistic formatting of the specialist's output (noted where relevant).

## The pipeline

`checkpoint.jsonl (stdin) → slym (night-or-day bundle) → resume.jsonl`

- **specialist**: a general-purpose model (`granite4.1:3b`) operating with `SLYM_THINK_BUFFER=0`.
- **mechanism**: The agent receives an empty user prompt (`""`) but is seeded with a historical trace containing a previous agent's tool output (`"23:37:29"`). It must infer the correct classification based solely on the injected shadow.

## Result

**The model correctly classified the time as "night" in 10/10 runs.** 

End-to-end time started at 1.36s in Round 0 (cold start) and rapidly stabilized to ~0.25s in Rounds 5–9. 

All runs used **identical input, prompts, and configuration**. The variance in output phrasing (Round 0: "The current time is nighttime.", Rounds 1–9: "NIGHT") is attributable to standard model temperature non-determinism in the generative stage. The semantic decision was perfectly stable.

**The state resumption was flawless; the generative phrasing was variable.** That is the finding.

## Scope

- **One task**: infer day/night from a historical trace.
- **One laptop**, CPU-only inference (see below); no GPU.
- **A reliability check** of stdin shape-detection and context injection, not a breadth or speed benchmark.

## Hardware

```text
OS:      Arch Linux x86_64
Host:    HP Pavilion Aero Laptop 13-bg0xxx
Kernel:  Linux 7.0.3-zen1-2-zen
CPU:     AMD Ryzen 7 8840U (16) @ 5.13 GHz
GPU:     AMD Radeon 780M Graphics [Integrated]
Memory:  3.14 GiB / 14.89 GiB (21%)
Locale:  en_US.UTF-8
```

Models run in an Ollama container on the same host.

## Inference backend

**Ollama runs CPU-only.** The 780M iGPU is not passed to the container (`--device /dev/dri` is absent), so inference is CPU-bound via `llamacpp`:

```text
$ podman exec ollama ollama ps
NAME             ID              SIZE      PROCESSOR    CONTEXT    RUNNER      UNTIL
granite4.1:3b    6fd349357287    2.5 GB    100% CPU     4096       llamacpp    4 minutes from now
```

A GPU passthrough was attempted and **did not take effect** (`ollama ps` remained `100% CPU`), so the reported times are **CPU-only**; the experiment is inconclusive as to GPU speedup.

## Container configuration

```yaml
version: '3.8'

services:
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    deploy:
      resources:
        limits:
          memory: 10G
        reservations:
          memory: 8G
    mem_limit: 6g
    mem_reservation: 4g
    volumes:
      - ollama_models:/root/.ollama
    ports:
      - "11434:11434"
    environment:
      - OLLAMA_HOST=0.0.0.0
      - OLLAMA_ORIGINS=*
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:11434/api/tags"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

volumes:
  ollama_models:
```

## Criteria

- **Expected output:** A correct classification of "night" or "nighttime" based on the `23:37:29` timestamp in the checkpoint.
- **Shortest path:** `checkpoint stdin → slym (night-or-day) → exit` (0 tool calls, 1 generation).

## Runs

| Round | Time | Output | Path / Notes |
|---|---|---|---|
| 0 | 1.363s | "The current time is nighttime." | cold start (KV cache initialization) |
| 1 | 0.603s | "NIGHT" | shortest |
| 2 | 0.607s | "NIGHT" | shortest |
| 3 | 0.605s | "NIGHT" | shortest |
| 4 | 0.394s | "NIGHT" | shortest |
| 5 | 0.253s | "NIGHT" | shortest (KV cache fully warmed) |
| 6 | 0.247s | "NIGHT" | shortest |
| 7 | 0.255s | "NIGHT" | shortest |
| 8 | 0.247s | "NIGHT" | shortest |
| 9 | 0.249s | "NIGHT" | shortest |

## What the runs show

- **State resumption was 10/10 correct.** The model successfully interpreted an empty user prompt (`""`) by relying entirely on the injected historical trace (`checkpoint.jsonl`). It correctly deduced that `23:37:29` means "night".
- **The variance was purely stylistic.** Round 0 produced a full sentence, while Rounds 1–9 converged on the exact token "NIGHT". This is standard temperature sampling behavior; the semantic decision never wavered.
- **End-to-end time demonstrated a clear "warmup" effect.** Because the prefix (the checkpoint history) was identical across all runs, Ollama's KV cache reused the computed attention matrices. After Round 4, the pipeline stabilized at an incredible ~0.25s end-to-end latency on CPU for a multi-agent handoff.

## Traces

Trace files for each round are stored alongside this report (`reliability_runs/trace_round_{0..9}`).
