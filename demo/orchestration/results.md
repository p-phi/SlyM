# Reliability run report: orchestration demo

## What this is

A **reliability run** of the SlyM orchestration demo pipeline, not a speed benchmark. The question it answers: *does the pipeline complete, and does the router make the right decision, across repeated runs with identical input?*

It does **not** benchmark speed, compare frameworks, or assess the correctness of the specialist's output (noted where relevant).

## The pipeline

`user prompt → prompt rewriter → router → specialist rewriter`

- **rewriter** and **specialist**: a general-purpose model (`granite4.1:3b`)
- **router**: a *System 1* model (`turintech/kev-4b-artemis:2.5gb`), which selects from a bounded list of tools and produces no free-text prose.

## Result

**The router selected `to_sql` in 10/10 runs.** End-to-end time was 7–11s in 9/10 runs, with one run (Round 7) at 54s due to 3 clarification rounds from the specialist. In one run (Round 8), the specialist produced prose instead of SQL.

All runs used **identical input, prompts, and configuration**, so the variance is attributable to **model non-determinism in the generative stages**—not to changes in the pipeline.

**The routing decision was stable; the generative stages were variable.** That is the finding.

## Scope

- **One task**, one expected specialist (`to_sql`), one laptop.
- **CPU-only** inference (see below); no GPU.
- **A reliability check**, not a breadth or speed benchmark.

## Hardware

```
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

```
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

- **Expected specialist choice:** `to_sql`
- **Shortest path:** `user → rewriter → router → specialist → router → exit`

## Runs

| Round | Time | Specialist choice | Path |
|---|---|---|---|
| 0 | 7.027s | `to_sql` | shortest |
| 1 | 7.301s | `to_sql` | shortest |
| 2 | 10.004s | `to_sql` | shortest |
| 3 | 10.456s | `to_sql` | shortest |
| 4 | 8.412s | `to_sql` | shortest |
| 5 | 11.043s | `to_sql` | shortest |
| 6 | 7.785s | `to_sql` | shortest |
| 7 | **53.815s** | `to_sql` | **longest** — specialist asked for additional information 3 times before generating the SQL |
| 8 | 7.965s | `to_sql` | shortest — **output was prose, not SQL** |
| 9 | 7.957s | `to_sql` | shortest |

## What the runs show

- **Routing was correct in 10/10 runs**, including the two runs where the specialist diverged. The router was not the source of variance.
- **The variance was downstream**, in the generative specialist: one run looped on clarification (3 extra rounds → 54s), one produced prose instead of SQL. **Same input, same config—model non-determinism.**
- **End-to-end time** was 7–11s in 9/10 runs; the outlier is explained by the extra generative rounds, not by routing or pipeline overhead.

## Traces

Trace files for each round are stored alongside this report (`results/trace_round_{0..9}.jsonl`).

