#!/usr/bin/env bash
# Local native-relay lab: two relay shards, one relay-registered daemon, one
# enrolled client, and a self-check that mirrors the staging test matrix.
# Everything runs on loopback. No Azure, no staging, no provider VM.
#
#   scripts/relay-lab.sh up            build if needed, start, enroll, check
#   scripts/relay-lab.sh check         rerun the matrix against a running lab
#   scripts/relay-lab.sh dashboard     browser dashboard: machines, PTYs (ghostty-web), shard drain buttons
#   scripts/relay-lab.sh attach        interactive TUI over shard a, fallback b
#   scripts/relay-lab.sh watch         live JSON: route, generation, state
#   scripts/relay-lab.sh forward PORT  loopback URL for a local server through the relay
#   scripts/relay-lab.sh rpc JSON [a|b] one workspace-rpc request (pin one shard, no fallback)
#   scripts/relay-lab.sh drain a|b     SIGTERM one shard (readyz flips, clients fail over)
#   scripts/relay-lab.sh start a|b     bring a drained shard back
#   scripts/relay-lab.sh status        shard health, daemon, connections
#   scripts/relay-lab.sh logs [a|b|daemon|http]
#   scripts/relay-lab.sh down [--purge]
#
# Environment:
#   CMUX_RELAY_LAB_DIR   lab state dir (default /tmp/cmux-relay-lab; must be short,
#                        Unix socket paths are length-limited)
#   CMUX_TUI_BIN         cmux-tui binary (default target/debug/cmux-tui)
#   CMUX_RELAY_BIN       cmux-relay binary (default target/debug/cmux-relay)
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tui_root="$(cd "$script_dir/.." && pwd)"
LAB="${CMUX_RELAY_LAB_DIR:-/tmp/cmux-relay-lab}"
TUI="${CMUX_TUI_BIN:-$tui_root/target/debug/cmux-tui}"
RELAY="${CMUX_RELAY_BIN:-$tui_root/target/debug/cmux-relay}"
SESSION=relaylab
DRAIN_SECONDS=3
CHECK_TIMEOUT=40

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '\033[36m>>\033[0m %s\n' "$*"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- state -----------------------------------------------------------

lab_env="$LAB/env"

load_env() {
  [[ -f "$lab_env" ]] || fail "no lab at $LAB. Run: $0 up"
  # shellcheck disable=SC1090
  source "$lab_env"
}

shard_var() { # shard_var a PORT -> value of SHARD_A_PORT
  local shard="$1" key="$2" name
  name="SHARD_$(printf '%s' "$shard" | tr '[:lower:]' '[:upper:]')_$key"
  printf '%s' "${!name}"
}

route_of() { printf 'relay+ws://127.0.0.1:%s' "$(shard_var "$1" PORT)"; }

pid_alive() { [[ -f "$1" ]] && kill -0 "$(cat "$1")" 2>/dev/null; }

free_port() {
  python3 - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PY
}

# Run a command with a wall-clock deadline (macOS has no GNU timeout).
deadline() {
  local seconds="$1"; shift
  "$@" &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if (( waited >= seconds * 10 )); then
      kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.1; waited=$((waited + 1))
  done
  wait "$pid"
}

wait_for() { # wait_for SECONDS "description" cmd...
  local seconds="$1" what="$2"; shift 2
  local waited=0
  until "$@" >/dev/null 2>&1; do
    (( waited >= seconds * 10 )) && fail "timed out waiting for $what"
    sleep 0.1; waited=$((waited + 1))
  done
}

