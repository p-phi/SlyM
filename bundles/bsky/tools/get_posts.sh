#!/usr/bin/env bash
# Fetch the last N posts of a Bluesky profile. Arguments are JSON on stdin.
set -euo pipefail

input=$(cat)
handle=$(jq -r '.handle // empty' <<<"$input")
limit=$(jq -r '.limit // 10' <<<"$input")

if [[ -z "$handle" ]]; then
  echo 'error: missing "handle". Expected {"handle": "<name>.bsky.social", "limit": 10}.' >&2
  exit 1
fi
if ! [[ "$limit" =~ ^[0-9]+$ ]] || (( limit < 1 || limit > 50 )); then
  echo "error: limit must be an integer between 1 and 50 (got: $limit)." >&2
  exit 1
fi

url="https://public.api.bsky.app/xrpc/app.bsky.feed.getAuthorFeed"
url+="?actor=${handle}&limit=${limit}&filter=posts_no_replies"

set +e
resp=$(curl -sSf "$url" 2>&1)
rc=$?
set -e

if [[ $rc -ne 0 ]]; then
  echo "error: feed request failed (exit $rc): $resp" >&2
  echo "       check the handle, e.g. alice.bsky.social" >&2
  exit 1
fi

jq -c '[.feed[] | {
  at: .post.indexedAt,
  text: (.post.record.text // "")
}] | .[0:'"$limit"']' <<<"$resp"
