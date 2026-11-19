# Neural Boolean Gate Routing Demo

A minimal, two-stage pipeline demonstrating how to use a constrained "System 1" LLM as a deterministic router, handing off control flow to standard Bash logic. 

Instead of asking an LLM to "decide what to do next" in free-text prose, this demo forces the model to perform a strict, bounded classification. The shell then reads that classification and executes the appropriate routing logic.

This demo is the companion to the reliability run report: it's the pipeline, the bundle, and the scripts that produced it.

## What it demonstrates

- **System 1 constraints** — by using a small, fast model (`kev-4b`) and enforcing `SLYM_MAX_ITERATIONS=1`, the agent is prevented from generating verbose prose or entering multi-turn tool loops.
- **Robust trace parsing** — extracting the tool's raw output cleanly using `jq -r '.trace.content | fromjson | .stdout'`, avoiding brittle regex or text-matching.
- **Separation of concerns** — the LLM handles *classification* (is the code broken?), and Bash handles *control flow* (if yes, route to reviewer; else, push to staging).
- **Predictable latency** — tight variance in execution time due to KV cache reuse and bounded generation.

## The pipeline

```text
code snippet 
  → slym (gate bundle, System 1 model, max 1 iteration)
  → jq (extract tool stdout: "yes" or "no")
  → bash if/else (route to Code Reviewer OR git push)
```

## Layout

Permalink: Layout

```text
.
├── bundles/
│   └── gate/             # System 1 classifier: outputs "broken" via tool if code has errors
├── pipeline.sh           # the routing pipeline
├── reliability_run.sh    # runs pipeline.sh N times, capturing time + trace
├── results.md            # the reliability run report
├── time_round_*          # per-round timing data
└── trace_round_*         # per-round console output traces
```

## Prerequisites

- `bash`, `curl`, `jq`
- Ollama running locally
- SlyM (`slym.sh` and `slym-show.sh`)

## Setup

Permalink: Setup

```bash
# start Ollama (if not running as a service)
ollama serve &

# the System 1 decision model
ollama pull turintech/kev-4b-artemis:2.5gb
```

Point the pipeline at your SlyM binary:

```bash
export DEMO_SLYM_BIN="../../slym.sh"   # or wherever slym is
```

## Run it

Permalink: Run it

```bash
./pipeline.sh
```

That's the whole demo: one command, one constrained agent, one pipe. It evaluates two scenarios:
1. A syntactically broken JavaScript snippet → Routes to "Code Reviewer".
2. A valid JavaScript snippet → Routes to "git push to staging".

## Read the receipts

Permalink: Read the receipts

To see exactly how the model arrived at its decision, you can inspect the raw trace. Modify `pipeline.sh` to save the intermediate output, then run:

```bash
# Render the full trace, showing the tool call and its raw stdout
slym-show --tools < gate-trace.jsonl
```

## How the parsing works

Permalink: How the parsing works

The core of this demo's reliability is this single `jq` pipeline:

```bash
jq -r '.trace.content | fromjson | .stdout'
```

SlyM records tool outputs as JSON-escaped strings within the `content` field of the assistant's trace. By piping the trace through `jq`, we first `fromjson` to parse that escaped string back into a JSON object, and then extract the `.stdout` field. 

This guarantees that the Bash `if [[ "$IS_CODE_BROKEN" == "yes" ]]` statement receives a clean, predictable string, completely insulated from any potential formatting quirks or hallucinated prose from the LLM.

## The reliability run


```bash
./reliability_run.sh
```

Runs `pipeline.sh` 10 times, capturing timing and output. The results are analyzed in `results.md`.

**Headline:** The router correctly classified and routed the code in **10/10 runs**. End-to-end latency started at 2.75s (cold) and stabilized to **~2.65s** (warm), with a variance of only ~120ms across all runs. 

## Notes and caveats


- **Inference is CPU-only** in the recorded run (`ollama ps` → `100% CPU`); times are hardware-bound and will be significantly lower on GPU-accelerated setups.
- **`SLYM_MAX_ITERATIONS=1` is critical.** Without this constraint, the model might attempt to "explain" its reasoning or enter a multi-turn tool loop, destroying both the latency guarantees and the deterministic parsing.
- **`SLYM_THINK_BUFFER=0`** is set so the trace is emitted immediately, without buffering text-only turns.
- **This is a reliability check, not a broad benchmark.** It measures one specific binary classification task (syntactically broken vs. valid JS snippet) on one machine.

## What to look for


- **Zero prose leakage** — the router does not output "I think the code is broken because...". It just executes the tool, and the tool outputs "yes".
- **The `jq` extraction pattern** — a robust, framework-agnostic way to get deterministic data out of an LLM trace.
- **Tight latency variance** — the ~120ms difference between the fastest and slowest run proves the inference engine is efficiently reusing the KV cache for the identical prompt prefix.
- **The Bash `if` statement** — evidence that complex AI orchestration doesn't require complex AI frameworks. Standard shell logic is sufficient when the neural component is properly constrained.
