#!/bin/sh
# Tests machine-join.sh with no network and no real acpmux:
#   sh cmux-tui/scripts/machine-join.test.sh
# Every command the script runs resolves through a recording shim (argv,
# and whether CMUX_JOIN or any cmj_ value is in its environment) before the
# real tool runs; curl is a fake that serves a fixture channel, and the
# acpmux it "downloads" is a fake that records its argv and stdin. Runs the
# script under sh, and under bash --posix and dash when present.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/machine-join.sh"
root="$(mktemp -d "${TMPDIR:-/tmp}/machine-join-test.XXXXXX")"
trap 'rm -rf "$root"' EXIT INT TERM

token="cmj_TestToken-0123456789_abcdefXYZ"
origin="https://platform.example.test"
fails=0
passes=0

fail() {
  fails=$((fails + 1))
  printf 'FAIL [%s] %s\n' "$case_name" "$*" >&2
}
ok() { passes=$((passes + 1)); }
check() { # check DESCRIPTION COMMAND...
  desc="$1"
  shift
  if "$@"; then ok; else fail "$desc"; fi
}

if command -v shasum >/dev/null 2>&1; then
  sha() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  sha() { sha256sum "$1" | awk '{print $1}'; }
fi

# The shims: one per tool the script may run. Each logs, then runs the real one.
shims="$root/shims"
fakes="$root/fakes"
mkdir -p "$shims" "$fakes"
for tool in awk basename cat chmod cp grep head hostname id install loginctl \
  mkdir mktemp mv rm sed shasum sha256sum tr launchctl systemctl; do
  real="$(command -v "$tool" 2>/dev/null || true)"
  case "$tool" in
    loginctl | launchctl | systemctl) real="" ;;
    *) [ -n "$real" ] || continue ;;
  esac
  {
    printf '#!/bin/sh\n'
    printf '. "%s/record.sh"\n' "$fakes"
    if [ -n "$real" ]; then
      printf 'exec "%s" "$@"\n' "$real"
    else
      printf 'exit 0\n'
    fi
  } >"$shims/$tool"
  chmod 755 "$shims/$tool"
done
# rm keeps the script's temp dir, so the tests can read what reached disk.
real_rm="$(command -v rm)"
{
  printf '#!/bin/sh\n'
  printf '. "%s/record.sh"\n' "$fakes"
  printf 'case "$*" in *cmux-join.*) exit 0 ;; esac\n'
  printf 'exec "%s" "$@"\n' "$real_rm"
} >"$shims/rm"
chmod 755 "$shims/rm"
# A printf on PATH would only run if the script exec'd one: it must not.
cp "$shims/cat" "$shims/printf"
real_env="$(command -v env)"
real_grep="$(command -v grep)"
cat >"$fakes/record.sh" <<EOF
# Sourced by every shim and fake: record argv and the environment check.
{
  printf '%s' "\${0##*/}"
  for a in "\$@"; do printf ' %s' "\$a"; done
  printf '\n'
} >>"\$JT_LOG/argv"
if [ -n "\${CMUX_JOIN+x}" ] || "$real_env" | "$real_grep" -q cmj_; then
  printf '%s\n' "\${0##*/}" >>"\$JT_LOG/env-leak"
fi
EOF

# The fake uname: JT_OS and JT_ARCH.
cat >"$shims/uname" <<EOF
#!/bin/sh
. "$fakes/record.sh"
case "\$1" in -s) echo "\$JT_OS" ;; -m) echo "\$JT_ARCH" ;; *) echo fake ;; esac
EOF
chmod 755 "$shims/uname"

# The fake curl: serves \$JT_SERVE/<kind> by the URL's shape, honours -o.
cat >"$shims/curl" <<EOF
#!/bin/sh
. "$fakes/record.sh"
out=""
url=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    --proto | --max-time) shift 2 ;;
    -*) shift ;;
    *) url="\$1"; shift ;;
  esac
