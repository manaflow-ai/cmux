#!/usr/bin/env bash
# Chief latency before/after: the Chief latency lane's one harness (shared
# plan "Chief turns are slow and large", 2026-11-23). It builds the Chief's
# host trio (acpmux, optchat-chief, cmux-tui) at two refs, then runs the
# `latency` scenario (Native/OptChat/optchat-chief/measure/scenario.py: 15
# typical asks: a trivial reply, a memory recall, a tool call, a long reply,
# one and two subagents, a view rebuild and the turn after it) on a scratch
# Chief at each ref, the order alternating by round, on one worker,
# with a real model. Each round is a new scratch Chief (cmux-tui --headless,
# optchat-chief host, its own acpmux and Claude Code), never a person's Chief.
# The driver and the analysis come from this checkout; only the binaries come
# from the refs. Run alone on a worker:
#   cmux-ci run --class exclusive --measurement --label measure \
#     --script scripts/measure/chief-latency.sh --ref HARNESS_SHA \
#     --arg=base_url=http://100.120.48.119:4016 --arg=before=BASE_SHA --arg=after=HEAD_SHA \
#     [--arg=rounds=1] [--arg=model=claude-opus-5-5] [--arg=effort=high] [--arg=only=l01,l02] \
#     [--arg=env=KEY=VALUE ...] [--arg=claude=2.1.325] --timeout 10800
# before= and after= are full commit SHAs; after= may be left out for one
# ref's numbers (a baseline). after= equal to before= is an A/A run: the
# noise floor of this harness.
# base_url= is a Claude route that needs no credential (a router that signs
# requests itself, SR2 http://100.120.48.119:4016); Claude Code gets only that
# base URL and a placeholder key, so no credential reaches the worker.
# env=KEY=VALUE (repeatable; KEY is OPTCHAT_*, CHIEF_* or MUX_*) goes to the
# host on both sides.
# Output: CHIEF-LAT-MACHINE, CHIEF-LAT-BUILD per ref, CHIEF-LAT-ROUND per
# round, one CHIEF-LAT-SUMMARY line of JSON per ref, then the markdown table
# (before/after, or the one ref). Files under .build/chief-latency:
# before.json, after.json, compare.json, table.md and each round's run dir.
set -euo pipefail
base_url=""
claude_version="2.1.325"
rounds=1
harness="claude"
model="claude-opus-5-5"
effort="high"
only=""
before=""
after=""
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
    before=*) before="${arg#before=}" ;;
    after=*) after="${arg#after=}" ;;
    env=*) host_env+=("${arg#env=}") ;;
    *) echo "chief-latency.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$base_url" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]] || { echo "chief-latency.sh: base_url=http://HOST[:PORT] is required" >&2; exit 2; }
[[ "$before" =~ ^[0-9a-f]{40}$ ]] || { echo "chief-latency.sh: before=SHA (40 hex) is required" >&2; exit 2; }
[[ -z "$after" || "$after" =~ ^[0-9a-f]{40}$ ]] || { echo "chief-latency.sh: after=SHA (40 hex)" >&2; exit 2; }
[[ "$claude_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "chief-latency.sh: claude=X.Y.Z" >&2; exit 2; }
[[ "$rounds" =~ ^[1-9]$ ]] || { echo "chief-latency.sh: rounds=1..9" >&2; exit 2; }
[[ "$harness" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]] || { echo "chief-latency.sh: harness is an acpmux harness name" >&2; exit 2; }
[[ "$model" =~ ^[A-Za-z0-9._/-]{1,80}$ || -z "$model" ]] || { echo "chief-latency.sh: model=NAME" >&2; exit 2; }
[[ "$effort" =~ ^(low|medium|high|xhigh|max)?$ ]] || { echo "chief-latency.sh: effort=low|medium|high|xhigh|max" >&2; exit 2; }
[[ "$only" =~ ^[a-z0-9,]*$ ]] || { echo "chief-latency.sh: only=l01,l02" >&2; exit 2; }
for kv in ${host_env[@]+"${host_env[@]}"}; do
  [[ "$kv" =~ ^(OPTCHAT|CHIEF|MUX)_[A-Z0-9_]+=[A-Za-z0-9._,:/-]*$ ]] || { echo "chief-latency.sh: env=OPTCHAT_*|CHIEF_*|MUX_*=VALUE" >&2; exit 2; }
done
root="$(git rev-parse --show-toplevel)"
cd "$root"
work="$root/.build/chief-latency"
sides=(before)
[[ -n "$after" ]] && sides+=(after)
remove_trees() {
  for side in before after; do
    [[ -d "$work/src-$side" ]] && git worktree remove --force "$work/src-$side" 2>/dev/null || true
  done
  git worktree prune 2>/dev/null || true
}
remove_trees
rm -rf "$work"
mkdir -p "$work/home/.local/bin"
case "$(uname -s)" in
  Darwin)
    os=darwin; tui_target=aarch64-apple-darwin; claude_platform=darwin-arm64
    sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
    machine="host=$(scutil --get ComputerName 2>/dev/null || hostname) cores=$(sysctl -n hw.ncpu) ram_gb=$(( $(sysctl -n hw.memsize) / 1073741824 )) macos=$(sw_vers -productVersion)" ;;
  Linux)
    os=linux; tui_target=x86_64-unknown-linux-gnu; claude_platform=linux-x64
    [[ "$(uname -m)" == aarch64 ]] && { tui_target=aarch64-unknown-linux-gnu; claude_platform=linux-arm64; }
    sha256() { sha256sum "$1" | awk '{print $1}'; }
    machine="host=$(hostname) cores=$(nproc) ram_gb=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1048576 )) linux=$(uname -r)" ;;
  *) echo "chief-latency.sh: unsupported OS $(uname -s)" >&2; exit 2 ;;
