#!/usr/bin/env bash
# One run of the coordinator-mode eval (cmuxterm-hq
# knowledge/inspiration/coordinator-mode-eval.md): one task, one arm, a real
# Chief through a credential-free Claude route, alone on a worker:
#   cmux-ci run --class exclusive --script scripts/measure/team-eval.sh --ref SHA \
#     --arg=base_url=http://HOST:PORT --arg=task=composer-scroll --arg=arm=A|A-steer|B|B2|L \
#     [--arg=budget=25] \
#     [--arg=minutes=60] [--arg=claude=2.1.300] \
#     --artifact .build/team-eval/out.tgz --timeout 7200
# base_url= is a Claude route that signs requests itself (the team subrouter);
# Claude Code gets only that base URL and a placeholder key, so no credential
# reaches the worker. The Chief, its desk and its subagents all run
# claude-opus-5-5 at medium effort, the one setting the Chief is used with
# (not an argument; team_eval.py fails a run that resolves to another); the
# compactor keeps its production setting.
# Builds acpmux and optchat-chief at this ref and takes cmux-tui from the
# published tree (else builds it), as scripts/measure/chief-import.sh does,
# installs Claude Code at the pinned version under the step, then runs
# Native/OptChat/optchat-chief/measure/team_eval.py. After the run it checks
# the agents' tree: `bun run check` in webviews/, and the reference PR's own
# tests (hidden from the agents). Output: TEAM-EVAL lines; the run's files in
# .build/team-eval/out.tgz (run.json, conversation.json, traces, diff.patch,
# checks.json). Spends real tokens: at most `budget` dollars, then it stops.
set -euo pipefail
base_url=""
task=""
arm=""
model="claude-opus-5-5"
effort="medium"
budget=25
minutes=60
claude_version="2.1.300"
for arg in "$@"; do
  case "$arg" in
    base_url=*) base_url="${arg#base_url=}" ;;
    task=*) task="${arg#task=}" ;;
    arm=*) arm="${arg#arm=}" ;;
    budget=*) budget="${arg#budget=}" ;;
    minutes=*) minutes="${arg#minutes=}" ;;
    claude=*) claude_version="${arg#claude=}" ;;
    *) echo "team-eval.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$base_url" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]] || { echo "team-eval.sh: base_url=http://HOST[:PORT] is required" >&2; exit 2; }
