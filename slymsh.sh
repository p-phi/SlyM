#!/usr/bin/env bash
# slymsh — a recorded shell with a conversational ai step.
set -euo pipefail

# --- Metadata ---
VERSION="0.0.7"
NAME="slymsh"

# --- Help & Version ---
usage() {
  cat <<EOF
$NAME v$VERSION — a recorded shell with a conversational ai step.

USAGE
  $NAME [options]

  Starts a recorded subshell. Type 'ai <question>' to ask the AI
  about what just happened in the terminal.

OPTIONS
  -h, --help       Show this help and exit
  -v, --version    Show version and exit

ENVIRONMENT
  SLYMSH_TRACE         Path to the conversation trace file
                       (default: \$TMPDIR/slym-trace-<timestamp>.jsonl)
  SLYMSH_BUNDLE        The bundle slym sends to
                       (default: bundles/oneliner). Change mid-session
                       with 'export SLYMSH_BUNDLE=bundles/other'.
  SLYMSH_SKIP_CONFIRM  If 1, tool calls run unattended. Default 0: the AI
                       proposes the tool call and you approve it. Toggle
                       mid-session with 'export SLYMSH_SKIP_CONFIRM=1'.
  SLYMSH_REC           Where the raw recording goes
                       (default: \$TMPDIR/slymsh-<timestamp>.log)
  SLYMSH_SHELL         The shell to run inside the recording
                       (default: \$SHELL or bash)
  SLYM_PROVIDER        Provider for the slym invocation (default: openai-compatible)
  SLYM_BIN             Path to the slym binary (default: slym)
  SLYM_SHOW            Path to the slym-show binary (default: slym-show)

EXAMPLES
  $NAME
  SLYMSH_TRACE=./my-session.jsonl $NAME
  SLYMSH_SHELL=zsh $NAME

EOF
}

version() { echo "$NAME v$VERSION"; }

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -v|--version) version; exit 0 ;;
    *) echo "error: unknown option '$1'" >&2; exit 1 ;;
  esac
done

# --- Dependency check ---
command -v script >/dev/null 2>&1 || {
  echo "$NAME: 'script' is required (util-linux). Install it and retry." >&2
  exit 1
}

# --- Configuration ---
SLYM_BIN="${SLYM_BIN:-slym}"
SLYM_SHOW="${SLYM_SHOW:-slym-show}"
SLYM_PROVIDER="${SLYM_PROVIDER:-openai-compatible}"
SLYMSH_TRACE="${SLYMSH_TRACE:-${TMPDIR:-/tmp}/slym-trace-$(date +%Y%m%d-%H%M%S).jsonl}"
SLYMSH_BUNDLE="${SLYMSH_BUNDLE:-bundles/oneliner}"
SLYMSH_SKIP_CONFIRM="${SLYMSH_SKIP_CONFIRM:-0}"
SLYMSH_REC="${SLYMSH_REC:-${TMPDIR:-/tmp}/slymsh-$(date +%Y%m%d-%H%M%S).log}"
SLYMSH_SHELL="${SLYMSH_SHELL:-${SHELL:-bash}}"

mkdir -p "$(dirname "$SLYMSH_TRACE")" "$(dirname "$SLYMSH_REC")"
touch "$SLYMSH_TRACE" "$SLYMSH_REC"

# Marker: line count at the last ai call. Preserve on resume.
MARK="${SLYMSH_REC}.mark"
[[ -f "$MARK" ]] || echo 0 > "$MARK"

export SLYM_BIN SLYM_SHOW SLYM_PROVIDER SLYMSH_TRACE SLYMSH_BUNDLE SLYMSH_SKIP_CONFIRM SLYMSH_REC MARK

# --- Cleanup Trap ---
RCFILE=""
ZDOTDIR_PATH=""
cleanup() {
  [[ -n "$RCFILE" && -f "$RCFILE" ]] && rm -f "$RCFILE"
  [[ -n "$ZDOTDIR_PATH" && -d "$ZDOTDIR_PATH" ]] && rm -rf "$ZDOTDIR_PATH"
}
trap cleanup EXIT

