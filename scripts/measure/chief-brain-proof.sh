#!/usr/bin/env bash
# One Chief on an open-source brain (Hermes Agent, OpenClaw) or on the default brain, end to end
# on the real model, on a scratch Chief home (chief-cohesion OSS-LOCAL-BRAINS.md "Build"):
# a chat turn, a cmux MCP tool call, a memory write and read through the Chief's memory, and a
# run the Chief's scheduler starts (a sleep wake). Prints BRAIN-PROOF and BRAIN-TIMING lines.
#   cmux-ci run --class exclusive --script scripts/measure/chief-brain-proof.sh --ref SHA \
#     --arg=brain=hermes|openclaw|default --arg=claude_url=http://HOST:PORT \
#     [--arg=brain_url=http://HOST:PORT] [--arg=model=M] [--arg=claude=X.Y.Z] \
#     [--arg=responsive=trivial,lookup] [--arg=runs=5] --timeout 7200
# A failed check keeps the brain homes' logs in artifacts/brain-logs/run-N (submit with
# --artifact artifacts/brain-logs to get them back).
# runs=N (1-10): N proofs in a row, each on a new scratch Chief home; prints one BRAIN-PASSRATE
# line per check (passes/N) and exits 1 when any check failed in any run.
# responsive=CLASSES: after the proof, one round of measure/responsive.py (the
# responsiveness lane's harness) on the same brain, for those ask classes.
# claude_url= is a Claude route that signs requests itself (SR2): the default harness and the
# compactor run on it. brain_url= is the OpenAI-compatible gateway the brain's own model calls go
# to (default the team subrouter, http://100.89.225.106:31415; fleet workers do not resolve its
# name). No key reaches the worker: every route here signs requests itself, and the brain sends
# a placeholder key.
# Everything is installed under the step only (.build/chief-brain-proof, a fresh HOME): Claude
# Code at the pinned version (checked against its release manifest), uv at a pinned version
# (checked against a sha256 written here), and Hermes Agent as a checkout of its official
# GitHub release commit (NousResearch/hermes-agent v0.23.2) synced from its own uv.lock; never
# PyPI (behind and unpinned) and never a wheel (Hermes refuses to build one). OpenClaw needs Docker or Podman for its sandbox mode "all"; without one the Chief
# marks it unavailable and the proof checks the fallback instead (brain=openclaw).
set -euo pipefail
brain=""
claude_url=""
brain_url="http://100.89.225.106:31415"
model=""
claude_version="2.1.300"
responsive=""
runs=1
for arg in "$@"; do
  case "$arg" in
    brain=*) brain="${arg#brain=}" ;;
    claude_url=*) claude_url="${arg#claude_url=}" ;;
    brain_url=*) brain_url="${arg#brain_url=}" ;;
    model=*) model="${arg#model=}" ;;
    claude=*) claude_version="${arg#claude=}" ;;
    responsive=*) responsive="${arg#responsive=}" ;;
    runs=*) runs="${arg#runs=}" ;;
    *) echo "chief-brain-proof.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$brain" =~ ^(hermes|openclaw|default)$ ]] || { echo "chief-brain-proof.sh: brain=hermes|openclaw|default" >&2; exit 2; }
