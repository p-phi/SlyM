#!/usr/bin/env bash
# =============================================================================
# SlyM
# -----------------------------------------------------------------------------
# A minimal agent defined by its skills.
#
# An agent is a harness plus a skill set. This script is the harness: it loads
# a skills directory, builds a tool registry from the schema files, and runs a
# loop: model -> tool call -> script -> result -> model. There is no general
# invocation path; the model can only ask for tools that a file declares.
#
# Environment:
#   SLYM_ENDPOINT   required; chat-completions URL
#   SLYM_MODEL      required; model name
#   SLYM_API_KEY    optional; bearer token for a hosted provider
#   SLYM_PROVIDER   optional; openai-compatible (default) | responses
#   SLYM_MAX_ITERATIONS  optional; loop cap, default 16
#   SLYM_THINK_BUFFER  optional; loop exit condition buffer
#   SLYM_REQUEST_INTERVAL  optional; enforce time gap (in seconds) between two model calls
#   SLYM_NO_SPINNER  optional; remove spinner animation between requests
#
# Source: https://github.com/p-phi/slym
# License: MIT — see the LICENSE file in the source repo.
# Author: P. Phi
# ============================================================================= 
set -euo pipefail

VERSION="0.0.6"
USAGE_ERROR=1

# ---------------------------------------------------------------- config
# Iteration control
MAX_ITERATIONS="${SLYM_MAX_ITERATIONS:-16}"
# If CAP_IS_SUCCESS is set to 1, reaching MAX_ITERATIONS exits 0
CAP_IS_SUCCESS="${SLYM_CAP_IS_SUCCESS:-0}"
# Allows the model to return pure text responses without tools for up to THINK_BUFFER rounds
THINK_BUFFER="${SLYM_THINK_BUFFER:-1}"
REQUEST_INTERVAL="${SLYM_REQUEST_INTERVAL:-0}"
NO_SPINNER="${SLYM_NO_SPINNER:-0}"
NO_TOOL=0
# Provider shape (default: OpenAI-compatible)
PROVIDER="${SLYM_PROVIDER:-openai-compatible}"
SPIN_PID=""
API_KEY=${SLYM_API_KEY:-}
# ---------------------------------------------------------------- args

TRACE_MESSAGES=""
SKILLS_DIR=""
TASK=""
TAGS=()
# Usage banner and command-line argument parsing
usage() {
  cat >&2 <<EOF
usage:
  slym <skills> --run <task> [--provider <name>]

options:
  --run <task>         run an agent on the given task
  --provider <name>    provider shape (default: openai-compatible)
  --tag <name>         tag trace lines (implies --trace); repeatable
  --show_config        show the current loaded configuration
  --no-tool            exits 0 on tool call after tracing it
  -h, --help           show this help
  -v, --version        show the version

providers:
  openai-compatible    OpenAI chat-completions shape (Ollama, Groq, Together, ...)
  system-one           System One shape (Jev, Laya, Kev...)

environment:
  SLYM_ENDPOINT   required; chat-completions URL
  SLYM_MODEL      required; model name
  SLYM_API_KEY    optional; bearer token for a hosted provider
  SLYM_PROVIDER   optional; default provider shape
  SLYM_MAX_ITERATIONS  optional; loop cap, default 16
  SLYM_CAP_IS_SUCCESS  optional; 1 = hitting the cap exits 0 (default 0 = exit 1)
  SLYM_THINK_BUFFER  optional; max rounds without tool, default 1
EOF
  exit "$USAGE_ERROR"
}
# Display version
version() {
  echo "SlyM v$VERSION"
  exit 0
}
# Print to stderr
log_stderr(){
  echo "[$1]$2" >&2
}
# Display config
show_config() {
  echo "SLYM_ENDPOINT=$SLYM_ENDPOINT" 
  echo "SLYM_MODEL=$SLYM_MODEL" 
  echo "SLYM_PROVIDER=$PROVIDER" 
  echo "SLYM_MAX_ITERATIONS=$MAX_ITERATIONS" 
  echo "SLYM_CAP_IS_SUCCESS=$CAP_IS_SUCCESS"
  echo "SLYM_THINK_BUFFER=$THINK_BUFFER"   
  exit 0
}
# Parse command-line arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run)
      [[ -n "${2:-}" ]] || usage
      TASK="$2"; shift 2 ;;
    --provider)
      [[ -n "${2:-}" ]] || usage
      PROVIDER="$2"; shift 2 ;;
    --no-tool) 
        NO_TOOL=1; shift ;;
    -h|--help)
      USAGE_ERROR=0
      usage ;;
    -v|--version)
      version ;;
    --show-config)
      show_config ;;
    --tag)
      [[ -n "${2:-}" ]] || usage
      [[ ! ${TAGS[*]} =~ $2 ]] && TAGS+=("$2")
      shift 2 ;;
    *)
      if [[ -z "$SKILLS_DIR" ]]; then
        SKILLS_DIR="$1"; shift
      else
        usage
      fi ;;
  esac