readyz() { curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$(shard_var "$1" PORT)/readyz" 2>/dev/null || true; }

# ---------- building ----------------------------------------------------------

ensure_binaries() {
  if [[ ! -x "$RELAY" || ! -x "$TUI" ]]; then
    info "building cmux-relay and cmux-tui (debug)"
    (cd "$tui_root" && cargo build -p cmux-relay -p cmux-tui)
  fi
  [[ -x "$RELAY" ]] || fail "missing relay binary $RELAY"
  [[ -x "$TUI" ]] || fail "missing cmux-tui binary $TUI"
}

# ---------- shards ------------------------------------------------------------

# The lab ticket helper mirrors /usr/local/libexec/cmux-native-relay-ticket on
# a cloud VM: cmux-tui asks for a fresh short-lived ticket per Register or
# Connect socket, so ticket expiry never breaks a long-running lab.
write_ticket_helper() {
  mkdir -p "$LAB/bin"
  cat > "$LAB/bin/ticket" <<EOF
#!/usr/bin/env bash
set -euo pipefail
shard="\${1:?shard}"; permission="\${2:?register|connect}"
case "\$shard" in a|b) ;; *) exit 64 ;; esac
lab="$LAB"
export CMUX_RELAY_HMAC_SECRET="\$(cat "\$lab/shard-\$shard/secret")"
export CMUX_RELAY_ISSUER="lab-\$shard"
slot="\$(cat "\$lab/shard-\$shard/slot")"
exec "$RELAY" ticket --permission "\$permission" --slot "\$slot" --ttl-seconds 300
EOF
  chmod 700 "$LAB/bin/ticket"
}

mint_ticket_file() { # mint_ticket_file shard permission path
  install -m 600 /dev/null "$3"
  "$LAB/bin/ticket" "$1" "$2" > "$3"
}

init_shard() { # init_shard a
  local shard="$1" dir="$LAB/shard-$1"
  install -d -m 700 "$dir"
  install -m 600 /dev/null "$dir/secret"; openssl rand -base64 48 > "$dir/secret"
  install -m 600 /dev/null "$dir/slot"; openssl rand -hex 16 > "$dir/slot"
}

start_shard() { # start_shard a
  local shard="$1" dir="$LAB/shard-$1" port
  port="$(shard_var "$shard" PORT)"
  if pid_alive "$dir/pid"; then info "shard $shard already running"; return; fi
  CMUX_RELAY_HMAC_SECRET="$(cat "$dir/secret")" CMUX_RELAY_ISSUER="lab-$shard" \
    "$RELAY" serve --bind "127.0.0.1:$port" --shard "lab-$shard" \
      --drain-timeout-seconds "$DRAIN_SECONDS" \
      >> "$dir/relay.log" 2>&1 &
  echo $! > "$dir/pid"
  wait_for 10 "shard $shard readyz" test "$(readyz "$shard")" = 200
  info "shard $shard listening on $(route_of "$shard") (pid $(cat "$dir/pid"))"
}

stop_shard() { # stop_shard a  (SIGTERM = drain)
  local shard="$1" dir="$LAB/shard-$1"
  pid_alive "$dir/pid" || { info "shard $shard is not running"; return; }
  local pid; pid="$(cat "$dir/pid")"
  kill -TERM "$pid"
  local t0; t0=$(date +%s)
  wait_for 5 "shard $shard readyz to leave 200" test "$(readyz "$shard")" != 200
  info "shard $shard readyz=$(readyz "$shard") after SIGTERM (drain window ${DRAIN_SECONDS}s)"
  while kill -0 "$pid" 2>/dev/null; do sleep 0.1; done
  info "shard $shard exited after $(( $(date +%s) - t0 ))s"
  rm -f "$dir/pid"
}

# ---------- daemon ------------------------------------------------------------

daemon_relay_args() {
  local shard
  for shard in a b; do
    printf '%s\n' --relay "$(route_of "$shard")" --relay-slot "$(cat "$LAB/shard-$shard/slot")" \
      --relay-ticket-command "$LAB/bin/ticket" \
      --relay-ticket-command-arg "$shard" --relay-ticket-command-arg register
  done
}

start_daemon() {
  if pid_alive "$LAB/daemon.pid"; then info "daemon already running"; return; fi
  local -a relay_args; mapfile -t relay_args < <(daemon_relay_args)
  mkdir -p "$LAB/home" "$LAB/project"
  ( cd "$LAB/project" && exec env HOME="$LAB/home" "$TUI" server start --session "$SESSION" \
      --socket "$LAB/mux.sock" \
      --remote-state-dir "$LAB/daemon-state" \
      --remote-link-socket "$LAB/link.sock" \
      --remote-admin-socket "$LAB/admin.sock" \
      "${relay_args[@]}" \
      > "$LAB/daemon.out" 2> "$LAB/daemon.err" ) &
  echo $! > "$LAB/daemon.pid"
  wait_for 20 "daemon admin socket" test -S "$LAB/admin.sock"
  info "daemon up: $(grep -o 'remote daemon [^,]*' "$LAB/daemon.err" | head -1 || true) (pid $(cat "$LAB/daemon.pid"))"
}

