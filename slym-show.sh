#!/usr/bin/env bash
# slym-show — render a SlyM trace for humans
# stdin:  wrapped JSONL trace ({"app":"slym","tags":[...],"trace":{...}})
# stdout: a human view
set -euo pipefail

VERSION="0.0.4"
usage() {
  cat >&2 <<'EOF'
usage: slym-show [--last | --tools | --tags | --all]

views:
  (default)   the full loop, rendered
  --last      only the final assistant message
  --tools     only tool calls and tool results
  --tags      only the tag summary
  --all       the full loop (same as default; explicit)
  -v, --version        show the version

reads a SlyM trace on stdin; writes a human view on stdout.
EOF
  exit 1
}

version() {
  echo "slym-show v$VERSION"
  exit 0
}

# ---------------------------------------------------------------- styling
# one function per *class*: a role has a label and a message, each styled
# independently. gum is optional; the fallbacks keep the layout, drop the color.

if command -v gum >/dev/null 2>&1; then
  # labels: bold, role-specific color
  label_user()      { gum style --border-foreground 100 --border rounded --bold --foreground 39  "$@"; }   # blue
  label_assistant() { gum style --border-foreground 100 --border rounded --bold --foreground 42  "$@"; }   # green
  label_tool()      { gum style --border-foreground 100 --border rounded --bold --foreground 245 "$@"; }   # grey

  # messages: role-specific treatment
  msg_user()        { gum style --border-foreground 100 --border rounded --italic --padding 2 --foreground 39  "$@"; }
  msg_assistant()   { gum style --border-foreground 100 --border rounded --italic --padding 2 --foreground 42  "$@"; }
  msg_tool()        { gum style --border-foreground 100 --border rounded --padding 2 --foreground 245 "$@"; }
else
  # fallbacks: same layout, no color
  label_user()      { printf '%s\n' "$*"; }
  label_assistant() { printf '%s\n' "$*"; }
  label_tool()      { printf '%s\n' "$*"; }
  msg_user()        { printf '  %s\n' "$*"; }
  msg_assistant()   { printf '  %s\n' "$*"; }
  msg_tool()        { printf '  %s\n' "$*"; }
fi
# ---------------------------------------------------------------- views
view=default
while [[ $# -gt 0 ]]; do
  case "$1" in
    --last)  view=last;  shift ;;
    --tools) view=tools; shift ;;
    --tags)  view=tags;  shift ;;
    --all)   view=default; shift ;;
    -h|--help) usage ;;
    -v|--version)
      version ;;
    *) usage ;;
  esac
done

# ---------------------------------------------------------------- render
# one JSON object per line; each line is a wrapped trace entry
render_line() {
  local line="$1"
  local role content tool args tag
  role=$(jq -r '.trace.role // empty'    <<<"$line")
  content=$(jq -r '.trace.content // empty' <<<"$line")
  tool=$(jq -r '.trace.tool_calls[0].name // empty' <<<"$line")
  args=$(jq -c '.trace.tool_calls[0].arguments // empty' <<<"$line")
  tag=$(jq -r '.tags[0] // empty' <<<"$line")

  case "$role" in
    user)
      label_user "🤓 user:"
      msg_user "\"$content\""
      ;;
    tool)
      label_tool "🔧 tool result:"
      msg_tool "$content"
      ;;
    assistant)
      if [[ -n "$tool" ]]; then
        label_tool "📦 tool call: $tool"
        msg_tool "$args"
      else
        local label="assistant"
        [[ -n "$tool" ]] && label="assistant [$tool]"
        [[ -n "$tag"  ]] && label="$label [$tag]"
        label_assistant "🤖 $label:"
        msg_assistant "\"$content\""
      fi
      ;;
  esac
}

case "$view" in
  default)
    while IFS= read -r line; do
      [[ -n "$line" ]] && render_line "$line"
    done
    ;;
  last)
    # the final answer: the last assistant message with no tool calls
    jq -s -r '
      [ .[] | select(.trace.role=="assistant" and ((.trace.tool_calls // [])|length)==0) ]
      | last
      | if . == null then empty
        else "\(.trace.content)" end
    ' | while IFS= read -r content; do
          bold "🤖 assistant:"
          italic "$(indent2 "\"$content\"")"
        done
    ;;
  tools)
    jq -c 'select(.trace.role=="tool" or ((.trace.tool_calls // [])|length)>0)' \
      | while IFS= read -r line; do
          render_line "$line"
        done
    ;;
  tags)
    jq -r '.tags[]? // empty' | sort -u | while IFS= read -r t; do
      printf '%s\n' "$t"
    done
    ;;
esac
