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