admin() { "$TUI" remote enroll "$@" --admin-socket "$LAB/admin.sock" --json; }

# ---------- client ------------------------------------------------------------

client_relay_args() { # both shards as route-scoped credentials; first arg is the preferred shard
  local first="${1:-a}" second shard
  [[ "$first" == a ]] && second=b || second=a
  for shard in "$first" "$second"; do
    printf '%s\n' --relay-route "$(route_of "$shard")" --relay-slot "$(cat "$LAB/shard-$shard/slot")" \
      --relay-ticket-command "$LAB/bin/ticket" \
      --relay-ticket-command-arg "$shard" --relay-ticket-command-arg connect
  done
  printf '%s\n' --state-dir "$LAB/client-state"
}

client() { # client <preferred-shard> <verb> [args...]   (both shards, fallback allowed)
  local shard="$1" verb="$2"; shift 2
  local -a args; mapfile -t args < <(client_relay_args "$shard")
  HOME="$LAB/home" "$TUI" remote "$verb" "$(route_of "$shard")" "${args[@]}" "$@"
}

client_only() { # client_only <shard> <verb> [args...]   (one shard, no fallback)
  local shard="$1" verb="$2"; shift 2
  HOME="$LAB/home" "$TUI" remote "$verb" "$(route_of "$shard")" \
    --relay-slot "$(cat "$LAB/shard-$shard/slot")" \
    --relay-ticket-command "$LAB/bin/ticket" --relay-ticket-command-arg "$shard" --relay-ticket-command-arg connect \
    --state-dir "$LAB/client-state" "$@"
}

enroll_client() {
  if [[ -d "$LAB/client-state" ]] && client a rpc --connect-timeout-seconds 10 --reconnect-attempts 1 \
       --request '{"type":"capabilities"}' >/dev/null 2>&1; then
    info "client already enrolled"; return
  fi
  rm -rf "$LAB/client-state"
  mint_ticket_file a connect "$LAB/shard-a/invite-connect.ticket"
  mint_ticket_file b connect "$LAB/shard-b/invite-connect.ticket"
  admin create \
    --relay-route "$(route_of a)" --relay-slot "$(cat "$LAB/shard-a/slot")" --relay-ticket-file "$LAB/shard-a/invite-connect.ticket" \
    --relay-route "$(route_of b)" --relay-slot "$(cat "$LAB/shard-b/slot")" --relay-ticket-file "$LAB/shard-b/invite-connect.ticket" \
    > "$LAB/invite.json"
  install -m 600 /dev/null "$LAB/invite.txt"
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["uri"])' "$LAB/invite.json" > "$LAB/invite.txt"
  HOME="$LAB/home" "$TUI" remote rpc --invite-file "$LAB/invite.txt" --state-dir "$LAB/client-state" \
    --device-name relay-lab-client --connect-timeout-seconds 60 \
    --request '{"type":"capabilities"}' > "$LAB/enroll.out" 2> "$LAB/enroll.err" &
  local rpc_pid=$! id=""
  local waited=0
  while [[ -z "$id" ]]; do
    (( waited > 300 )) && { cat "$LAB/enroll.err" >&2; fail "no pending enrollment appeared"; }
    id="$(admin pending 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["invitation_id"] if d else "")')"
    [[ -z "$id" ]] && { sleep 0.1; waited=$((waited + 1)); }
  done
  admin approve "$id" > "$LAB/approve.json"
  wait "$rpc_pid" || { cat "$LAB/enroll.err" >&2; fail "enrollment RPC failed"; }
  grep -q '"type":"capabilities"' "$LAB/enroll.out" || fail "enrollment RPC returned no capabilities"
  info "client enrolled through the relay and approved (device $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$LAB/approve.json"))"
}

# ---------- http fixture ------------------------------------------------------

