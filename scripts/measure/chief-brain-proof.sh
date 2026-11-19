#!/usr/bin/env bash
# One Chief on an open-source brain (Hermes Agent, OpenClaw) or on the default brain, end to end
# on the real model, on a scratch Chief home (chief-cohesion OSS-LOCAL-BRAINS.md "Build"):
# a chat turn, a cmux MCP tool call, a memory write and read through the Chief's memory, and a
# run the Chief's scheduler starts (a sleep wake). Prints BRAIN-PROOF and BRAIN-TIMING lines.
#   cmux-ci run --class exclusive --script scripts/measure/chief-brain-proof.sh --ref SHA \
#     --arg=brain=hermes|openclaw|default --arg=claude_url=http://HOST:PORT \
#     [--arg=brain_url=http://HOST:PORT] [--arg=model=M] [--arg=claude=X.Y.Z] --timeout 7200
# claude_url= is a Claude route that signs requests itself (SR2): the default harness and the
# compactor run on it. brain_url= is the OpenAI-compatible gateway the brain's own model calls go
# to (default the team subrouter, http://100.89.225.106:31415; fleet workers do not resolve its
# name). No key reaches the worker: every route here signs requests itself, and the brain sends
# a placeholder key.
# Everything is installed under the step only (.build/chief-brain-proof, a fresh HOME): Claude
# Code at the pinned version (checked against its release manifest), uv at a pinned version
# (checked against a sha256 written here), and Hermes Agent from its official GitHub release
# commit (NousResearch/hermes-agent v0.23.2), never PyPI (the PyPI name is behind and
# unpinned). OpenClaw needs Docker or Podman for its sandbox mode "all"; without one the Chief
# marks it unavailable and the proof checks the fallback instead (brain=openclaw).
set -euo pipefail
brain=""
claude_url=""
brain_url="http://100.89.225.106:31415"
model=""
claude_version="2.1.300"
for arg in "$@"; do
  case "$arg" in
    brain=*) brain="${arg#brain=}" ;;
    claude_url=*) claude_url="${arg#claude_url=}" ;;
    brain_url=*) brain_url="${arg#brain_url=}" ;;
    model=*) model="${arg#model=}" ;;
    claude=*) claude_version="${arg#claude=}" ;;
    *) echo "chief-brain-proof.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$brain" =~ ^(hermes|openclaw|default)$ ]] || { echo "chief-brain-proof.sh: brain=hermes|openclaw|default" >&2; exit 2; }
url_re='^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?$'
[[ "$claude_url" =~ $url_re ]] || { echo "chief-brain-proof.sh: claude_url=http://HOST[:PORT] is required" >&2; exit 2; }
[[ "$brain_url" =~ $url_re ]] || { echo "chief-brain-proof.sh: brain_url=http://HOST[:PORT]" >&2; exit 2; }
[[ -z "$model" || "$model" =~ ^[A-Za-z0-9._/-]{1,80}$ ]] || { echo "chief-brain-proof.sh: model is one model id" >&2; exit 2; }
[[ "$claude_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "chief-brain-proof.sh: claude=X.Y.Z" >&2; exit 2; }

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
  export UV_TOOL_DIR="$work/uv-tools" UV_TOOL_BIN_DIR="$work/home/.local/bin" UV_PYTHON_INSTALL_DIR="$work/uv-python" UV_CACHE_DIR="$work/uv-cache"
  "$work/uv-aarch64-apple-darwin/uv" tool install --python 3.12 "hermes-agent[acp] @ git+https://github.com/NousResearch/hermes-agent@$hermes_commit"
  echo "BRAIN-BIN hermes $("$work/home/.local/bin/hermes" --version 2>&1 | head -1)"
  "$work/home/.local/bin/hermes" acp --check || { echo "BRAIN hermes acp --check failed" >&2; exit 1; }
  # Beside acpmux, so its discovery finds it whatever login PATH it reads.
  ln -s "$work/home/.local/bin/hermes" "$work/bin/hermes"
elif [[ "$brain" == openclaw ]]; then
  command -v npm >/dev/null || { echo "BRAIN npm is not on this worker" >&2; exit 1; }
  npm install --silent --prefix "$work/openclaw" "openclaw@$openclaw_version"
  ln -s "$work/openclaw/node_modules/.bin/openclaw" "$work/home/.local/bin/openclaw"
  echo "BRAIN-BIN openclaw $("$work/home/.local/bin/openclaw" --version 2>&1 | head -1)"
  ln -s "$work/openclaw/node_modules/.bin/openclaw" "$work/bin/openclaw"
  if command -v docker >/dev/null || command -v podman >/dev/null; then
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
python3 Native/OptChat/optchat-chief/measure/chief_driver.py --scenario brain \
  --out "$work/run" --bins "$work/bin" --turn-timeout 900 \
  --engine-harness "$engine_harness" --engine-model "$model" --brain-base-url "$brain_url" ${fallback_flag[@]+"${fallback_flag[@]}"} \
  --env "ANTHROPIC_BASE_URL=$claude_url" --env "ANTHROPIC_API_KEY=sk-ant-placeholder-the-router-signs" \
  --env "CLAUDE_CONFIG_DIR=$work/home/.claude" --env "DISABLE_AUTOUPDATER=1" > "$work/driver.log" 2>&1 &
driver_pid=$!
wait "$driver_pid" || status=$?
driver_pid=""
grep -E '^\[chief .*\] BRAIN' "$work/driver.log" || true
tail -5 "$work/driver.log"
if ! grep -q "acpmux cleanup: .*no process holds its locks" "$work/driver.log"; then
  echo "BRAIN acpmux cleanup not confirmed" >&2
  status=1
fi
exit "$status"
