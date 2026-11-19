#!/usr/bin/env bash
# Terminal scroll integrity on Linux (goal terminal-scroll-integrity: "A scroll-stress probe on local, SSH and
# Cloud terminals shows 0 blank or missing rows and 0 viewport jumps while scrolled up"). Builds the release
# cmux-tui, then runs its probe (`cmux-tui __scroll-probe`, crates/cmux-tui/src/scroll_probe.rs) against:
#   local: a headless daemon on this host;
#   ssh:   the local socket of `cmux-tui remote connect ssh://USER@127.0.0.1:PORT`, through a real OpenSSH sshd
#          this script starts as the current user on a loopback port (its own host key and authorized key), whose
#          far side runs `cmux-tui remote-link --stdio` and its own daemon. No /usr/sbin/sshd: the ssh rows are
#          not printed (never a fake ssh under the ssh name).
# The Cloud surface runs the same probe from hq's cloud synthetic probe against `cmux carrier serve`'s socket.
# Run at a pushed head:
#   cmux-ci test --setup rust -- 'scripts/measure/terminal-scroll-stress-linux.sh [surfaces=local,ssh] [runs=1]'
#   terminal-scroll-stress-linux.sh build-only: only the release build (the perf cron builds under a cap of its own).
# Prints SCROLLPROBE (each probe's JSON report) and PERF_ROW lines, then the rows as one JSON object
# ({"rows": [...]}) on a line of its own: the report perf-cron.py's terminal-scroll part reads. Rows:
#   terminal.scroll.<surface>.<view>.{blank_rows,missing_rows,jumps}  (view: mirror = the byte client's own
#   ghostty-vt terminal, daemon = the daemon's shared render viewport), terminal.scroll.<surface>.bad (their sum).
# Counts, lower is better, target 0. With runs=N each row is the worst run (p95) and the median (p50).
set -euo pipefail
surfaces="local,ssh"
runs=1
build_only=0
for arg in "$@"; do
  case "$arg" in
    surfaces=*) surfaces="${arg#surfaces=}" ;;
    runs=*) runs="${arg#runs=}" ;;
    build-only) build_only=1 ;;
    *) echo "terminal-scroll-stress-linux.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
root="$(git rev-parse --show-toplevel)"
cd "$root"
# A bare runner (the perf cron's Linux part): the pinned Rust and the native build tools.
command -v cargo >/dev/null || ./scripts/install-rust-ci.sh
command -v clang >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq clang libclang-dev pkg-config; }
export PATH="$HOME/.cargo/bin:$PATH"
cd "$root/cmux-tui"
# The gate profile: release code generation without its link-time cost (a release cmux-tui link
# needs more memory than a lane VM or small runner has; the counts do not depend on LTO).
cargo build --locked --profile gate -p cmux-tui --bin cmux-tui 2>&1 | tail -n 3
[[ "$build_only" == 1 ]] && exit 0
target="$(cargo metadata --locked --no-deps --format-version 1 | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')"
bin="$target/gate/cmux-tui"
cd "$root"

