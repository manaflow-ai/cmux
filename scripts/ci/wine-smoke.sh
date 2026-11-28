#!/usr/bin/env bash
# Run the Linux-built Windows binaries (scripts/ci/windows-gnu-cross-build.sh) under Wine on Linux.
#
# The checks are the Windows runner's own (cmux-tui-build-package.yml build-windows): the same
# smoke scripts, run by a Windows CPython 3.12.10 under Wine against the same .exe files, so a
# Windows API the daemon calls goes through Wine's implementation of it. What Wine cannot stand in
# for (AF_UNIX sockets, so the daemon smokes; ConPTY resize; PowerShell; the install-key handoff) stays on the Windows runner; see
# docs/windows-wine-smoke.md for the list and why.
#
# Usage: wine-smoke.sh setup                     # Wine prefix + Windows Python + pywinpty (pinned)
#        wine-smoke.sh BINARY DIST_DIR TESTS_DIR # one binary's checks (cmux-tui, cmux-tui-hook, ...)
#        wine-smoke.sh all DIST_DIR TESTS_DIR    # every binary, one line per check, nonzero if any failed
# Env: WINE_SMOKE_DIR (prefix and downloads; default $RUNNER_TEMP or ~/.cache /cmux-wine-smoke).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# macOS has no `timeout`; every scripts/ci script bounds a command through timeout.sh (CiScriptsCallPortableTimeout).
ci_timeout="$repo_root/scripts/ci/timeout.sh"
root="${WINE_SMOKE_DIR:-${RUNNER_TEMP:-$HOME/.cache}/cmux-wine-smoke}"
export WINEPREFIX="$root/prefix" WINEDEBUG="${WINEDEBUG:--all}" WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml=}"
# The Windows runner's Python (actions/setup-python 3.12.10); the embeddable zip is the same build.
py_url="https://www.python.org/ftp/python/3.12.10/python-3.12.10-embed-amd64.zip"
py_sha="4acbed6dd1c744b0376e3b1cf57ce906f9dc9e95e68824584c8099a63025a3c3"
pydir="$root/python"
step_timeout="${WINE_SMOKE_STEP_TIMEOUT:-120}"

fetch() { # url sha out
  [[ -f "$3" ]] || { curl -fsSL --retry 4 --retry-all-errors --max-time 300 -o "$3.part" "$1"; mv "$3.part" "$3"; }
  echo "$2  $3" | sha256sum -c - >&2
}

setup() {
  command -v wine >/dev/null || bash "$repo_root/scripts/ci/apt-ensure.sh" wine64 wine
  mkdir -p "$root/dl"
  if [[ ! -f "$pydir/.ok" ]]; then
    fetch "$py_url" "$py_sha" "$root/dl/python-embed.zip"
    # pywinpty: the wheel requirements-windows-conpty.txt pins, by its hash.
    local whl_sha whl_url
    whl_sha="$(sed -n 's/.*--hash=sha256:\([0-9a-f]\{64\}\).*/\1/p' "$repo_root/cmux-tui/scripts/requirements-windows-conpty.txt" | head -1)"
    whl_url="$(curl -fsSL --max-time 60 https://pypi.org/pypi/pywinpty/3.0.5/json \
      | python3 -I -c 'import json,sys; h=sys.argv[1]; print(next(u["url"] for u in json.load(sys.stdin)["urls"] if u["digests"]["sha256"]==h))' "$whl_sha")"
    fetch "$whl_url" "$whl_sha" "$root/dl/pywinpty.whl"
    rm -rf "$pydir"; mkdir -p "$pydir"
    python3 -I -m zipfile -e "$root/dl/python-embed.zip" "$pydir"
    python3 -I -m zipfile -e "$root/dl/pywinpty.whl" "$pydir/site"
    sed -i 's/^#import site/import site/' "$pydir"/python3*._pth
    echo site >> "$pydir"/python3*._pth
    touch "$pydir/.ok"
  fi
  [[ -f "$WINEPREFIX/system.reg" ]] || bash "$ci_timeout" 300 wineboot -i >/dev/null 2>&1
  wine --version >&2
}

# Wine's console layer refuses a regular file as a Windows process's stdout ("init_sys_streams:
# Invalid handle" from CPython), so every run reads its output through a pipe.
wrun() { bash "$ci_timeout" --kill-after=10 "$step_timeout" wine "$@" </dev/null 2>&1 | cat; return "${PIPESTATUS[0]}"; }
wpy() { wrun "$pydir/python.exe" "$@"; }

failed=0
check() { # name cmd...
  local name="$1"; shift
  local start=$SECONDS out status
  set +e; out="$("$@")"; status=$?; set -e
  if [[ $status -eq 0 ]]; then
    printf 'wine-smoke: PASS %-48s %3ds\n' "$name" $((SECONDS - start))
  else
    printf 'wine-smoke: FAIL %-48s %3ds exit %s\n%s\n' "$name" $((SECONDS - start)) "$status" "$out" | tail -40
    failed=1
  fi
}

