#!/usr/bin/env bash
# `cmux migrate` on real public repos in CI (migrate-journey-pr.yml; hq RFD 0168): for each repo, a shallow
# clone read by `cmux migrate plan DIR` (devcontainer, compose or Nix), then `cmux migrate apply DIR --headless`,
# which runs `cloud journey --repo` on staging with the model stub: create the machine, clone the repo, apply
# the machine config, start an agent in the checkout, reply. The create-to-reply time is the project's time
# to its first working chat. CMUX_MIGRATE_JOURNEY_DELETE=1 drops `--keep`, so the journey deletes each machine
# after it is measured, pass or fail: CI leaves no machines behind. Debugging a red needs no live machine: the
# journey's own journey.json and the apply logs below are the record (set CMUX_MIGRATE_JOURNEY_DELETE=0 on a
# manual run to keep the machines, then `cmux migrate undo SOURCE_ID --yes` or `cmux vm rm ID`).
# Then one server over SSH (`cmux migrate plan ssh:HOST`; MIGRATE_SSH_HOST, the workflow's throwaway sshd).
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
export CMUX_MIGRATE_JOURNEY_DELETE="${CMUX_MIGRATE_JOURNEY_DELETE:-1}"
# Small public repos, one per reader. Override with MIGRATE_REPOS="url url".
repos=(${MIGRATE_REPOS:-https://github.com/microsoft/vscode-remote-try-node https://github.com/docker/getting-started-app https://github.com/microsoft/vscode-remote-try-python})
status=0
printf '### cmux migrate on %s\n\n| repo | source | result | time to first working chat (ms) |\n|---|---|---|---:|\n' "$TARGET" >> "$summary"
# One case: plan SOURCE, apply it headless (once more on a failure), one table row and results.jsonl line.
# $1 names the row, $2 is the word `cmux migrate` reads (a folder, ssh:HOST), $3 the file stem; HOME is the case's own.
run_case() {
  local label="$1" source="$2" name="$3" result=pass
  if ! "$CMUX_PATH" migrate plan "$source" --json > "$out/$name.plan.json" 2> "$out/$name.plan.log"; then
    echo "::error title=Migrate journey plan failed::$label: cmux migrate plan $source failed (see $name.plan.log)"
    result=red
  elif ! python3 -I -c 'import json, sys; p = json.load(open(sys.argv[1])); p = p.get("result", p); sys.exit(0 if p.get("projects") else 1)' "$out/$name.plan.json"; then
    echo "::error title=Migrate journey read nothing::$label: the plan from $source has no project"
    result=red
  elif ! "$CMUX_PATH" migrate apply "$source" --headless --backend "$TARGET" --json > "$out/$name.apply.json" 2> "$out/$name.apply.log"; then
    echo "::warning title=Migrate journey retried::$name failed once; applying again (the ledger resumes it)"
    cp "$out/$name.apply.log" "$out/$name.apply.first.log"
    sleep 15  # sleep-ok: backoff before the one retry
    if ! "$CMUX_PATH" migrate apply "$source" --headless --backend "$TARGET" --json > "$out/$name.apply.json" 2> "$out/$name.apply.log"; then
      result=red
    fi
  fi
  [ "$result" = pass ] || status=1
  python3 -I - "$out/$name.plan.json" "$HOME/.cmux/migrate/ledger.json" "$label" "$name" "$result" "$out/results.jsonl" >> "$summary" <<'PY'
import json, sys
plan_p, ledger_p, url, name, result, results = sys.argv[1:7]
try:
    plan = json.load(open(plan_p))
    plan = plan.get("result", plan)
except (OSError, ValueError, AttributeError):
    plan = {}
# The plan's kind (ssh-host) as the table's source word (ssh_host).
source = plan.get("source", {}).get("kind", "?").replace("-", "_")
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
}
for url in "${repos[@]}"; do
  name="$(basename "$url")"
  dir="$out/src/$name"
  export HOME="$out/home-$name"   # each repo's own ledger (~/.cmux/migrate): every entry in it is this repo's
  mkdir -p "$HOME"
  git clone --depth 1 --quiet "$url" "$dir"
  run_case "$url" "$dir" "$name"
done
# An existing server over SSH: the workflow starts a throwaway sshd on 127.0.0.1 whose own HOME holds one
# checkout and dotfiles, and names it in MIGRATE_SSH_HOST (an ~/.ssh/config alias) and MIGRATE_SSH_HOME (the
# migrating HOME that alias is written into). `cmux migrate plan ssh:HOST` runs the read-only probe there.
if [ -n "${MIGRATE_SSH_HOST:-}" ]; then
  export HOME="${MIGRATE_SSH_HOME:-$out/home-ssh-host}"
  mkdir -p "$HOME"
  run_case "ssh:$MIGRATE_SSH_HOST${MIGRATE_SSH_REPO:+ ($MIGRATE_SSH_REPO)}" "ssh:$MIGRATE_SSH_HOST" ssh-host
else
  echo "::notice title=Migrate journey: no SSH host::MIGRATE_SSH_HOST is unset; the ssh_host case did not run"
fi
exit "$status"
