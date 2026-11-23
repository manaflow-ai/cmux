#!/usr/bin/env bash
# Stores the base commit's copy of every file the working tree changed (run locally before each A/B).
set -eu
base=${1:-3c8851dd8435f893c72d27def1e45b95692de438}
root=$(git rev-parse --show-toplevel); cd "$root"
ab=webviews/.ab-gcsc; rm -rf "$ab/base" "$ab/head"; mkdir -p "$ab/base"; : > "$ab/base/ADDED"
for f in $(git diff --name-only "$base" -- webviews/src; git ls-files --others --exclude-standard -- webviews/src); do
  if git cat-file -e "$base:$f" 2>/dev/null; then mkdir -p "$ab/base/$(dirname "$f")"; git show "$base:$f" > "$ab/base/$f"; else echo "$f" >> "$ab/base/ADDED"; fi
done
find "$ab/base" -type f | sed "s|$ab/base/||"
