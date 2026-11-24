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
  SLYMSH_TRACE     Path to the conversation trace file
                   (default: \$TMPDIR/slym-trace-<timestamp>.jsonl)
  SLYMSH_BUNDLE    The bundle slym sends to
                   (default: bundles/oneliner)
  SLYMSH_REC       Where the raw recording goes
                   (default: \$TMPDIR/slymsh-<timestamp>.log)
  SLYMSH_SHELL     The shell to run inside the recording
                   (default: \$SHELL or bash)
  SLYM_BIN         Path to the slym binary
                   (default: slym)
  SLYM_SHOW        Path to the slym-show binary
                   (default: slym-show)

EXAMPLES
  # Start with defaults
  $NAME

  # Use a specific trace file
  SLYMSH_TRACE=./my-session.jsonl $NAME

  # Force zsh instead of the default shell
  SLYMSH_SHELL=zsh $NAME

EOF
}

version() {
  echo "$NAME v$VERSION"
}

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -v|--version) version; exit 0 ;;
    *)
      echo "error: unknown option '$1'" >&2
      echo "Try '$NAME --help' for more information." >&2
      exit 1
      ;;
  esac
done

# --- Configuration ---
SLYM_BIN="${SLYM_BIN:-slym}"
SLYM_SHOW="${SLYM_SHOW:-slym-show}"
SLYMSH_TRACE="${SLYMSH_TRACE:-${TMPDIR:-/tmp}/slym-trace-$(date +%Y%m%d-%H%M%S).jsonl}"
SLYMSH_BUNDLE="${SLYMSH_BUNDLE:-bundles/oneliner}"
SLYMSH_REC="${SLYMSH_REC:-${TMPDIR:-/tmp}/slymsh-$(date +%Y%m%d-%H%M%S).log}"
SLYMSH_SHELL="${SLYMSH_SHELL:-${SHELL:-bash}}"

mkdir -p "$(dirname "$SLYMSH_TRACE")" "$(dirname "$SLYMSH_REC")"
touch "$SLYMSH_TRACE" "$SLYMSH_REC"

# The marker tracks the line count of the last ai call
MARK="${SLYMSH_REC}.mark"
echo 0 > "$MARK"

# Export what the subshell needs
export SLYM_BIN SLYM_SHOW SLYMSH_TRACE SLYMSH_BUNDLE SLYMSH_REC MARK

# --- Cleanup Trap ---
RCFILE=""
ZDOTDIR_PATH=""
cleanup() {
  [[ -n "$RCFILE" && -f "$RCFILE" ]] && rm -f "$RCFILE"
  [[ -n "$ZDOTDIR_PATH" && -d "$ZDOTDIR_PATH" ]] && rm -rf "$ZDOTDIR_PATH"
  [[ -f "$MARK" ]] && rm -f "$MARK"
}
trap cleanup EXIT

# --- AI Function Definition (Shell-Agnostic Core) ---
# We use a quoted heredoc so $, \n, etc. are written literally to the RC file.
AI_FUNC=$(cat <<'EOF'
_SPINNER_PID=""

_start_spinner() {
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
}
_stop_spinner() {
  if [[ -n "$_SPINNER_PID" ]]; then
    kill "$_SPINNER_PID" 2>/dev/null || true
    wait "$_SPINNER_PID" 2>/dev/null || true
    printf "\r%*s\r" 20 "" >&2  # Clear the line (20 chars wide)
    _SPINNER_PID=""
  fi
}

# Global trap to ensure spinner cleanup on Ctrl+C or script exit
trap '_stop_spinner' EXIT INT TERM
ai() {
  local IFS=' '
  local q start now tmp tracetmp before line

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
      if ! IFS= read -r line < /dev/tty; then
        break  # Ctrl-D
      fi
      [[ -z "$line" ]] && break
      q+="${q:+$'\n'}$line"
    done
    
    # Add to shell history (handles both bash and zsh)
    if [[ -n "$ZSH_VERSION" ]]; then
      print -s "ai $q" &>/dev/null || true
    else
      history -s "ai $q" &>/dev/null || true
    fi
  fi

  q="${q:-what happened?}"

  # 2. Capture recording segment
  start=$(cat "$MARK")
  sync # Ensure script's buffer is fully on disk
  now=$(wc -l < "$SLYMSH_REC")
  
  if (( now <= start )); then
    echo "ai: nothing recorded since the last call" >&2
    return 0
  fi

  tmp=$(mktemp)
  tail -n "+$((start + 1))" "$SLYMSH_REC" | head -n "$((now - start))" \
    | sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' -e 's/\r$//' > "$tmp"

  # 3. Append user turn to trace
  jq -nc --arg q "$q" --rawfile seg "$tmp" \
    '{app:"slym", tags:["recording"], trace:{role:"user", content:($q + "\n\n" + $seg)}}' \
    >> "$SLYMSH_TRACE"
  
  before=$(wc -l < "$SLYMSH_TRACE")
  tracetmp=$(mktemp)
  
  # 4. Send trace and capture answer
  _start_spinner
  if ! "$SLYM_BIN" "$SLYMSH_BUNDLE" --tag "slymsh" < "$SLYMSH_TRACE" > "$tracetmp" 2>/dev/null; then
    echo "ai: slym request failed (check network or endpoint)" >&2
    rm -f "$tmp" "$tracetmp"
    return 1
  fi
  _stop_spinner

  # 5. Append ONLY the new lines to prevent exponential trace growth
  tail -n "+$((before + 1))" "$tracetmp" >> "$SLYMSH_TRACE"

  # 6. Display answer
  "$SLYM_SHOW" --last < "$SLYMSH_TRACE" || \
  cat "$SLYMSH_TRACE" | tail -n 1 | jq '.trace.content' \
  || true

  # 7. Advance marker
  wc -l < "$SLYMSH_REC" > "$MARK"
  rm -f "$tmp" "$tracetmp"
}
EOF
)

