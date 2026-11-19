#!/usr/bin/env bash
set -euo pipefail

export SLYM_NO_SPINNER=1
export SLYM_BIN="${DEMO_SLYM_BIN:-../../slym.sh}"
export SLYM_THINK_BUFFER=0
export SLYM_SHOW_BIN="${DEMO_SLYM_BIN:-../../slym-show.sh}"

# 1. Run the Neural Boolean Gate
# We use the system-one provider for strict, bounded classification
CODE_BROKEN="$(cat <<'EOF'
```javascript
function broken() { return
```
EOF
)"

CODE_VALID="$(cat <<'EOF'
```javascript
function valid() { return; }
```
EOF
)"

# Run slym. The model will pick the tool, the tool will echo 'broken' if code broken.
# We capture the final output.
pipeline() {
  IS_CODE_BROKEN=$(echo "$1" | \
    SLYM_ENDPOINT="http://localhost:11434/v1/systemone" \
    SLYM_MODEL="turintech/kev-4b-artemis:2.5gb" \
    SLYM_MAX_ITERATIONS=1 \
    SLYM_CAP_IS_SUCCESS=1 \
    "$SLYM_BIN" bundles/gate --tag gate --provider system-one \
    | "$SLYM_SHOW_BIN" --tools --raw | tail -n 1 \
    | jq -r '.trace.content | fromjson | .stdout'
  )
  
  ## 2. The Bash Routing Logic (The "Circuit")
  
  if [[ "$IS_CODE_BROKEN" == "yes" ]]; then
      echo "→ Routing to: Code Reviewer"
      # Uncomment the block below for actual processing
      # SLYM_ENDPOINT=http://localhost:11434/v1/chat/completions \
      # SLYM_MODEL=granite4.1:3b \
      # "$SLYM_BIN" bundles/reviewer --run "$1" \
      # | "$SLYM_SHOW_BIN" --last
      
  else
      echo "→ git push to staging"
  fi
}

echo "==== Running pipeline on broken code ===="
echo "$CODE_BROKEN"
pipeline "$CODE_BROKEN"
echo ""

echo "==== Running pipeline on valid code ===="
echo "$CODE_VALID"
pipeline "$CODE_VALID"
