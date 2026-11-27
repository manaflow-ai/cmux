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
# The cases run at once, each in its own subshell with its own HOME (so its own ledger), and the table is
# written in case order once all have ended. One after another they took 36-40 min on 2026-11-25 and then
# passed the job's 50 min bound: 35 of the 41 cancelled runs of the 60 before 2026-11-27 01:45Z ran 50-59 min
# and ended with no verdict, each case alone being 5-10 min of staging waits (ci-min-per-pr-14, Leo
# 2026-11-21: "de facto, im asking for 99% fewer minutes of ci time, period"). MIGRATE_SERIAL=1 runs them
# one after another, as before.
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
  python3 -I - "$out/$name.plan.json" "$HOME/.cmux/migrate/ledger.json" "$label" "$name" "$result" "$out/$name.result.jsonl" > "$out/$name.row" <<'PY'
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
  [ "$result" = pass ]
}
# Starts one case in the background (or runs it here with MIGRATE_SERIAL=1); its subshell keeps the HOME and
# environment of the moment it starts. finish_cases waits for every one, then writes the rows in start order.
cases=() pids=()
start_case() {
  cases+=("$3")
  if [ "${MIGRATE_SERIAL:-0}" = 1 ]; then
    ( run_case "$@" ) || status=1
    pids+=("")
  else
    ( run_case "$@" ) &
    pids+=("$!")
  fi
}
finish_cases() {
  local i
  for i in "${!cases[@]}"; do
    if [ -n "${pids[$i]}" ]; then wait "${pids[$i]}" || status=1; fi
    cat "$out/${cases[$i]}.row" >> "$summary" 2>/dev/null || { echo "| ${cases[$i]} | ? | red (no row) | - |" >> "$summary"; status=1; }
    cat "$out/${cases[$i]}.result.jsonl" >> "$out/results.jsonl" 2>/dev/null || true
  done
}
for url in "${repos[@]}"; do
  name="$(basename "$url")"
  dir="$out/src/$name"
  export HOME="$out/home-$name"   # each repo's own ledger (~/.cmux/migrate): every entry in it is this repo's
  mkdir -p "$HOME"
  git clone --depth 1 --quiet "$url" "$dir"
  start_case "$url" "$dir" "$name"
done
# A T3 Code workspace (cmuxterm-hq#23822, the switch kit; CMUX_SWITCH_KIT=1 turns the source on): a T3 home
# whose statev2.sqlite lists one project (a public checkout) and one thread run in a git worktree of it, with
# the thread's Claude Code transcript where T3 leaves it. `cmux migrate plan t3code:DIR` reads it read-only;
# apply makes a machine per project and per thread worktree. A canary in the auth table and a script command
# must never reach the plan.
t3_url="${MIGRATE_T3_REPO:-https://github.com/microsoft/vscode-remote-try-node}"
runner_home=$HOME
export HOME="$out/home-t3code"
mkdir -p "$HOME"
t3_repo="$HOME/code/$(basename "$t3_url")"
git clone --depth 1 --quiet "$t3_url" "$t3_repo"
t3_wt="$HOME/.t3/worktrees/$(basename "$t3_url")/t3-docs"
git -C "$t3_repo" worktree add --quiet -b t3/docs "$t3_wt"
python3 -I - "$HOME" "$t3_repo" "$t3_wt" <<'PY'
import json, os, re, sqlite3, sys
home, repo, wt = sys.argv[1:4]
os.makedirs(f"{home}/.t3/userdata", exist_ok=True)
db = sqlite3.connect(f"{home}/.t3/userdata/statev2.sqlite")
db.executescript('''
CREATE TABLE projection_projects (project_id TEXT PRIMARY KEY, title TEXT, workspace_root TEXT,
  scripts_json TEXT, deleted_at TEXT, archived_at TEXT);
CREATE TABLE orchestration_v2_projection_threads (thread_id TEXT PRIMARY KEY, project_id TEXT, title TEXT,
  active_provider_thread_id TEXT, archived_at TEXT, deleted_at TEXT, payload_json TEXT);
CREATE TABLE orchestration_v2_projection_provider_threads (provider_thread_id TEXT PRIMARY KEY,
  thread_id TEXT, payload_json TEXT);
CREATE TABLE auth_sessions (id TEXT, token TEXT);
''')
native = "5b1c0f6e-0000-4000-8000-000000023822"
db.execute("INSERT INTO projection_projects VALUES ('p1', 'try-node', ?, ?, NULL, NULL)",
           (repo, json.dumps([{"name": "dev", "command": "SECRET=CANARY23822 npm start"}])))
db.execute("INSERT INTO orchestration_v2_projection_threads VALUES ('t1', 'p1', 'docs pass', 'pt1', NULL, NULL, ?)",
           (json.dumps({"branch": "t3/docs", "worktreePath": wt, "modelSelection": {"model": "claude-sonnet-5-5"}}),))
db.execute("INSERT INTO orchestration_v2_projection_provider_threads VALUES ('pt1', 't1', ?)",
           (json.dumps({"nativeThreadRef": {"driver": "claudeAgent", "nativeId": native}}),))
db.execute("INSERT INTO auth_sessions VALUES ('s', 'CANARY23822')")
db.commit()
slug = re.sub(r"[^A-Za-z0-9]", "-", os.path.realpath(wt))
os.makedirs(f"{home}/.claude/projects/{slug}", exist_ok=True)
open(f"{home}/.claude/projects/{slug}/{native}.jsonl", "w").write('{"type":"user","message":{"role":"user","content":"docs pass"}}\n')
PY
export CMUX_SWITCH_KIT=1
start_case "t3code ($t3_url)" "t3code:$HOME/.t3" t3code
unset CMUX_SWITCH_KIT
export HOME="$runner_home"   # later cases start from the runner's HOME, not the T3 fixture's
# An existing server over SSH: the workflow starts a throwaway sshd on 127.0.0.1 whose own HOME holds one
# checkout and dotfiles, and names it in MIGRATE_SSH_HOST (an ~/.ssh/config alias) and MIGRATE_SSH_HOME (the
# migrating HOME that alias is written into). `cmux migrate plan ssh:HOST` runs the read-only probe there.
if [ -n "${MIGRATE_SSH_HOST:-}" ]; then
  export HOME="${MIGRATE_SSH_HOME:-$out/home-ssh-host}"
  mkdir -p "$HOME"
  start_case "ssh:$MIGRATE_SSH_HOST${MIGRATE_SSH_REPO:+ ($MIGRATE_SSH_REPO)}" "ssh:$MIGRATE_SSH_HOST" ssh-host
else
  echo "::notice title=Migrate journey: no SSH host::MIGRATE_SSH_HOST is unset; the ssh_host case did not run"
fi
finish_cases
if grep -q CANARY23822 "$out/t3code.plan.json"; then
  echo "::error title=Switch kit leaked a canary::the t3code plan carries the auth or script canary"
  status=1
fi
exit "$status"
