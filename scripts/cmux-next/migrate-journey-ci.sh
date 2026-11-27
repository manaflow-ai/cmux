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
# A failed apply runs once more (the ledger resumes it: nothing made twice) when the budget still holds one.
#
# The cases run side by side (each has its own HOME and ledger) and every attempt is bounded by
# MIGRATE_JOURNEY_END_BY (epoch seconds; the workflow sets it a few minutes inside timeout-minutes), so the
# script always ends with its own verdict, never a cancellation. A machine an attempt cut off at the bound
# leaves behind is a `jr-` journey machine, which the next journey's sweep deletes (cloud_journey/sweep.rs).
# Each case ends one of:
#   pass     the plan read a project and apply reached a first working chat;
#   red      a plan or apply failure that is not staging's (a CLI regression lands here);
#   timeout  an attempt ran past the budget (counted red: a hang is a finding);
#   staging  every failed event of the last attempt is `create-machine` with a staging capacity or reachability
#            signature (STAGING below: cloud-journey.ts CAPACITY_RED, plus create_overdue and an unreachable API).
# Exit 0: no red or timeout and at least one pass (each staging case is named in a warning). Exit 1: a red or
# timeout. Exit 4: staging stopped every case, so nothing was verified (cloud-journey-ci.sh's capacity-only code).
# Writes a table of repo, source, result, attempts, wall and ms to the job summary, $out/results.jsonl and
# $out/verdict.json. tests/test_migrate_journey_verdict.py pins the verdicts with a stub CLI.
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
export CMUX_MIGRATE_MODEL_STUB="${CMUX_MIGRATE_MODEL_STUB:-$here/../../tests/fixtures/model-stub/model_stub.py}"
export CMUX_MIGRATE_JOURNEY_DELETE="${CMUX_MIGRATE_JOURNEY_DELETE:-1}"
# The budget: every attempt ends by end_by. A retry starts only with retry_min_s left (a first chat took 435 to
# 512 s in run 45899973376, and a create that never settles fails at 300 s). Cases start stagger_s apart so
# their creates do not reach staging in one burst.
end_by="${MIGRATE_JOURNEY_END_BY:-$(( $(date +%s) + 1800 ))}"
retry_min_s="${MIGRATE_JOURNEY_RETRY_MIN_S:-600}"
stagger_s="${MIGRATE_JOURNEY_STAGGER_S:-20}"
plan_bound_s="${MIGRATE_JOURNEY_PLAN_BOUND_S:-180}"
backoff_s="${MIGRATE_JOURNEY_RETRY_BACKOFF_S:-15}"
min_attempt_s="${MIGRATE_JOURNEY_MIN_ATTEMPT_S:-60}"
left() { echo $(( end_by - $(date +%s) )); }
# Small public repos, one per reader. Override with MIGRATE_REPOS="url url".
repos=(${MIGRATE_REPOS:-https://github.com/microsoft/vscode-remote-try-node https://github.com/docker/getting-started-app https://github.com/microsoft/vscode-remote-try-python})

# One apply attempt's result from its exit code and log: pass, timeout, staging or red.
classify() {
  local rc="$1" log="$2"
  if [ "$rc" = 0 ]; then echo pass; return; fi
  if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then echo timeout; return; fi
  python3 -I - "$log" <<'CLASSIFY'
import json, re, sys
# cloud-journey.ts CAPACITY_RED, plus a create the platform failed as overdue and a Cloud API that never answered.
STAGING = re.compile(
    r"\b429\b|rate.?limit|too many requests|no (?:machine|spare|capacity)s? (?:is |are )?available|out of capacity"
    r"|at capacity|insufficient capacity|no_capacity|VM start capacity|infrastructure overloaded"
    r"|cloud\.machine\.create_overdue|could not reach the Cloud API|the Cloud API answered HTTP 50[234]\b",
    re.I,
)
failed = []
try:
    for line in open(sys.argv[1]):
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if isinstance(event, dict) and event.get("event") == "failed":
            failed.append(event)
except OSError:
    pass
staging = bool(failed) and all(
    e.get("step") == "create-machine" and STAGING.search(str(e.get("detail", ""))) for e in failed
)
print("staging" if staging else "red")
CLASSIFY
}

# One apply attempt, bounded by what is left of the budget; prints its result.
apply_once() {
  local source="$1" name="$2" budget rc=0
  budget="$(left)"
  if [ "$budget" -lt "$min_attempt_s" ]; then echo timeout; return; fi
  timeout -k 20 "$budget" "$CMUX_PATH" migrate apply "$source" --headless --backend "$TARGET" --json \
    > "$out/$name.apply.json" 2> "$out/$name.apply.log" || rc=$?
  classify "$rc" "$out/$name.apply.log"
}

# One case: plan SOURCE, apply it headless (once more on a failure, budget allowing), then its row in
# $out/$name.result.json. $1 names the row, $2 is the word `cmux migrate` reads (a folder, ssh:HOST), $3 the file
# stem; HOME is the case's own. It runs in its own subshell, so it reports through that file, not variables.
run_case() {
  local label="$1" source="$2" name="$3" result attempts=0 first="" started
  started="$(date +%s)"
  if ! timeout -k 10 "$plan_bound_s" "$CMUX_PATH" migrate plan "$source" --json > "$out/$name.plan.json" 2> "$out/$name.plan.log"; then
    echo "::error title=Migrate journey plan failed::$label: cmux migrate plan $source failed (see $name.plan.log)"
    result=red
  elif ! python3 -I -c 'import json, sys; p = json.load(open(sys.argv[1])); p = p.get("result", p); sys.exit(0 if p.get("projects") else 1)' "$out/$name.plan.json"; then
    echo "::error title=Migrate journey read nothing::$label: the plan from $source has no project"
    result=red
  else
    attempts=1
    result="$(apply_once "$source" "$name")"
    if [ "$result" != pass ] && [ "$(left)" -ge "$retry_min_s" ]; then
      echo "::warning title=Migrate journey retried::$name: $result once; applying again (the ledger resumes it)"
      cp "$out/$name.apply.log" "$out/$name.apply.first.log"
      first="$result"
      sleep "$backoff_s"  # sleep-ok: backoff before the one retry
      attempts=2
      result="$(apply_once "$source" "$name")"
      # A retry the budget cut short after a staging failure is still staging's, not the CLI's.
      if [ "$result" = timeout ] && [ "$first" = staging ]; then result=staging; fi
    elif [ "$result" != pass ]; then
      echo "::warning title=Migrate journey not retried::$name: $result with $(left) s left, under the ${retry_min_s} s a retry needs"
    fi
  fi
  python3 -I - "$out/$name.plan.json" "$HOME/.cmux/migrate/ledger.json" "$out/$name.apply.log" "$label" "$name" \
    "$result" "$attempts" "$(( $(date +%s) - started ))" "$out/$name.result.json" <<'ROW'
import json, sys
plan_p, ledger_p, log_p, url, name, result, attempts, wall_s, dest = sys.argv[1:10]
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
detail = ""
if result != "pass":
    try:
        for line in open(log_p):
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if isinstance(event, dict) and event.get("event") == "failed":
                detail = f"{event.get('step', '?')}: {event.get('detail', '')}"[:300]
    except OSError:
        pass
with open(dest, "w") as f:
    json.dump({"repo": url, "name": name, "source": source, "result": result, "attempts": int(attempts),
               "wall_s": int(wall_s), "first_chat_ms": ms, "detail": detail}, f)
ROW
}

# The cases, in table order, as "label|source|name|HOME|extra env".
cases=()
for url in "${repos[@]}"; do
  name="$(basename "$url")"
  git clone --depth 1 --quiet "$url" "$out/src/$name"
  cases+=("$url|$out/src/$name|$name|$out/home-$name|")
done
# A T3 Code workspace (cmuxterm-hq#23822, the switch kit; CMUX_SWITCH_KIT=1 turns the source on): a T3 home
# whose statev2.sqlite lists one project (a public checkout) and one thread run in a git worktree of it, with
# the thread's Claude Code transcript where T3 leaves it. `cmux migrate plan t3code:DIR` reads it read-only;
# apply makes a machine per project and per thread worktree. A canary in the auth table and a script command
# must never reach the plan.
t3_url="${MIGRATE_T3_REPO:-https://github.com/microsoft/vscode-remote-try-node}"
t3_home="$out/home-t3code"
mkdir -p "$t3_home"
t3_repo="$t3_home/code/$(basename "$t3_url")"
git clone --depth 1 --quiet "$t3_url" "$t3_repo"
t3_wt="$t3_home/.t3/worktrees/$(basename "$t3_url")/t3-docs"
git -C "$t3_repo" worktree add --quiet -b t3/docs "$t3_wt"
python3 -I - "$t3_home" "$t3_repo" "$t3_wt" <<'PY'
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
cases+=("t3code ($t3_url)|t3code:$t3_home/.t3|t3code|$t3_home|CMUX_SWITCH_KIT=1")
# An existing server over SSH: the workflow starts a throwaway sshd on 127.0.0.1 whose own HOME holds one
# checkout and dotfiles, and names it in MIGRATE_SSH_HOST (an ~/.ssh/config alias) and MIGRATE_SSH_HOME (the
# migrating HOME that alias is written into). `cmux migrate plan ssh:HOST` runs the read-only probe there.
if [ -n "${MIGRATE_SSH_HOST:-}" ]; then
  cases+=("ssh:$MIGRATE_SSH_HOST${MIGRATE_SSH_REPO:+ ($MIGRATE_SSH_REPO)}|ssh:$MIGRATE_SSH_HOST|ssh-host|${MIGRATE_SSH_HOME:-$out/home-ssh-host}|")
else
  echo "::notice title=Migrate journey: no SSH host::MIGRATE_SSH_HOST is unset; the ssh_host case did not run"
fi

# Every case at once, each in its own subshell with its own HOME (its own ledger: every entry is that case's).
pids=()
results=()
for i in "${!cases[@]}"; do
  IFS='|' read -r label source name home extra <<< "${cases[$i]}"
  results+=("$out/$name.result.json")
  mkdir -p "$home"
  if [ "$i" != 0 ]; then sleep "$stagger_s"; fi  # sleep-ok: spread the creates
  (
    export HOME="$home"
    if [ -n "$extra" ]; then export "${extra?}"; fi
    run_case "$label" "$source" "$name"
  ) &
  pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid" || true; done

status=0
python3 -I - "$TARGET" "$out/results.jsonl" "$out/verdict.json" "$summary" "${results[@]}" <<'VERDICT' || status=$?
import json, sys
target, results_p, verdict_p, summary_p, *paths = sys.argv[1:]
rows = []
for p in paths:
    try:
        rows.append(json.load(open(p)))
    except (OSError, ValueError):
        # A case that wrote no result (its subshell died) is not a pass.
        name = p.rsplit("/", 1)[-1].removesuffix(".result.json")
        rows.append({"repo": name, "name": name, "source": "?", "result": "red", "attempts": 0, "wall_s": None,
                     "first_chat_ms": None, "detail": "the case wrote no result"})
count = lambda r: sum(1 for row in rows if row["result"] == r)
passed, red, timed_out, staging = count("pass"), count("red"), count("timeout"), count("staging")
if red or timed_out:
    verdict, code = "red", 1
elif passed:
    verdict, code = "pass", 0
else:
    verdict, code = "staging_unavailable", 4
with open(results_p, "w") as f:
    for row in rows:
        f.write(json.dumps(row) + "\n")
with open(verdict_p, "w") as f:
    json.dump({"verdict": verdict, "pass": passed, "red": red, "timeout": timed_out, "staging": staging,
               "cases": rows}, f, indent=2)
with open(summary_p, "a") as s:
    s.write(f"### cmux migrate on {target}: {verdict}\n\n")
    s.write("| repo | source | result | attempts | wall (s) | time to first working chat (ms) |\n"
            "|---|---|---|---:|---:|---:|\n")
    for row in rows:
        ms, wall = row.get("first_chat_ms"), row.get("wall_s")
        s.write(f"| {row['repo']} | {row['source']} | {row['result']} | {row.get('attempts', 0)} | "
                f"{wall if wall is not None else '-'} | {ms if ms is not None else '-'} |\n")
    for row in rows:
        if row["result"] != "pass" and row.get("detail"):
            s.write(f"\n- {row['repo']} ({row['result']}): `{row['detail']}`")
    s.write("\n")
for row in rows:
    if row["result"] == "staging":
        print(f"::warning title=Migrate journey: staging, not the CLI::{row['repo']}: staging could not create its "
              f"machine ({row.get('detail') or 'capacity'}); this case was not verified on this run")
    elif row["result"] in ("red", "timeout"):
        print(f"::error title=Migrate journey {row['result']}::{row['repo']}: {row.get('detail') or row['result']}")
if verdict == "staging_unavailable":
    print("::error title=Migrate journey: staging unavailable::staging stopped every case before a first chat, "
          "so this run has no CLI verdict (exit 4); rerun once staging capacity is back")
print(f"migrate journey: {verdict} (pass {passed}, red {red}, timeout {timed_out}, staging {staging})")
sys.exit(code)
VERDICT
if grep -q CANARY23822 "$out/t3code.plan.json" 2>/dev/null; then
  echo "::error title=Switch kit leaked a canary::the t3code plan carries the auth or script canary"
  status=1
fi
exit "$status"