done
case "\$url" in
  https://files.cmux.com/cmux-tui/channels/*.json) src="\$JT_SERVE/channel.json" ;;
  https://files.cmux.com/cmux-tui/tree/*/cmux-tui-acpmux-*) src="\$JT_SERVE/acpmux" ;;
  https://files.cmux.com/cmux-tui/latest/manifest.json) src="\$JT_SERVE/manifest.json" ;;
  https://files.cmux.com/cmux-tui/*/cmux-tui-*) src="\$JT_SERVE/cmux" ;;
  *) exit 6 ;;
esac
[ -f "\$src" ] || exit 22
if [ -n "\$out" ]; then "$(command -v cat)" "\$src" >"\$out"; else "$(command -v cat)" "\$src"; fi
EOF
chmod 755 "$shims/curl"

# The fake acpmux, "downloaded" from the channel. Behaviour from env:
# JT_CAPS (capability lines), JT_JOIN_EXIT, JT_STATE (a file; present = joined),
# JT_DOCTOR=1 (it has `host doctor --here`), JT_SERVICE=1 (`daemon service`).
cat >"$root/acpmux.src" <<EOF
#!/bin/sh
. "$fakes/record.sh"
case "\$*" in
  capabilities) printf '%s\n' \$JT_CAPS ;;
  "daemon service --help") [ "\${JT_SERVICE:-0}" = 1 ] || exit 2 ;;
  "host doctor --help") [ "\${JT_DOCTOR:-0}" = 1 ] && echo "  --here" || exit 2 ;;
  "host doctor --here") echo '{"step":"credential","state":"ok"}' ;;
  "host join --status --json")
    if [ -f "\$JT_STATE" ]; then
      printf '{\n  "consent": {"screen": "none"},\n  "credentialPath": "/h/.acpmux/machine-credential.json",\n  "credentialPresent": true,\n  "revoked": false\n}\n'
    else
      printf '{\n  "credentialPath": "/h/.acpmux/machine-credential.json",\n  "credentialPresent": false,\n  "revoked": false\n}\n'
    fi ;;
  "host join --status") echo "credential: present" ;;
  "host join "*)
    "$(command -v cat)" >>"\$JT_LOG/join-stdin"
    echo "\$*" >>"\$JT_LOG/joins"
    code="\${JT_JOIN_EXIT:-0}"
    [ "\$code" = 0 ] || { echo "acpmux: join failed (cmj_LeakedInError)" >&2; exit "\$code"; }
    : >"\$JT_STATE"
    printf '{"joined": true, "alreadyJoined": false}\n' ;;
  *) ;;
esac
EOF

# Fixtures served by the fake curl.
serve_dir() { # serve_dir DIR [WRONG_SHA]
  mkdir -p "$1"
  cp "$root/acpmux.src" "$1/acpmux"
  s="$(sha "$1/acpmux")"
  [ -z "${2:-}" ] || s="$2"
  cat >"$1/channel.json" <<EOF
{
  "binaries": {
    "cmux-tui-acpmux-aarch64-apple-darwin": "$s",
    "cmux-tui-acpmux-x86_64-unknown-linux-musl": "$s"
  },
  "commit": "0bb2eda1a2029e41086d6ef6d2afadd85e99235f",
  "key": "121e0512465089798aba4eea7eba48644ecac9a9"
}
EOF
  printf '#!/bin/sh\necho cmux\n' >"$1/cmux"
  c="$(sha "$1/cmux")"
  printf '{"commit": "a6d89d443f5f9ffb66c296d7a9680e307bbe6c58", "cmux-tui-x86_64-unknown-linux-gnu": "%s", "cmux-tui-aarch64-apple-darwin": "%s"}\n' "$c" "$c" >"$1/manifest.json"
}

# A fresh case: its own HOME, log and fixtures.
new_case() {
  case_name="$1"
  d="$root/case-$n-$1"
  n=$((n + 1))
  mkdir -p "$d/home" "$d/log" "$d/tmp"
  serve_dir "$d/serve"
  JT_OS=Linux JT_ARCH=x86_64
  JT_CAPS="acpmux-v1 machine.join.stdin.v1"
  JT_JOIN_EXIT=0 JT_DOCTOR=0 JT_SERVICE=1
  : >"$d/log/argv"
}

