# Reliability Run Report: Neural Boolean Gate Routing

## Headline
The router correctly classified and routed code snippets in **10/10 runs**. End-to-end latency stabilized at **~2.65s** after an initial cold start of **2.75s**, demonstrating highly predictable, low-variance System 1 inference.

## Latency Analysis
The pipeline was executed 10 times consecutively. The timing data shows a classic cold-to-warm cache stabilization pattern, with exceptionally tight variance.

| Round | Real Time | Status |
| :--- | :--- | :--- |
| 0 | 2.754s | Cold start |
| 1 | 2.678s | Warm |
| 2 | 2.690s | Warm |
| 3 | 2.676s | Warm |
| 4 | 2.655s | Warm |
| 5 | 2.643s | Warm |
| 6 | 2.648s | Warm |
| 7 | 2.634s | Warm |
| 8 | 2.640s | Warm |
| 9 | 2.632s | Warm (Fastest) |

- **Cold Start**: 2.754s
- **Warm Average (Rounds 1–9)**: ~2.655s
- **Variance**: ~120ms (max difference between fastest and slowest run)

## Accuracy & Reliability
**100% Accuracy (10/10 runs).** 

In every single round, the pipeline produced the exact expected routing behavior:
- **Broken code input** (`function broken() { return`) → Correctly identified and output `→ Routing to: Code Reviewer`.
- **Valid code input** (`function valid() { return; }`) → Correctly identified and output `→ git push to staging`.

There was zero prose leakage, no misclassification, and no deviation in the routing decision. The strict bounding of the System 1 model (`turintech/kev-4b-artemis:2.5gb`) combined with the `jq` JSON parsing pipeline proved to be a highly robust mechanism for extracting deterministic boolean states from LLM tool outputs.

## Notes and Caveats
- **Inference is CPU-only**: The recorded run used Ollama running via `llamacpp` on CPU (`ollama ps` → `100% CPU`). 
- **This is a reliability check, not a broad benchmark**: This measures one specific binary classification task (syntactically broken vs. valid JS snippet) on one laptop. 
- **`SLYM_MAX_ITERATIONS=1` is critical**: This environment variable enforces the "System 1" behavior. Without it, the model might attempt to "explain" its reasoning or enter a multi-turn tool loop, destroying both the latency guarantees and the deterministic parsing.
- **The `jq` parsing pattern is robust**: Using `jq -r '.trace.content | fromjson | .stdout'` cleanly extracts the tool's raw output without relying on brittle regex or text-matching, ensuring the Bash routing logic receives a clean `yes`/`no` string.

## Conclusion
This demo corroborates the feasibility of a minimal, Unix-native pipeline can achieve production-grade routing reliability. By delegating *classification* to a constrained, fast LLM and delegating *control flow* to a simple Bash `if` statement, the system achieves sub-3-second latency with zero framework overhead and perfect auditability.
