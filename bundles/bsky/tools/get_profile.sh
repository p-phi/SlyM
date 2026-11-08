#!/usr/bin/env bash
# Fetch a Bluesky profile. Arguments are JSON on stdin.
set -euo pipefail

input=$(cat)
handle=$(jq -r '.handle // empty' <<<"$input")

if [[ -z "$handle" ]]; then
  echo 'error: missing "handle". Expected {"handle": "<name>.bsky.social"}.' >&2
  exit 1
fi

url="https://public.api.bsky.app/xrpc/app.bsky.actor.getProfile?actor=${handle}"

set +e
resp=$(curl -sSf "$url" 2>&1)
rc=$?
set -e

if [[ $rc -ne 0 ]]; then
  echo "error: profile request failed (exit $rc): $resp" >&2
  echo "       check the handle, e.g. alice.bsky.social" >&2
  exit 1
fi

jq -c '{
  handle: .handle,
  display_name: (.displayName // ""),
  bio: (.description // ""),
  followers: (.followersCount // 0),
  following: (.followsCount // 0)
}' <<<"$resp"