esac
echo "CHIEF-LAT-MACHINE $machine harness_rev=$(git rev-parse HEAD) before=$before after=${after:-none} harness=$harness model=$model effort=$effort rounds=$rounds env=${host_env[*]+"${host_env[*]}"}"
curl -fsS -m 10 -o /dev/null "$base_url/_subrouter/ready" || { echo "CHIEF-LAT the route $base_url is not reachable from this worker" >&2; exit 1; }
# Ready says nothing about Claude: one tiny real request, else stop before any build.
probe_status=0
python3 -I Native/OptChat/optchat-chief/measure/first_turn_cost.py probe --url "$base_url" || probe_status=$?
[[ "$probe_status" == 0 ]] || { echo "CHIEF-LAT the route $base_url does not answer Claude requests ($probe_status)" >&2; exit "$probe_status"; }

# Cargo runs only on a build host; this step is one. Each ref builds in its own
# worktree with its own build scripts; the Cargo target dirs are shared, so the
# second ref builds incrementally.
export CI=1
export CMUX_NEXT_ACPMUX_TARGET_DIR="$root/.build/chief-latency-target/acpmux"
export CMUX_NEXT_OPTCHAT_CHIEF_TARGET_DIR="$root/.build/chief-latency-target/optchat-chief"
build_side() {
  local side="$1" sha="$2" src="$work/src-$1" bin="$work/bin-$1"
  if [[ "$side" == after && "$sha" == "$before" ]]; then
    cp -R "$work/bin-before" "$bin"
    echo "CHIEF-LAT-BUILD after $sha (same as before: A/A)"
    return
  fi
  depth=()
  [[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth 1)
  git cat-file -e "$sha^{commit}" 2>/dev/null || git fetch --quiet ${depth[@]+"${depth[@]}"} origin "$sha"
  git worktree add --quiet --detach "$src" "$sha"
  mkdir -p "$bin"
  "$src/scripts/cmux-next/build-acpmux.sh" --output "$bin/acpmux"
  "$src/scripts/cmux-next/build-optchat-chief.sh" --output "$bin/optchat-chief"
  local key tree sum
  key="$(cd "$src" && python3 scripts/ci/cmux_tui_tree_key.py HEAD)"
  tree="${CMUX_TUI_PIN_BASE:-https://files.cmux.com/cmux-tui}/tree/$key"
  if curl -fsSL --proto '=https' "$tree/cmux-tui-$tui_target" -o "$bin/cmux-tui"; then
    sum="$(curl -fsSL --proto '=https' "$tree/cmux-tui-$tui_target.sha256" | awk '{print $1}')"
    [[ "$(sha256 "$bin/cmux-tui")" == "$sum" ]] || { echo "CHIEF-LAT cmux-tui sha256 mismatch ($side $key)" >&2; exit 1; }
    tui_from="published tree $key"
  else
    # cmux-tui crates build libghostty-vt from ghostty-next.
    git -C "$src" submodule update --init --depth 1 ghostty-next
    (cd "$src/cmux-tui" && CARGO_TARGET_DIR="$root/.build/chief-latency-target/cmux-tui" cargo build --release --locked -p cmux-tui)
    cp "$root/.build/chief-latency-target/cmux-tui/release/cmux-tui" "$bin/cmux-tui"
    tui_from="cargo build"
  fi
  cp "$bin/cmux-tui" "$bin/cmux"
  chmod 755 "$bin/"*
  echo "$sha" > "$bin/REV"
  echo "CHIEF-LAT-BUILD $side $sha cmux-tui from $tui_from"
}
build_side before "$before"
[[ -n "$after" ]] && build_side after "$after"
remove_trees

# Claude Code at the pinned version (the native build, checked against the
# release manifest), under the step only; a fresh HOME keeps the worker's own
# settings and logins out of the run.
dl="https://downloads.claude.ai/claude-code-releases/$claude_version"
curl -fsSL --proto '=https' -m 60 "$dl/manifest.json" -o "$work/claude-manifest.json"
want="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["platforms"][sys.argv[2]]["checksum"])' "$work/claude-manifest.json" "$claude_platform")"
curl -fsSL --proto '=https' -m 600 "$dl/$claude_platform/claude" -o "$work/claude"
[[ "$(sha256 "$work/claude")" == "$want" ]] || { echo "CHIEF-LAT claude $claude_version sha256 mismatch" >&2; exit 1; }
chmod 755 "$work/claude"
ln -s "$work/claude" "$work/home/.local/bin/claude"
echo "CHIEF-LAT-BIN claude $(HOME="$work/home" "$work/home/.local/bin/claude" --version)"

driver_pid=""
stop_driver() {
  if [[ -n "$driver_pid" ]] && kill -0 "$driver_pid" 2>/dev/null; then
    kill -TERM "$driver_pid" 2>/dev/null || true
    wait "$driver_pid" 2>/dev/null || true
  fi
  remove_trees
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
before_dirs=()
after_dirs=()
for r in $(seq 1 "$rounds"); do
  order=("${sides[@]}")
  # Alternate the order by round, so a drift of the route or the worker lands on both sides.
  [[ ${#sides[@]} == 2 && $((r % 2)) == 0 ]] && order=(after before)
  for side in "${order[@]}"; do
    out="$work/$side-round-$r"
    if [[ "$side" == before ]]; then before_dirs+=("$out"); else after_dirs+=("$out"); fi
    rs=0
    HOME="$work/home" python3 Native/OptChat/optchat-chief/measure/chief_driver.py --scenario latency \
      --out "$out" --bins "$work/bin-$side" --harness "$harness" --turn-timeout 600 --only "$only" \
      --env "ANTHROPIC_BASE_URL=$base_url" --env "ANTHROPIC_API_KEY=sk-ant-placeholder-the-route-signs" \
      --env "CLAUDE_CONFIG_DIR=$work/home/.claude" --env "DISABLE_AUTOUPDATER=1" \
      "${engine_env[@]}" > "$out.log" 2>&1 &
    driver_pid=$!
    wait "$driver_pid" || rs=$?
    driver_pid=""
    echo "CHIEF-LAT-ROUND $side $r exit=$rs"
    if ! grep -q "acpmux cleanup: .*no process holds its locks" "$out.log"; then
      echo "CHIEF-LAT $side round $r: acpmux cleanup not confirmed" >&2
      rs=1
    fi
    if [[ "$rs" != 0 ]]; then
      echo "CHIEF-LAT $side round $r ended $rs; last lines:" >&2
      tail -15 "$out.log" >&2
      status=1
    fi
  done
done
measure=Native/OptChat/optchat-chief/measure
summarize() {
  local side="$1" sha="$2"; shift 2
  local line
  line="$(python3 -I "$measure/chief_latency.py" summary "$@" --label "$side" --ref "$sha" \
    --out "$work/$side.json" --md "$work/$side.md")" || return 1
  echo "CHIEF-LAT-SUMMARY $line"
}
summarize before "$before" ${before_dirs[@]+"${before_dirs[@]}"} || status=1
if [[ -n "$after" ]]; then
  summarize after "$after" ${after_dirs[@]+"${after_dirs[@]}"} || status=1
  python3 -I "$measure/chief_latency.py" compare "$work/before.json" "$work/after.json" \
    --md "$work/table.md" --json "$work/compare.json" || status=1
else
  cp "$work/before.md" "$work/table.md" 2>/dev/null && cat "$work/table.md" || status=1
fi
exit "$status"
