#!/bin/sh
# Runs one installer case as the non-root test user against the local test
# channel (build-test-channel.sh, served on 127.0.0.1:$PORT).
#   install-cases.sh <case>
# Cases: cut fresh client idempotent upgrade rollback tampered badsig expired
#        downgrade reupgrade uninstall purge status
set -u
PORT=${PORT:-8765}
CH="http://127.0.0.1:$PORT"
[ -n "${HOME:-}" ] || HOME=$(getent passwd "$(id -u)" | cut -d: -f6)
export HOME
XDG_RUNTIME_DIR="/run/user/$(id -u)"
export XDG_RUNTIME_DIR
export PATH="$HOME/.local/bin:$PATH"
INSTALLER="$HOME/channel/install.sh"
DATA="$HOME/.local/share/cmux"
STATE="$HOME/.local/state/cmux/server"

ms() { date +%s%3N; }
pass() { printf 'RESULT %s PASS %s\n' "$case" "$*"; }
fail() { printf 'RESULT %s FAIL %s\n' "$case" "$*"; }
gen() { basename "$(readlink "$DATA/current" 2>/dev/null)" 2>/dev/null; }
# Server processes by executable path (an exec wrapper's argv may contain the
# same words as text).
server_procs() { pgrep -u "$(id -u)" -f -- '^(/proc/self/exe |/usr/bin/systemd-inhibit |/usr/lib/postgresql/[0-9]+/bin/postgres )' | wc -l; }
mainpid() { systemctl --user show cmux-server.service -p MainPID --value 2>/dev/null; }

# Runs the installer, prints its output and the elapsed time; sets rc.
inst() {
  t0=$(ms)
  out=$(sh "$INSTALLER" "$@" 2>&1)
  rc=$?
  t1=$(ms)
  printf '%s\n' "$out" | sed 's/^/  | /'
  printf '  rc=%s elapsed_ms=%s\n' "$rc" "$((t1 - t0))"
}

refused() { # expected refusal; current must not change
  before=$(gen)
  inst --version "$1"
  after=$(gen)
  if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "$2" && [ "$before" = "$after" ]; then
    pass "refused ($2), current stays $after"
  else
    fail "rc=$rc before=$before after=$after"
  fi
}

case=${1:?case}
printf '=== CASE %s (user %s, %s)\n' "$case" "$(id -un)" "$(date -u +%FT%TZ)"
case "$case" in
  cut)
    # A cut download must run nothing: send the first 6000 bytes to sh.
    curl -fsS "$CH/install.sh" | head -c 6000 | sh -s -- --version 1
    rc=$?
    if [ ! -e "$DATA" ] && [ ! -e "$STATE" ]; then pass "truncated script ran nothing (rc=$rc)"; else fail "state appeared"; fi
    ;;
  fresh)
    t0=$(ms)
    out=$(curl -fsSL "$CH/install.sh" | sh -s -- --version 1 2>&1)
    rc=$?
    t1=$(ms)
    printf '%s\n' "$out" | sed 's/^/  | /'
    printf '  rc=%s elapsed_ms=%s\n' "$rc" "$((t1 - t0))"
    if [ "$rc" = 0 ] && [ "$(gen)" = 1 ] && systemctl --user is-active --quiet cmux-server.service; then
      pass "generation 1 active, pid $(mainpid)"
    else
      fail "rc=$rc gen=$(gen)"
    fi
    stat -c '  perms %a %U %n' "$DATA" "$DATA/store" "$STATE" "$STATE/updater.state" 2>/dev/null
    find "$DATA" -maxdepth 1 -exec stat -c '  %A %n' {} +
    ;;
  client)
    printf "  server status: %s\n" "$(cmux server status --session server --json 2>&1 | head -c 600)"
    ws=$(cmux --session server --json workspace create --name proto 2>&1)
    printf '  workspace create: %s\n' "$(printf '%s' "$ws" | head -c 300)"
    tab=$(cmux --session server --json tab create terminal 2>&1)
    printf '  tab create: %s\n' "$(printf '%s' "$tab" | head -c 400)"
    term=$(printf '%s' "$tab" | grep -o 'term_[A-Za-z0-9]*' | head -n 1)
    [ -n "$term" ] || term=$(cmux --session server --json terminal list | grep -o 'term_[A-Za-z0-9]*' | head -n 1)
    printf '%s\n' "$term" >"$HOME/proto-term-id"
    # shellcheck disable=SC2016 # the literal $((6*7)) is typed into the terminal
    cmux --session server terminal "$term" write --text 'echo proto-marker-$((6*7))
' >/dev/null
    if cmux --session server terminal "$term" screen wait --pattern 'proto-marker-42' --timeout-ms 10000 >/dev/null; then
      cmux --session server terminal "$term" screen read | grep -m2 'proto-marker' | sed 's/^/  screen| /'
      cmux --session server terminal "$term" write --text 'echo "shell-pid=$$"