start_http() {
  if pid_alive "$LAB/http.pid"; then return; fi
  echo "relay-lab fixture $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LAB/project/index.html"
  ( cd "$LAB/project" && exec python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 > "$LAB/http.log" 2>&1 ) &
  echo $! > "$LAB/http.pid"
  wait_for 10 "fixture http server" curl -fsS "http://127.0.0.1:$HTTP_PORT/"
}

# ---------- checks ------------------------------------------------------------

results=()
record() { results+=("$1|$2|$3"); }

check_rpc_via() { # check_rpc_via a|b [label]
  local label="${2:-rpc via shard $1 only}" out
  out="$(deadline "$CHECK_TIMEOUT" client_only "$1" rpc --connect-timeout-seconds 15 --reconnect-attempts 2 --request '{"type":"list-workspaces"}' 2>&1)" || { record "$label" FAIL "$out"; return; }
  if grep -q '"type":"workspaces"' <<<"$out"; then record "$label" PASS "list-workspaces answered, no fallback route offered"; else record "$label" FAIL "$out"; fi
}

check_forward() {
  start_http
  : > "$LAB/fwd.out"; : > "$LAB/fwd.err"
  client a forward --workspace-root "$LAB/project" --host 127.0.0.1 --port "$HTTP_PORT" \
    --listen 127.0.0.1:0 --scheme http > "$LAB/fwd.out" 2> "$LAB/fwd.err" &
  local pid=$! url="" waited=0 body
  while [[ -z "$url" ]]; do
    (( waited > CHECK_TIMEOUT * 10 )) && { kill $pid 2>/dev/null; record "forward loopback url" FAIL "$(cat "$LAB/fwd.err")"; return; }
    url="$(grep -o 'http://127.0.0.1:[0-9]*' "$LAB/fwd.out" | head -1 || true)"; sleep 0.1; waited=$((waited + 1))
  done
  body="$(curl -s --max-time 10 "$url/" || true)"
  if [[ "$body" == *"relay-lab fixture"* && "$url" != *"$HTTP_PORT"* ]]; then
    record "forward loopback url" PASS "$url served the fixture through the relay"
  else
    record "forward loopback url" FAIL "url=$url body=$body"
  fi
  kill $pid 2>/dev/null; wait $pid 2>/dev/null || true
}

check_rejected() {
  local bad="$LAB/bad.ticket" out
  install -m 600 /dev/null "$bad"; "$LAB/bin/ticket" a connect | sed 's/./X/20' > "$bad"
  out="$(deadline "$CHECK_TIMEOUT" env HOME="$LAB/home" "$TUI" remote rpc "$(route_of a)" \
    --relay-slot "$(cat "$LAB/shard-a/slot")" --relay-ticket-file "$bad" --state-dir "$LAB/client-state" \
    --connect-timeout-seconds 15 --reconnect-attempts 1 --request '{"type":"capabilities"}' 2>&1)" && { record "tampered ticket rejected" FAIL "connect succeeded"; return; }
  if grep -q "relay rejected" <<<"$out"; then record "tampered ticket rejected" PASS "relay rejected the authenticated operation"; else record "tampered ticket rejected" FAIL "$out"; fi
  out="$(deadline "$CHECK_TIMEOUT" env HOME="$LAB/home" "$TUI" remote rpc "$(route_of a)" \
    --relay-slot "$(cat "$LAB/shard-b/slot")" --relay-ticket-command "$LAB/bin/ticket" --relay-ticket-command-arg a --relay-ticket-command-arg connect \
    --state-dir "$LAB/client-state" --connect-timeout-seconds 15 --reconnect-attempts 1 --request '{"type":"capabilities"}' 2>&1)" && { record "wrong slot rejected" FAIL "connect succeeded"; return; }
  if grep -q "relay rejected" <<<"$out"; then record "wrong slot rejected" PASS "ticket for shard a slot cannot open shard b slot"; else record "wrong slot rejected" FAIL "$out"; fi
}

snapshot_route() { # last snapshot line's route and state from a --headless --json log
  python3 - "$1" <<'PY'
import json, sys
route = state = ""
for line in open(sys.argv[1]):
    try:
        d = json.loads(line)
    except ValueError:
        continue
    c = d.get("connection") or {}
    route, state = c.get("transport", {}).get("route", ""), c.get("state", "")
print(f"{state} {route}")
PY
}

