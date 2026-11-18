# Trace-based checkpoint resumption demo

A single-agent pipeline built on SlyM that demonstrates **state resumption via stdin shape detection**. A historical trace (`checkpoint.jsonl`) is piped into a new agent, which continues the conversation and classifies the time from the previous agent's tool output (`23:37:29`) — with an **empty user prompt**. The answer comes from the trace, not the prompt, and the counterfactual below proves it.

This demo is a companion to the [reliability run report](results.md): it's the pipeline, the bundle, and the scripts that produced it.

## What it demonstrates

- **The trace is the state** — no databases, no session IDs, no framework memory. Piping a historical JSONL trace into `slym` resumes the conversation, because the harness injects the trace as the conversation so far.
- **The empty prompt proves it** — the agent receives `""` as its prompt and still classifies the time as "night," by reading the prior tool output (`23:37:29`) from the injected trace. Without the trace, it says it has no information (see [the counterfactual](#the-counterfactual)).
- **Tag-based observability** — each stage's output is explicitly tagged (e.g., `time`, `day_night`), so the handoff is trivial to filter and audit.
- **KV cache reuse** — repeated runs with an identical prefix stabilize in latency as the inference backend reuses cached attention matrices (measured below, not assumed).

## The pipeline

```text
checkpoint.jsonl (historical trace)
  → slym (night-or-day bundle, granite4.1:3b)
  → resume.jsonl (auditable output)
```

## Layout

```text
.
├── bundles/
│   └── night-or-day/     # generative: classifies time from historical trace
├── checkpoint.jsonl      # the historical trace from a previous agent
├── pipeline.sh           # the resumption pipeline
├── reliability_run.sh    # runs pipeline.sh N times, capturing time + trace
├── results.md            # the reliability run report
├── reliability_runs/     # per-round traces and timings
└── resume.jsonl          # the combined trace (last run)
```

## Prerequisites

- `bash`, `curl`, `jq`
- [Ollama](https://ollama.com) running locally
- SlyM (`slym.sh` and `slym-show.sh`)

## Setup

```bash
# start Ollama (if not running as a service)
ollama serve &

# the generative model
ollama pull granite4.1:3b
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

That's the whole demo: one command, one agent, one pipe. It writes:

- **`resume.jsonl`** — the combined trace, containing both the historical `time` events and the new `day_night` classification.

## Read the receipts

```bash
# the full resumption trace, rendered
slym-show < resume.jsonl

# only the new agent's contribution
jq 'select(.tags[] == "day_night")' resume.jsonl | slym-show
```

## How state resumption works

The mechanism is standard Unix redirection:

```bash
SLYM_ENDPOINT="http://localhost:11434/v1/chat/completions" \
SLYM_MODEL="granite4.1:3b" \
"$SLYM_BIN" bundles/night-or-day --tag day_night \
    < checkpoint.jsonl \
    | tee resume.jsonl
```

SlyM's stdin shape detection reads `checkpoint.jsonl`: it recognizes the wrapped JSONL format, unpacks the historical messages, and **injects them as the conversation so far**, before the new (empty) user prompt. The model continues that conversation — it isn't told it's a "new" run; the harness has made the trace the conversation.

## The counterfactual

The claim is that the answer comes from the trace, not the prompt. The proof is to run the same bundle with **no checkpoint**:

```bash
SLYM_ENDPOINT="http://localhost:11434/v1/chat/completions" \
SLYM_MODEL="granite4.1:3b" \
"$SLYM_BIN" bundles/night-or-day --tag day_night \
    | tee no-checkpoint.jsonl
```

Output:

```jsonl
{"app":"slym","tags":["day_night"],"trace":{"role":"user","content":""}}
{"app":"slym","tags":["day_night"],"trace":{"role":"assistant","content":"It appears there is no prior information provided about the current time, so I cannot definitively say whether it is DAY or NIGHT based on the available context. Please provide the current time or any relevant information that might indicate whether it is daytime or nighttime.","tool_calls":[]}}
```

**Same bundle, same model, same empty prompt — only the trace differs.**

| Run | Input | Output |
|---|---|---|
| With checkpoint | `23:37:29` in the trace | "NIGHT" (commits) |
| Without checkpoint | no trace | "I have no prior information" (defers) |

The model doesn't just get *more information* with the trace — it gets **the basis to commit**. Without it, it correctly defers rather than guessing. **That's the proof that the state is the trace.**

## The reliability run

```bash
./reliability_run.sh
```

Runs `pipeline.sh` 10 times (configurable via `RELIABILITY_RUN_ROUNDS`), writing each round's trace and timing to `reliability_runs/`. The results are analyzed in [`results.md`](results.md).

**Headline:** the model correctly classified the time as "night" in 10/10 runs. End-to-end time started at 1.36s (cold) and stabilized to ~0.25s (warm cache). The variance in phrasing (Round 0: "The current time is nighttime."; Rounds 1–9: "NIGHT") is standard temperature non-determinism; **the semantic decision was stable in 10/10 runs**.

## Notes and caveats

- **Inference is CPU-only** in the recorded run (`ollama ps` → `100% CPU`); the models run via `llamacpp`. Times are CPU-bound and will vary with hardware.
- **The KV-cache result is expected, not surprising.** The 1.36s → ~0.25s stabilization is what an inference engine *should* do with an identical prefix: the attention cache is reused. It's a *measurement* of that behavior, not a discovery.
- **This is in-context inference, not zero-shot.** The model has the full historical trace (including `23:37:29`) in its context. "Zero-shot" would mean no examples at all; this is the opposite — it's *entirely* context-driven.
- **The model isn't "aware" of resumption.** It isn't told it's a new run; it simply *sees* the conversation the harness injected and continues it. The resumption is the harness's doing, not the model's inference about its own process.
- **`SLYM_THINK_BUFFER=0`** is set in `pipeline.sh` so the trace is emitted immediately, without buffering text-only turns.
- **This is not a speed benchmark.** It's a reliability check on one task, one bundle, one laptop. See [`results.md`](results.md) for scope and caveats.

## What to look for

- **The empty user prompt** — the `day_night` agent receives `""`, and answers from the injected trace alone.
- **The counterfactual** — same setup, no checkpoint, no answer. The trace is the only difference.
- **Semantic stability** — 10/10 runs classify the time correctly from `23:37:29`, despite phrasing variance.
- **Latency warmup** — 1.36s cold → ~0.25s warm, as the backend reuses the cache for the identical prefix.
- **Every step leaves a receipt** — the `time` and `day_night` tags make it trivial to audit which agent produced which part of the trace.

