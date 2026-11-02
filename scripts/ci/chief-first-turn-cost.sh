#!/usr/bin/env bash
# First-turn cost guard for a new Chief (a gate step of optchat-chief changes,
# not of every CI run). Runs the production trio (cmux-tui --headless,
# optchat-chief host, the brain's own acpmux with Claude Code) on a scratch
# brain against a local Messages API stand-in that answers with one canned
# reply, records the first turn's requests, counts their input tokens through
# the team subrouter (count_tokens) and fails when one is over the limit.
#   cmux-ci run --class isolated --script scripts/ci/chief-first-turn-cost.sh --ref SHA \
#     --arg=count_url=http://HOST:PORT [--arg=limit=50000] [--arg=claude=X.Y.Z] \
#     [--arg=force_full_tools=1] [--arg=turns=N] [--arg=real=1 --arg=min_hit=PCT] --timeout 6000
# count_url= is a Claude route that needs no credential (a router that signs
# requests itself); only count_tokens goes there, never a turn (except real=1).
# force_full_tools=1 proves the guard red: Claude Code gets a --settings file
# with ENABLE_TOOL_SEARCH=false (it wins over the turn's project
# settings), which is the behavior before session_dir::TURN_SETTINGS_ENV: every
# cmux MCP tool loads with the turn.
# turns=N (1-6) sends the smoke scenario's first N turns (s01..sNN) to one brain.
# real=1 (cx-d7a4d) runs those turns on the real model through count_url (the team
# subrouter; it signs requests itself) instead of the stand-in, then prints one
# CHIEF-TURN-CACHE line per turn with its usage and cache hit (cache_read /
# (input + cache_read + cache_write), spec 5a.5) and fails when a warm turn (2..N)
# is under min_hit percent (min_hit=0: measure only). No count_tokens step then.
# real=1 reports each reply's correctness but does not check it, and a route that
# fails mid-run exits 1 (a failed turn), not 3.
# A failed count_tokens (the team subrouter answers 502 on purpose) falls back
# to a byte estimate with a WARNING line; the limit still applies. With real=1
# the first turn's provider usage (input + cache read + cache write) must stay
# under the limit too.
# Exit: 0 pass; 1 over the limit, a failed turn or setup; 3 real=1 and the route
# answered 503 (stop: it is down); 4 a router error from an older count step.
# Output: FIRST-TURN-COST lines; files under .build/chief-first-turn.
set -euo pipefail
count_url=""
limit=50000
claude_version="2.1.300"
force_full_tools=0
turns=1
real=0
min_hit=0
for arg in "$@"; do
  case "$arg" in
    count_url=*) count_url="${arg#count_url=}" ;;
    limit=*) limit="${arg#limit=}" ;;
    claude=*) claude_version="${arg#claude=}" ;;
    force_full_tools=*) force_full_tools="${arg#force_full_tools=}" ;;
    turns=*) turns="${arg#turns=}" ;;
    real=*) real="${arg#real=}" ;;
    min_hit=*) min_hit="${arg#min_hit=}" ;;
    *) echo "chief-first-turn-cost.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$count_url" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]] || { echo "chief-first-turn-cost.sh: count_url=http://HOST[:PORT] is required" >&2; exit 2; }