check_drain() {
  : > "$LAB/watch.jsonl"
  client a connect --headless --json --local-socket "$LAB/watch-mux.sock" > "$LAB/watch.jsonl" 2> "$LAB/watch.err" &
  local pid=$! waited=0
  while ! grep -q '"state":"connected"' "$LAB/watch.jsonl"; do
    (( waited > CHECK_TIMEOUT * 10 )) && { kill $pid 2>/dev/null; record "drain shard a fails over" FAIL "$(cat "$LAB/watch.err")"; return; }
    sleep 0.1; waited=$((waited + 1))
  done
  local before; before="$(snapshot_route "$LAB/watch.jsonl")"
  [[ "$before" == "connected $(route_of a)" ]] || { kill $pid 2>/dev/null; record "drain shard a fails over" FAIL "initial route was '$before'"; return; }
  # Hold a tunnel stream open across the drain: it must close, and a fresh one must work.
  start_http
  client a forward --workspace-root "$LAB/project" --host 127.0.0.1 --port "$HTTP_PORT" \
    --listen 127.0.0.1:0 --scheme http > "$LAB/fwd-drain.out" 2> "$LAB/fwd-drain.err" &
  local fwd_pid=$! url=""
  wait_for "$CHECK_TIMEOUT" "forward url" grep -q 'http://127.0.0.1:' "$LAB/fwd-drain.out"
  url="$(grep -o 'http://127.0.0.1:[0-9]*' "$LAB/fwd-drain.out" | head -1 || true)"
  curl -s --max-time 10 "$url/" | grep -q "relay-lab fixture" || { record "tcp stream across drain" FAIL "pre-drain curl failed"; }
  stop_shard a
  waited=0
  until [[ "$(snapshot_route "$LAB/watch.jsonl")" == "connected $(route_of b)" ]]; do
    (( waited > CHECK_TIMEOUT * 10 )) && break
    sleep 0.1; waited=$((waited + 1))
  done
  local after; after="$(snapshot_route "$LAB/watch.jsonl")"
  if [[ "$after" == "connected $(route_of b)" ]]; then
    record "drain shard a fails over" PASS "session moved a -> b in $((waited / 10)).$((waited % 10))s ($(grep -c connection-snapshot "$LAB/watch.jsonl" || true) snapshots)"
  else
    record "drain shard a fails over" FAIL "route after drain was '$after'"
  fi
  local body; body="$(curl -s --max-time 15 "$url/" || true)"
  if [[ "$body" == *"relay-lab fixture"* ]]; then
    record "tcp stream across drain" PASS "new forward connection works via shard b"
  else
    record "tcp stream across drain" FAIL "post-drain curl body='$body' $(tail -2 "$LAB/fwd-drain.err")"
  fi
  kill $fwd_pid $pid 2>/dev/null; wait $fwd_pid $pid 2>/dev/null || true
  start_shard a
}

check_reregister() { # after a shard restart its slot is empty until the daemon re-registers (backoff caps at 5s)
  local shard="$1" waited=0
  until client_only "$shard" rpc --connect-timeout-seconds 10 --reconnect-attempts 1 --request '{"type":"capabilities"}' >/dev/null 2>&1; do
    if (( waited >= 60 )); then record "daemon re-registers on shard $shard" FAIL "slot still empty after 30s"; return; fi
    sleep 0.5; waited=$((waited + 1))
  done
  record "daemon re-registers on shard $shard" PASS "single-route rpc via $shard works again after $((waited / 2)).$(( (waited % 2) * 5 ))s"
}