# --- AI Function Definition (Shell-Agnostic Core) ---
AI_FUNC=$(cat <<'EOF'
_SPINNER_PID=""

_start_spinner() {
  set +m
  (
    chars=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    i=0
    while true; do
      printf "\r%s thinking..." "${chars[$((i % ${#chars[@]}))]}" >&2
      sleep 0.1
      i=$((i + 1))
    done
  ) &
  _SPINNER_PID=$!
  set -m
}
_stop_spinner() {
  set +m
  if [[ -n "$_SPINNER_PID" ]]; then
    kill "$_SPINNER_PID" 2>/dev/null || true
    wait "$_SPINNER_PID" 2>/dev/null || true
    printf "\r\033[K" >&2
    _SPINNER_PID=""
  fi
  set -m
}

# prompt on stderr, read from the tty (portable: no `read -p`, which means
# something different in zsh)
_ask() {
  printf '  ⏺ %s — approve? [y/N] ' "$1" >&2
  local reply=""
  IFS= read -r reply < /dev/tty || true
  printf '%s' "$reply"
}

# the pending tool call, if the trace's last message is an assistant with a
# non-empty tool_calls array. defensive: skip malformed lines.
_pending_call() {
  jq -sr '
    map(select(.trace != null) | .trace)
    | if length > 0 and .[-1].role == "assistant"
         and ((.[-1].tool_calls // []) | length) > 0
      then .[-1].tool_calls[0] | "\(.name)(\(.arguments | tojson))"
      else empty end
  ' "$SLYMSH_TRACE" 2>/dev/null
}

# append a synthetic tool result for a declined call
_decline_pending() {
  local call_id
  call_id=$(jq -sr 'map(select(.trace != null) | .trace) | .[-1].tool_calls[0].id // empty' "$SLYMSH_TRACE" 2>/dev/null)
  [[ -n "$call_id" ]] || return 0
  jq -nc --arg id "$call_id" '
    {app:"slym", tags:["slymsh"], trace:
      {role:"tool", tool_call_id:$id,
       content: "{\"ok\":false,\"exit\":130,\"stdout\":\"\",\"stderr\":\"declined by user\"}"}}
  ' >> "$SLYMSH_TRACE"
}

# append only the new lines of $1 to the trace (no exponential growth)
_append_new() {
  local tmp="$1" before="$2"
  tail -n "+$((before + 1))" "$tmp" >> "$SLYMSH_TRACE"
}

# one slym call: read the trace, write the new turn to $2. returns slym's exit.
_step() {
  local bundle="$1" out="$2"; shift 2
  SLYM_MAX_ITERATIONS=1 \
  SLYM_CAP_IS_SUCCESS=1 \
  "$SLYM_BIN" "$bundle" --tag "slymsh" --provider "$SLYM_PROVIDER" "$@" \
    < "$SLYMSH_TRACE" > "$out" 2>/dev/null
}
ai() {
  local IFS=' '
  local q qfile start now tmp tracetmp before line reply call
  local bundle="${SLYMSH_BUNDLE:-bundles/oneliner}"
  local skip="${SLYMSH_SKIP_CONFIRM:-0}"

  # 1. Determine input source
  if (( $# )); then
    q="$*"
  elif [[ ! -t 0 ]]; then
    q=$(cat)
  else
    q=""
    echo "ai> (type your question, press Enter twice to send, or Ctrl-D)" >&2
    while true; do
      printf "  " >&2
      if ! IFS= read -r line < /dev/tty; then break; fi
      [[ -z "$line" ]] && break
      q+="${q:+$'\n'}$line"
    done
    if [[ -n "$ZSH_VERSION" ]]; then
      print -s "ai $q" &>/dev/null || true
    else
      history -s "ai $q" &>/dev/null || true
    fi
  fi
  q="${q:-what happened?}"

  # 2. Capture recording segment
  start=$(cat "$MARK")
  sync
  now=$(wc -l < "$SLYMSH_REC")
  if (( now <= start )); then
    echo "ai: nothing recorded since the last call" >&2
    return 0
  fi
  tmp=$(mktemp)
  tail -n "+$((start + 1))" "$SLYMSH_REC" | head -n "$((now - start))" \
    | sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' -e 's/\r$//' > "$tmp"

  # 3. Append user turn (question and segment through files)
  qfile=$(mktemp)
  printf '%s' "$q" > "$qfile"
  jq -nc --rawfile q "$qfile" --rawfile seg "$tmp" \
    '{app:"slym", tags:["recording"], trace:{role:"user", content:($q + "\n\n" + $seg)}}' \
    >> "$SLYMSH_TRACE"
  rm -f "$qfile"

  # 4. skip-confirm: one full loop, unattended.
  if [[ "$skip" == "1" ]]; then
    before=$(wc -l < "$SLYMSH_TRACE")
    tracetmp=$(mktemp)
    trap '_stop_spinner' INT TERM
    _start_spinner
    if ! _step "$bundle" "$tracetmp" --no-tool; then
      trap - INT TERM; _stop_spinner
      echo "ai: slym request failed (check network or endpoint)" >&2
      rm -f "$tmp" "$tracetmp"
      return 1
    fi
    trap - INT TERM; _stop_spinner
    _append_new "$tracetmp" "$before"
    rm -f "$tracetmp"

  # 5. confirm: every step is --no-tool; the loop is the gate.
  else
    while true; do
      before=$(wc -l < "$SLYMSH_TRACE")
      tracetmp=$(mktemp)

      trap '_stop_spinner' INT TERM
      _start_spinner
      if ! _step "$bundle" "$tracetmp" --no-tool; then
        trap - INT TERM; _stop_spinner
        echo "ai: slym request failed (check network or endpoint)" >&2
        rm -f "$tmp" "$tracetmp"
        return 1
      fi
      trap - INT TERM; _stop_spinner

      _append_new "$tracetmp" "$before"
      rm -f "$tracetmp"

      # no pending call -> the model finished; done
      call=$(_pending_call)
      [[ -z "$call" ]] && break

      # pending call -> gate it
      reply=$(_ask "$call")
      case "$reply" in
        [yY]*)
          # approve: the next --no-tool step runs the tool and stops on the
          # next call (or finishes). loop.
          ;;
        *)
          # decline: synthetic result; the next step continues from there.
          _decline_pending
          ;;
      esac
    done
  fi

  # 6. Display answer
  "$SLYM_SHOW" --last < "$SLYMSH_TRACE" 2>/dev/null \
    || tail -n 1 "$SLYMSH_TRACE" | jq '.trace.content' \
    || true

  # 7. Advance marker
  wc -l < "$SLYMSH_REC" > "$MARK"
  rm -f "$tmp"
}
EOF
)

# --- Shell-Specific RCFILE Generation ---
SHELL_NAME=$(basename "$SLYMSH_SHELL")

# --- Welcome Banner ---
SHOW_CONF_FUNC=$(cat <<'CONF'
slymsh-conf() {
  local mode="required"
  [[ "${SLYMSH_SKIP_CONFIRM:-0}" == "1" ]] && mode="skipped"
  cat <<EOF
────────────────────────────────────────────────────────
slymsh session
  shell:      ${SHELL:-}
  endpoint:   ${SLYM_ENDPOINT:-}
  model:      ${SLYM_MODEL:-}
  provider:   ${SLYM_PROVIDER:-}
  bundle:     ${SLYMSH_BUNDLE:-}
  confirm:    $mode
  trace:      ${SLYMSH_TRACE:-}
  recording:  ${SLYMSH_REC:-}

Type 'ai <question>' to ask the AI about what just happened.
  export SLYMSH_SKIP_CONFIRM=1   # run tools unattended
  export SLYMSH_BUNDLE=...       # switch bundle mid-session

Type 'slymsh-conf' to show this banner.

Press Ctrl+D or type 'exit' to finish and save the trace.
────────────────────────────────────────────────────────
EOF
}
CONF
)

# the prompt shows the mode: [slymsh] asks, [slymsh:skip] skips.
PROMPT_CMD='
__slymsh_ps1() {
  local mode=""
  [[ "${SLYMSH_SKIP_CONFIRM:-0}" == "1" ]] && mode=":skip"
  printf "[slymsh%s] " "$mode"
}
PS1="$(__slymsh_ps1)${PS1:-}"
slymsh-conf
'

case "$SHELL_NAME" in
  bash)
    RCFILE=$(mktemp)
    cat > "$RCFILE" <<EOF
if [ -f "\$HOME/.bashrc" ]; then source "\$HOME/.bashrc"; fi
$AI_FUNC
$SHOW_CONF_FUNC
$PROMPT_CMD
EOF
    SHELL_CMD="$SLYMSH_SHELL --rcfile $RCFILE -i"
    ;;
  zsh)
    ZDOTDIR_PATH=$(mktemp -d)
    RCFILE="$ZDOTDIR_PATH/.zshrc"
    cat > "$RCFILE" <<EOF