done

# ---------------------------------------------------------------- trace functions

wrap_message() {
  local tags_json='[]'
  if ((${#TAGS[@]})); then
    tags_json=$(printf '%s\n' "${TAGS[@]}" | jq -R . | jq -s -c .)
  fi
  jq -c --arg app "slym" --argjson tags "$tags_json" \
    '{app:$app, tags:$tags, trace:.}'
}
unwrap_message() { jq -c 'if has("app") and .app=="slym" then .trace else . end'; }
is_slym_trace() {
  jq -e 'type=="object" and .app=="slym" and has("trace")' >/dev/null 2>&1 <<<"$1"
}
# PIPE SUPPORT
# ---------------------------------------------------------------- stdin detection
# Two input kinds arrive on stdin, and they mean different things:
#   * a transcript  → resume it (the previous stage's trace becomes our state)
#   * anything else → task text (append to --run, as a plain pipe would)
# The distinction is made by *shape*, not by a flag, so | and < both work and
# need no ceremony. If stdin parses as messages, it is a conversation; if not,
# it is prompt text.
if [[ ! -t 0 ]]; then
  input=$(cat)
  # Separate trace lines from non-trace lines incase of mixed stdin input types
  mapfile -t lines <<<"$input"
  wrapped=(); rest=()
  for line in "${lines[@]}"; do
    if is_slym_trace "$line"; then
      echo "$line"
      wrapped+=("$line")
    else
      rest+=("$line")
    fi
  done
  
  if ((${#wrapped[@]})); then
    TRACE_MESSAGES=$(printf '%s\n' "${wrapped[@]}" | unwrap_message | jq -s -c '.')
  fi
  if ((${#rest[@]})); then
    TASK+="${TASK:+$'\n\n'}$(printf '%s\n' "${rest[@]}")"
  fi
fi

# ---------------------------------------------------------------- resume
# If stdin ended on an assistant tool_call with no tool result, and no new
# task was given, run the pending tool(s) and continue from there.
RESUME_TOOL_CALLS=""
if [[ -n "$TRACE_MESSAGES" && -z "$TASK" ]]; then
  last_role=$(printf '%s' "$TRACE_MESSAGES" | jq -r 'if length > 0 then .[-1].role else empty end')
  if [[ "$last_role" == "assistant" ]]; then
    pending=$(printf '%s' "$TRACE_MESSAGES" | jq -c '.[-1].tool_calls // []')
    if [[ "$(jq 'length' <<<"$pending")" -gt 0 ]]; then
      RESUME_TOOL_CALLS="$pending"
    fi
  fi
fi
# ----------------------------------------------------------------


# Validate required args and permissions
[[ -n "$SKILLS_DIR" ]] || usage
[[ -d "$SKILLS_DIR" ]] || { echo "error: skills dir not found: $SKILLS_DIR" >&2; exit 1; }

# Parse provider
case "$PROVIDER" in
  openai-compatible|system-one) ;;
  *) echo "error: unknown provider: $PROVIDER" >&2; usage ;;
esac

# ---------------------------------------------------------------- registry
# Path resolution helper
resolve_script() {
  local bundle_root="$1" raw="$2"
  # reject absolute and parent-traversal
  if [[ "$raw" == /* || "$raw" == *..* ]]; then
    echo "error: unsafe script path: $raw" >&2; return 1
  fi
  local resolved
  resolved="$(cd "$bundle_root" && pwd)/$raw"
  # ensure it's still under the bundle root after resolution (symlinks)
  local canon
  canon=$(realpath -m "$resolved" 2>/dev/null) || { echo "error: cannot resolve $raw" >&2; return 1; }
  if [[ "$canon" != "$(realpath -m "$bundle_root")"/* ]]; then
    echo "error: script escapes bundle: $raw" >&2; return 1
  fi
  printf '%s' "$canon"
}

declare -A SCRIPT=() DECLS=()

# Loads all skills into SCRIPT map
load_registry() {
  local f name raw bundle_root resolved skillpath="$SKILLS_DIR/*/schemas/*.json"
  if [[ -f "$SKILLS_DIR/SKILL.md" ]]; then
    skillpath="$SKILLS_DIR/schemas/*.json"
  fi
  shopt -s nullglob
  for f in $skillpath; do
    name=$(jq -r '.name // empty' "$f")
    if [[ -z "$name" ]]; then
      echo "warning: schema without name: $f" >&2
      continue
    fi
    if [[ -n "${SCRIPT[$name]:-}" ]]; then
      echo "warning: duplicate tool '$name' in $f (ignored)" >&2
      continue
    fi

    # bundle root = parent of the schemas/ dir that contains this file
    bundle_root="$(cd "$(dirname "$f")/.." && pwd)"
    raw=$(jq -r '.script // empty' "$f")
    if [[ -z "$raw" ]]; then
      echo "warning: schema without script: $f" >&2
      continue
    fi
    if ! resolved=$(resolve_script "$bundle_root" "$raw"); then
      echo "warning: skipping tool '$name' (unsafe script path: $raw)" >&2
      continue
    fi

    SCRIPT["$name"]="$resolved"
    DECLS["$name"]="$f"
  done
  shopt -u nullglob
}
# ---------------------------------------------------------------- prompt

build_system_prompt() {
  local f out="You are a terminal assistant. Use the available tools when helpful."
  local skillpath="$SKILLS_DIR/*/SKILL.md"
  if [[ -f "$SKILLS_DIR/SKILL.md" ]]; then
    skillpath="$SKILLS_DIR/SKILL.md"
  fi
  shopt -s nullglob
  for f in $skillpath; do
    out+=$'\n\n'"$(cat "$f")"
  done
  shopt -u nullglob
  printf '%s' "$out"
}

# ---------------------------------------------------------------- model client
# build_tools_json() translates bundle schemas into provider-friendly API schemas, setting type: string as parameter type.
# Example of bundle schema:
# {
    # "name": "get_posts",
    # "description": "Get the last N posts of a Bluesky profile, newest first.",
    # "script": "tools/get_posts.sh",
    # "parameters": {
    #     "handle": "Bluesky handle, e.g. alice.bsky.social.",
    #     "limit?": "Number of posts to fetch, 1 to 50. Defaults to 10."
    # }
# }
# N.B: the character '?' at the end of 'limit?' signals an optional parameter.

build_tools_json() {
  if [[ ${#DECLS[@]} -eq 0 ]]; then printf '[]'; return; fi
  local name f
  for name in "${!DECLS[@]}"; do
    f="${DECLS[$name]}"
    jq -c '
      { type: "function",
        function: {
          name: .name,
          description: .description,
          parameters: (
            .parameters
            | to_entries
            | { type: "object",
                properties: (
                  map({ key: (.key | rtrimstr("?")),
                        value: { type: "string", description: .value } })
                  | from_entries ),
                required: ( map(select(.key | endswith("?") | not) | .key) ) }
          )
        }
      }' "$f"
  done | jq -s -c '.'
}

call_model() {
  local messages_json="$1"
  case "$PROVIDER" in
    openai-compatible) printf '%s' "$messages" | call_openai_compatible ;;
    system-one) printf '%s' "$messages" | call_systemone ;;
    *) echo "error: unknown provider: $PROVIDER" >&2; return 1 ;;
    # responses)         call_responses "$messages_json" ;;
  esac
}


call_openai_compatible() {
  local tools_json
  tools_json=$(build_tools_json)

  # the conversation streams through the rewrite into the payload builder;
  # messages: . reads it from stdin (no --argjson, no E2BIG)
  printf '%s' "$messages_json" \
    | jq -c '
        [ .[] | if .tool_calls then
            .tool_calls = [ .tool_calls[] | {
              id: .id,
              type: "function",
              function: {name: .name, arguments: (.arguments | tojson)}
            } ]
          else . end ]
      ' \
    | jq -c \
        --arg model "$SLYM_MODEL" \
        --argjson tools "$tools_json" \
        '{model: $model, messages: ., tools: $tools, stream: false}' \
    | post_json
}

# -------------- System One Provider-------------------------
# 1. Zero-Argument Tools Only: 
# Because System One models classify into fixed choices rather than generating 
# free-form JSON arguments, `arguments` will always be `{}`. 
# This works great for parameterless scripts (e.g., `check_disk.sh`, `run_tests.sh`, 
# `fetch_queue.sh`) or skill/sub-agent routing, 
# where the tool reads from stdin/environment rather than LLM-invented parameters.

# call_systemone: reads the conversation from stdin (JSON array),
# streams it into the payload builder, pipes to post_json.
# system and criteria stay --arg / --argjson (usually small).
call_systemone() {
  local system criteria_json

  # read the conversation once (it's used twice: system-extract and turns)
  conv=$(cat)

  system=$(printf '%s' "$conv" | jq -r '[.[] | select(.role=="system") | .content] | join("\n\n")')

  criteria_json=$(
    if [[ ${#DECLS[@]} -gt 0 ]]; then
      for name in "${!DECLS[@]}"; do
        jq -c '{key: .name, value: .description}' "${DECLS[$name]}"
      done
    fi | jq -s -c 'from_entries + {"__done__": "No further tool calls needed; task is complete."}'
  )

  # the conversation streams through; turns become `state: .` (no --argjson state)
  printf '%s' "$conv" \
    | jq -c '[.[] | select(.role!="system")]' \
    | jq -c \
        --arg model "${SLYM_MODEL:-}" \
        --argjson criteria "$criteria_json" \
        --arg instr "$system" \
      '{
        state: .,
        questions: {
          next_tool: {
            type: "choice",
            instructions: $instr,
            criteria: $criteria
          }
        }
      } | if $model != "" then . + {model: $model} else . end' \
    | post_json
}

# call_responses() {
#   echo "error: provider 'responses' is not implemented yet." >&2
#   echo "       implement call_responses and normalize_responses." >&2
#   exit 1
# }

# post_json: read the payload from stdin, send it to the endpoint.
# the payload is a *stream* (never an argument), so it can be any size.
post_json() {
  local -a headers=(-H "Content-Type: application/json")
  [[ -n "$API_KEY" ]] && headers+=(-H "Authorization: Bearer $API_KEY")
  curl -sS "${headers[@]}" -d @- "$SLYM_ENDPOINT"
}

normalize_response() {
  local resp="$1"
  case "$PROVIDER" in
    openai-compatible) normalize_openai "$resp" ;;
    system-one) normalize_systemone "$resp" ;;
    *) echo "error: unknown provider: $PROVIDER" >&2; return 1 ;;
    # responses)         normalize_responses "$resp" ;;
  esac
}

normalize_openai() {
  local resp="$1"
  local normalized
  normalized=$(jq -c '
    if (.choices // null) == null then
      {__error: (.error.message // "no choices in response")}
    else
    .choices[0].message
    | {
        role: "assistant",
        content: (.content // ""),
        tool_calls: [
          (.tool_calls // [])[]
          | {
              id: .id,
              name: .function.name,
              arguments: (.function.arguments | if type == "string" then (try fromjson catch {}) else . end)
            }
        ]
      }
    end
    ' <<<"$resp")
  # Handle error case  
  if jq -e 'has("__error")' >/dev/null <<<"$normalized"; then
    jq -r '.__error' <<<"$normalized" >&2
    return 1
  fi
  # Return cleaned JSON
  printf '%s' "$normalized"
}

normalize_systemone() {
  local resp="$1"
  local choice conf call_id

  if jq -e '.error != null or (.answers.next_tool // null) == null' >/dev/null <<<"$resp"; then
    jq -r '.error.message // .detail // "invalid systemone response"' <<<"$resp" >&2
    return 1
  fi

  choice=$(jq -r '.answers.next_tool.choice' <<<"$resp")
  conf=$(jq -r '.answers.next_tool.confidence // 0' <<<"$resp")
  call_id="sys1_$(date +%s)_$RANDOM"

  if [[ "$choice" == "__done__" ]]; then
    jq -n -c --arg c "Done (confidence: $conf)" \
      '{role: "assistant", content: $c, tool_calls: []}'
  else
      jq -n -c --arg id "$call_id" --arg name "$choice" --arg conf "$choice (confidence: $conf)" \
      '{
        role: "assistant",
        content: $conf,
        tool_calls: [{id: $id, name: $name, arguments: {}}]
      }'
  fi
}


# normalize_responses() {
#   echo "error: provider 'responses' is not implemented yet." >&2
#   exit 1
# }

# ---------------------------------------------------------------- execution

run_tool() {
  local name="$1" args="$2"
  local script="${SCRIPT[$name]:-}"

  if [[ -z "$script" ]]; then
    printf 'error: unknown tool: %s' "$name" >&2
    return 1
  fi
  if [[ ! -f "$script" ]]; then
    printf 'error: script not found: %s' "$script" >&2
    return 1
  fi
  if [[ ! -x "$script" ]]; then
    printf 'error: script not executable: %s (chmod +x)' "$script" >&2
    return 1
  fi

  local errfile out err rc
  errfile=$(mktemp "${TMPDIR:-/tmp}/slym.XXXXXX") || {
    printf 'error: mktemp failed' >&2
    return 1
  }

  set +e
  out=$(printf '%s' "$args" | "$script" 2>"$errfile")
  rc=$?
  set -e

  err=$(cat "$errfile" 2>/dev/null || true)
  rm -f "$errfile"

  jq -nc --arg out "$out" --arg err "$err" --argjson rc "$rc" \
    '{ok:($rc==0), exit:$rc, stdout:$out, stderr:$err}'
}
# User feedback loop
spinner_start() {
  local display="${1:-waiting}"
  [[ -t 2 ]] || return 0
  [[ ${NO_SPINNER} -eq 1 ]] && return 0
  (
    local t=0
    while :; do
      printf '\r%s… %ds' "$display" "$t" >&2
      sleep 1
      t=$((t+1))
    done
  ) &
  SPIN_PID=$!
}
# Stop the 'thinking' task if running
spinner_stop() {
  [[ -n "${SPIN_PID:-}" ]] || return 0
  kill "${SPIN_PID:-}" 2>/dev/null || true
  wait "${SPIN_PID:-}" 2>/dev/null || true
  SPIN_PID=""
  printf '\r\033[K' >&2
}

# Throttle request to avoid provider rate limits
throttle_request() {
  [[ "$REQUEST_INTERVAL" == "0" ]] && return 0
  local now elapsed wait
  now=$(date +%s)
  elapsed=$(( now - LAST_REQUEST_AT ))
  wait=$(( REQUEST_INTERVAL - elapsed ))
  if (( wait > 0 )); then
    sleep "$wait"
  fi
  LAST_REQUEST_AT=$(date +%s)
}

# ---------------------------------------------------------------- loop

main() {
  # Validate required vars
  : "${SLYM_ENDPOINT:?set SLYM_ENDPOINT (e.g. http://localhost:11434/v1/chat/completions)}"
  : "${SLYM_MODEL:?set SLYM_MODEL (e.g. llama3.2)}"
  # Kill thinking task on exit
  trap 'spinner_stop' EXIT
  
  LAST_REQUEST_AT=0

  # Load tools
  load_registry
  # Initialize task messages
  local system messages prompt 
  # ---------------------------------------------------------------- messages init
  # Two starting states, chosen by whether stdin supplied a transcript:
  #   * resume → the transcript is pure history (no system message); we
  #              *re-apply the current bundle's system prompt*. 
  #              Resuming under a different bundle re-skins the
  #              conversation under that bundle's policy.
  #   * fresh  → build system prompt from the bundle's SKILL.md, pair with --run.
  system=$(build_system_prompt)
  prompt="$(jq -nc --arg t "$TASK" '{role: "user", content: $t}')"
  # trace: pipe it to wrap_message
  wrap_message <<<"$prompt"
  
  # messages: inject it as a JSON value via --argjson, not string concat
  if [[ -n "$TRACE_MESSAGES" ]]; then
    messages=$(printf '%s' "$TRACE_MESSAGES" | jq -c --arg s "$system" --argjson p "$prompt" \
      '[{role:"system",content:$s}] + . + [$p]')
  else
    messages=$(jq -nc --arg s "$system" --argjson p "$prompt" \
      '[{role:"system",content:$s}, $p]')
  fi

  # resume
  # Execute any tool calls the incoming trace left pending, so the
  # conversation is well-formed (every tool_call has a tool result).
  if [[ -n "$RESUME_TOOL_CALLS" ]]; then
    local rn rj rname rargs rcall rresult
    rn=$(jq 'length' <<<"$RESUME_TOOL_CALLS")
    for ((rj = 0; rj < rn; rj++)); do
      rname=$(jq -r ".[$rj].name" <<<"$RESUME_TOOL_CALLS")
      rargs=$(jq -c ".[$rj].arguments" <<<"$RESUME_TOOL_CALLS")
      rcall=$(jq -r ".[$rj].id" <<<"$RESUME_TOOL_CALLS")
      rresult=$(run_tool "$rname" "$rargs")
      messages=$(printf '%s' "$messages" | jq -c --arg id "$rcall" --arg content "$rresult" \
        '. + [{role: "tool", tool_call_id: $id, content: $content}]')
      jq -nc --arg id "$rcall" --arg content "$rresult" \
          '{role:"tool", tool_call_id:$id, content:$content}' | wrap_message
    done
  fi

  # Main conversation loop
  local i resp normalized calls
  local buffer=0
  for ((i = 0; i < MAX_ITERATIONS; i++)); do 
    spinner_start "throttling"
    throttle_request
    spinner_stop
    spinner_start "thinking"
    # Call model to get response
    resp=$(call_model "$messages")
    spinner_stop
    # record last request after the request completes
    LAST_REQUEST_AT=$(date +%s)   

    # Normalize the response
    normalized=$(normalize_response "$resp")
    calls=$(jq -c '.tool_calls' <<<"$normalized")
    wrap_message <<<"$normalized"
    # Add response to messages
    messages=$(printf '%s' "$messages" | jq -c --argjson m "$normalized" '. + [$m]')

    # Buffer or return based on conditions
    # This allows some models to use tools better
    if [[ "$(jq 'length' <<<"$calls")" -eq 0 ]]; then
      (( buffer +=1 ))
    else
    # A tool call means the run isn't over
      buffer=0
    fi
    [[ $buffer -gt $THINK_BUFFER ]] && return 0
    
    # Handle tool calls
    local n j name args call_id result
    n=$(jq 'length' <<<"$calls")
    
    # --no-tool: a tool call is the terminal condition. Emit the trace as-is
    # (already done above) and exit 0 without executing anything.
    if [[ "$NO_TOOL" == "1" && "$n" -gt 0 ]]; then
      exit 0
    fi
    
    for ((j = 0; j < n; j++)); do
      name=$(jq -r ".[$j].name" <<<"$calls")
      args=$(jq -c ".[$j].arguments" <<<"$calls")
      call_id=$(jq -r ".[$j].id" <<<"$calls")
      result=$(run_tool "$name" "$args")
      # Reconstruct messages with tool response
      messages=$(printf '%s' "$messages" | jq -c --arg id "$call_id" --arg content "$result" \
        '. + [{role: "tool", tool_call_id: $id, content: $content}]')
      jq -nc --arg id "$call_id" --arg content "$result" \
          '{role:"tool", tool_call_id:$id, content:$content}' \
          | wrap_message
    done
  done
  if [[ "$CAP_IS_SUCCESS" == "1" ]]; then
  # the cap was the intended stop (e.g. a System 1 router doing one decision)
    exit 0
  fi
  echo "error: max iterations ($MAX_ITERATIONS) reached" >&2
  exit 1
}

main