[[ "$limit" =~ ^[1-9][0-9]{2,6}$ ]] || { echo "chief-first-turn-cost.sh: limit is a token count" >&2; exit 2; }
[[ "$claude_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "chief-first-turn-cost.sh: claude=X.Y.Z" >&2; exit 2; }
[[ "$force_full_tools" =~ ^[01]$ ]] || { echo "chief-first-turn-cost.sh: force_full_tools=0|1" >&2; exit 2; }
[[ "$turns" =~ ^[1-6]$ ]] || { echo "chief-first-turn-cost.sh: turns=1..6" >&2; exit 2; }
[[ "$real" =~ ^[01]$ ]] || { echo "chief-first-turn-cost.sh: real=0|1" >&2; exit 2; }
[[ "$min_hit" =~ ^([0-9]|[1-9][0-9]|100)$ ]] || { echo "chief-first-turn-cost.sh: min_hit=0..100" >&2; exit 2; }
root="$(git rev-parse --show-toplevel)"
cd "$root"
work="$root/.build/chief-first-turn"
rm -rf "$work"
mkdir -p "$work/bin" "$work/home/.local/bin" "$work/cap"
echo "FIRST-TURN-COST-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) rev=$(git rev-parse HEAD) limit=$limit force_full_tools=$force_full_tools turns=$turns real=$real min_hit=$min_hit"
ready="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' "$count_url/_subrouter/ready" || true)"
if [[ "$real" == 1 ]]; then
  # The turns run on this route: it must be up.
  if [[ "$ready" == 503 ]]; then echo "FIRST-TURN-COST the route $count_url answered 503. Stop: the route is down." >&2; exit 3; fi
  [[ "$ready" == 200 ]] || { echo "FIRST-TURN-COST the route $count_url is not reachable from this worker ($ready)" >&2; exit 1; }
elif [[ "$ready" != 200 ]]; then
  # The stand-in runs the turn; count_tokens falls back to the byte estimate.
  echo "FIRST-TURN-COST WARNING the route $count_url answered $ready to ready; count_tokens may fall back to the byte estimate" >&2
fi

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
# A worker keychain login could reach Claude Code outside HOME; the env key and
# base URL win over it. Report only whether one exists, never its content.
if security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1; then echo "FIRST-TURN-COST-KEYCHAIN login item present (not used: env key + stand-in)"; else echo "FIRST-TURN-COST-KEYCHAIN no login item"; fi

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
only="$(seq -f 's%02g' 1 "$turns" | paste -sd, -)"
if [[ "$real" == 1 ]]; then
  # The real model through the subrouter (it signs; the key is a placeholder).
  base_url="$count_url"
  api_key="sk-ant-placeholder-the-router-signs"
else
  # The stand-in prints its port once it listens. Wait for that line or for the
  # stand-in to end (its stdout closes), not a fixed 10 s: a slow start on one host
  # (cx-rkzfny: a 35 s reverse DNS lookup) failed with nothing to show. 300 s bounds a hung start.
  mkfifo "$work/proxy.out"
  python3 -I Native/OptChat/optchat-chief/measure/first_turn_cost.py proxy "$work/cap" > "$work/proxy.out" 2> "$work/proxy.log" &
  proxy_pid=$!
  # Held open until the step ends, so later output from the stand-in never meets a closed pipe.
  exec 7< "$work/proxy.out"
  proxy_port=""
  proxy_started=$SECONDS
  IFS= read -r -t 300 proxy_port <&7 || true
  if [[ ! "$proxy_port" =~ ^[0-9]+$ ]]; then
    # The read timed out, or the stand-in closed its stdout as it ended. Steps run under
    # bash 3.2, whose read exits 1 in both cases, so the time it took says which.
    if (( SECONDS - proxy_started >= 299 )); then
      proxy_end="still running after $((SECONDS - proxy_started)) s"
    else
      proxy_status=0
      wait "$proxy_pid" || proxy_status=$?
      proxy_end="exited with status $proxy_status after $((SECONDS - proxy_started)) s"
    fi
    echo "FIRST-TURN-COST the stand-in did not start: $proxy_end; python3 is $(command -v python3 || echo missing) ($(python3 -V 2>&1 || true))" >&2
    cat "$work/proxy.log" >&2
    exit 1
  fi
  echo "FIRST-TURN-COST-PROXY port $proxy_port after $((SECONDS - proxy_started)) s"
  base_url="http://127.0.0.1:$proxy_port"
  api_key="sk-ant-placeholder-no-model-runs"
fi

status=0
HOME="$work/home" python3 Native/OptChat/optchat-chief/measure/chief_driver.py --scenario smoke --only "$only" \
  --out "$work/run" --bins "$work/bin" --turn-timeout 600 \
  --env "ANTHROPIC_BASE_URL=$base_url" --env "ANTHROPIC_API_KEY=$api_key" \
  --env "CLAUDE_CONFIG_DIR=$work/home/.claude" --env "DISABLE_AUTOUPDATER=1" > "$work/driver.log" 2>&1 7<&- &
driver_pid=$!
wait "$driver_pid" || status=$?
driver_pid=""
tail -5 "$work/driver.log"
if [[ "$status" != 0 ]]; then echo "FIRST-TURN-COST the driver failed ($status)" >&2; fi
if ! grep -q "acpmux cleanup: .*no process holds its locks" "$work/driver.log"; then
  echo "FIRST-TURN-COST acpmux cleanup not confirmed: $(grep "acpmux cleanup" "$work/driver.log" || echo 'no cleanup line')" >&2
  status=1
fi
if [[ "$real" == 1 ]]; then
  # Every turn must have ended; then one line per turn from the driver's
  # metrics (turns.json: the turn.end usage in the brain's trace).
  if ! python3 -I - "$work/run/turns.json" "$turns" "$min_hit" "$limit" <<'PY'
import json, sys
path, want, min_hit, limit = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), int(sys.argv[4])
try:
    rows = json.load(open(path))
    rows = rows.get("turns", rows) if isinstance(rows, dict) else rows
except (OSError, ValueError) as e:
    sys.exit(f"FIRST-TURN-COST no turns.json: {e!r}")
bad = []
for k, r in enumerate(rows):
    u = r.get("turn_usage") or {}
    i, cr, cw = (u.get("input") or 0), (u.get("cache_read") or 0), (u.get("cache_write") or 0)
    hit = round(100.0 * cr / (i + cr + cw), 1) if i + cr + cw else None
    print("CHIEF-TURN-CACHE " + json.dumps({"turn": r.get("id"), "input": i, "cache_read": cr, "cache_write": cw,
                                            "output": u.get("output") or 0, "hit": hit, "requests": r.get("chat_calls"),
                                            "view_bytes": r.get("view_bytes"), "timeout": r.get("timeout"),
                                            "correct": r.get("correct")}))
    if r.get("timeout") or hit is None:
        bad.append(f"{r.get('id')} did not end with usage")
    elif k > 0 and min_hit and hit < min_hit:
        bad.append(f"{r.get('id')} read {hit}% from the cache, under {min_hit:g}%")
if len(rows) != want:
    bad.append(f"{len(rows)} turns ran, not {want}")
if rows:
    u = rows[0].get("turn_usage") or {}
    first = sum(u.get(k) or 0 for k in ("input", "cache_read", "cache_write"))
    requests = rows[0].get("chat_calls") or 1
    # The provider's own usage of the first turn, averaged over its requests
    # (the driver records the turn's sum only; a later request may be larger).
    print("FIRST-TURN-COST " + json.dumps({"limit": limit, "first_turn_tokens": first, "requests": requests,
                                           "average_per_request": first // requests, "source": "provider usage"}))
    if first / requests > limit:
        bad.append(f"the first turn averaged {first // requests} input tokens per request ({first} over {requests}), over the limit {limit}")
warm = rows[1:]
tot = {k: sum((r.get("turn_usage") or {}).get(k) or 0 for r in warm) for k in ("input", "cache_read", "cache_write")}
den = sum(tot.values())
print("CHIEF-TURN-CACHE-WARM " + json.dumps(dict(tot, hit=round(100.0 * tot["cache_read"] / den, 1) if den else None, turns=len(warm))))
if bad:
    sys.exit("FIRST-TURN-COST FAIL: " + "; ".join(bad))
PY
  then
    status=1
  fi
  exit "$status"
fi
# The driver exits 0 also when the turn timed out: the turn must have ended
# and posted the canned reply, or the recorded requests are not a whole turn.
if ! python3 -I - "$work/run/raw.json" <<'PY'
import json, sys
try:
    r = json.load(open(sys.argv[1]))["results"]
except (OSError, ValueError, KeyError) as e:
    sys.exit(f"FIRST-TURN-COST no driver result: {e!r}")
if not r or r[0].get("timeout") or not any("noted" in m.get("text", "").lower() for m in r[0].get("msgs", [])):
    sys.exit("FIRST-TURN-COST the turn did not end with the canned reply: " + json.dumps(r)[:600])
PY
then
  status=1
fi
count_status=0
count_timeout=120
# A route that is not ready: fall back to the estimate quickly.
if [[ "$ready" != 200 ]]; then count_timeout=10; fi
python3 -I Native/OptChat/optchat-chief/measure/first_turn_cost.py count "$work/cap" --url "$count_url" --limit "$limit" --timeout "$count_timeout" || count_status=$?
if [[ "$count_status" == 3 || "$count_status" == 4 ]]; then
  echo "FIRST-TURN-COST router failure (exit $count_status); the turn's own status was $status" >&2
  exit "$count_status"
fi
if [[ "$count_status" != 0 ]]; then status=1; fi
exit "$status"
