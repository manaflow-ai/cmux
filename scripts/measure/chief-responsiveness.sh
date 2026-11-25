#!/usr/bin/env bash
# The Chief's responsiveness as the person feels it, on a quiet Mac: first
# visible sign, first useful sentence and final answer per ask class (trivial,
# lookup, small task, delegated), bursts of 2, 3 and 5 messages within 10 s,
# a message while a long tool call runs (steer), and the cold start. Each round
# is a new scratch Chief (cmux-tui --headless, optchat-chief host, its own
# acpmux and Claude Code), never a person's Chief. Run alone on a worker:
#   cmux-ci run --class exclusive --measurement --label measure \
#     --script scripts/measure/chief-responsiveness.sh --ref SHA \
#     --arg=base_url=http://HOST:PORT [--arg=rounds=3] [--arg=harness=claude] \
#     [--arg=model=claude-opus-5-5] [--arg=effort=high] [--arg=only=trivial,burst2] \
#     [--arg=idle=360] [--arg=env=KEY=VALUE ...] [--arg=claude=2.1.325] --timeout 14400
# base_url= is a Claude route that needs no credential (a router that signs
# requests itself, SR2 http://100.120.48.119:4016); Claude Code gets only that
# base URL and a placeholder key, so no credential reaches the worker.
# harness= is the Chief's engine harness (an acpmux harness name: claude,
# codex, or another brain acpmux knows); model= and effort= its turn engine.
# env=KEY=VALUE (repeatable; KEY is OPTCHAT_*, CHIEF_* or MUX_*) goes to the
# host, for A/B runs of one change (env=CHIEF_KEEP_TURN_SESSION=0).
# Output: CHIEF-RESP-MACHINE, one CHIEF-RESP-ROUND line per round, the markdown
# table (median and p90 per class) and one RESPONSIVENESS line of JSON
# (measure/responsive.py report). Files under .build/chief-responsiveness.
set -euo pipefail
base_url=""
claude_version="2.1.325"
rounds=3
harness="claude"
model="claude-opus-5-5"
effort="high"
only=""
idle=0
host_env=()
for arg in "$@"; do
  case "$arg" in
    base_url=*) base_url="${arg#base_url=}" ;;
    claude=*) claude_version="${arg#claude=}" ;;
    rounds=*) rounds="${arg#rounds=}" ;;
    harness=*) harness="${arg#harness=}" ;;
    model=*) model="${arg#model=}" ;;
    effort=*) effort="${arg#effort=}" ;;
    only=*) only="${arg#only=}" ;;
    idle=*) idle="${arg#idle=}" ;;
    env=*) host_env+=("${arg#env=}") ;;
    *) echo "chief-responsiveness.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$base_url" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]] || { echo "chief-responsiveness.sh: base_url=http://HOST[:PORT] is required" >&2; exit 2; }
