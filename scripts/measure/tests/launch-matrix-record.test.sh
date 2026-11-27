#!/usr/bin/env bash
# launch-matrix.sh's record writes one JSON row per launch. A single quote in its inline python (a comment's
# apostrophe) once ended the quoted program, and every row on cmux13s became shell text instead of JSON.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# shellcheck disable=SC1090
source <(sed -n '/^record() {/,/^}/p' "$here/../launch-matrix.sh")
load1() { echo 1.5; }
OUT="$tmp" NAME=app KIND=home
LM_OTHERS="452 " record warm 1 '{"window_on_screen": 600}' '{"prompt_seen": false}' >/dev/null
LM_OTHERS="" record cold-quit 2 '{"window_on_screen": 700}' >/dev/null
python3 -I - "$tmp/runs.jsonl" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1])]
assert len(rows) == 2, rows
assert rows[0] == {"window_on_screen": 600, "prompt_seen": False, "app_name": "app", "scenario": "warm", "rep": 1,
                   "load": 1.5, "profile": "home", "other_instance_pids": [452]}, rows[0]
assert rows[1]["scenario"] == "cold-quit" and "other_instance_pids" not in rows[1], rows[1]
print("launch-matrix record: ok")
PY