url_re='^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?$'
[[ "$claude_url" =~ $url_re ]] || { echo "chief-brain-proof.sh: claude_url=http://HOST[:PORT] is required" >&2; exit 2; }
[[ "$brain_url" =~ $url_re ]] || { echo "chief-brain-proof.sh: brain_url=http://HOST[:PORT]" >&2; exit 2; }
[[ -z "$model" || "$model" =~ ^[A-Za-z0-9._/-]{1,80}$ ]] || { echo "chief-brain-proof.sh: model is one model id" >&2; exit 2; }
[[ "$claude_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "chief-brain-proof.sh: claude=X.Y.Z" >&2; exit 2; }
[[ "$runs" =~ ^([1-9]|10)$ ]] || { echo "chief-brain-proof.sh: runs=1..10" >&2; exit 2; }
[[ -z "$responsive" || "$responsive" =~ ^[a-z0-9,]{1,80}$ ]] || { echo "chief-brain-proof.sh: responsive=class,class" >&2; exit 2; }

uv_version="0.13.9"
uv_sha256="5aeca67f2283f75235de40d0bd9c0a5bbc5fce23b6d48b3bf9fa1b2db08382ca"
hermes_commit="ae2a81ccc00e9b7c06301523e5bb09608397149c"
openclaw_version="2026.11.5"

root="$(git rev-parse --show-toplevel)"
cd "$root"
work="$root/.build/chief-brain-proof"
rm -rf "$work"
mkdir -p "$work/bin" "$work/home/.local/bin"
echo "BRAIN-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) rev=$(git rev-parse HEAD) brain=$brain claude_url=$claude_url brain_url=$brain_url"

export CI=1
git submodule update --init --depth 1 ghostty-next
scripts/cmux-next/build-acpmux.sh --output "$work/bin/acpmux"
scripts/cmux-next/build-optchat-chief.sh --output "$work/bin/optchat-chief"
key="$(python3 scripts/ci/cmux_tui_tree_key.py HEAD)"
tree="${CMUX_TUI_PIN_BASE:-https://files.cmux.com/cmux-tui}/tree/$key"
if curl -fsSL --proto '=https' "$tree/cmux-tui-aarch64-apple-darwin" -o "$work/bin/cmux-tui"; then
  sum="$(curl -fsSL --proto '=https' "$tree/cmux-tui-aarch64-apple-darwin.sha256" | awk '{print $1}')"
  [[ "$(shasum -a 256 "$work/bin/cmux-tui" | awk '{print $1}')" == "$sum" ]] || { echo "BRAIN cmux-tui sha256 mismatch ($key)" >&2; exit 1; }
else
  (cd cmux-tui && CARGO_TARGET_DIR="$work/target" cargo build --release --locked -p cmux-tui)
  cp "$work/target/release/cmux-tui" "$work/bin/cmux-tui"
fi
# acpmux gives every agent chat `cmux mcp serve` from its own folder (agent_tools.rs).
cp "$work/bin/cmux-tui" "$work/bin/cmux"
chmod 755 "$work/bin/"*
git rev-parse HEAD > "$work/bin/REV"

# Claude Code: the default harness and the compactor.
dl="https://downloads.claude.ai/claude-code-releases/$claude_version"
curl -fsSL --proto '=https' -m 60 "$dl/manifest.json" -o "$work/claude-manifest.json"
want="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["platforms"]["darwin-arm64"]["checksum"])' "$work/claude-manifest.json")"
curl -fsSL --proto '=https' -m 600 "$dl/darwin-arm64/claude" -o "$work/claude"
[[ "$(shasum -a 256 "$work/claude" | awk '{print $1}')" == "$want" ]] || { echo "BRAIN claude $claude_version sha256 mismatch" >&2; exit 1; }
chmod 755 "$work/claude"
ln -s "$work/claude" "$work/home/.local/bin/claude"

# The brain, under the step's HOME only.
export HOME="$work/home"
if [[ "$brain" == hermes ]]; then
  curl -fsSL --proto '=https' -m 120 "https://github.com/astral-sh/uv/releases/download/$uv_version/uv-aarch64-apple-darwin.tar.gz" -o "$work/uv.tar.gz"
  [[ "$(shasum -a 256 "$work/uv.tar.gz" | awk '{print $1}')" == "$uv_sha256" ]] || { echo "BRAIN uv $uv_version sha256 mismatch" >&2; exit 1; }
  tar -xzf "$work/uv.tar.gz" -C "$work"
  export UV_PYTHON_INSTALL_DIR="$work/uv-python" UV_CACHE_DIR="$work/uv-cache"
  # Hermes refuses wheel builds ("distributed via the shell installer, Docker image, or Nix"):
  # a checkout at the release commit, synced from its own uv.lock (every dependency pinned),
  # the way its developer setup runs it. Its lock supports only Python 3.14 (uv installs it here).
  git clone -q --filter=blob:none https://github.com/NousResearch/hermes-agent "$work/hermes-src"
  git -C "$work/hermes-src" checkout -q "$hermes_commit"
  # `mcp` too: its pyproject sets uv default-groups = [] and the acp extra has no MCP client, so
  # without it Hermes skips every session MCP server and logs that only at debug level (the cmux
  # tool check failed 10 of 10 runs, cmux-ci steps 63b0626cfa4b and 21d276d75848). The official
  # installer installs [all], which includes mcp.
  (cd "$work/hermes-src" && "$work/uv-aarch64-apple-darwin/uv" sync -q --frozen --python 3.14 --extra acp --extra mcp)
  "$work/hermes-src/.venv/bin/python" -c "import mcp" || { echo "BRAIN hermes has no MCP client (import mcp failed)" >&2; exit 1; }
  ln -s "$work/hermes-src/.venv/bin/hermes" "$work/home/.local/bin/hermes"
  echo "BRAIN-BIN hermes $("$work/home/.local/bin/hermes" --version 2>&1 | head -1)"
  "$work/home/.local/bin/hermes" acp --check || { echo "BRAIN hermes acp --check failed" >&2; exit 1; }
  # Beside acpmux, so its discovery finds it whatever login PATH it reads.
  ln -s "$work/home/.local/bin/hermes" "$work/bin/hermes"
elif [[ "$brain" == openclaw ]]; then
  # The fleet Macs have neither npm nor a container engine: OpenClaw then cannot run here at
  # all, and the proof checks the Chief's fallback (state, note, every turn on the stand-in).
  if command -v npm >/dev/null; then
    npm install --silent --prefix "$work/openclaw" "openclaw@$openclaw_version"
    ln -s "$work/openclaw/node_modules/.bin/openclaw" "$work/home/.local/bin/openclaw"
    echo "BRAIN-BIN openclaw $("$work/home/.local/bin/openclaw" --version 2>&1 | head -1)"
    ln -s "$work/openclaw/node_modules/.bin/openclaw" "$work/bin/openclaw"
  else
    echo "BRAIN-BIN openclaw not installed: no npm on this worker"
  fi
  if ! command -v npm >/dev/null; then
    expect_fallback=1
  elif command -v docker >/dev/null || command -v podman >/dev/null; then
    echo "BRAIN-SANDBOX engine present"
  else
    echo "BRAIN-SANDBOX no Docker or Podman: OpenClaw must fall back"
    expect_fallback=1
  fi
fi

engine_harness=""
fallback_flag=()
[[ "${expect_fallback:-0}" == 1 ]] && fallback_flag=(--expect-fallback)
[[ "$brain" != default ]] && engine_harness="$brain"
driver_pid=""
stop_all() {
  if [[ -n "$driver_pid" ]] && kill -0 "$driver_pid" 2>/dev/null; then
    kill -TERM "$driver_pid" 2>/dev/null || true
    wait "$driver_pid" 2>/dev/null || true
  fi
}
trap stop_all EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
status=0
for n in $(seq 1 "$runs"); do
  rs=0
  python3 Native/OptChat/optchat-chief/measure/chief_driver.py --scenario brain \
    --out "$work/run-$n" --bins "$work/bin" --turn-timeout 900 --keep-brain-logs "$PWD/artifacts/brain-logs/run-$n" \
    --engine-harness "$engine_harness" --engine-model "$model" --brain-base-url "$brain_url" ${fallback_flag[@]+"${fallback_flag[@]}"} \
    --env "ANTHROPIC_BASE_URL=$claude_url" --env "ANTHROPIC_API_KEY=sk-ant-placeholder-the-router-signs" \
    --env "CLAUDE_CONFIG_DIR=$work/home/.claude" --env "DISABLE_AUTOUPDATER=1" > "$work/driver-$n.log" 2>&1 &
  driver_pid=$!
  # One line a minute while the driver runs: its output goes to a file, and the controller stops a
  # measurement after 45 min with no log line (cmux-ci step 4bd3963570e5, 5 runs of about 12 min).
  while kill -0 "$driver_pid" 2>/dev/null; do
    echo "BRAIN-RUN $n of $runs: running, last: $(grep -E '\] BRAIN' "$work/driver-$n.log" | tail -1 | cut -c1-120)"
    wait_s=0; while [[ $wait_s -lt 60 ]] && kill -0 "$driver_pid" 2>/dev/null; do sleep 5; wait_s=$((wait_s + 5)); done
  done
  wait "$driver_pid" || rs=$?
  driver_pid=""
  echo "BRAIN-RUN $n of $runs: driver exit $rs"
  grep -E '^\[chief .*\] BRAIN' "$work/driver-$n.log" | sed "s/^/run$n /" || true
  [[ "$rs" == 0 ]] || status=1
  if ! grep -q "acpmux cleanup: .*no process holds its locks" "$work/driver-$n.log"; then
    echo "BRAIN acpmux cleanup not confirmed (run $n)" >&2
    tail -5 "$work/driver-$n.log"
    status=1
  fi
done
# Pass rate per check over the runs (a check missing from a run's log counts as a failure).
cat "$work"/driver-*.log | python3 -I -c '
import re, sys
runs = int(sys.argv[1]); seen = {}
for line in sys.stdin:
    m = re.search(r"BRAIN-PROOF (\w+)=(PASS|FAIL)", line)
    if m: seen.setdefault(m.group(1), []).append(m.group(2) == "PASS")
for k, v in seen.items():
    print(f"BRAIN-PASSRATE {k}={sum(v)}/{runs}")
' "$runs"
if [[ -n "$responsive" ]]; then
  # The same engine through the responsiveness lane's harness: one round, a new scratch Chief.
  rs=0
  python3 Native/OptChat/optchat-chief/measure/chief_driver.py --scenario responsive \
    --out "$work/responsive" --bins "$work/bin" --turn-timeout 600 --only "$responsive" \
    --engine-harness "$engine_harness" --engine-model "$model" --brain-base-url "$brain_url" \
    --env "ANTHROPIC_BASE_URL=$claude_url" --env "ANTHROPIC_API_KEY=sk-ant-placeholder-the-router-signs" \
    --env "CLAUDE_CONFIG_DIR=$work/home/.claude" --env "DISABLE_AUTOUPDATER=1" > "$work/responsive.log" 2>&1 || rs=$?
  python3 -I Native/OptChat/optchat-chief/measure/responsive.py report --label "$brain" "$work/responsive" 2>&1 | sed 's/^/BRAIN-RESPONSIVE /' || true
  tail -3 "$work/responsive.log" | sed 's/^/BRAIN-RESPONSIVE-LOG /'
  [[ "$rs" == 0 ]] || { echo "BRAIN responsive round failed ($rs)" >&2; status=1; }
fi
exit "$status"
