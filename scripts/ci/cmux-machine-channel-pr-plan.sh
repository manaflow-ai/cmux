#!/usr/bin/env bash
# The machine channel's plan for a pull request head (PR_HEAD_FAST_LANE, cmux-machine-channel.yml): build the
# head's thin Linux pair only when it is this repository's, into feat-cmux-next, and its merge with the base (HEAD,
# a two-commit checkout) changes the v2 tree key; a pull request never points. Writes build, the
# machine_channel profile (scripts/cmux-next/cmux-tui-build-profiles.json) and nothing else to $GITHUB_OUTPUT.
#
# pr-router.yml's route job runs this in its own checkout (git trees only: ls-tree, one inputs blob), so a pull
# request head starts no runner for "does the machine channel need this commit": that job was a whole runner and a
# fetch-depth 200 checkout for a 0.3 s answer, 1,460 runner-min in 6 h (943 runs, 2026-11-26 02Z..08Z). The plan
# job runs it too when the router passed no answer (the route step failed), so the answer never depends on it.
#
# cmux_tui_tree_key.py takes `[--version V] [REV]`: the `key` subcommand every caller named before (#56753) is no
# argument it reads, so each key came back empty and every full-tier head built both targets.
#
# Env: HEAD_REPO (the head's owner/name), GITHUB_REPOSITORY, GITHUB_BASE_REF, GITHUB_OUTPUT.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"

python3 -I -c '
import json, sys
p = json.load(open(sys.argv[1]))["machine_channel"]
for k in ("x86_64_target_set", "aarch64_target_set", "lto", "artifact_prefix"):
    print(f"{k}={p[k]}")' "$root/scripts/cmux-next/cmux-tui-build-profiles.json" >> "$GITHUB_OUTPUT"

build=false
mine="" base=""
if [[ "${GITHUB_REPOSITORY:-}" == manaflow-ai/cmux && "${HEAD_REPO:-}" == "${GITHUB_REPOSITORY:-}" \
      && "${GITHUB_BASE_REF:-}" == feat-cmux-next ]]; then
  tk="$here/cmux_tui_tree_key.py"
  mine="$("$here/timeout.sh" 60 python3 "$tk" --version v2 HEAD 2>/dev/null)" || mine=""
  base="$("$here/timeout.sh" 60 python3 "$tk" --version v2 HEAD^1 2>/dev/null)" || base=""
  if [[ -z "$mine" || -z "$base" || "$mine" != "$base" ]]; then build=true; fi
fi
echo "::notice title=machine channel PR head build::build=$build (merge key ${mine:-none}, base key ${base:-none})"
echo "build=$build" >> "$GITHUB_OUTPUT"