# run_join FORM [extra VAR=value...]: FORM env | arg | none.
run_join() {
  form="$1"
  shift
  set -- env -i HOME="$d/home" PATH="$shims" TMPDIR="$d/tmp" SHELL=/bin/bash \
    JT_LOG="$d/log" JT_SERVE="$d/serve" JT_STATE="$d/home/joined" \
    JT_OS="$JT_OS" JT_ARCH="$JT_ARCH" JT_CAPS="$JT_CAPS" JT_JOIN_EXIT="$JT_JOIN_EXIT" \
    JT_DOCTOR="$JT_DOCTOR" JT_SERVICE="$JT_SERVICE" CMUX_PLATFORM_URL="$origin" "$@"
  rc=0
  case "$form" in
    env) "$@" CMUX_JOIN="$token" $shell_cmd -s <"$script_under_test" >"$d/out" 2>&1 || rc=$? ;;
    arg) "$@" $shell_cmd -s -- "$token" <"$script_under_test" >"$d/out" 2>&1 || rc=$? ;;
    bad) "$@" CMUX_JOIN="not-a-token" $shell_cmd -s <"$script_under_test" >"$d/out" 2>&1 || rc=$? ;;
    none) "$@" $shell_cmd -s <"$script_under_test" >"$d/out" 2>&1 || rc=$? ;;
  esac
}

no_token_in_argv() { ! grep -q 'cmj_[A-Za-z0-9_-]' "$d/log/argv"; }
# The token, or the fake's leaked error, anywhere the script wrote (the fake
# acpmux binary itself holds the leak marker's text, so join.* files only for it).
no_token_on_disk() {
  ! grep -rqF -- "$token" "$d/tmp" "$d/home" 2>/dev/null &&
    ! cat "$d/tmp"/cmux-join.*/join.* 2>/dev/null | grep -q cmj_
}
no_env_leak() { [ ! -s "$d/log/env-leak" ]; }
no_token_in_output() { ! grep -q cmj_ "$d/out"; }
token_on_stdin_once() { [ "$(cat "$d/log/join-stdin" 2>/dev/null)" = "$token" ]; }
no_redeem() { [ ! -e "$d/log/join-stdin" ]; }
out_has() { grep -qF -- "$1" "$d/out"; }
rc_is() { [ "$rc" = "$1" ]; }
installed() { [ -x "$d/home/.local/bin/acpmux" ]; }
fetched_binary() { grep -q 'tree/.*/cmux-tui-acpmux-' "$d/log/argv"; }

