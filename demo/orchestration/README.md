# Orchestration demo: rewrite → route → specialize

A three-agent pipeline built on SlyM. A messy request is **rewritten** into a clean task, **routed** to the right specialist by a fast decision model, and **handled** by a generative specialist. Every stage leaves a trace.

This demo is the companion to the [reliability run report](results.md): it's the pipeline, the bundles, and the scripts that produced it.

## What it demonstrates

- **Agents are bundles** — each agent is a directory (`SKILL.md`, `schemas/`, `tools/`), not framework code.
- **Routing is a decision** — the router uses a **System 1** model: it selects from a bounded list of tools and produces no free-text prose.
- **Two models, one pipe** — the router runs on `kev-4b` (System 1); the rewriter and specialist run on `granite4.1:3b` (generative). The per-tool env (`WORKER_*`) is how the specialist gets its own model.
- **The trace is the state** — each stage's trace is `tee`'d to a file, so the task, the routing decision, and the work are all auditable.

## The pipeline

```
user prompt
  → rewriter        (generative: messy request → clean task)
  → router          (System 1: pick to_sql or to_python)
  → specialist      (generative: write the SQL / Python)
  → router exit
```

## Layout

```
.
├── bundles/
│   ├── rewriter/       # generative: messy request → clean task
│   ├── triage/         # System 1 router: to_sql | to_python
│   ├── sql-writer/     # generative: write the SQL
│   └── python-writer/  # generative: write the Python
├── pipeline.sh         # the three-agent pipeline
├── reliability_run.sh  # runs pipeline.sh N times, capturing time + trace
├── results.md          # the reliability run report
├── reliability_run/    # per-round traces and timings
├── router-trace.jsonl  # the routing record (last run)
└── sql-writer.jsonl    # the specialist's trace (last run)
```

## Prerequisites

- `bash`, `curl`, `jq`
- [Ollama](https://ollama.com) running locally
- SlyM (`slym` and `slym-show`)

## Setup

```bash
# start Ollama (if not running as a service)
ollama serve &

# the generative model
ollama pull granite4.1:3b

# the System 1 decision model
ollama pull turintech/kev-4b-artemis:2.5gb
```

Point the pipeline at your SlyM binary:

```bash
export DEMO_SLYM_BIN="../../slym.sh"   # or wherever slym is
```

`pipeline.sh` sets the model endpoints itself — no other env is required.

## Run it

```bash
./pipeline.sh
```

That's the whole demo: one command, three agents, two models, one pipe. It writes:

- **`router-trace.jsonl`** — the routing record: the router's decision (`tool_calls`) plus the specialist's trace, nested in the tool result.
- **`sql-writer.jsonl`** — the specialist's trace (via the `tee` inside the router's tool).

## Read the receipts

```bash
# the routing record, rendered
slym-show < router-trace.jsonl

# the specialist's own trace
slym-show < sql-writer.jsonl
```

## How the specialist gets its own model

The router's tool is a `slym` call. It reads the **pre-router trace** (saved in `$TRACE_FILE`) — the *task*, not the routing — and runs the specialist with the **`WORKER_*`** env vars:

```bash
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
  "$SLYM_BIN" --tag sql bundles/sql-writer \
  | tee "${SLYM_TRACE_DIR:-.}/sql-writer.jsonl" \
  | slym-show --raw --flatten \
  && printf "\n%s" "WORK DONE"


```

So the router runs on `kev-4b`, the specialist on `granite4.1:3b`, and **neither the harness nor the bundle has to know** — the tool sets its own env.

## The reliability run

```bash
./reliability_run.sh
```

Runs `pipeline.sh` 10 times (configurable via `BENCHMARK_ROUNDS`), writing each round's trace and timing to `reliability_run/`. The results are analyzed in [`results.md`](results.md).

**Headline:** the router selected `to_sql` in 10/10 runs; end-to-end time was 7–11s in 9/10 runs (CPU-only); one run took 54s due to 3 clarification rounds from the specialist; one run produced prose instead of SQL. The variance is in the **generative** stage, not the routing.

## Notes

- **Inference is CPU-only** in the recorded run (`ollama ps` → `100% CPU`); the models run via `llamacpp`. Times are CPU-bound and will vary with hardware.
- **`SLYM_THINK_BUFFER=0`** is set in `pipeline.sh` so the trace is emitted immediately, without buffering text-only turns.
- **The demo is not a speed benchmark.** It's a reliability check on one task, one specialist, one laptop. See [`results.md`](results.md) for scope and caveats.

## What to look for

- **The rewriter's output is the task** — the specialist sees the clean sentence (via `$TRACE_FILE`), not the router's decision.
- **The router's decision is a tool call** — `to_sql`, chosen by a System 1 model; the decision is *in the trace*, so it's auditable.
- **Two models, one pipe** — `WORKER_*` is how the specialist gets its own model, without the harness knowing.
- **Every step leaves a receipt** — `$TRACE_FILE` is the task; `router-trace.jsonl` is the routing record; `sql-writer.jsonl` is the work.

