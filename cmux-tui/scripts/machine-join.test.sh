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
for tool in awk basename bash cat chmod cp grep head hostname id install loginctl \
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
  https://claude.ai/install.sh) src="\$JT_SERVE/claude-install.sh" ;;
  *) exit 6 ;;
esac
[ -f "\$src" ] || exit 22
if [ -n "\$out" ]; then "$(command -v cat)" "\$src" >"\$out"; else "$(command -v cat)" "\$src"; fi
EOF
chmod 755 "$shims/curl"

# The fake acpmux, "downloaded" from the channel. Behaviour from env:
# JT_CAPS (capability lines), JT_JOIN_EXIT (with JT_JOIN_ERR, its message), JT_STATE (a file; present = joined),
# JT_DOCTOR=1 (it has `host doctor --here`), JT_SERVICE=1 (`daemon service`),
# JT_SVC=fail (`daemon service install` fails), JT_RESTART=fail (`daemon restart` fails),
# JT_VAULT (what `host vault pull --json` answers: ok, not_granted or fail),
# JT_CODEX_RT=1 (it has `harness codex-runtime`; install records a ready runtime).
# Recovery, as acpmux's cloud_join/recovery.rs does it: JT_PENDING (a file;
# present = joinIncomplete, a pending proposal on disk; it holds the
# proposal's hub when a case sets one) with JT_PROBE (what
# the hub says of it: live, unknown or revoked), and JT_REVOKED (a file;
# present = the final credential is revoked, which only --replace with a
# token on stdin re-enrolls; without --replace acpmux says already joined).
cat >"$root/acpmux.src" <<EOF
#!/bin/sh
. "$fakes/record.sh"
joined() { : >"\$JT_STATE"; printf '{"joined": true, "alreadyJoined": false}\n'; }
refuse() { printf '{"error":{"code":"runtime","exit":%s,"detail":"join.incomplete","message":"%s"}}\n' "\$1" "\$2" >&2; exit "\$1"; }
case "\$*" in
  capabilities) printf '%s\n' \$JT_CAPS ;;
  "daemon service --help") [ "\${JT_SERVICE:-0}" = 1 ] || exit 2 ;;
  "daemon service install")
    case "\${JT_SVC:-ok}" in
      fail) echo "launchd did not load com.acpmux.daemon" >&2; exit 1 ;;
      *) echo "acpmux.service runs" ;;
    esac ;;
  "daemon restart") [ "\${JT_RESTART:-ok}" != fail ] || exit 1 ;;
  "host doctor --help") [ "\${JT_DOCTOR:-0}" = 1 ] && echo "  --here" || exit 2 ;;
  "host doctor --here") echo '{"step":"credential","state":"ok"}' ;;
  "host join --status --json")
    inc=false
    [ ! -f "\$JT_PENDING" ] || inc=true
    rev=false
    [ ! -f "\$JT_REVOKED" ] || rev=true
    if [ -f "\$JT_STATE" ]; then
      printf '{\n  "consent": {"screen": "none"},\n  "credentialPath": "/h/.acpmux/machine-credential.json",\n  "credentialPresent": true,\n  "joinIncomplete": %s,\n  "revoked": %s\n}\n' "\$inc" "\$rev"
    else
      printf '{\n  "credentialPath": "/h/.acpmux/machine-credential.json",\n  "credentialPresent": false,\n  "joinIncomplete": %s,\n  "revoked": false\n}\n' "\$inc"
    fi ;;
  "host join --status") echo "credential: present" ;;
  "host vault pull --json")
    case "\${JT_VAULT:-fail}" in
      ok) printf '{\n  "state": "ok",\n  "env": ["OPENAI_API_KEY", "GITHUB_TOKEN"],\n  "note": "sk-must-not-print"\n}\n' ;;
      not_granted) printf '{"state": "not_granted"}\n' ;;
      off) printf '{"state": "off"}\n' ;;
      partial) printf '{"state": "partial", "env": ["OPENAI_API_KEY"], "note": "sk-must-not-print"}\n'; exit 1 ;;
      *) echo "acpmux: vault failed sk-must-not-print" >&2; exit 1 ;;
    esac ;;
  "harness codex-runtime --help") [ "\${JT_CODEX_RT:-0}" = 1 ] || exit 2 ;;
  "harness codex-runtime install") [ "\${JT_CODEX_RT:-0}" = 1 ] || exit 2; : >"\$HOME/codex-ready" ;;
  "harness codex-runtime status")
    if [ -f "\$HOME/codex-ready" ]; then
      printf '{\n  "path": "%s",\n  "ready": true\n}\n' "\$JT_SERVE/codex dir/codex"
    else
      printf '{"path": "/nowhere", "ready": false}\n'
    fi ;;
  "host join "*)
    got="\$("$(command -v cat)")"
    [ -z "\$got" ] || printf '%s\n' "\$got" >>"\$JT_LOG/join-stdin"
    echo "\$*" >>"\$JT_LOG/joins"
    case " \$* " in *" --replace "*) rep=1 ;; *) rep=0 ;; esac
    if [ -f "\$JT_PENDING" ]; then
      case "\$*" in *" --name "*) refuse 2 "join incomplete; retry with the original hub and name" ;; esac
      ph="\$("$(command -v cat)" "\$JT_PENDING")"
      if [ -n "\$ph" ]; then
        case " \$* " in
          *" --hub \$ph "*) ;;
          *" --hub "*) refuse 2 "join incomplete; retry with the original hub and name" ;;
        esac
      fi
      case "\${JT_PROBE:-unknown}" in
        live) ;;
        down) refuse 4 "join incomplete; hub unavailable or returned an invalid response; rerun join" ;;
        revoked) [ "\$rep" = 1 ] && [ -n "\$got" ] || refuse 3 "revoked: run machine add again" ;;
        *) [ -n "\$got" ] || refuse 2 "join incomplete; original join token required on stdin" ;;
      esac
      "$(command -v rm)" -f "\$JT_PENDING"
      joined
      exit 0
    fi
    if [ -f "\$JT_REVOKED" ]; then
      if [ "\$rep" = 1 ] && [ -n "\$got" ]; then
        "$(command -v rm)" -f "\$JT_REVOKED"
        joined
      else
        printf '{"joined": false, "alreadyJoined": true}\n'
      fi
      exit 0
    fi
    code="\${JT_JOIN_EXIT:-0}"
    # The error echoes a token-shaped value and the token read from stdin:
    # the script's redaction is what keeps both off disk and out of output.
    [ "\$code" = 0 ] || { echo "\${JT_JOIN_ERR:-acpmux: join failed} (cmj_LeakedInError \$got)" >&2; exit "\$code"; }
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
  # Claude Code's installer puts a fake claude in ~/.local/bin; `auth status`
  # says signed in when ~/claude-in exists. The fake codex reads ~/codex-in.
  cat >"$1/claude-install.sh" <<EOS
