#!/bin/bash
# Extract 60 fps frame sequences + contact sheets for every segment in segments.txt.
set -u
ROOT="${CNM_ROOT:-$HOME/cnm/imessage}"
export PATH=/opt/homebrew/bin:$PATH
D="$(cd "$(dirname "$0")" && pwd)"
grep -v '^#' "$D/segments.txt" | while read -r name vid a b; do
  [ -z "$name" ] && continue
  [ "$a" = "0" ] && continue
  rm -rf "$ROOT/an/$name"
  "$D/extract_frames.sh" "$ROOT/videos/$vid.mp4" "$a" "$b" "$ROOT/an/$name" 12 >/dev/null && echo "$name $(ls "$ROOT/an/$name/frames" | wc -l)"
done