check_logs() {
  local canary="relay-lab-canary-$RANDOM$RANDOM" leak=""
  deadline "$CHECK_TIMEOUT" client b rpc --connect-timeout-seconds 15 \
    --request "{\"type\":\"open-workspace\",\"root\":\"$LAB/project\"}" >/dev/null 2>&1 || true
  mkdir -p "$LAB/project/$canary"
  deadline "$CHECK_TIMEOUT" client b rpc --connect-timeout-seconds 15 --request '{"type":"list-workspaces"}' >/dev/null 2>&1 || true
  local ticket; ticket="$("$LAB/bin/ticket" a connect)"
  local f
  for f in "$LAB"/shard-*/relay.log; do
    grep -q -- "$canary" "$f" && leak="$leak $f:canary"
    grep -q -- "${ticket:0:24}" "$f" && leak="$leak $f:ticket"
    grep -q -- "$(cat "$LAB/shard-a/secret")" "$f" && leak="$leak $f:secret"
  done
  rmdir "$LAB/project/$canary" 2>/dev/null || true
  if [[ -z "$leak" ]]; then record "relay logs carry no payload or secrets" PASS "no canary, ticket, or HMAC secret in shard logs"; else record "relay logs carry no payload or secrets" FAIL "$leak"; fi
}

print_results() {
  echo
  bold "relay lab check"
  local r status failed=0
  for r in "${results[@]}"; do
    IFS='|' read -r name status detail <<<"$r"
    if [[ "$status" == PASS ]]; then printf '  \033[32mPASS\033[0m  %-40s %s\n' "$name" "$detail"; else printf '  \033[31mFAIL\033[0m  %-40s %s\n' "$name" "$detail"; failed=1; fi
  done
  echo
  return $failed
}

run_checks() {
  results=()
  check_rpc_via a
  check_rpc_via b
  check_forward
  check_rejected
  check_drain
  check_reregister a
  check_logs
  print_results
}

# ---------- commands ----------------------------------------------------------

cmd_up() {
  ensure_binaries
  [[ ${#LAB} -lt 60 ]] || fail "lab dir $LAB is too long for Unix socket paths; set CMUX_RELAY_LAB_DIR=/tmp/<short>"
  if [[ -f "$lab_env" ]]; then
    load_env
  else
    install -d -m 700 "$LAB"
    init_shard a; init_shard b
    cat > "$lab_env" <<EOF
SHARD_A_PORT=$(free_port)
SHARD_B_PORT=$(free_port)
HTTP_PORT=$(free_port)
EOF
    load_env
  fi
  write_ticket_helper
  start_shard a; start_shard b
  start_daemon
  enroll_client
  start_http
  run_checks || true
  cmd_cheatsheet
}

cmd_cheatsheet() {
  load_env
  bold "relay lab is running at $LAB"
  cat <<EOF
  shard a   $(route_of a)   readyz=$(readyz a)
  shard b   $(route_of b)   readyz=$(readyz b)
  daemon    session $SESSION, admin $LAB/admin.sock
  fixture   http://127.0.0.1:$HTTP_PORT (the "server on port 3000" stand-in)

  $0 dashboard         browser UI at http://127.0.0.1:8790 (ghostty-web PTYs, drain buttons)
  $0 attach            interactive TUI through shard a; type fast, then in another terminal:
  $0 drain a           the TUI keeps working through shard b (watch it with: $0 watch)
  $0 start a           bring shard a back
  $0 forward $HTTP_PORT   prints a loopback URL; open it in a browser
  $0 check             rerun the automated matrix
  $0 down              stop everything
EOF
}

cmd_check() { load_env; ensure_binaries; start_http; run_checks; }

cmd_dashboard() {
  load_env
  command -v bun >/dev/null || fail "bun is required for the dashboard (https://bun.sh)"
  info "dashboard: pick the machine, type, then press drain on the shard shown in the status bar"
  CMUX_RELAY_LAB_DIR="$LAB" CMUX_TUI_BIN="$TUI" exec bun "$tui_root/tools/relay-dashboard/server.ts"
}

cmd_attach() {
  load_env
  local shard="${1:-a}"
  info "attaching through shard $shard with fallback to the other shard (Ctrl-C or detach to leave)"
  client "$shard" connect
}

cmd_watch() {
  load_env
  info "live connection snapshots (route, generation, state); Ctrl-C to stop"
  client "${1:-a}" connect --headless --json --local-socket "$LAB/watch-$$.sock" 2>&1 | python3 -u -c '
import json, sys, time
for line in sys.stdin:
    try:
        d = json.loads(line)
    except ValueError:
        print(line.rstrip()); continue
    c = d.get("connection") or {}
    t = c.get("transport", {})
    print(time.strftime("%H:%M:%S"), c.get("state"), "gen", c.get("generation"), t.get("route"), "links", c.get("physical_link_count"), flush=True)
'
}

cmd_forward() {
  load_env
  local port="${1:?usage: $0 forward PORT [--scheme http|https]}"; shift || true
  info "forwarding 127.0.0.1:$port through the relay; Ctrl-C to stop"
  client a forward --workspace-root "$LAB/project" --host 127.0.0.1 --port "$port" --listen 127.0.0.1:0 --scheme http "$@"
}

cmd_rpc() {
  load_env
  local request="${1:?usage: $0 rpc '{\"type\":\"capabilities\"}' [a|b]}"
  if [[ -n "${2:-}" ]]; then client_only "$2" rpc --connect-timeout-seconds 15 --request "$request"
  else client a rpc --connect-timeout-seconds 15 --request "$request"; fi
}

cmd_drain() { load_env; stop_shard "${1:?usage: $0 drain a|b}"; }
cmd_start() { load_env; start_shard "${1:?usage: $0 start a|b}"; }

cmd_status() {
  load_env
  local shard
  for shard in a b; do
    printf 'shard %s  %s  readyz=%s  %s\n' "$shard" "$(route_of "$shard")" "$(readyz "$shard")" "$(pid_alive "$LAB/shard-$shard/pid" && echo "pid $(cat "$LAB/shard-$shard/pid")" || echo stopped)"
  done
  printf 'daemon   %s\n' "$(pid_alive "$LAB/daemon.pid" && echo "pid $(cat "$LAB/daemon.pid")" || echo stopped)"
  printf 'fixture  http://127.0.0.1:%s  %s\n' "$HTTP_PORT" "$(pid_alive "$LAB/http.pid" && echo running || echo stopped)"
  if [[ -S "$LAB/admin.sock" ]]; then
    echo "connections:"; admin connections 2>/dev/null | python3 -c '
import json, sys
for c in json.load(sys.stdin):
    print("  device", c.get("device_id"), c.get("state"), "gen", c.get("generation"), "links", c.get("physical_link_count"))
' || true
  fi
}

cmd_logs() {
  load_env
  case "${1:-all}" in
    a|b) tail -n 50 "$LAB/shard-$1/relay.log" ;;
    daemon) tail -n 50 "$LAB/daemon.err" ;;
    http) tail -n 50 "$LAB/http.log" ;;
    all) for f in "$LAB"/shard-*/relay.log "$LAB/daemon.err"; do bold "== $f"; tail -n 20 "$f"; done ;;
    *) fail "unknown log $1" ;;
  esac
}