[[ "$task" =~ ^[a-z0-9-]{1,40}$ ]] || { echo "team-eval.sh: task=ID (see team_eval_tasks.json)" >&2; exit 2; }
[[ "$arm" =~ ^(A|A-steer|B|B2|L)$ ]] || { echo "team-eval.sh: arm=A|A-steer|B|B2|L" >&2; exit 2; }
[[ "$budget" =~ ^[1-9][0-9]{0,2}$ ]] || { echo "team-eval.sh: budget is whole dollars, at least 1" >&2; exit 2; }
[[ "$minutes" =~ ^[1-9][0-9]{0,2}$ ]] || { echo "team-eval.sh: minutes is whole minutes, at least 1" >&2; exit 2; }
[[ "$claude_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "team-eval.sh: claude=X.Y.Z" >&2; exit 2; }
root="$(git rev-parse --show-toplevel)"
cd "$root"
tasks="Native/OptChat/optchat-chief/measure/team_eval_tasks.json"
read -r base reference hidden < <(python3 -I - "$tasks" "$task" <<'PY'
import json, sys
t = next((t for t in json.load(open(sys.argv[1]))["tasks"] if t["id"] == sys.argv[2]), None)
if t is None:
    sys.exit(f"team-eval.sh: no task {sys.argv[2]}")
print(t["base"], t["reference"], ",".join(t.get("hidden_tests", [])) or "-")
PY
)
work="$root/.build/team-eval"
rm -rf "$work"
mkdir -p "$work/bin" "$work/out"
# The agents' checkout and HOME live outside this checkout: from inside it
# (or its parents) they could read the merged answer and this repo's CLAUDE.md.
scratch="$(mktemp -d /tmp/te-step.XXXXXX)"
repo="$scratch/repo"
home="$scratch/home"
mkdir -p "$home/.local/bin"
driver_pid=""
failed=()
packed=""
finished=""
# The run's evidence and its TEAM-EVAL line (spend, pin, checks), once,
# on every way out: a normal end, a failure or a stop. `ok` is false with
# the reasons in `failed` when the run did not pass (a pin failure, a
# cleanup that left processes); the step still exits 0 then, so cmux-ci
# returns the artifact, and the campaign reads `ok`.
pack() {
  [[ -z "$packed" ]] || return 0
  packed=1
  [[ -f "$work/out/checks.json" ]] || echo "{}" > "$work/out/checks.json"
  python3 -I - "$work/out/run.json" "$work/out/checks.json" ${failed[@]+"${failed[@]}"} <<'PY' || true
import json, os, sys
have = os.path.exists(sys.argv[1])
r = json.load(open(sys.argv[1])) if have else {"flags": ["no run.json"]}
# No driver log: no agent ever started, so nothing was spent.
started = have or os.path.exists(os.path.join(os.path.dirname(sys.argv[1]), "driver.log"))
if not started:
    r["cost_usd"] = {"all": 0, "live": 0}
    r["tokens"] = {"input": 0, "output": 0, "cache_write": 0, "cache_read": 0, "total": 0}
r["checks"] = json.load(open(sys.argv[2]))
keep = ("task", "arm", "end", "minutes", "cost_usd", "turns", "spawns", "receipts", "chief_messages",
        "diff_lines", "stub_calls", "leaks", "flags", "timeline", "checks", "acpmux_left", "pin",
        "followup_skew_s", "stall", "tokens", "ratelimit")
line = {k: r.get(k) for k in keep}
line["failed"] = sys.argv[3:] + ([] if have else ["no run.json"])
line["ok"] = not line["failed"]
line["started"] = started
# The scorer reads these from run.json.
r.update(failed=line["failed"], ok=line["ok"], started=started)
json.dump(r, open(sys.argv[1], "w"), indent=1)
print("TEAM-EVAL " + json.dumps(line))
PY
  tar -czf "$work/out.tgz" -C "$work" out 2>/dev/null || true
}
on_exit() {
  local rc=$?
  # Nothing cuts this short: the driver's own cleanup, then the evidence.
  trap '' TERM INT HUP
  if [[ -n "$driver_pid" ]] && kill -0 "$driver_pid" 2>/dev/null; then
    kill -TERM "$driver_pid" 2>/dev/null || true
    wait "$driver_pid" 2>/dev/null || true
    failed+=("stopped")
  fi
  # Left before the end (set -e, a stop): never ok, never exit 0. Not $?
  # alone: bash 3.2 reaches this trap with $? 0 after a set -u abort.
  if [[ -z "$finished" ]]; then
    failed+=("step stopped early (exit $rc)")
  fi
  if [[ -d "$work/out" ]]; then pack; fi
  rm -rf "$scratch"
  if [[ -z "$finished" ]]; then exit $(( rc == 0 ? 1 : rc )); fi
}
trap on_exit EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP
# Fleet steps run with a short PATH; look where bun installs too, and give the
# agents bun and node on theirs (~/.local/bin under the run's HOME).
BUN="$(command -v bun || true)"
for candidate in "$HOME/.bun/bin/bun" /opt/homebrew/bin/bun /usr/local/bin/bun; do
  [[ -n "$BUN" ]] && break
  [[ -x "$candidate" ]] && BUN="$candidate"
done
[[ -n "$BUN" ]] || { echo "TEAM-EVAL bun not found (PATH, ~/.bun/bin, /opt/homebrew/bin, /usr/local/bin)" >&2; exit 1; }
NODE="$(command -v node || true)"
for candidate in /opt/homebrew/bin/node /usr/local/bin/node; do
  [[ -n "$NODE" ]] && break
  [[ -x "$candidate" ]] && NODE="$candidate"
done
[[ -n "$NODE" ]] || { echo "TEAM-EVAL node not found (PATH, /opt/homebrew/bin, /usr/local/bin)" >&2; exit 1; }
# npm (for Claude Code) sits beside node.
export PATH="$(dirname "$NODE"):$PATH"
ln -s "$BUN" "$home/.local/bin/bun"
ln -s "$NODE" "$home/.local/bin/node"
echo "TEAM-EVAL-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) cores=$(sysctl -n hw.ncpu) rev=$(git rev-parse HEAD) task=$task arm=$arm model=$model effort=$effort"
curl -fsS -m 10 -o /dev/null "$base_url/_subrouter/ready" || { echo "TEAM-EVAL the route $base_url is not reachable from this worker" >&2; exit 1; }
# The task's base and reference must be in this checkout. --depth only in an
# already-shallow checkout; it would make a full clone shallow.
depth=()
[[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth 1)
for sha in "$base" "$reference"; do
  git cat-file -e "$sha^{commit}" 2>/dev/null || git fetch -q ${depth[@]+"${depth[@]}"} origin "$sha"
done

export CI=1
# Arm L runs no Chief: only Claude Code.
if [[ "$arm" != L ]]; then
git submodule update --init --depth 1 ghostty-next
scripts/cmux-next/build-acpmux.sh --output "$work/bin/acpmux"
scripts/cmux-next/build-optchat-chief.sh --output "$work/bin/optchat-chief"
key="$(python3 scripts/ci/cmux_tui_tree_key.py HEAD)"
tree="${CMUX_TUI_PIN_BASE:-https://files.cmux.com/cmux-tui}/tree/$key"
if curl -fsSL --proto '=https' "$tree/cmux-tui-aarch64-apple-darwin" -o "$work/bin/cmux-tui"; then
  sum="$(curl -fsSL --proto '=https' "$tree/cmux-tui-aarch64-apple-darwin.sha256" | awk '{print $1}')"
  [[ "$(shasum -a 256 "$work/bin/cmux-tui" | awk '{print $1}')" == "$sum" ]] || { echo "TEAM-EVAL cmux-tui sha256 mismatch ($key)" >&2; exit 1; }
else
  (cd cmux-tui && CARGO_TARGET_DIR="$work/target" cargo build --release --locked -p cmux-tui)
  cp "$work/target/release/cmux-tui" "$work/bin/cmux-tui"
fi
# The CLI is the same binary under the name cmux (`cmux chief edit` sets the arm's profile).
cp "$work/bin/cmux-tui" "$work/bin/cmux"
chmod 755 "$work/bin/"*
fi
git rev-parse HEAD > "$work/bin/REV"

npm install --prefix "$work/cc" --no-fund --no-audit "@anthropic-ai/claude-code@$claude_version" >/dev/null
ln -s "$work/cc/node_modules/.bin/claude" "$home/.local/bin/claude"
echo "TEAM-EVAL-BIN claude $(HOME="$home" "$home/.local/bin/claude" --version)"

status=0
# fd 3 is the step's stdout: each TEAM-EVAL-RATELIMIT line goes there as it
# comes (cmux-ci streams it to the campaign's headroom gate mid-run).
exec 3>&1
HOME="$home" python3 Native/OptChat/optchat-chief/measure/team_eval.py run --task "$task" --arm "$arm" \
  --bins "$work/bin" --repo "$root" --out "$work/out" --keep-repo "$repo" --live-fd 3 \
  --budget-usd "$budget" --max-minutes "$minutes" \
  --env "ANTHROPIC_BASE_URL=$base_url" --env "ANTHROPIC_API_KEY=sk-ant-placeholder-the-route-signs" \
  --env "CLAUDE_CONFIG_DIR=$home/.claude" --env "DISABLE_AUTOUPDATER=1" \
  --env "OPTCHAT_CHIEF_MODEL=$model" --env "OPTCHAT_CHIEF_EFFORT=$effort" \
  --env "OPTCHAT_SUBAGENT_MODEL=$model" --env "OPTCHAT_SUBAGENT_EFFORT=$effort" \
  --env "OPTCHAT_SUBAGENT_HARNESS=claude" > "$work/out/driver.log" 2>&1 &
driver_pid=$!
wait "$driver_pid" || status=$?
driver_pid=""
tail -3 "$work/out/driver.log"
# Exit 3 is a run that resolved to another model or effort than the pin.
if [[ "$status" == 3 ]]; then
  failed+=("driver exit 3 (pin)")
elif [[ "$status" != 0 ]]; then
  failed+=("driver exit $status")
fi
if ! grep -q "acpmux cleanup: no process holds its locks" "$work/out/driver.log"; then
  echo "TEAM-EVAL acpmux cleanup: $(grep "acpmux cleanup" "$work/out/driver.log" || echo 'no cleanup line')"
  failed+=("cleanup left processes")
fi

# Checks on the agents' tree, after the run (the agents never see their results).
checks="{}"
if [[ -d "$repo/webviews" ]]; then
  check_rc=0
  (cd "$repo/webviews" && "$BUN" install --frozen-lockfile > "$work/out/bun-install.log" 2>&1 && \
    "$BUN" run check > "$work/out/bun-check.log" 2>&1) || check_rc=$?
  hidden_rc="none"
  if [[ "$hidden" != "-" ]]; then
    # The reference PR's tests under their own names, beside whatever the agents
    # wrote. Browser-lane tests run only with CMUX_BROWSER_TESTS=1 and the
    # engines installed, else they skip; the counts show which happened.
    (cd "$repo/webviews" && "$BUN" x playwright install chromium webkit > "$work/out/playwright-install.log" 2>&1) || true
    hidden_rc=0
    IFS=, read -ra files <<< "$hidden"
    names=()
    for f in "${files[@]}"; do
      name="${f%.test.ts}.hidden.test.ts"
      git show "$reference:$f" > "$repo/$name" || hidden_rc="missing $f"
      names+=("${name#webviews/}")
    done
    if [[ "$hidden_rc" == 0 ]]; then
      (cd "$repo/webviews" && CMUX_BROWSER_TESTS=1 "$BUN" test "${names[@]}" > "$work/out/hidden-tests.log" 2>&1) || hidden_rc=$?
    fi
  fi
  checks="$(python3 -I - "$check_rc" "$hidden_rc" "$work/out/hidden-tests.log" <<'PY'
import json, os, re, sys
log = open(sys.argv[3]).read() if os.path.exists(sys.argv[3]) else ""
count = lambda word: sum(int(n) for n in re.findall(rf"^\s*(\d+) {word}$", log, re.M))
rc = sys.argv[2]
print(json.dumps({"bun_check_rc": int(sys.argv[1]), "hidden_tests_rc": int(rc) if rc.isdigit() else rc,
                  "hidden_pass": count("pass"), "hidden_skip": count("skip"), "hidden_fail": count("fail")}))
PY
)"
fi
echo "$checks" > "$work/out/checks.json"
rm -rf "$repo"
finished=1
pack
