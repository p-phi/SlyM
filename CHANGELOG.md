# Changelog

## [0.0.7]
### Added
- slymsh: SlyM integration for your shell (bash and zsh supported)
- slymsh installation into install.sh
- version and usage into slym-show

## [0.0.6]
### Fixed
- Fix E2BIG on jq by using pipes instead of heredocs"

## [0.0.5]
### Added
- Resumption support for interrupted `tool_call` traces
- `--no-tool` flag to exit 0 when a tool call is emitted
- Confidence score in system one trace
- `release.sh` script for versioning

## [0.0.4]
### Added
- `system-one` provider for bounded-decision endpoints, configurable with `SLYM_PROVIDER=system-one` and `SLYM_ENDPOINT`.
- `--tag` option for `slym`, with tags included in JSONL trace output.
- `slym-show` terminal visualizer for `slym` traces.
- `--flatten` flag for `slym-show` to hoist nested traces.
- `NO_SPINNER=1` to disable the spinner.
- Provider rate-limit throttling.
- Tool-schema path resolution checks.
- Demo for checkpoint resumption.
- Demo with reliability run and capped-iteration success switch.
- `release.sh` script for versioning.

### Changed
- Renamed `salaryman` to `slym`.
- `slym` is now trace-only; display is handled by `slym-show` or `jq`.
- Simplified tool schemas: parameters are key-value descriptions, `?` marks optional arguments, and parameter coercion is the bundle tool's responsibility.
- `slym-show` uses ANSI formatting when not in a TTY instead of requiring `gum`.
- Removed embedded system-one instructions from the harness.
- Prior trace is prepended to output trace when `--trace` is set; user prompt is prepended to LLM response trace.
- Stdin trace/prompt splitting now uses `is_slym_trace()`.
- Tool errors are included in the trace as `{ok, exit, stdout, stderr}`.
- `slym-show` can be used to compose pipelines.

### Fixed
- Double tag entries.
- Tool call failures now include tool errors in the trace.
- `slym-show --last`.
- Malformed bundle schema.
- `SPIN_PID` handling when running inside containers.
- Install script issues.
- Trace handling issues.

## [0.0.3] - 2026-11-08
### Added
- `--show-config` to display current config.
- `--trace` to output the trace to stdout.
- Stdin trace recognition; identified traces are prepended to the message thread.
- Task input via `--run` or stdin.
- Checkpoint creation and loading via trace JSONL.
- Agent piping with traces.
- Alternate task syntax: `salaryman bundle <<< "task 1"`.

### Removed
- `--verbose`.

## [0.0.2] - 2026-11-05
### Added
- UNIX piping capability.
- Quiet-by-default runtime; `--verbose` flag for runtime info.
- `run-bundle` and `run-and-make` bundle commands.
- Test suite using a containerized llama server and a 0.2b model.
- `SALARYMAN_THINK_BUFFER` for iterations without tool calls.
- Install script.
- `--version` flag.

### Changed
- Rebranded from "agent framework" to "shell-native agent runtime".
- Updated exit codes for usage and version.
- Reworked file tree.
- Registry now loads tools from the bundle top directory.
- Improved UI, logo, and `make-bundle` SKILL.md consistency.
- Improved UX.

### Fixed
- `SPIN_PID` when running inside containers.
- Version function.
- Install script issues.

## [0.0.1] - 2026-10-26
### Added
- Initial `salaryman` shell-native agent runtime.')