mkdir -p "\$HOME/.local/bin"
cat >"\$HOME/.local/bin/claude" <<'EOC'
#!/bin/sh
. "$fakes/record.sh"
case "\$*" in
  "auth status") if [ -f "\$HOME/claude-in" ]; then echo '{"loggedIn": true, "email": "x@example.com"}'; else echo '{"loggedIn": false}'; exit 1; fi ;;
esac
EOC
chmod 755 "\$HOME/.local/bin/claude"
EOS
  cat >"$1/codex" <<EOS
#!/bin/sh
. "$fakes/record.sh"
case "\$*" in
  "login status") [ -f "\$HOME/codex-in" ] ;;
esac
EOS
  chmod 755 "$1/codex"
  # The managed runtime's path has a space in it, as ~/Library/Application Support does.
  mkdir -p "$1/codex dir"
  cp "$1/codex" "$1/codex dir/codex"
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
  JT_JOIN_EXIT=0 JT_DOCTOR=0 JT_SERVICE=1 JT_PROBE=unknown JT_JOIN_ERR=""
  JT_VAULT=fail JT_CODEX_RT=0 JT_SVC=ok JT_RESTART=ok
  : >"$d/log/argv"
}

# run_join FORM [extra VAR=value...]: FORM env | arg | none.
run_join() {
  form="$1"
  shift
  set -- env -i HOME="$d/home" PATH="$shims" TMPDIR="$d/tmp" SHELL=/bin/bash \
    JT_LOG="$d/log" JT_SERVE="$d/serve" JT_STATE="$d/home/joined" \
    JT_OS="$JT_OS" JT_ARCH="$JT_ARCH" JT_CAPS="$JT_CAPS" JT_JOIN_EXIT="$JT_JOIN_EXIT" \
    JT_DOCTOR="$JT_DOCTOR" JT_SERVICE="$JT_SERVICE" JT_PROBE="$JT_PROBE" JT_JOIN_ERR="$JT_JOIN_ERR" \
    JT_PENDING="$d/home/pending" JT_REVOKED="$d/home/revoked" \
    JT_VAULT="$JT_VAULT" JT_CODEX_RT="$JT_CODEX_RT" JT_SVC="$JT_SVC" JT_RESTART="$JT_RESTART" \
    CMUX_PLATFORM_URL="$origin" "$@"
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
      3)
        check "3 line" out_has "this line was used or expired; make a new one: cmux machine add (or Add Machine in the app)"
        check "3 shows acpmux's own error, redacted" out_has "acpmux: join failed ([redacted token] [redacted token])"
        ;;
      4) check "4 line" out_has "cannot reach $origin: check this machine's outbound HTTPS, then paste a new line" ;;
      5) check "5 line" out_has "could not store the machine credential in /h/.acpmux/machine-credential.json: free disk / fix permissions, then paste a new line" ;;
    esac
  done

  # An exit 3 that is not a revocation shows acpmux's reason, never a token.
  new_case exit-3-replacement-refused
  JT_JOIN_EXIT=3
  JT_JOIN_ERR="existing enrollment cannot authorize replacement"
  run_join env CMUX_JOIN_REPLACE=1
  check "replacement refused: exit 3 (got $rc)" rc_is 3
  check "replacement refused: acpmux's reason is shown" out_has "existing enrollment cannot authorize replacement"
  check "replacement refused: the token on stdin was redacted from it" out_has "([redacted token] [redacted token])"
  check "replacement refused: no token in output" no_token_in_output
  check "replacement refused: no token on disk" no_token_on_disk

  # A resume whose hub cannot be reached: rerun the same line (a new one
  # carries another token, and recovery needs the original), naming no origin.
  for form in env none; do
    new_case "incomplete-hub-down-$form"
    : >"$d/home/pending"
    JT_PROBE=down
    run_join "$form"
    check "resume, hub down ($form): exit 4 (got $rc)" rc_is 4
    check "resume, hub down ($form): rerun the same line" out_has "the hub could not be reached; rerun the same line once this machine's outbound HTTPS works"
    check "resume, hub down ($form): never asks for a new line" eval '! out_has "paste a new line"'
    check "resume, hub down ($form): names no origin" eval '! out_has "$origin"'
    check "resume, hub down ($form): pending kept" test -e "$d/home/pending"
    check "resume, hub down ($form): no token in output" no_token_in_output
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

  new_case service
  run_join env
  check "service: exit 0 (got $rc)" rc_is 0
  check "service: installed" grep -q "^acpmux daemon service install" "$d/log/argv"
  check "service: before the daemon starts" eval '[ "$(grep -n "^acpmux daemon service install" "$d/log/argv" | head -n 1 | cut -d: -f1)" -lt "$(grep -n "^acpmux daemon start" "$d/log/argv" | head -n 1 | cut -d: -f1)" ]'
  check "service: says where it stands" out_has "cmux join: acpmux.service runs"
  check "service: no warning" eval '! grep -q "did not install" "$d/out"'

  new_case service-fails
  JT_SVC=fail
  run_join env
  check "service fails: still joins (got $rc)" rc_is 0
  check "service fails: warns with acpmux's words" out_has "warning: the acpmux service did not install: launchd did not load com.acpmux.daemon"
  check "service fails: daemon start" grep -q "^acpmux daemon start" "$d/log/argv"

  new_case restart-fails
  JT_RESTART=fail
  run_join env
  check "restart fails: still joins (got $rc)" rc_is 0
  check "restart fails: says the daemon has no heartbeat yet" out_has "did not restart onto the join, so it sends no heartbeat yet"

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

  # A join cut off after redeem (joinIncomplete) wins over a present
  # credential: the rerun resumes through acpmux, never "already joined".
  new_case incomplete-over-credential
  : >"$d/home/joined"
  : >"$d/home/pending"
  run_join env
  check "incomplete+credential: exit 0 (got $rc): $(cat "$d/out")" rc_is 0
  check "incomplete+credential: resumes through acpmux host join" test -s "$d/log/joins"
  check "incomplete+credential: never says already joined" eval '! out_has "already joined"'
  check "incomplete+credential: says it resumes" out_has "resuming a join that did not finish"
  check "incomplete+credential: the resume keeps the pending name (no --name)" eval '! grep -q -- "--name" "$d/log/joins"'
  check "incomplete+credential: the join finished" test ! -e "$d/home/pending"
  check "incomplete+credential: token on stdin, once" token_on_stdin_once
  check "incomplete+credential: no cmj_ in any argv" no_token_in_argv
  check "incomplete+credential: no env leak" no_env_leak
  check "incomplete+credential: no token in output" no_token_in_output

  # With no line at all, acpmux recovers the pending proposal from the hub.
  new_case incomplete-no-token
  : >"$d/home/joined"
  : >"$d/home/pending"
  JT_PROBE=live
  run_join none
  check "incomplete, no token: exit 0 (got $rc): $(cat "$d/out")" rc_is 0
  check "incomplete, no token: one resume" test "$(wc -l <"$d/log/joins")" -eq 1
  check "incomplete, no token: nothing on stdin" no_redeem
  check "incomplete, no token: the join finished" test ! -e "$d/home/pending"
  check "incomplete, no token: says joined" out_has "cmux join: joined"
  check "incomplete, no token: never says already joined" eval '! out_has "already joined"'

  # A tokenless resume asks the pending proposal's own hub (no --hub), so a
  # join started against another platform origin still recovers.
  new_case incomplete-other-hub
  printf '%s\n' "https://other.example.test" >"$d/home/pending"
  JT_PROBE=live
  run_join none
  check "incomplete, other hub: exit 0 (got $rc): $(cat "$d/out")" rc_is 0
  check "incomplete, other hub: no --hub on a tokenless resume" eval '! grep -q -- "--hub" "$d/log/joins"'
  check "incomplete, other hub: the join finished" test ! -e "$d/home/pending"
  # With a token, the token goes only to this script's origin.
  new_case incomplete-other-hub-token
  printf '%s\n' "https://other.example.test" >"$d/home/pending"
  run_join env
  check "incomplete, other hub, token: refused (got $rc)" rc_is 2
  check "incomplete, other hub, token: --hub is this origin" grep -q -- "--hub $origin" "$d/log/joins"
  check "incomplete, other hub, token: says so" out_has "the join that did not finish could not resume"
  check "incomplete, other hub, token: no token in output" no_token_in_output
  check "incomplete, other hub, token: no token on disk" no_token_on_disk

  # The hub does not know the proposal yet and there is no line: ask for it.
  new_case incomplete-needs-line
  : >"$d/home/pending"
  run_join none
  check "incomplete, needs line: exit 2 (got $rc)" rc_is 2
  check "incomplete, needs line: says so" out_has "the join that did not finish could not resume: paste the same line again"
  check "incomplete, needs line: pending kept" test -e "$d/home/pending"

  # The hub revoked the pending proposal: the fresh line goes in with --replace.
  new_case incomplete-revoked
  : >"$d/home/pending"
  JT_PROBE=revoked
  run_join env
  check "incomplete, revoked: exit 0 (got $rc): $(cat "$d/out")" rc_is 0
  check "incomplete, revoked: retried with --replace" test "$(sed -n 2p "$d/log/joins" | grep -c -- "--replace")" -eq 1
  check "incomplete, revoked: the first try had no --replace" eval '! sed -n 1p "$d/log/joins" | grep -q -- "--replace"'
  check "incomplete, revoked: the token only ever on stdin" eval '[ "$(sort -u "$d/log/join-stdin")" = "$token" ]'
  check "incomplete, revoked: no cmj_ in any argv" no_token_in_argv
  check "incomplete, revoked: no env leak: $(cat "$d/log/env-leak" 2>/dev/null)" no_env_leak
  check "incomplete, revoked: no token in output" no_token_in_output
  check "incomplete, revoked: no token on disk" no_token_on_disk
  new_case incomplete-revoked-no-token
  : >"$d/home/pending"
  JT_PROBE=revoked
  run_join none
  check "incomplete, revoked, no token: exit 3 (got $rc)" rc_is 3
  check "incomplete, revoked, no token: asks for a new line" out_has "enrollment was revoked or has expired; paste a new line: cmux machine add"

  # A revoked enrollment: the fresh token re-enrolls with --replace, on stdin.
  for form in env arg; do
    new_case "revoked-$form"
    : >"$d/home/joined"
    : >"$d/home/revoked"
    run_join "$form"
    check "revoked ($form): exit 0 (got $rc): $(cat "$d/out")" rc_is 0
    check "revoked ($form): joins with --replace" grep -q -- "--replace" "$d/log/joins"
    check "revoked ($form): re-enrolled" test ! -e "$d/home/revoked"
    check "revoked ($form): never says already joined" eval '! out_has "already joined"'
    check "revoked ($form): token on stdin, once" token_on_stdin_once
    check "revoked ($form): no cmj_ in any argv" no_token_in_argv
    check "revoked ($form): no env leak: $(cat "$d/log/env-leak" 2>/dev/null)" no_env_leak
    check "revoked ($form): no token in output" no_token_in_output
  done
  new_case revoked-no-token
  : >"$d/home/joined"
  : >"$d/home/revoked"
  run_join none
  check "revoked, no token: exit 3 (got $rc)" rc_is 3
  check "revoked, no token: asks for a new line" out_has "enrollment was revoked or has expired; paste a new line: cmux machine add"
  check "revoked, no token: no join attempted" test ! -e "$d/log/joins"

  # Once joined: Claude Code from its own installer, Codex from acpmux's
  # runtime (macOS), and a sign-in line for each, through its own flow.
  new_case harnesses
  JT_OS=Darwin JT_ARCH=arm64 JT_CODEX_RT=1
  run_join env
  check "harnesses: exit 0 (got $rc): $(cat "$d/out")" rc_is 0
  check "harnesses: claude's own installer fetched" grep -q "^curl .*https://claude.ai/install.sh" "$d/log/argv"
  check "harnesses: claude installed" test -x "$d/home/.local/bin/claude"
  check "harnesses: says so" out_has "installed Claude Code"
  check "harnesses: codex through acpmux's runtime" grep -q "^acpmux harness codex-runtime install" "$d/log/argv"
  check "harnesses: claude sign-in line" out_has "sign in to Claude Code: run '$d/home/.local/bin/claude' here and sign in with its /login"
  check "harnesses: codex sign-in line" out_has "sign in to Codex: run '$d/serve/codex dir/codex' login here"
  check "harnesses: no login was run without a terminal" eval '! grep -q "auth login\|^codex login$" "$d/log/argv"'
  check "harnesses: the sign-in is last" eval '[ "$(tail -n 1 "$d/out")" = "cmux join: sign in to Codex: run '"'"'$d/serve/codex dir/codex'"'"' login here" ]'
  check "harnesses: no env leak: $(cat "$d/log/env-leak" 2>/dev/null)" no_env_leak
  check "harnesses: no cmj_ in any argv" no_token_in_argv
  check "harnesses: no token in output" no_token_in_output

  # Signed in already: said so, nothing offered.
  new_case harnesses-signed-in
  JT_OS=Darwin JT_ARCH=arm64 JT_CODEX_RT=1
  : >"$d/home/claude-in"
  : >"$d/home/codex-in"
  run_join env
  check "signed in: exit 0 (got $rc)" rc_is 0
  check "signed in: claude" out_has "Claude Code is signed in"
  check "signed in: codex" out_has "Codex is signed in"
  check "signed in: the runtime path with a space was used" grep -q "^codex login status" "$d/log/argv"
  check "signed in: no sign-in line" eval '! out_has "sign in to"'
  check "signed in: nothing of claude's status is shown" eval '! out_has "x@example.com"'

  new_case harnesses-none
  run_join env CMUX_JOIN_HARNESSES=none
  check "none: exit 0 (got $rc)" rc_is 0
  check "none: no installer" eval '! grep -q "claude.ai" "$d/log/argv"'
  check "none: no codex" eval '! grep -q "codex" "$d/log/argv"'
  check "none: no sign-in" eval '! out_has "sign in to"'

  new_case harnesses-linux
  run_join env CMUX_JOIN_HARNESSES=codex
  check "linux codex: exit 0 (got $rc)" rc_is 0
  check "linux codex: says how" out_has "Codex is not installed: npm install -g @openai/codex"
  check "linux codex: no claude" eval '! grep -q "claude.ai" "$d/log/argv"'

  new_case harnesses-bad
  run_join env CMUX_JOIN_HARNESSES='claude;rm'
  check "bad harnesses: exit 2 (got $rc)" rc_is 2
  check "bad harnesses: nothing redeemed" no_redeem

  # A repair run of a machine that never joined installs no harness and pulls nothing.
  new_case not-joined-repair
  JT_CAPS="acpmux-v1 machine.join.stdin.v1 machine.vault.pull.v1"
  JT_VAULT=ok
  run_join none
  check "repair: exit 0 (got $rc)" rc_is 0
  check "repair: no installer" eval '! grep -q "claude.ai" "$d/log/argv"'
  check "repair: no vault pull" eval '! grep -q "host vault pull" "$d/log/argv"'

  # The vault: names and a count, never anything else acpmux says.
  new_case vault-ok
  JT_CAPS="acpmux-v1 machine.join.stdin.v1 machine.vault.pull.v1"
  JT_VAULT=ok
  run_join env CMUX_JOIN_HARNESSES=none
  check "vault ok: exit 0 (got $rc): $(cat "$d/out")" rc_is 0
  check "vault ok: pulled" grep -q "^acpmux host vault pull --json" "$d/log/argv"
  check "vault ok: names and count" out_has "vault: 2 env vars (OPENAI_API_KEY GITHUB_TOKEN)"
  check "vault ok: nothing else" eval '! out_has "sk-must-not-print"'
  check "vault ok: acpmux's answer never reached disk" eval '! grep -rq --exclude=acpmux "sk-must-not-print" "$d/tmp"'
  check "vault ok: no env leak" no_env_leak

  new_case vault-not-granted
  JT_CAPS="acpmux-v1 machine.join.stdin.v1 machine.vault.pull.v1"
  JT_VAULT=not_granted
  run_join env CMUX_JOIN_HARNESSES=none
  check "vault not granted: still exit 0 (got $rc)" rc_is 0
  check "vault not granted: says how" out_has "vault: not shared with this machine (from your Mac: cmux machine vault grant"

  new_case vault-fail
  JT_CAPS="acpmux-v1 machine.join.stdin.v1 machine.vault.pull.v1"
  JT_VAULT=fail
  run_join env CMUX_JOIN_HARNESSES=none
  check "vault fail: still exit 0 (got $rc)" rc_is 0
  check "vault fail: warns with the exit code only" out_has "the vault pull did not finish (acpmux exit 1)"
  check "vault fail: acpmux's words are not shown" eval '! out_has "sk-must-not-print"'

  new_case vault-off
  JT_CAPS="acpmux-v1 machine.join.stdin.v1 machine.vault.pull.v1"
  JT_VAULT=off
  run_join env CMUX_JOIN_HARNESSES=none
  check "vault off: exit 0 (got $rc)" rc_is 0
  check "vault off: says nothing of the vault" eval '! grep -q "vault:\|vault pull" "$d/out"'

  new_case vault-partial
  JT_CAPS="acpmux-v1 machine.join.stdin.v1 machine.vault.pull.v1"
  JT_VAULT=partial
  run_join env CMUX_JOIN_HARNESSES=none
  check "vault partial: the join still exits 0 (got $rc)" rc_is 0
  check "vault partial: warns with names" out_has "warning: the vault pull got 1 env vars (OPENAI_API_KEY), not all of them"
  check "vault partial: nothing else" eval '! out_has "sk-must-not-print"'

  new_case vault-no-capability
  JT_VAULT=ok
  run_join env CMUX_JOIN_HARNESSES=none
  check "no vault capability: no pull" eval '! grep -q "host vault pull" "$d/log/argv"'

  # The sign-in step alone (`machine add USER@HOST` runs it over ssh -t).
  new_case signin-step
  HOME="$d/home" sh "$d/serve/claude-install.sh"
  run_join none CMUX_JOIN_STEP=signin
  check "signin step: exit 0 (got $rc): $(cat "$d/out")" rc_is 0
  check "signin step: the claude line" out_has "sign in to Claude Code: run '$d/home/.local/bin/claude' here"
  check "signin step: no download, no join" eval '! grep -q "^curl\|host join" "$d/log/argv"'
  run_join env CMUX_JOIN_STEP=signin
  check "signin step with a token: exit 2 (got $rc)" rc_is 2
  check "signin step with a token: no token in output" no_token_in_output
  run_join none CMUX_JOIN_STEP=bogus
  check "unknown step: exit 2 (got $rc)" rc_is 2

  new_case unsupported
  JT_OS=FreeBSD
  run_join env
  check "unsupported exit 1 (got $rc)" rc_is 1
  check "unsupported line" out_has "unsupported platform FreeBSD-x86_64"
}

# The checks are live: a copy that passes the token in argv must fail them.
mutant="$root/mutant.sh"
sed 's/^\( *\)printf .%s\\n. "\$t" | "\$acpmux" "\$@"/\1"$acpmux" "$@" "$t" <\/dev\/null/' "$script" >"$mutant"
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