' >/dev/null
      cmux --session server terminal "$term" screen wait --pattern 'shell-pid=[0-9]+' --timeout-ms 10000 >/dev/null
      shell_pid=$(cmux --session server terminal "$term" screen read | grep -o 'shell-pid=[0-9]*' | tail -n 1 | cut -d= -f2)
      printf '%s\n' "$shell_pid" >"$HOME/proto-term-shell"
      ps -o ppid= -p "$shell_pid" | tr -d ' ' >"$HOME/proto-term-host"
      pass "terminal $term created, wrote, read back proto-marker-42 (shell $shell_pid, host $(cat "$HOME/proto-term-host"))"
    else
      fail "screen wait failed for $term"
    fi
    ;;
  idempotent)
    pid0=$(mainpid)
    inst --version 1
    if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'no change' && [ "$(mainpid)" = "$pid0" ] &&
      ! printf '%s' "$out" | grep -q 'fetching\|wrote '; then
      pass "no-op: store hits, same generation, unit unchanged, same pid $pid0"
    else
      fail "rc=$rc pid $pid0 -> $(mainpid)"
    fi
    ;;
  upgrade)
    pid0=$(mainpid)
    term=$(cat "$HOME/proto-term-id" 2>/dev/null)
    inst --version 2
    v=$("$DATA/current/bin/cmux-host-run" version 2>/dev/null)
    hook=$([ -x "$DATA/current/bin/cmux-hook" ] && echo yes || echo no)
    if [ "$rc" = 0 ] && [ "$(gen)" = 2 ] && [ "$v" = 2 ] && [ "$hook" = yes ]; then
      pass "generation 2 (cmux-host-run $v, cmux-hook $hook), pid $pid0 -> $(mainpid)"
    else
      fail "rc=$rc gen=$(gen) host-run=$v hook=$hook"
    fi
    shell_pid=$(cat "$HOME/proto-term-shell" 2>/dev/null)
    host_after=$(ps -o ppid= -p "$shell_pid" 2>/dev/null | tr -d ' ')
    if [ -n "$shell_pid" ] && [ "$host_after" = "$(cat "$HOME/proto-term-host")" ]; then
      printf 'RESULT upgrade-host-adopted PASS shell %s still runs under host %s after the daemon restart\n' "$shell_pid" "$host_after"
    else
      printf 'RESULT upgrade-host-adopted FAIL shell %s parent now %s\n' "$shell_pid" "$host_after"
    fi
    if [ -n "$term" ] && cmux --session server terminal "$term" screen read 2>/dev/null | grep -q 'proto-marker-42'; then
      printf 'RESULT upgrade-terminal-survives PASS %s kept its screen across the session host restart\n' "$term"
    else
      printf 'RESULT upgrade-terminal-survives FAIL %s not readable after restart\n' "$term"
    fi
    ;;
  rollback)
    t0=$(ms)
    inst --rollback
    v=$("$DATA/current/bin/cmux-host-run" version 2>/dev/null)
    if [ "$rc" = 0 ] && [ "$(gen)" = 1 ] && [ "$v" = 1 ] && systemctl --user is-active --quiet cmux-server.service; then
      pass "current -> generation 1 (cmux-host-run $v), service active"
    else
      fail "rc=$rc gen=$(gen) v=$v"
    fi
    ;;
  tampered) refused tampered 'SHA-256 mismatch' ;;
  badsig) refused badsig 'signature is invalid' ;;
  expired) refused expired 'expired' ;;
  downgrade) refused 1 'lower than the last applied' ;;
  reupgrade)
    inst --version 2
    if [ "$rc" = 0 ] && [ "$(gen)" = 2 ]; then pass "back to generation 2 from the store"; else fail "rc=$rc"; fi
    ;;
  uninstall)
    inst --uninstall
    left=$(server_procs)
    if [ "$rc" = 0 ] && [ ! -e "$DATA" ] && [ ! -e "$HOME/.local/bin/cmux" ] && [ -f "$STATE/postgres/17/data/PG_VERSION" ] && [ -f "$STATE/apps/notes/pgpass" ] &&
      [ ! -e "$HOME/.config/systemd/user/cmux-server.service" ] && [ "$left" = 0 ]; then
      pass "store, shim, units removed; state kept ($(find "$STATE" -mindepth 1 -maxdepth 1 -printf '%f ' )); cmux processes left: $left"
    else
      fail "rc=$rc data=$(ls -d "$DATA" 2>/dev/null) left=$left"
    fi
    ;;
  purge)
    inst --version 2
    inst --uninstall --purge
    left=$(server_procs)
    if [ "$rc" = 0 ] && [ ! -e "$STATE" ] && [ ! -e "$DATA" ] && [ "$left" = 0 ]; then
      pass "state purged; server processes left: $left"
    else
      fail "rc=$rc left=$left"
    fi
    ;;
  status) sh "$INSTALLER" --status ;;
  *) echo "unknown case $case" >&2; exit 2 ;;
esac