if [ -f "\$HOME/.zshrc" ]; then source "\$HOME/.zshrc"; fi
$AI_FUNC
$SHOW_CONF_FUNC
$PROMPT_CMD
EOF
    SHELL_CMD="env ZDOTDIR=$ZDOTDIR_PATH $SLYMSH_SHELL -i"
    ;;
  *)
    echo "warning: shell '$SHELL_NAME' not natively supported, defaulting to bash logic" >&2
    RCFILE=$(mktemp)
    cat > "$RCFILE" <<EOF
if [ -f "\$HOME/.bashrc" ]; then source "\$HOME/.bashrc"; fi
$AI_FUNC
$SHOW_CONF_FUNC
$PROMPT_CMD
EOF
    SHELL_CMD="$SLYMSH_SHELL --rcfile $RCFILE -i"
    ;;
esac

# --- Run the recorded subshell ---
script -q -f -e -c "$SHELL_CMD" "$SLYMSH_REC" || true

# --- Post-Session Summary ---
echo
echo "$NAME: trace     → $SLYMSH_TRACE" >&2
echo "$NAME: recording → $SLYMSH_REC" >&2
echo "$NAME: resume    → SLYMSH_TRACE=$SLYMSH_TRACE SLYMSH_REC=$SLYMSH_REC $NAME" >&2
