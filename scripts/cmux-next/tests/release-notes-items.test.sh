#!/usr/bin/env bash
# release-notes.py build emits structured change items (UPDATE-CARD):
# newest first, the title without its "(#1234)" suffix, the author and the
# PR number; subjects without a PR keep their whole title and no pr.
set -euo pipefail
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/release-notes.py"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
git -C "$tmp" init -q
commit() { GIT_AUTHOR_NAME="$1" GIT_COMMITTER_NAME="$1" GIT_AUTHOR_EMAIL=a@example.com GIT_COMMITTER_EMAIL=a@example.com \
  git -C "$tmp" commit -q --allow-empty -m "$2"; }
commit "Ada" "Add the update card (#101)"
commit "Grace" "Fix a crash"
commit "Linus" "Faster tabs (#103)"
(cd "$tmp" && python3 "$script" build --build 7 --short 1.2.3 --date 2026-10-06 --head HEAD --out notes >/dev/null)
python3 - "$tmp/notes/7.json" <<'PY'
import json, sys
notes = json.load(open(sys.argv[1]))
assert notes["changes"] == ["Faster tabs (#103)", "Fix a crash", "Add the update card (#101)"], notes["changes"]
expected = [{"title": "Faster tabs", "author": "Linus", "pr": 103},
            {"title": "Fix a crash", "author": "Grace"},
            {"title": "Add the update card", "author": "Ada", "pr": 101}]
assert notes["items"] == expected, notes["items"]
print("ok")
PY

# The summary and the What's New digest read as a person reads them (Leo on nightly
# 3913596493801): work-stream commits ("cmux NEXT perf-split:", "perf-gate:") stay out, and a
# long line keeps every word; its digest title ends at its first clause instead of an ellipsis, and
# the digest summary carries the rest of the line, not the title again.
for subject in \
  "cmux NEXT perf-split: review: name which tabs a surface expectation finds; the gate prints them (cx-8w027.14)" \
  "cmux NEXT perf-fanout: a restored New Tab page reads no tab list in its pane's snapshot (cx-sya4n)" \
  "perf-gate: a switch budget of 0 sidebar row configures (cx-8w027.17)" \
  "cmux-next strip: terminals in the keep-alive band keep drawing, so a column scrolled in is never blank" \
  "cmux-next strip: a column's tab bar lays out for where its pane rests, never pinned to the traffic lights while the camera scrolls"; do
  commit "Ada" "$subject"
done
(cd "$tmp" && python3 "$script" build --build 8 --short 1.0.0-nightly.8 --date 2026-10-18 --head HEAD --since HEAD~5 --out notes >/dev/null)
python3 - "$tmp/notes/8.json" <<'PY'
import json, sys
notes = json.load(open(sys.argv[1]))
titles = [line["title"] for line in notes["summary"]]
assert titles == [
    "A column's tab bar lays out for where its pane rests, never pinned to the traffic lights while the camera scrolls",
    "Terminals in the keep-alive band keep drawing, so a column scrolled in is never blank",
], titles
entries = notes["whatsNew"]["entries"]
assert [(e["title"]["en"], e["summary"]["en"]) for e in entries] == [
    ("A column's tab bar lays out for where its pane rests", "Never pinned to the traffic lights while the camera scrolls."),
    ("Terminals in the keep-alive band keep drawing", "So a column scrolled in is never blank."),
], entries
assert not any("…" in e["title"]["en"] for e in entries)
print("ok")
PY