n=0
suite() {

  new_case env-form
  run_join env
  check "exit 0 (got $rc): $(cat "$d/out")" rc_is 0
  check "no cmj_ in any argv" no_token_in_argv
  check "CMUX_JOIN or a cmj_ value reached a child's env: $(cat "$d/log/env-leak" 2>/dev/null)" no_env_leak
  check "the token reaches acpmux host join on stdin, once" token_on_stdin_once
  check "acpmux installed" installed
  check "joins with --hub and --name" grep -q -- "--hub $origin --name" "$d/log/joins"
  check "the cmux CLI installed" test -x "$d/home/.cmux/bin/cmux"
  check "the consent line" out_has "Screen sharing and control are off on this machine."
  check "no token in output" no_token_in_output
  check "no printf binary was exec'd (it is a builtin)" eval '! grep -q "^printf" "$d/log/argv"'

  # Re-run: the binary already has the channel's sha256 and the machine is
  # joined, so nothing is downloaded and nothing redeemed.
  rm -f "$d/log/join-stdin"
  : >"$d/log/argv"
  run_join env
  check "re-run exit 0 (got $rc)" rc_is 0
  check "re-run redeems nothing" no_redeem
  check "re-run says already joined" out_has "already joined; nothing redeemed"
  check "re-run downloads no binary" eval '! fetched_binary'

  # CMUX_JOIN_REPLACE=1 does spend the new token, with --replace.
  run_join env CMUX_JOIN_REPLACE=1
  check "replace exit 0 (got $rc)" rc_is 0
  check "replace passes --replace" grep -q -- "--replace" "$d/log/joins"
  check "replace: token on stdin" token_on_stdin_once

  # A caller that exported `t` (or `j`) must not get the token exported.
  new_case exported-t
  run_join env t=caller-value j=caller-value
  check "exported t: exit 0 (got $rc): $(cat "$d/out")" rc_is 0
  check "exported t: no env leak: $(cat "$d/log/env-leak" 2>/dev/null)" no_env_leak
  check "exported t: token on stdin" token_on_stdin_once
  new_case exported-t-arg
  run_join arg t=caller-value
  check "exported t, arg form: no env leak" no_env_leak

  # bash takes allexport and xtrace from an inherited SHELLOPTS.
  for opts in allexport xtrace allexport:xtrace; do
    new_case "shellopts-$opts"
    run_join env SHELLOPTS="$opts"
    check "SHELLOPTS=$opts: exit 0 (got $rc): $(tail -3 "$d/out")" rc_is 0
    check "SHELLOPTS=$opts: no env leak: $(cat "$d/log/env-leak" 2>/dev/null)" no_env_leak
    check "SHELLOPTS=$opts: no token in output" no_token_in_output
    check "SHELLOPTS=$opts: token on stdin" token_on_stdin_once
  done

  new_case arg-form
  run_join arg
  check "exit 0 (got $rc): $(cat "$d/out")" rc_is 0
  check "no cmj_ in any child argv" no_token_in_argv
  check "no env leak" no_env_leak
  check "the token reaches acpmux on stdin" token_on_stdin_once

  for code in 2 3 4 5; do
    new_case "exit-$code"
    JT_JOIN_EXIT=$code
    run_join env
    check "exit $code passes through (got $rc)" rc_is "$code"
    check "one line for $code" test "$(grep -c '^cmux join:' "$d/out")" -ge 1
    check "no token in output" no_token_in_output
    check "no token on disk" no_token_on_disk
    case "$code" in
      2) check "2 line" out_has "the line was damaged; copy it again from cmux" ;;
      3) check "3 line" out_has "this line was used or expired; make a new one: cmux machine add (or Add Machine in the app)" ;;
      4) check "4 line" out_has "cannot reach $origin: check this machine's outbound HTTPS, then paste a new line" ;;
      5) check "5 line" out_has "could not store the machine credential in /h/.acpmux/machine-credential.json: free disk / fix permissions, then paste a new line" ;;
    esac
  done

  # Any other failure shows acpmux's own error, with anything token-shaped cut.
  new_case exit-other
  JT_JOIN_EXIT=7
  run_join env
  check "exit 7 passes through (got $rc)" rc_is 7
  check "acpmux's error is shown" out_has "acpmux: join failed"
  check "the generic line" out_has "joining failed (acpmux exit 7)"
  check "no token in output" no_token_in_output
  check "the temp dir was kept for the disk check" eval 'ls "$d/tmp"/cmux-join.*/join.err >/dev/null 2>&1'
  check "acpmux's stderr is redacted before it reaches disk" no_token_on_disk

  new_case sha-mismatch
  serve_dir "$d/serve" "0000000000000000000000000000000000000000000000000000000000000000"
  run_join env
  check "mismatch fails (got $rc)" rc_is 1
  check "mismatch says so" out_has "checksum verification failed for acpmux"
  check "nothing installed" eval '! installed'
  check "nothing redeemed" no_redeem

  # A capable acpmux whose sha256 is not the channel's never gets the token:
  # the channel's build replaces it first.
  new_case capable-mismatch
  mkdir -p "$d/home/.local/bin"
  { cat "$root/acpmux.src"; echo "# a different build"; } >"$d/home/.local/bin/acpmux"
  chmod 755 "$d/home/.local/bin/acpmux"
  run_join env
  check "capable mismatch exit 0 (got $rc): $(cat "$d/out")" rc_is 0
  check "the channel build replaced it" test "$(sha "$d/home/.local/bin/acpmux")" = "$(sha "$d/serve/acpmux")"
  check "the old one kept as acpmux.prev" grep -q "a different build" "$d/home/.local/bin/acpmux.prev"
  check "the replaced daemon restarted" grep -q "^acpmux daemon restart" "$d/log/argv"
  check "token on stdin of the verified binary" token_on_stdin_once

  # Without a token (repair), a capable different build is kept.
  new_case capable-mismatch-repair
  mkdir -p "$d/home/.local/bin"
  { cat "$root/acpmux.src"; echo "# a different build"; } >"$d/home/.local/bin/acpmux"
  chmod 755 "$d/home/.local/bin/acpmux"
  run_join none
  check "repair exit 0 (got $rc)" rc_is 0
  check "repair keeps the capable build" grep -q "a different build" "$d/home/.local/bin/acpmux"
  check "repair downloads no binary" eval '! fetched_binary'

  # The channel cannot be read: a token run refuses, a repair run keeps going.
  new_case no-channel
  mkdir -p "$d/home/.local/bin"
  cp "$root/acpmux.src" "$d/home/.local/bin/acpmux"
  chmod 755 "$d/home/.local/bin/acpmux"
  rm "$d/serve/channel.json"
  run_join env
  check "no channel with a token exits 1 (got $rc)" rc_is 1
  check "no channel says so" out_has "cannot read the feat-cmux-next channel"
  check "no channel redeems nothing" no_redeem
  run_join none
  check "no channel repair exit 0 (got $rc)" rc_is 0

  new_case too-old
  JT_CAPS="acpmux-v1"
  run_join env
  check "too old fails (got $rc)" rc_is 1
  check "too old says update" out_has "this acpmux is too old: update"
  check "too old redeems nothing" no_redeem

  new_case bad-token
  run_join bad
  check "bad token exit 2 (got $rc)" rc_is 2
  check "bad token line" out_has "that is not a cmux join token (it starts with cmj_)"
  check "bad token downloads nothing" eval '! grep -q "^curl" "$d/log/argv"'

  new_case no-token
  run_join none
  check "no token: exit 0 (got $rc)" rc_is 0
  check "no token: installed" installed
  check "no token: service and daemon" grep -q "^acpmux daemon start" "$d/log/argv"
  check "no token: nothing redeemed" no_redeem

  new_case doctor
  JT_DOCTOR=1
  run_join env
  check "doctor run" grep -q "^acpmux host doctor --here" "$d/log/argv"
  check "doctor lines printed" out_has '"step":"credential"'

  new_case no-service
  JT_SERVICE=0
  run_join env
  check "no service: still joins (got $rc)" rc_is 0
  check "no service: warns" out_has "cannot install its service yet"
  check "no service: daemon start" grep -q "^acpmux daemon start" "$d/log/argv"

  new_case macos
  JT_OS=Darwin JT_ARCH=arm64
  run_join env
  check "macos exit 0 (got $rc): $(cat "$d/out")" rc_is 0
  check "macos fetches the darwin build" grep -q "cmux-tui-acpmux-aarch64-apple-darwin" "$d/log/argv"

  new_case unsupported
  JT_OS=FreeBSD
  run_join env
  check "unsupported exit 1 (got $rc)" rc_is 1
  check "unsupported line" out_has "unsupported platform FreeBSD-x86_64"
}

# The checks are live: a copy that passes the token in argv must fail them.
mutant="$root/mutant.sh"
sed 's/^    printf .%s\\n. "\$t" | "\$acpmux" "\$@"/    "$acpmux" "$@" "$t" <\/dev\/null/' "$script" >"$mutant"
if cmp -s "$script" "$mutant"; then
  case_name=mutant
  fail "the mutant did not change the redeem line"
fi

shells="sh"
command -v bash >/dev/null 2>&1 && shells="$shells bash"
command -v dash >/dev/null 2>&1 && shells="$shells dash"
for shell_name in $shells; do
  case "$shell_name" in
    bash) shell_cmd="$(command -v bash) --posix" ;;
    *) shell_cmd="$(command -v "$shell_name")" ;;
  esac
  script_under_test="$script"
  suite
done

# Mutant: run the env form and require the argv check to catch it.
shell_cmd="$(command -v sh)"
script_under_test="$mutant"
n=900
new_case mutant
run_join env
if no_token_in_argv; then
  fail "a script that puts the token in argv passed the argv check"
else
  ok
fi

printf 'machine-join.test.sh: %d passed, %d failed (shells: %s)\n' "$passes" "$fails" "$shells"
[ "$fails" -eq 0 ]