cmd_down() {
  [[ -f "$lab_env" ]] || { info "no lab at $LAB"; return; }
  load_env
  local f
  for f in "$LAB/http.pid" "$LAB/daemon.pid" "$LAB/shard-a/pid" "$LAB/shard-b/pid"; do
    if pid_alive "$f"; then kill "$(cat "$f")" 2>/dev/null || true; fi
    rm -f "$f"
  done
  pkill -f "remote connect $(route_of a)" 2>/dev/null || true
  pkill -f "remote connect $(route_of b)" 2>/dev/null || true
  local waited=0
  while pgrep -f "$LAB/" >/dev/null 2>&1 && (( waited < 50 )); do sleep 0.1; waited=$((waited + 1)); done
  info "stopped"
  if [[ "${1:-}" == --purge ]]; then rm -rf "$LAB"; info "removed $LAB"; fi
}

case "${1:-}" in
  up) cmd_up ;;
  check) cmd_check ;;
  dashboard) cmd_dashboard ;;
  attach) cmd_attach "${2:-a}" ;;
  watch) cmd_watch "${2:-a}" ;;
  forward) shift; cmd_forward "$@" ;;
  rpc) cmd_rpc "${2:-}" "${3:-}" ;;
  drain) cmd_drain "${2:-}" ;;
  start) cmd_start "${2:-}" ;;
  status) cmd_status ;;
  logs) cmd_logs "${2:-all}" ;;
  down) cmd_down "${2:-}" ;;
  cheatsheet) cmd_cheatsheet ;;
  ""|-h|--help|help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) fail "unknown command $1 (try: $0 help)" ;;
esac