[[ "$claude_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "chief-responsiveness.sh: claude=X.Y.Z" >&2; exit 2; }
[[ "$rounds" =~ ^[1-9][0-9]?$ && "$rounds" -le 20 ]] || { echo "chief-responsiveness.sh: rounds=1..20" >&2; exit 2; }
[[ "$harness" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]] || { echo "chief-responsiveness.sh: harness is an acpmux harness name" >&2; exit 2; }
[[ "$model" =~ ^[A-Za-z0-9._/-]{1,80}$ || -z "$model" ]] || { echo "chief-responsiveness.sh: model=NAME" >&2; exit 2; }
[[ "$effort" =~ ^(low|medium|high|xhigh|max)?$ ]] || { echo "chief-responsiveness.sh: effort=low|medium|high|xhigh|max" >&2; exit 2; }
[[ "$only" =~ ^[a-z0-9,]*$ ]] || { echo "chief-responsiveness.sh: only=probe,probe" >&2; exit 2; }
[[ "$idle" =~ ^[0-9]{1,4}$ ]] || { echo "chief-responsiveness.sh: idle is seconds" >&2; exit 2; }
for kv in ${host_env[@]+"${host_env[@]}"}; do
  [[ "$kv" =~ ^(OPTCHAT|CHIEF|MUX)_[A-Z0-9_]+=[A-Za-z0-9._,:/-]*$ ]] || { echo "chief-responsiveness.sh: env=OPTCHAT_*|CHIEF_*|MUX_*=VALUE" >&2; exit 2; }
done
root="$(git rev-parse --show-toplevel)"
cd "$root"
work="$root/.build/chief-responsiveness"
rm -rf "$work"
mkdir -p "$work/bin" "$work/home/.local/bin"
echo "CHIEF-RESP-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) cores=$(sysctl -n hw.ncpu) ram_gb=$(( $(sysctl -n hw.memsize) / 1073741824 )) macos=$(sw_vers -productVersion) rev=$(git rev-parse HEAD) harness=$harness model=$model effort=$effort rounds=$rounds env=${host_env[*]+"${host_env[*]}"}"
curl -fsS -m 10 -o /dev/null "$base_url/_subrouter/ready" || { echo "CHIEF-RESP the route $base_url is not reachable from this worker" >&2; exit 1; }
# Ready says nothing about Claude (a router answered 200 here while every
# request got 502): one tiny real request, else stop before any round.
probe_status=0
python3 -I Native/OptChat/optchat-chief/measure/first_turn_cost.py probe --url "$base_url" || probe_status=$?
[[ "$probe_status" == 0 ]] || { echo "CHIEF-RESP the route $base_url does not answer Claude requests ($probe_status)" >&2; exit "$probe_status"; }

# Cargo runs only on a build host; this step is one. cmux-tui crates build
# libghostty-vt from ghostty-next.
export CI=1
git submodule update --init --depth 1 ghostty-next
scripts/cmux-next/build-acpmux.sh --output "$work/bin/acpmux"
scripts/cmux-next/build-optchat-chief.sh --output "$work/bin/optchat-chief"
key="$(python3 scripts/ci/cmux_tui_tree_key.py HEAD)"
tree="${CMUX_TUI_PIN_BASE:-https://files.cmux.com/cmux-tui}/tree/$key"
if curl -fsSL --proto '=https' "$tree/cmux-tui-aarch64-apple-darwin" -o "$work/bin/cmux-tui"; then
  sum="$(curl -fsSL --proto '=https' "$tree/cmux-tui-aarch64-apple-darwin.sha256" | awk '{print $1}')"
  [[ "$(shasum -a 256 "$work/bin/cmux-tui" | awk '{print $1}')" == "$sum" ]] || { echo "CHIEF-RESP cmux-tui sha256 mismatch ($key)" >&2; exit 1; }
else
  (cd cmux-tui && CARGO_TARGET_DIR="$work/target" cargo build --release --locked -p cmux-tui)
  cp "$work/target/release/cmux-tui" "$work/bin/cmux-tui"
fi
cp "$work/bin/cmux-tui" "$work/bin/cmux"
chmod 755 "$work/bin/"*
git rev-parse HEAD > "$work/bin/REV"

# Claude Code at the pinned version (the native build, checked against the
# release manifest), under the step only; a fresh HOME keeps the worker's own
# settings and logins out of the run.
dl="https://downloads.claude.ai/claude-code-releases/$claude_version"
curl -fsSL --proto '=https' -m 60 "$dl/manifest.json" -o "$work/claude-manifest.json"
want="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["platforms"]["darwin-arm64"]["checksum"])' "$work/claude-manifest.json")"
curl -fsSL --proto '=https' -m 600 "$dl/darwin-arm64/claude" -o "$work/claude"
[[ "$(shasum -a 256 "$work/claude" | awk '{print $1}')" == "$want" ]] || { echo "CHIEF-RESP claude $claude_version sha256 mismatch" >&2; exit 1; }
chmod 755 "$work/claude"
ln -s "$work/claude" "$work/home/.local/bin/claude"
echo "CHIEF-RESP-BIN claude $(HOME="$work/home" "$work/home/.local/bin/claude" --version)"

driver_pid=""
stop_driver() {
  if [[ -n "$driver_pid" ]] && kill -0 "$driver_pid" 2>/dev/null; then
    kill -TERM "$driver_pid" 2>/dev/null || true
    wait "$driver_pid" 2>/dev/null || true
  fi
}
trap stop_driver EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP
engine_env=(--env "OPTCHAT_CHIEF_HARNESS=$harness")
[[ -n "$model" ]] && engine_env+=(--env "OPTCHAT_CHIEF_MODEL=$model")
[[ -n "$effort" ]] && engine_env+=(--env "OPTCHAT_CHIEF_EFFORT=$effort")
for kv in ${host_env[@]+"${host_env[@]}"}; do engine_env+=(--env "$kv"); done
status=0
dirs=()
for r in $(seq 1 "$rounds"); do
  out="$work/round-$r"
  dirs+=("$out")
  rs=0
  HOME="$work/home" python3 Native/OptChat/optchat-chief/measure/chief_driver.py --scenario responsive \
    --out "$out" --bins "$work/bin" --harness "$harness" --turn-timeout 600 --idle "$idle" --only "$only" \
    --env "ANTHROPIC_BASE_URL=$base_url" --env "ANTHROPIC_API_KEY=sk-ant-placeholder-the-route-signs" \
    --env "CLAUDE_CONFIG_DIR=$work/home/.claude" --env "DISABLE_AUTOUPDATER=1" \
    "${engine_env[@]}" > "$out.log" 2>&1 &
  driver_pid=$!
  wait "$driver_pid" || rs=$?
  driver_pid=""
  grep -E '\] probe[ -]' "$out.log" | sed "s/^/CHIEF-RESP-ROUND $r /" || true
  if ! grep -q "acpmux cleanup: .*no process holds its locks" "$out.log"; then
    echo "CHIEF-RESP round $r: acpmux cleanup not confirmed" >&2
    rs=1
  fi
  if [[ "$rs" != 0 ]]; then
    echo "CHIEF-RESP round $r ended $rs; last lines:" >&2
    tail -15 "$out.log" >&2
    status=1
  fi
done
python3 -I Native/OptChat/optchat-chief/measure/responsive.py report ${dirs[@]+"${dirs[@]}"} \
  --label "$(git rev-parse --short=12 HEAD) $harness $model $effort ${host_env[*]+"${host_env[*]}"}" \
  --json "$work/report.json" || status=1
exit "$status"
