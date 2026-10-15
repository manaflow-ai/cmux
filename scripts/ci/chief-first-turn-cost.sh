#!/usr/bin/env bash
# First-turn cost guard for a new Chief (a gate step of optchat-chief changes,
# not of every CI run). Runs the production trio (cmux-tui --headless,
# optchat-chief host, the brain's own acpmux with Claude Code) on a scratch
# brain against a local Messages API stand-in that answers with one canned
# reply, records the first turn's requests, counts their input tokens through
# the team subrouter (count_tokens) and fails when one is over the limit.
#   cmux-ci run --class isolated --script scripts/ci/chief-first-turn-cost.sh --ref SHA \
#     --arg=count_url=http://HOST:PORT [--arg=limit=50000] [--arg=claude=X.Y.Z] \
#     [--arg=force_full_tools=1] --timeout 6000
# count_url= is a Claude route that needs no credential (a router that signs
# requests itself); only count_tokens goes there, never a turn.
# force_full_tools=1 proves the guard red: Claude Code gets an inline
# --settings with ENABLE_TOOL_SEARCH=false (it wins over the turn's project
# settings), which is the behavior before session_dir::TURN_SETTINGS_ENV: every
# cmux MCP tool loads with the turn.
# Output: FIRST-TURN-COST lines; files under .build/chief-first-turn.
set -euo pipefail
count_url=""
limit=50000
claude_version="2.1.300"
force_full_tools=0
for arg in "$@"; do
  case "$arg" in
    count_url=*) count_url="${arg#count_url=}" ;;
    limit=*) limit="${arg#limit=}" ;;
    claude=*) claude_version="${arg#claude=}" ;;
    force_full_tools=*) force_full_tools="${arg#force_full_tools=}" ;;
    *) echo "chief-first-turn-cost.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$count_url" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]] || { echo "chief-first-turn-cost.sh: count_url=http://HOST[:PORT] is required" >&2; exit 2; }
[[ "$limit" =~ ^[1-9][0-9]{2,6}$ ]] || { echo "chief-first-turn-cost.sh: limit is a token count" >&2; exit 2; }
[[ "$claude_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "chief-first-turn-cost.sh: claude=X.Y.Z" >&2; exit 2; }
[[ "$force_full_tools" =~ ^[01]$ ]] || { echo "chief-first-turn-cost.sh: force_full_tools=0|1" >&2; exit 2; }
root="$(git rev-parse --show-toplevel)"
cd "$root"
work="$root/.build/chief-first-turn"
rm -rf "$work"
mkdir -p "$work/bin" "$work/home/.local/bin" "$work/cap"
echo "FIRST-TURN-COST-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) rev=$(git rev-parse HEAD) limit=$limit force_full_tools=$force_full_tools"
ready="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' "$count_url/_subrouter/ready" || true)"
if [[ "$ready" == 503 ]]; then echo "FIRST-TURN-COST the route $count_url answered 503. Stop: the route is down." >&2; exit 3; fi
[[ "$ready" == 200 ]] || { echo "FIRST-TURN-COST the route $count_url is not reachable from this worker ($ready)" >&2; exit 1; }

# The build scripts run Cargo only on a build host; this step is one. The
# step's checkout has empty submodules; cmux-tui crates build libghostty-vt
# from ghostty-next.
export CI=1
git submodule update --init --depth 1 ghostty-next
scripts/cmux-next/build-acpmux.sh --output "$work/bin/acpmux"
scripts/cmux-next/build-optchat-chief.sh --output "$work/bin/optchat-chief"
key="$(python3 scripts/ci/cmux_tui_tree_key.py HEAD)"
tree="${CMUX_TUI_PIN_BASE:-https://files.cmux.com/cmux-tui}/tree/$key"
if curl -fsSL --proto '=https' "$tree/cmux-tui-aarch64-apple-darwin" -o "$work/bin/cmux-tui"; then
  sum="$(curl -fsSL --proto '=https' "$tree/cmux-tui-aarch64-apple-darwin.sha256" | awk '{print $1}')"
  [[ "$(shasum -a 256 "$work/bin/cmux-tui" | awk '{print $1}')" == "$sum" ]] || { echo "FIRST-TURN-COST cmux-tui sha256 mismatch ($key)" >&2; exit 1; }
  echo "FIRST-TURN-COST-BIN cmux-tui published tree $key"
else
  echo "FIRST-TURN-COST-BIN cmux-tui tree $key not published; building it"
  (cd cmux-tui && CARGO_TARGET_DIR="$work/target" cargo build --release --locked -p cmux-tui)
  cp "$work/target/release/cmux-tui" "$work/bin/cmux-tui"
fi
# The app ships the cmux-tui binary as bin/cmux; acpmux gives every agent
# chat `cmux mcp serve` from its own folder (agent_tools.rs), the server whose
# tools this guard keeps out of the first turn.
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
[[ "$(shasum -a 256 "$work/claude" | awk '{print $1}')" == "$want" ]] || { echo "FIRST-TURN-COST claude $claude_version sha256 mismatch" >&2; exit 1; }
chmod 755 "$work/claude"
if [[ "$force_full_tools" == 1 ]]; then
  printf '{"env":{"ENABLE_TOOL_SEARCH":"false"}}\n' > "$work/full-tools-settings.json"
  cat > "$work/home/.local/bin/claude" <<EOF
#!/bin/sh
# force_full_tools=1: the behavior before TURN_SETTINGS_ENV (no tool search).
case "\${1:-}" in
  -v|--version|"") exec "$work/claude" "\$@" ;;
  -*) exec "$work/claude" --settings "$work/full-tools-settings.json" "\$@" ;;
  *) exec "$work/claude" "\$@" ;;
