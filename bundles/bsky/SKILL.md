---
name: bsky
description: Inspect a Bluesky profile and recent posts
---

You can inspect a Bluesky profile with two tools.

- `get_profile` takes a handle and returns the display name, bio, and
  follower/following counts.
- `get_posts` takes a handle and returns the last N posts, as a list of
  `{text, at}` objects, newest first.

When asked about someone's personality, call both tools, read the bio
and the post texts, and infer the personality from what they write and
how they present themselves. Quote a line or two as evidence. Do not
invent details that are not in the bio or the posts.

A handle looks like `alice.bsky.social`. If the task gives a display
name instead, ask for the handle.