# --- Shell-Specific RCFILE Generation ---
SHELL_NAME=$(basename "$SLYMSH_SHELL")

case "$SHELL_NAME" in
  bash)
    RCFILE=$(mktemp)
    cat > "$RCFILE" <<EOF
# Source user's native bash config
if [ -f "\$HOME/.bashrc" ]; then source "\$HOME/.bashrc"; fi

# Inject slymsh ai() function
$AI_FUNC

# Set slymsh prompt (bash syntax)
PS1="[slymsh]\${PS1:-}"
EOF
    SHELL_CMD="$SLYMSH_SHELL --rcfile $RCFILE -i"
    ;;
    
  zsh)
    # Zsh requires ZDOTDIR to point to a directory containing .zshrc
    ZDOTDIR_PATH=$(mktemp -d)
    RCFILE="$ZDOTDIR_PATH/.zshrc"
    cat > "$RCFILE" <<EOF
# Source user's native zsh config
if [ -f "\$HOME/.zshrc" ]; then source "\$HOME/.zshrc"; fi

# Inject slymsh ai() function
$AI_FUNC

# Set slymsh prompt (zsh syntax)
PS1="[slymsh]\${PS1:-}"
EOF
    SHELL_CMD="env ZDOTDIR=$ZDOTDIR_PATH $SLYMSH_SHELL -i"
    ;;
    
  *)
    echo "warning: shell '$SHELL_NAME' not natively supported, defaulting to bash logic" >&2
    RCFILE=$(mktemp)
    cat > "$RCFILE" <<EOF
if [ -f "\$HOME/.bashrc" ]; then source "\$HOME/.bashrc"; fi
$AI_FUNC
PS1="[slymsh]\${PS1:-}"
EOF
    SHELL_CMD="$SLYMSH_SHELL --rcfile $RCFILE -i"
    ;;
esac

# --- Welcome Banner ---
cat >&2 <<EOF
────────────────────────────────────────────────────────
$NAME session started
  shell:      $SHELL_NAME
  trace:      $SLYMSH_TRACE
  recording:  $SLYMSH_REC

Type 'ai <question>' to ask the AI about what just happened.
Examples:
  ai why did this fail?
  ai explain the last command
  ai   (press Enter twice for interactive multiline input)

Press Ctrl+D or type 'exit' to finish and save the trace.
────────────────────────────────────────────────────────
EOF

# --- Run the recorded subshell ---
# -q: quiet, -f: flush output immediately (crucial for wc -l marker), -e: return child exit code
script -q -f -e -c "$SHELL_CMD" "$SLYMSH_REC" || true

# --- Post-Session Summary ---
echo
echo "$NAME: trace     → $SLYMSH_TRACE" >&2
echo "$NAME: recording → $SLYMSH_REC" >&2
echo "$NAME: resume    → SLYMSH_TRACE=$SLYMSH_TRACE SLYMSH_REC=$SLYMSH_REC $NAME" >&2