version_ok() { # exe: --version exits 0 and prints a version
  local out; out="$(wrun "$1" --version)" || { printf '%s\n' "$out"; return 1; }
  printf '%s\n' "$out"; grep -Eq '[0-9]+\.[0-9]+' <<<"$out"
}

remote_probe_refuses() { # the Windows runner's check: remote daemon commands fail clearly
  local out status
  set +e; out="$(wrun "$1" remote-probe --json)"; status=$?; set -e
  printf '%s\n' "$out"
  [[ $status -eq 1 ]] && grep -Fq "remote daemon commands require Unix sockets" <<<"$out"
}

core_tests() { # the Windows runner's long-path unit tests that Wine can run; each filter must run a test
  # Not here: registry_opens_and_persists_under_a_long_windows_state_root (Wine 9.0's long-path
  # canonicalize returns ERROR_MORE_DATA, 234) and normalize_long_windows (those tests are in
  # cmux-tui-platform, not this binary: the filter matches 0 tests).
  local t=socket_start_lock_acquires_a_new_lock_file out
  out="$(wrun "$1" "$t")" || { printf '%s\n' "$out"; return 1; }
  printf '%s\n' "$out"
  grep -Eq 'test result: ok\. [1-9][0-9]* passed' <<<"$out" || { echo "$t: no test ran"; return 1; }
}

relay_serves() { # exe: serve on loopback under Wine; Linux curl reads /healthz and upgrades /v1/relay
  local port=$((20000 + RANDOM % 20000)) pid body code
  bash "$ci_timeout" --kill-after=5 60 wine "$1" serve --allow-open --bind "127.0.0.1:$port" </dev/null >"$root/relay.log" 2>&1 &
  pid=$!
  for _ in $(seq 1 80); do body="$(curl -fsS --max-time 2 "http://127.0.0.1:$port/healthz" 2>/dev/null)" && break; sleep 0.25; done
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 -H 'Upgrade: websocket' -H 'Connection: Upgrade' \
    -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "http://127.0.0.1:$port/v1/relay" 2>/dev/null || true)"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
  printf 'healthz: %s\nwebsocket upgrade: %s\n' "$body" "$code"; cat "$root/relay.log"
  grep -Fq '"status":"ok"' <<<"$body" && [[ $code == 101 ]]
}

help_ok() { local out; out="$(wrun "$1" --help)" || { printf '%s\n' "$out"; return 1; }; printf '%s\n' "$out"; grep -q 'Usage\|usage\|OPTIONS' <<<"$out"; }

host_refuses() { # cmux-tui-host only runs under its daemon: without a bootstrap pipe it starts, then refuses
  local out status
  set +e; out="$(wrun "$1")"; status=$?; set -e
  printf '%s\n' "$out"
  [[ $status -ne 0 ]] && grep -Fq "not a bootstrap pipe name" <<<"$out"
}

smoke() { # binary name dist tests
  local name="$1" tests="$3" exe="$2/$1-x86_64-pc-windows-gnu.exe"
  [[ -f "$exe" ]] || { printf 'wine-smoke: FAIL %-48s missing %s\n' "$name" "$exe"; failed=1; return 0; }
  case "$name" in
    cmux-tui)
      check "$name --version" version_ok "$exe"
      check "$name remote-probe refuses" remote_probe_refuses "$exe"
      check "$name long-path unit tests" core_tests "$tests/cmux-tui-core-tests.exe"
      # Not here: smoke-windows-long-state-path.py and smoke-windows-process-wait.py start the
      # daemon, whose Windows socket is AF_UNIX, and Wine 9.0 has none (WSAEAFNOSUPPORT, 10047).
      ;;
    cmux-tui-hook) check "$name --help" help_ok "$exe" ;; # it has no --version: it reads a native event
    cmux-tui-host) check "$name refuses without a bootstrap pipe" host_refuses "$exe" ;;
    cmux-relay)
      check "$name --version" version_ok "$exe"
      check "$name serves /healthz and a websocket" relay_serves "$exe" ;;
    acpmux) check "$name --version" version_ok "$exe" ;; # build-windows-acpmux's only check
    *) check "$name --version" version_ok "$exe"; check "$name --help" help_ok "$exe" ;;
  esac
}

case "${1:-}" in
  setup) setup ;;
  all)
    setup
    for b in cmux-tui cmux-tui-hook cmux-tui-host cmux-relay chatmux-relay; do smoke "$b" "${2:?DIST_DIR}" "${3:?TESTS_DIR}"; done
    exit $failed ;;
  cmux-tui|cmux-tui-hook|cmux-tui-host|cmux-relay|chatmux-relay|acpmux)
    setup; smoke "$1" "${2:?DIST_DIR}" "${3:?TESTS_DIR}"; exit $failed ;;
  *) echo "usage: $0 setup | all DIST TESTS | BINARY DIST TESTS" >&2; exit 2 ;;
esac