esac
EOF
  chmod 755 "$work/home/.local/bin/claude"
else
  ln -s "$work/claude" "$work/home/.local/bin/claude"
fi
echo "FIRST-TURN-COST-BIN claude $(HOME="$work/home" "$work/home/.local/bin/claude" --version)"

proxy_pid=""
driver_pid=""
# A cancelled step stops the driver with SIGTERM, so its own cleanup runs (it
# stops the brain's acpmux daemon and checks its locks), then the stand-in.
stop_all() {
  if [[ -n "$driver_pid" ]] && kill -0 "$driver_pid" 2>/dev/null; then
    kill -TERM "$driver_pid" 2>/dev/null || true
    wait "$driver_pid" 2>/dev/null || true
  fi
  if [[ -n "$proxy_pid" ]]; then kill "$proxy_pid" 2>/dev/null || true; fi
}
trap stop_all EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP
python3 -I Native/OptChat/optchat-chief/measure/first_turn_cost.py proxy "$work/cap" > "$work/proxy.log" 2>&1 &
proxy_pid=$!
for _ in $(seq 1 100); do [[ -s "$work/cap/port" ]] && break; sleep 0.1; done
[[ -s "$work/cap/port" ]] || { echo "FIRST-TURN-COST the stand-in did not start" >&2; cat "$work/proxy.log" >&2; exit 1; }
port="$(cat "$work/cap/port")"

status=0
HOME="$work/home" python3 Native/OptChat/optchat-chief/measure/chief_driver.py --scenario smoke --only s01 \
  --out "$work/run" --bins "$work/bin" --turn-timeout 600 \
  --env "ANTHROPIC_BASE_URL=http://127.0.0.1:$port" --env "ANTHROPIC_API_KEY=sk-ant-placeholder-no-model-runs" \
  --env "CLAUDE_CONFIG_DIR=$work/home/.claude" --env "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1" \
  --env "DISABLE_AUTOUPDATER=1" > "$work/driver.log" 2>&1 &
driver_pid=$!
wait "$driver_pid" || status=$?
driver_pid=""
tail -5 "$work/driver.log"
if [[ "$status" != 0 ]]; then echo "FIRST-TURN-COST the driver failed ($status)" >&2; fi
if ! grep -q "acpmux cleanup: .*no process holds its locks" "$work/driver.log"; then
  echo "FIRST-TURN-COST acpmux cleanup not confirmed: $(grep "acpmux cleanup" "$work/driver.log" || echo 'no cleanup line')" >&2
  status=1
fi
count_status=0
python3 -I Native/OptChat/optchat-chief/measure/first_turn_cost.py count "$work/cap" --url "$count_url" --limit "$limit" || count_status=$?
if [[ "$count_status" == 3 ]]; then exit 3; fi
if [[ "$count_status" != 0 ]]; then status=1; fi
exit "$status"
