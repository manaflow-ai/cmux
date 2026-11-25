#!/usr/bin/env bash
# `cmux migrate` on real public repos in CI (migrate-journey-pr.yml; hq RFD 0168): for each repo, a shallow
# clone read by `cmux migrate plan DIR` (devcontainer, compose or Nix), then `cmux migrate apply DIR --headless`,
# which runs `cloud journey --repo` on staging with the model stub: create the machine, clone the repo, apply
# the machine config, start an agent in the checkout, reply. The create-to-reply time is the project's time
# to its first working chat; CMUX_MIGRATE_JOURNEY_DELETE=1 deletes each machine after it is measured.
# A failed apply runs once more (the ledger resumes it: nothing made twice). Writes a table of
# repo, source, result and ms to the job summary and $out/results.json.
#
# Leo, 2026-11-24: "we ought to be able to have good migration capabilities all around for people of all
# stages any and all levels of technical sophistication and teams and organizations of any size and demand to
# move to autocloud"
set -euo pipefail
: "${CMUX_PATH:?CMUX_PATH is the cmux-tui to run}"
: "${TARGET:=staging}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="${RUNNER_TEMP:-$(mktemp -d)}/migrate-journey"
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
mkdir -p "$out"
if [ -z "${CMUX_DOGFOOD_STACK_EMAIL:-}" ] || [ -z "${CMUX_DOGFOOD_STACK_PASSWORD:-}" ]; then
  echo "::error title=Migrate journey cannot run::CMUX_DOGFOOD_STACK_EMAIL/_PASSWORD are empty in this environment"
  exit 1
fi
export CMUX_MIGRATE_MODEL_STUB="$here/../../tests/fixtures/model-stub/model_stub.py"
export CMUX_MIGRATE_JOURNEY_DELETE=1
# Small public repos, one per reader. Override with MIGRATE_REPOS="url url".
repos=(${MIGRATE_REPOS:-https://github.com/microsoft/vscode-remote-try-node https://github.com/docker/getting-started-app https://github.com/microsoft/vscode-remote-try-python})
status=0
printf '### cmux migrate on %s\n\n| repo | source | result | time to first working chat (ms) |\n|---|---|---|---:|\n' "$TARGET" >> "$summary"
for url in "${repos[@]}"; do
  name="$(basename "$url")"
  dir="$out/src/$name"
  export HOME="$out/home-$name"   # each repo's own ledger (~/.cmux/migrate): every entry in it is this repo's
  mkdir -p "$HOME"
  git clone --depth 1 --quiet "$url" "$dir"
  "$CMUX_PATH" migrate plan "$dir" --json > "$out/$name.plan.json"
  result=pass
  if ! "$CMUX_PATH" migrate apply "$dir" --headless --backend "$TARGET" --json > "$out/$name.apply.json" 2> "$out/$name.apply.log"; then
    echo "::warning title=Migrate journey retried::$name failed once; applying again (the ledger resumes it)"
    cp "$out/$name.apply.log" "$out/$name.apply.first.log"
    sleep 15  # sleep-ok: backoff before the one retry
    if ! "$CMUX_PATH" migrate apply "$dir" --headless --backend "$TARGET" --json > "$out/$name.apply.json" 2> "$out/$name.apply.log"; then
      result=red; status=1
    fi
  fi
  python3 -I - "$out/$name.plan.json" "$HOME/.cmux/migrate/ledger.json" "$url" "$name" "$result" "$out/results.jsonl" >> "$summary" <<'PY'
import json, sys
plan_p, ledger_p, url, name, result, results = sys.argv[1:7]
plan = json.load(open(plan_p))
plan = plan.get("result", plan)
source = plan.get("source", {}).get("kind", "?")
ms = None
try:
    for entry in json.load(open(ledger_p)).get("projects", {}).values():
        if entry.get("first_chat_ms") is not None and entry.get("started_ms") is not None:
            ms = entry["first_chat_ms"] - entry["started_ms"]
except (OSError, ValueError, AttributeError):
    pass
print(f"| {url} | {source} | {result} | {ms if ms is not None else '-'} |")
with open(results, "a") as f:
    f.write(json.dumps({"repo": url, "source": source, "result": result, "first_chat_ms": ms}) + "\n")
PY
done
exit "$status"
