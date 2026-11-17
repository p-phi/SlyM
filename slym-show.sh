#!/usr/bin/env bash
# slym-show — render or emit a SlyM trace
#
# stdin:  wrapped JSONL trace ({"app":"slym","tags":[...],"trace":{...}})
# stdout: a rendered human view, or JSONL with --raw
#
# dependencies: bash, jq
set -euo pipefail

MAXIMUM_NESTING_DEPTH="${SLYM_SHOW_MAXIMUM_NESTING_DEPTH:-10}"

usage() {
  cat >&2 <<'EOF'
usage: slym-show [--last | --tools | --tags | --all] [--raw] [--flatten]

views:
  (default)   the full loop
  --last      only the final assistant message
  --tools     only tool calls and tool results
  --tags      only the tag summary
  --all       the full loop (same as default; explicit)

flags:
  --raw       emit JSONL (no rendering); composes with any view
  --flatten   hoist nested traces (recursively) to the root level

environment:
  SLYM_SHOW_MAXIMUM_NESTING_DEPTH     (optional) sets maximum nesting depth when flattening a trace (default=10).

reads a SlyM trace on stdin; writes a human view (or JSONL with --raw) on stdout.
EOF
  exit 1
}

# ---------------------------------------------------------------- args
view=default
raw=0
flatten=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --last)    view=last;    shift ;;
    --tools)   view=tools;   shift ;;
    --tags)    view=tags;    shift ;;
    --all)     view=default; shift ;;
    --raw)     raw=1;        shift ;;
    --flatten) flatten=1;    shift ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
# ---------------------------------------------------------------- styling
# inline ANSI — the terminal is the styling engine; no gum, no dependency.
# only used when rendering (raw=0); --raw bypasses all of this.
if [[ $raw -eq 0 ]]; then
  # colors (empty when not a TTY, so piped output stays clean)
  if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_ITAL=$'\033[3m'
    C_BLUE=$'\033[34m'; C_GREEN=$'\033[32m'; C_GREY=$'\033[90m'
  else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_ITAL=""
    C_BLUE=""; C_GREEN=""; C_GREY=""
  fi

  label_user()      { printf '%s- user:%s\n' "$C_BOLD$C_BLUE" "$C_RESET"; }
  label_assistant() { printf '%s- assistant:%s\n' "$C_BOLD$C_GREEN" "$C_RESET"; }
  label_tool()      { printf '%s- tool:%s\n' "$C_BOLD$C_GREY" "$C_RESET"; }

  msg_user()        { printf '  %s%s%s\n' "$C_ITAL$C_BLUE" "$1" "$C_RESET"; }
  msg_assistant()   { printf '  %s%s%s\n' "$C_ITAL$C_GREEN" "$1" "$C_RESET"; }
  msg_tool()        { printf '  %s%s%s\n' "$C_GREY" "$1" "$C_RESET"; }
else
  # never called when raw=1; defined for safety
  label_user()      { printf '%s\n' "$*"; }
  label_assistant() { printf '%s\n' "$*"; }
  label_tool()      { printf '%s\n' "$*"; }
  msg_user()        { printf '  %s\n' "$*"; }
  msg_assistant()   { printf '  %s\n' "$*"; }
  msg_tool()        { printf '  %s\n' "$*"; }
fi

# ---------------------------------------------------------------- flatten
flatten_once() {
  jq -c '
    if (.trace.role == "tool")
       and ((.trace.content | fromjson? | .stdout // "") as $s
            | ($s | split("\n") | map(select(. != ""))) as $lines
            | ($lines | length) > 0
            and ($lines | all(. | fromjson? | .app == "slym")))
    then
      .trace.content | fromjson | .stdout | split("\n")[] | select(. != "") | fromjson
    else . end
  '
}

flatten_traces() {
  local depth="${1:-$MAXIMUM_NESTING_DEPTH}" i cur prev
  cur=$(cat)
  for ((i = 0; i < depth; i++)); do
    prev="$cur"
    cur=$(printf '%s\n' "$cur" | flatten_once)
    [[ "$cur" == "$prev" ]] && break
  done
  printf '%s\n' "$cur"
}

# ---------------------------------------------------------------- render
render_line() {
  local line="$1"
  local role content tool args tag label

  role=$(jq -r '.trace.role // empty'        <<<"$line")
  content=$(jq -r '.trace.content // empty'  <<<"$line")
  tool=$(jq -r '.trace.tool_calls[0].name // empty' <<<"$line")
  args=$(jq -c '.trace.tool_calls[0].arguments // empty' <<<"$line")
  tag=$(jq -r '.tags[0] // empty'            <<<"$line")

  case "$role" in
    user)
      label_user
      msg_user "\"$content\""
      ;;
    tool)
      label_tool
      msg_tool "$content"
      ;;
    assistant)
      if [[ -n "$tool" ]]; then
        printf '%s- tool call: %s%s\n' "$C_BOLD$C_GREY" "$tool" "$C_RESET"
        msg_tool "$args"
      else
        label="assistant"
        [[ -n "$tool" ]] && label="$label [$tool]"
        [[ -n "$tag"  ]] && label="$label [$tag]"
        printf '%s- %s:%s\n' "$C_BOLD$C_GREEN" "$label" "$C_RESET"
        msg_assistant "\"$content\""
      fi
      ;;
  esac
}

# ---------------------------------------------------------------- main
input=$(cat)
[[ -z "$input" ]] && usage
if [[ $flatten -eq 1 ]]; then
  input=$(printf '%s\n' "$input" | flatten_traces)
fi

case "$view" in
  default) selected="$input" ;;
  last)
    selected=$(jq -c -s '
      [ .[] | select(.trace.role=="assistant" and ((.trace.tool_calls // [])|length)==0) ]
      | last
      | select(. != null)
    ' <<<"$input")
    ;;
  tools)
    selected=$(jq -c 'select(.trace.role=="tool" or ((.trace.tool_calls // [])|length)>0)' <<<"$input")
    ;;
  tags)
    selected=$(jq -r '.tags[]? // empty' <<<"$input" | sort -u)
    ;;
esac

if [[ $raw -eq 1 ]]; then
  printf '%s\n' "$selected"
else
  if [[ "$view" == "tags" ]]; then
    printf '%s\n' "$selected"
  else
    while IFS= read -r line; do
      [[ -n "$line" ]] && render_line "$line"
    done <<<"$selected"
  fi
fi