work="$(mktemp -d /tmp/tscroll.XXXXXX)"
chmod 700 "$work"
pids=()
cleanup() {
  # Every daemon this script started (local ones and the far side of ssh) serves a mux.sock under $work:
  # end its terminals and stop it, then stop the processes this script started, by PID.
  local envfile sock
  while IFS= read -r envfile; do
    while IFS= read -r sock; do
      # shellcheck disable=SC2046
      env $(cat "$envfile") "$bin" daemon stop --socket "$sock" --end-terminals >/dev/null 2>&1 || true
    done < <(find "$(dirname "$envfile")" -name '*.sock' -type s 2>/dev/null)
  done < <(find "$work" -name daemon.env 2>/dev/null)
  for pid in "${pids[@]+"${pids[@]}"}"; do kill "$pid" 2>/dev/null || true; done
  [[ -f "$work/ssh/sshd.pid" ]] && kill "$(cat "$work/ssh/sshd.pid")" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

# An isolated daemon environment under $1 (state, runtime and config dirs of its own).
daemon_env() {
  local dir="$1"
  mkdir -p "$dir/rt" "$dir/state" "$dir/config" "$dir/tui"
  chmod 700 "$dir" "$dir/rt"
  echo "XDG_RUNTIME_DIR=$dir/rt XDG_STATE_HOME=$dir/state XDG_CONFIG_HOME=$dir/config CMUX_TUI_STATE_DIR=$dir/tui" \
    | tee "$dir/daemon.env"
}

wait_for_socket() {
  local path="$1" i
  for i in $(seq 1 200); do
    [[ -S "$path" ]] && return 0
    sleep 0.1
  done
  echo "terminal-scroll: no socket at $path" >&2
  return 1
}

reports="$work/reports.jsonl"
: >"$reports"

probe() {  # probe SURFACE SOCKET RUN
  local out
  out="$("$bin" __scroll-probe --socket "$2" --surface-label "$1" --json 2>"$work/probe-$1-$3.err")" || {
    echo "terminal-scroll: the $1 probe failed: $(tail -n 5 "$work/probe-$1-$3.err")" >&2
    return 1
  }
  echo "SCROLLPROBE $out"
  echo "$out" >>"$reports"
}

run_local() {  # run_local RUN
  local dir="$work/local-$1" envs sock
  envs="$(daemon_env "$dir")"
  sock="$dir/mux.sock"
  # shellcheck disable=SC2086
  env $envs "$bin" daemon ensure --session "tscroll-local-$1" --socket "$sock" >"$dir/daemon.log" 2>&1
  wait_for_socket "$sock"
  probe local "$sock" "$1"
}

start_sshd() {
  local dir="$work/ssh" port
  mkdir -p "$dir"
  ssh-keygen -q -t ed25519 -N '' -f "$dir/host_key"
  ssh-keygen -q -t ed25519 -N '' -f "$dir/user_key"
  cp "$dir/user_key.pub" "$dir/authorized_keys"
  port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
  local far
  far="$(daemon_env "$work/far")"
  # The far side's login gets an isolated daemon environment (SetEnv), so it never reaches this user's sessions.
  {
    echo "Port $port"
    echo "ListenAddress 127.0.0.1"
    echo "HostKey $dir/host_key"
    echo "AuthorizedKeysFile $dir/authorized_keys"
    echo "PidFile $dir/sshd.pid"
    echo "UsePAM no"
    echo "StrictModes no"
    echo "PasswordAuthentication no"
    echo "KbdInteractiveAuthentication no"
    echo "SetEnv $far"
  } >"$dir/sshd_config"
  /usr/sbin/sshd -f "$dir/sshd_config" -E "$dir/sshd.log"
  {
    echo "Host 127.0.0.1"
    echo "  IdentityFile $dir/user_key"
    echo "  IdentitiesOnly yes"
    echo "  UserKnownHostsFile $dir/known_hosts"
    echo "  StrictHostKeyChecking accept-new"
    echo "  BatchMode yes"
  } >"$dir/ssh_config"
  ssh_port="$port"
}

run_ssh() {  # run_ssh RUN PORT
  local dir="$work/ssh-$1" sock
  mkdir -p "$dir/client"
  chmod 700 "$dir" "$dir/client"
  sock="$dir/link.sock"
  "$bin" remote connect "ssh://$(id -un)@127.0.0.1:$2" --session "tscroll-ssh-$1" --headless --json \
    --lanes single --no-install --ssh-binary /usr/bin/ssh --ssh-arg -F --ssh-arg "$work/ssh/ssh_config" \
    --remote-binary "$bin" --state-dir "$dir/client" --local-socket "$sock" --connect-timeout-seconds 30 \
    >"$dir/connect.out" 2>"$dir/connect.err" &
  pids+=("$!")
  wait_for_socket "$sock"
  # The socket answers before the first dial ends; the probe retries identify until the link carries it.
  probe ssh "$sock" "$1" || { echo "terminal-scroll: connect stderr: $(tail -n 20 "$dir/connect.err")" >&2; return 1; }
}

ssh_port=""
if [[ ",$surfaces," == *",ssh,"* ]]; then
  if [[ -x /usr/sbin/sshd ]]; then
    start_sshd
  else
    echo "terminal-scroll: no /usr/sbin/sshd on this host; the ssh rows are not measured" >&2
  fi
fi
for run in $(seq 1 "$runs"); do
  [[ ",$surfaces," == *",local,"* ]] && run_local "$run"
  [[ -n "$ssh_port" ]] && run_ssh "$run" "$ssh_port"
done

python3 -c '
import json, sys
reports = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
by = {}
for r in reports:
    s = r["surface"]
    for view in ("mirror", "daemon"):
        for key in ("blank_rows", "missing_rows", "jumps"):
            by.setdefault(f"terminal.scroll.{s}.{view}.{key}", []).append(r["views"][view][key])
    by.setdefault(f"terminal.scroll.{s}.bad", []).append(r["bad"])
rows = []
for name, values in by.items():
    ordered = sorted(values)
    # Integer counts: a regression is one more blank, missing or jumped row (floor 0.5).
    rows.append({"name": name, "p50": ordered[len(ordered) // 2], "p95": ordered[-1], "unit": "rows",
                 "target": 0, "floor": 0.5, "runs": len(values)})
for row in rows:
    print("PERF_ROW " + json.dumps(row))
print(json.dumps({"rows": rows}))
' "$reports"
