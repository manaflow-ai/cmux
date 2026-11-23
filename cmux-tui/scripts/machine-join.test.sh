#!/bin/sh
# Tests machine-join.sh with no network and no real acpmux:
#   sh cmux-tui/scripts/machine-join.test.sh
# Every command the script runs resolves through a recording shim (argv,
# and whether CMUX_JOIN or any cmj_ value is in its environment) before the
# real tool runs; curl is a fake that serves a fixture channel, and the
# acpmux it "downloads" is a fake that records its argv and stdin. Runs the
# script under sh, and under bash --posix and dash when present. On Linux the
# CLI (and, in phase 1b, acpmux) come from a signed release file: the script
# runs with a generated test key in place of the release keys
# (linux-release-verify-gen.py --render), and serve_dir signs the fixture.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
root="$(mktemp -d "${TMPDIR:-/tmp}/machine-join-test.XXXXXX")"
trap 'rm -rf "$root"' EXIT INT TERM
. "$here/linux-release-fixture.sh"
lrf_key "$root/key"
script="$root/machine-join.sh"
python3 "$here/linux-release-verify-gen.py" --render "$here/machine-join.sh" --keys "$root/key/keys.json" >"$script"

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
for tool in awk basename bash cat chmod cp cut date dirname grep head hostname id install loginctl \
  mkdir mktemp mv openssl rm sed shasum sha256sum sort tr uniq wc launchctl systemctl; do
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
# install and mv of cmux-rd's temp file fail when ~/rd-install-fail or ~/rd-mv-fail
# exists: a ~/.local/bin that cannot be written (read-only, or a full disk).
for tool in install mv; do
  real="$(command -v "$tool")"
  {
    printf '#!/bin/sh\n'
    printf '. "%s/record.sh"\n' "$fakes"
    printf 'case "$*" in *.cmux-rd.new*) [ ! -f "$HOME/rd-%s-fail" ] || { echo "%s: Read-only file system" >&2; exit 1; } ;; esac\n' "$tool" "$tool"
    # With ~/rd-install-changes, the copy in bin is not the file that was checked (another
    # writer of ~/.local/bin, a disk that flipped a byte): it must not be moved into place.
    if [ "$tool" = install ]; then
      printf 'case "$*" in *.cmux-rd.new*) if [ -f "$HOME/rd-install-changes" ]; then "%s" "$@" || exit; eval "last=\\${$#}"; echo changed >>"$last"; exit 0; fi ;; esac\n' "$real"
      # With ~/rd-dir-appears, a directory appears where cmux-rd goes after the script
      # looked (another writer of ~/.local/bin): nothing may be moved inside it.
      printf 'case "$*" in *.cmux-rd.new*) if [ -f "$HOME/rd-dir-appears" ]; then "%s" "$@" || exit; eval "last=\\${$#}"; mkdir -p "${last%%/*}/cmux-rd"; exit 0; fi ;; esac\n' "$real"
    fi
    printf 'exec "%s" "$@"\n' "$real"
  } >"$shims/$tool"
  chmod 755 "$shims/$tool"
done
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

# The fake systemctl: JT_UNIT=1 has acpmux.service loaded, and JT_UNIT_UP=0
# keeps it from coming up; otherwise nothing is loaded and every call is a no-op.
cat >"$shims/systemctl" <<EOF
#!/bin/sh
. "$fakes/record.sh"
[ "\${JT_UNIT:-0}" = 1 ] || exit 0
case "\$*" in
  "--user show -p LoadState --value acpmux.service") echo loaded ;;
  "--user is-active --quiet acpmux.service") [ "\${JT_UNIT_UP:-1}" = 1 ] ;;
esac
EOF
chmod 755 "$shims/systemctl"

# sleep records its argv and returns at once: a retry's wait costs the suite nothing.
cat >"$shims/sleep" <<EOF
#!/bin/sh
. "$fakes/record.sh"
EOF
chmod 755 "$shims/sleep"

# The fake curl: serves \$JT_SERVE/<kind> by the URL's shape, honours -o.
# \$JT_LOG/curl-fails, one curl exit code per line: the acpmux download
# fails with each in turn (a reset is 56, an HTTP status 22), then succeeds.
cat >"$shims/curl" <<EOF
#!/bin/sh
. "$fakes/record.sh"
out=""
url=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    --proto | --proto-redir | --max-filesize | --max-time) shift 2 ;;
    -*) shift ;;
    *) url="\$1"; shift ;;
  esac
done
case "\$url" in
  https://files.cmux.com/cmux-tui/channels/linux-*.json) src="\$JT_SERVE/linux-channel.json" ;;
  https://files.cmux.com/cmux-tui/channels/*.json) src="\$JT_SERVE/channel.json" ;;
  https://files.cmux.com/cmux-tui/tree/*/cmux-tui-acpmux-*) src="\$JT_SERVE/acpmux" ;;
  https://files.cmux.com/cmux-tui/tree/*/cmux-tui-rd-*) src="\$JT_SERVE/cmux-rd" ;;
  https://files.cmux.com/cmux-tui/latest/manifest.json) src="\$JT_SERVE/manifest.json" ;;
  https://files.cmux.com/cmux-tui/*/cmux-tui-*) src="\$JT_SERVE/cmux" ;;
  https://claude.ai/install.sh) src="\$JT_SERVE/claude-install.sh" ;;
  *) exit 6 ;;
esac
case "\$url" in
  */tree/*/cmux-tui-acpmux-*)
    if [ -s "\$JT_LOG/curl-fails" ]; then
      code="\$("$(command -v head)" -n 1 "\$JT_LOG/curl-fails")"
      "$(command -v sed)" 1d "\$JT_LOG/curl-fails" >"\$JT_LOG/curl-fails.next"
      "$(command -v mv)" "\$JT_LOG/curl-fails.next" "\$JT_LOG/curl-fails"
      exit "\$code"
    fi ;;
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
  "host doctor --here --fix") echo '{"step":"credential","state":"ok"}' ;;
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
# serve_dir DIR [WRONG_SHA [RD_SHA]]: RD_SHA "none" leaves cmux-rd out of the
# channel; another value is the channel's cmux-rd sha256 instead of the served one's.
serve_dir() {
  mkdir -p "$1"
  cp "$root/acpmux.src" "$1/acpmux"
  s="$(sha "$1/acpmux")"
  [ -z "${2:-}" ] || s="$2"
  # The fake cmux-rd, served at tree/<key>/cmux-tui-rd-<target>: it records its
  # argv; `openh264-install` fails when ~/oh264-fail exists.
  cat >"$1/cmux-rd" <<EOS
#!/bin/sh
. "$fakes/record.sh"
# the channel's cmux-rd
case "\$1" in openh264-install) [ ! -f "\$HOME/oh264-fail" ] ;; esac
EOS
  r="$(sha "$1/cmux-rd")"
  [ -z "${3:-}" ] || r="$3"
  rd_lines=""
  if [ "$r" != none ]; then
    rd_lines="
    \"cmux-tui-rd-aarch64-unknown-linux-gnu\": \"$r\",
    \"cmux-tui-rd-x86_64-unknown-linux-gnu\": \"$r\","
  fi
  cat >"$1/channel.json" <<EOF
{
  "binaries": {
    "cmux-tui-acpmux-aarch64-apple-darwin": "$s",
    "cmux-tui-acpmux-aarch64-unknown-linux-musl": "$s",$rd_lines
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
  sign_channel "$1" 1
}

# sign_channel DIR PHASE: DIR/linux-channel.json, the signed release file of
# feat-cmux-next (cmuxterm-hq docs/design/linux-signed-packages.md). Phase 1
# names cmux-tui for the gnu targets only; phase 1b adds a sequence, a
# tree_key, URLs under tree/<key>/ and cmux-tui-acpmux for the musl targets.
sign_channel() {
  commit=a6d89d443f5f9ffb66c296d7a9680e307bbe6c58
  tree=121e0512465089798aba4eea7eba48644ecac9a9
  if [ "$2" = 1 ]; then
    base="https://files.cmux.com/cmux-tui/$commit"
    extra=""
    musl=""
  else
    base="https://files.cmux.com/cmux-tui/tree/$tree"
    extra='"sequence":20261102000000,'
    musl=""
    for t in x86_64-unknown-linux-musl aarch64-unknown-linux-musl; do
      musl="$musl,\"$t\":{$(lrf_entry cmux-tui-acpmux "$base/cmux-tui-acpmux-$t" "$1/acpmux")}"
    done
  fi
  targets=""
  for t in x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu; do
    targets="$targets${targets:+,}\"$t\":{$(lrf_entry cmux-tui "$base/cmux-tui-$t" "$1/cmux")}"
  done
  printf '{"channel":"feat-cmux-next","commit":"%s","expires_at":%s,"purpose":"cmux-linux-release","schema":1,%s"targets":{%s%s},%s"version":"1.0.0+20261101000000.a6d89d443f5f"}' \
    "$commit" "$(($(date +%s) + 86400))" "$extra" "$targets" "$musl" "$([ "$2" = 1 ] || printf '"tree_key":"%s",' "$tree")" >"$1/linux-payload.json"
  lrf_sign "$1/linux-payload.json" "$root/key" "$1/linux-channel.json"
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
  JT_VAULT=fail JT_CODEX_RT=0 JT_SVC=ok JT_RESTART=ok JT_UNIT=0 JT_UNIT_UP=1
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
    JT_UNIT="$JT_UNIT" JT_UNIT_UP="$JT_UNIT_UP" CMUX_PLATFORM_URL="$origin" "$@"
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
fetched_rd() { grep -q '^curl .*tree/.*/cmux-tui-rd-' "$d/log/argv"; }
rd_is_channels() {
  f="$d/home/.local/bin/cmux-rd"
  [ -f "$f" ] && [ ! -L "$f" ] && [ "$(sha "$f")" = "$(sha "$d/serve/cmux-rd")" ] &&
    [ "$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")" = 755 ]
}
rd_state() { printf '%s' "$d/home/.acpmux/share-host/cmux-rd-install"; }
rd_lines() { grep -c 'cmux-rd did not install' "$d/out"; }
# An earlier cmux-rd in place, which a failure must leave as it is.
old_rd() {
  mkdir -p "$d/home/.local/bin"
  printf '#!/bin/sh\n# the old cmux-rd\n' >"$d/home/.local/bin/cmux-rd"
  chmod 755 "$d/home/.local/bin/cmux-rd"
}
old_rd_kept() { grep -q "the old cmux-rd" "$d/home/.local/bin/cmux-rd"; }

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
  check "linux: cmux-rd installed from the channel" rd_is_channels
  check "linux: says the screen is shared with nothing to do" out_has "Your own account can view this machine's screen from your other devices, with nothing to do here."
  check "linux: no consent line (cmux-rd's host serves your own account)" eval '! out_has "Screen sharing and control are off"'
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

  # A transport reset is retried (run 44192875334: a 23 s blip reset every
  # connection); an HTTP status the server sent is not.
  new_case fetch-reset
  printf '56\n56\n' >"$d/log/curl-fails"
  run_join env
  check "two resets, then the download: exit 0 (got $rc): $(cat "$d/out")" rc_is 0
  check "one line per retry" test "$(grep -c 'retrying in' "$d/out")" = 2
  check "the retry line names the curl exit" out_has "(curl exit 56); retrying in 2 s"
  check "waits 2 s, then 8 s" test "$(grep '^sleep' "$d/log/argv" | tr '\n' ' ')" = "sleep 2 sleep 8 "
  check "three tries of the download" test "$(grep -c '^curl .*tree/.*/cmux-tui-acpmux-' "$d/log/argv")" = 3
  check "acpmux installed" installed
  check "the token reaches acpmux on stdin, once" token_on_stdin_once
  check "no token in output" no_token_in_output

  new_case fetch-reset-gives-up
  printf '56\n7\n28\n35\n' >"$d/log/curl-fails"
  run_join env
  check "four transport failures: exit 1 (got $rc)" rc_is 1
  check "it stops after four tries" test "$(grep -c '^curl .*tree/.*/cmux-tui-acpmux-' "$d/log/argv")" = 4
  check "waits 2, 8 and 20 s" test "$(grep '^sleep' "$d/log/argv" | tr '\n' ' ')" = "sleep 2 sleep 8 sleep 20 "
  check "it says the download failed" out_has "cannot download acpmux for x86_64-unknown-linux-musl"
  check "nothing installed" eval '! installed'
  check "nothing redeemed" no_redeem

  new_case fetch-http-status
  printf '22\n' >"$d/log/curl-fails"
  run_join env
  check "an HTTP status: exit 1 (got $rc)" rc_is 1
  check "an HTTP status is not retried" test "$(grep -c '^curl .*tree/.*/cmux-tui-acpmux-' "$d/log/argv")" = 1
  check "no wait" eval '! grep -q "^sleep" "$d/log/argv"'
  check "no retry line" eval '! out_has "retrying in"'
  check "nothing redeemed" no_redeem

  new_case sha-mismatch
  serve_dir "$d/serve" "0000000000000000000000000000000000000000000000000000000000000000"
  run_join env
  check "mismatch fails (got $rc)" rc_is 1
  check "mismatch says so" out_has "checksum verification failed for acpmux"
  check "a mismatch is not retried" test "$(grep -c '^curl .*tree/.*/cmux-tui-acpmux-' "$d/log/argv")" = 1
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
  check "replace and redeem restart the daemon once, not twice" test "$(grep -c "^acpmux daemon restart" "$d/log/argv")" = 1
  check "token on stdin of the verified binary" token_on_stdin_once

  # acpmux.prev still runs (processes started before an earlier update): on
  # Linux, writing over it fails with "Text file busy"; the join goes on.
  if [ "$(uname -s)" = Linux ]; then
    new_case prev-busy
    bin="$d/home/.local/bin"
    mkdir -p "$bin"
    { cat "$root/acpmux.src"; echo "# a different build"; } >"$bin/acpmux"
    chmod 755 "$bin/acpmux"
    cp "$(command -v sleep)" "$bin/acpmux.prev"
    chmod 755 "$bin/acpmux.prev"
    "$bin/acpmux.prev" 120 &
    busy=$!
    tries=0
    while [ "$(readlink "/proc/$busy/exe" 2>/dev/null)" != "$bin/acpmux.prev" ] && [ "$tries" -lt 50 ]; do
      sleep 0.1
      tries=$((tries + 1))
    done
    # Live: the copy-over this replaced fails on this file.
    check "prev-busy: acpmux.prev is running, so cp over it fails" eval '! cp "$bin/acpmux" "$bin/acpmux.prev" 2>/dev/null'
    run_join env
    kill "$busy" 2>/dev/null || :
    wait "$busy" 2>/dev/null || :
    check "prev-busy: exit 0 (got $rc): $(cat "$d/out")" rc_is 0
    check "prev-busy: the channel build replaced it" test "$(sha "$bin/acpmux")" = "$(sha "$d/serve/acpmux")"
    check "prev-busy: the old one kept as acpmux.prev" grep -q "a different build" "$bin/acpmux.prev"
    check "prev-busy: no staged copy left" test ! -e "$bin/.acpmux.prev.new"
    check "prev-busy: token on stdin" token_on_stdin_once
  fi

  # systemd's acpmux.service runs the daemon: restarts go through it after
  # reset-failed, once per run (two within seconds hit its start limit).
  new_case unit-replace-join
  JT_UNIT=1
  mkdir -p "$d/home/.local/bin"
  { cat "$root/acpmux.src"; echo "# a different build"; } >"$d/home/.local/bin/acpmux"
  chmod 755 "$d/home/.local/bin/acpmux"
  run_join env
  check "unit: exit 0 (got $rc): $(cat "$d/out")" rc_is 0
  check "unit: one systemd restart" test "$(grep -c "^systemctl --user restart acpmux.service" "$d/log/argv")" = 1
  check "unit: reset-failed before it" grep -q "^systemctl --user reset-failed acpmux.service" "$d/log/argv"
  check "unit: never acpmux daemon restart or start" eval '! grep -qE "^acpmux daemon (restart|start)" "$d/log/argv"'
  check "unit: the restart comes after the redeem" eval '[ "$(grep -n "^acpmux host join --hub" "$d/log/argv" | head -n 1 | cut -d: -f1)" -lt "$(grep -n "^systemctl --user restart" "$d/log/argv" | cut -d: -f1)" ]'
  check "unit: says it is active" out_has "restarted acpmux.service; it is active"
  : >"$d/log/argv"
  run_join env
  check "unit re-run: exit 0 (got $rc)" rc_is 0
  check "unit re-run: no restart" eval '! grep -q "^systemctl --user restart" "$d/log/argv"'

  # A replaced binary on a joined machine (nothing redeemed) still restarts, once.
  new_case unit-replace-joined
  JT_UNIT=1
  mkdir -p "$d/home/.local/bin"
  { cat "$root/acpmux.src"; echo "# a different build"; } >"$d/home/.local/bin/acpmux"
  chmod 755 "$d/home/.local/bin/acpmux"
  : >"$d/home/joined"
  run_join env
  check "unit, joined: exit 0 (got $rc): $(cat "$d/out")" rc_is 0
  check "unit, joined: nothing redeemed" no_redeem
  check "unit, joined: one systemd restart" test "$(grep -c "^systemctl --user restart acpmux.service" "$d/log/argv")" = 1

  # The unit does not come back: fail with the way out.
  new_case unit-down
  JT_UNIT=1
  JT_UNIT_UP=0
  run_join env
  check "unit down: exit 1 (got $rc)" rc_is 1
  check "unit down: names reset-failed and start" out_has "systemctl --user reset-failed acpmux.service; systemctl --user start acpmux.service"

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
  # cmux-rd is installed, but nothing joined this machine: its screen is not shared.
  mkdir -p "$d/home/.local/bin"
  printf '#!/bin/sh\n. "%s/record.sh"\nexit 0\n' "$fakes" >"$d/home/.local/bin/cmux-rd"
  chmod 755 "$d/home/.local/bin/cmux-rd"
  run_join none
  check "no token: exit 0 (got $rc)" rc_is 0
  check "no token: installed" installed
  check "no token: service and daemon" grep -q "^acpmux daemon start" "$d/log/argv"
  check "no token: nothing redeemed" no_redeem
  check "no token, not joined: the screen is not shared" out_has "This machine is not joined, so its screen is not shared."
  check "no token, not joined: never says it is shared" eval '! out_has "Your own account can view this machine'"'"'s screen"'

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
  check "restart fails: says the daemon has no heartbeat yet" out_has "did not restart onto the new acpmux or the join, so it sends no heartbeat yet"

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
  check "macos: the consent line" out_has "Screen sharing and control are off on this machine."

  # Linux: cmux-rd from the channel, where the screen host unit runs it; the
  # daemon finds it and shares the screen with the joining account by itself.
  new_case linux-cmux-rd
  run_join env
  check "linux-cmux-rd exit 0 (got $rc): $(cat "$d/out")" rc_is 0
  check "linux-cmux-rd: fetched from the channel's tree" grep -q "^curl .*tree/121e0512465089798aba4eea7eba48644ecac9a9/cmux-tui-rd-x86_64-unknown-linux-gnu" "$d/log/argv"
  check "linux-cmux-rd: installed, mode 755, the channel's sha256" rd_is_channels
  check "linux-cmux-rd: through a temp name, moved into place" grep -q "^mv -f $d/home/.local/bin/.cmux-rd.new $d/home/.local/bin/cmux-rd" "$d/log/argv"
  check "linux-cmux-rd: says so" out_has "installed cmux-rd to $d/home/.local/bin/cmux-rd"
  check "linux-cmux-rd: no failure state" test ! -e "$(rd_state)"
  check "linux-cmux-rd: Cisco's OpenH264 fetched through cmux-rd" grep -q "^cmux-rd openh264-install" "$d/log/argv"
  check "linux-cmux-rd: cmux-rd only for openh264-install" eval '[ "$(grep -c "^cmux-rd" "$d/log/argv")" = 1 ]'
  check "linux-cmux-rd: before the vault and sign-in" eval '[ "$(grep -n "^cmux-rd openh264-install" "$d/log/argv" | cut -d: -f1)" -lt "$(grep -n "^acpmux host join --status$\|^acpmux host doctor" "$d/log/argv" | tail -n 1 | cut -d: -f1)" ]'
  check "linux-cmux-rd: your own account, nothing to do here" out_has "Your own account can view this machine's screen from your other devices, with nothing to do here. Other accounts can't reach it."
  check "linux-cmux-rd: no consent line" eval '! out_has "Screen sharing and control are off"'
  check "linux-cmux-rd: the daemon restarts onto the join" grep -q "^acpmux daemon restart" "$d/log/argv"
  check "linux-cmux-rd: no env leak" no_env_leak
  check "linux-cmux-rd: no cmj_ in any argv" no_token_in_argv
  # Again: the installed one already has the channel's sha256, so nothing is fetched.
  : >"$d/log/argv"
  run_join env
  check "linux-cmux-rd again: exit 0 (got $rc)" rc_is 0
  check "linux-cmux-rd again: no cmux-rd download" eval '! fetched_rd'
  check "linux-cmux-rd again: still the channel's" rd_is_channels

  # An older cmux-rd is replaced by the channel's, on aarch64 too.
  new_case linux-cmux-rd-update-arm64
  JT_ARCH=aarch64
  old_rd
  # Joined before (a repair run, no token): the rerun brings cmux-rd too.
  : >"$d/home/joined"
  run_join none
  check "rd update: exit 0 (got $rc): $(cat "$d/out")" rc_is 0
  check "rd update: the aarch64 gnu build" grep -q "^curl .*cmux-tui-rd-aarch64-unknown-linux-gnu" "$d/log/argv"
  check "rd update: replaced" rd_is_channels

  # A failed OpenH264 download is one warning; cmux-rd stays installed.
  new_case linux-cmux-rd-openh264-fails
  mkdir -p "$d/home"
  : >"$d/home/oh264-fail"
  run_join env
  check "openh264 fails: exit 0 (got $rc)" rc_is 0
  check "openh264 fails: installed anyway" rd_is_channels
  check "openh264 fails: one warning" eval '[ "$(grep -c "OpenH264 did not download" "$d/out")" = 1 ]'

  # The channel's sha256 is not the served file's: nothing replaced, the join goes on.
  new_case linux-cmux-rd-mismatch
  serve_dir "$d/serve" "" "1111111111111111111111111111111111111111111111111111111111111111"
  old_rd
  run_join env
  check "rd mismatch: the join still exits 0 (got $rc): $(cat "$d/out")" rc_is 0
  check "rd mismatch: joined" token_on_stdin_once
  check "rd mismatch: one line" eval '[ "$(rd_lines)" = 1 ]'
  check "rd mismatch: says checksum" out_has "cmux-rd did not install (checksum verification failed for cmux-rd"
  check "rd mismatch: the old cmux-rd untouched" old_rd_kept
  check "rd mismatch: no temp file left in bin" test ! -e "$d/home/.local/bin/.cmux-rd.new"
  check "rd mismatch: the state file holds the reason" grep -q "^checksum verification failed for cmux-rd" "$(rd_state)"
  check "rd mismatch: OpenH264 not fetched" eval '! grep -q "^cmux-rd openh264-install" "$d/log/argv"'
  # Then a channel that matches: installed, the state file gone.
  serve_dir "$d/serve"
  run_join none
  check "rd mismatch then ok: installed" rd_is_channels
  check "rd mismatch then ok: state file removed" test ! -e "$(rd_state)"

  # The download fails: the same.
  new_case linux-cmux-rd-fetch-fails
  rm "$d/serve/cmux-rd"
  run_join env
  check "rd fetch fails: the join still exits 0 (got $rc): $(cat "$d/out")" rc_is 0
  check "rd fetch fails: one line" eval '[ "$(rd_lines)" = 1 ]'
  check "rd fetch fails: says download" out_has "cmux-rd did not install (cannot download cmux-rd for x86_64-unknown-linux-gnu)"
  check "rd fetch fails: nothing installed" test ! -e "$d/home/.local/bin/cmux-rd"
  check "rd fetch fails: the state file holds the reason" grep -qx "cannot download cmux-rd for x86_64-unknown-linux-gnu" "$(rd_state)"
  check "rd fetch fails: step 8 says why the screen is not shared" out_has "This machine's screen is not shared: cmux-rd is not installed at $d/home/.local/bin/cmux-rd (cannot download cmux-rd for x86_64-unknown-linux-gnu)."
  # ACPMUX_HOME moves the state file with acpmux's home.
  run_join none ACPMUX_HOME="$d/home/other-acpmux"
  check "rd fetch fails, ACPMUX_HOME: state file there" test -f "$d/home/other-acpmux/share-host/cmux-rd-install"

  # A channel with no cmux-rd yet.
  new_case linux-cmux-rd-not-in-channel
  serve_dir "$d/serve" "" none
  old_rd
  run_join env
  check "rd not in channel: exit 0 (got $rc)" rc_is 0
  check "rd not in channel: one line" eval '[ "$(rd_lines)" = 1 ]'
  check "rd not in channel: says so" out_has "cmux-rd did not install (the feat-cmux-next channel has no cmux-rd build for x86_64-unknown-linux-gnu)"
  check "rd not in channel: nothing fetched" eval '! fetched_rd'
  check "rd not in channel: the old cmux-rd untouched" old_rd_kept
  check "rd not in channel: the state file holds the reason" grep -q "has no cmux-rd build" "$(rd_state)"

  # A symlinked cmux-rd (a test harness's own build) is kept.
  new_case linux-cmux-rd-symlink
  mkdir -p "$d/home/.local/bin" "$d/own"
  printf '#!/bin/sh\n# my own build\n' >"$d/own/cmux-rd"
  chmod 755 "$d/own/cmux-rd"
  ln -s "$d/own/cmux-rd" "$d/home/.local/bin/cmux-rd"
  run_join env
  check "rd symlink: exit 0 (got $rc)" rc_is 0
  check "rd symlink: kept" test -L "$d/home/.local/bin/cmux-rd"
  check "rd symlink: nothing fetched" eval '! fetched_rd'

  # The channel's cmux-rd in place but not executable (the daemon refuses it): made
  # executable, not downloaded again.
  new_case linux-cmux-rd-not-executable
  mkdir -p "$d/home/.local/bin"
  cp "$d/serve/cmux-rd" "$d/home/.local/bin/cmux-rd"
  chmod 644 "$d/home/.local/bin/cmux-rd"
  run_join env
  check "rd not executable: exit 0 (got $rc): $(cat "$d/out")" rc_is 0
  check "rd not executable: now mode 755, the channel's" rd_is_channels
  check "rd not executable: nothing fetched" eval '! fetched_rd'
  check "rd not executable: no failure state" test ! -e "$(rd_state)"

  # A symlink to nothing, or to a directory, is no cmux-rd: replaced by the channel's.
  for to in nothing dir; do
    new_case "linux-cmux-rd-symlink-to-$to"
    mkdir -p "$d/home/.local/bin"
    [ "$to" = dir ] && mkdir -p "$d/own"
    ln -s "$d/own" "$d/home/.local/bin/cmux-rd"
    run_join env
    check "rd symlink to $to: exit 0 (got $rc): $(cat "$d/out")" rc_is 0
    check "rd symlink to $to: replaced by the channel's" rd_is_channels
    check "rd symlink to $to: nothing put inside its target" test ! -e "$d/own/cmux-rd"
  done

  # ~/.local/bin cannot be written: one line and the state file, the join goes on, the
  # old cmux-rd kept and no temp file left.
  for step in install mv; do
    new_case "linux-cmux-rd-$step-fails"
    old_rd
    : >"$d/home/rd-$step-fail"
    run_join env
    check "rd $step fails: the join still exits 0 (got $rc): $(cat "$d/out")" rc_is 0
    check "rd $step fails: joined" token_on_stdin_once
    check "rd $step fails: one line" eval '[ "$(rd_lines)" = 1 ]'
    check "rd $step fails: says so" out_has "cmux-rd did not install (cannot write it to $d/home/.local/bin)"
    check "rd $step fails: the state file holds the reason" grep -qx "cannot write it to $d/home/.local/bin" "$(rd_state)"
    check "rd $step fails: the old cmux-rd untouched" old_rd_kept
    check "rd $step fails: no temp file left in bin" test ! -e "$d/home/.local/bin/.cmux-rd.new"
    check "rd $step fails: the join's last step ran" grep -q "^acpmux daemon restart" "$d/log/argv"
  done

  # The file in bin is checked, not only the download: a copy that differs from the
  # channel's sha256 is never moved into place, and the old cmux-rd stays.
  new_case linux-cmux-rd-copy-changed
  old_rd
  : >"$d/home/rd-install-changes"
  run_join env
  check "rd copy changed: the join still exits 0 (got $rc): $(cat "$d/out")" rc_is 0
  check "rd copy changed: one line" eval '[ "$(rd_lines)" = 1 ]'
  check "rd copy changed: says so" out_has "cmux-rd did not install (checksum verification failed for the copy in $d/home/.local/bin"
  check "rd copy changed: the old cmux-rd untouched" old_rd_kept
  check "rd copy changed: no temp file left in bin" test ! -e "$d/home/.local/bin/.cmux-rd.new"

  # A directory that appears where cmux-rd goes after the script looked: nothing is moved
  # inside it, the join says cmux-rd did not install, and never that the screen is shared.
  new_case linux-cmux-rd-directory-appears
  : >"$d/home/rd-dir-appears"
  run_join env
  check "rd dir appears: the join still exits 0 (got $rc): $(cat "$d/out")" rc_is 0
  check "rd dir appears: one line" eval '[ "$(rd_lines)" = 1 ]'
  check "rd dir appears: says so" out_has "cmux-rd did not install ($d/home/.local/bin/cmux-rd is not a file: remove it, then run the line again)"
  check "rd dir appears: nothing moved inside it" eval '[ -d "$d/home/.local/bin/cmux-rd" ] && [ -z "$(ls -A "$d/home/.local/bin/cmux-rd")" ]'
  check "rd dir appears: no temp file left in bin" test ! -e "$d/home/.local/bin/.cmux-rd.new"
  check "rd dir appears: never says the screen is shared" eval '! grep -q "can view this machine" "$d/out"'
  check "rd dir appears: says it is not shared" out_has "This machine's screen is not shared: cmux-rd is not installed at $d/home/.local/bin/cmux-rd"

  # A directory where cmux-rd goes: one clear line, left as it is, nothing fetched.
  new_case linux-cmux-rd-directory
  mkdir -p "$d/home/.local/bin/cmux-rd"
  run_join env
  check "rd directory: the join still exits 0 (got $rc): $(cat "$d/out")" rc_is 0
  check "rd directory: one line" eval '[ "$(rd_lines)" = 1 ]'
  check "rd directory: says so" out_has "cmux-rd did not install ($d/home/.local/bin/cmux-rd is not a file: remove it, then run the line again)"
  check "rd directory: left as it is, nothing inside" eval '[ -d "$d/home/.local/bin/cmux-rd" ] && [ -z "$(ls -A "$d/home/.local/bin/cmux-rd")" ]'
  check "rd directory: nothing fetched" eval '! fetched_rd'
  check "rd directory: the state file holds the reason" grep -q "is not a file" "$(rd_state)"

  # No cmux-rd before the join finished, nor on a machine that is not joined.
  new_case linux-cmux-rd-not-joined
  JT_JOIN_EXIT=3
  run_join env
  check "rd, join refused: nothing fetched" eval '! fetched_rd'

  # CMUX_JOIN_STEP=cmux-rd: only the install (a test of the install path runs it after its own join).
  new_case cmux-rd-step
  run_join none CMUX_JOIN_STEP=cmux-rd
  check "rd step: exit 0 (got $rc): $(cat "$d/out")" rc_is 0
  check "rd step: installed" rd_is_channels
  check "rd step: no acpmux, no service, no join" eval '! grep -q "^acpmux\|tree/.*/cmux-tui-acpmux-" "$d/log/argv"'
  run_join env CMUX_JOIN_STEP=cmux-rd
  check "rd step with a token: exit 2 (got $rc)" rc_is 2
  check "rd step with a token: no token in output" no_token_in_output

  # macOS: no cmux-rd at all.
  new_case macos-no-cmux-rd
  JT_OS=Darwin JT_ARCH=arm64
  run_join env
  check "macos rd: exit 0 (got $rc)" rc_is 0
  check "macos rd: nothing fetched" eval '! fetched_rd'
  check "macos rd: nothing installed" test ! -e "$d/home/.local/bin/cmux-rd"
  check "macos rd: no state" test ! -e "$(rd_state)"

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
  # runtime (macOS and Linux), and a sign-in line for each, through its own flow.
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
  # A fixed name: the host name (gcp-codex-lane-11) would put "codex" in the join's argv.
  run_join env CMUX_JOIN_HARNESSES=none CMUX_JOIN_NAME=box
  check "none: exit 0 (got $rc)" rc_is 0
  check "none: no installer" eval '! grep -q "claude.ai" "$d/log/argv"'
  check "none: no codex" eval '! grep -q "codex" "$d/log/argv"'
  check "none: no sign-in" eval '! out_has "sign in to"'

  new_case harnesses-linux
  JT_CODEX_RT=1 JT_DOCTOR=1
  run_join env CMUX_JOIN_HARNESSES=codex
  check "linux codex: exit 0 (got $rc)" rc_is 0
  check "linux codex: installed" test -f "$d/home/codex-ready"
  check "linux codex: uses managed installer" grep -q "^acpmux harness codex-runtime install" "$d/log/argv"
  check "linux sandbox: join repairs prerequisites" grep -q "^acpmux host doctor --here --fix$" "$d/log/argv"
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

  # Linux: the CLI comes from the signed release file, at the URL it names.
  new_case signed-cli
  run_join env
  check "signed cli: exit 0 (got $rc): $(cat "$d/out")" rc_is 0
  check "signed cli: read the signed file" grep -q '^curl .*channels/linux-feat-cmux-next.json' "$d/log/argv"
  check "signed cli: not the unsigned manifest" eval '! grep -q "^curl .*latest/manifest.json" "$d/log/argv"'
  check "signed cli: the CLI from the URL the file names" grep -q '^curl .*/a6d89d443f5f9ffb66c296d7a9680e307bbe6c58/cmux-tui-x86_64-unknown-linux-gnu' "$d/log/argv"
  check "signed cli: recorded the build" grep -qF '"sequence":20261101000000' "$d/home/.cmux/installed.json"
  check "signed cli: acpmux still from the channel (phase-1b pending)" fetched_binary

  # Phase 1b: acpmux too comes from the signed file, under tree/<key>/.
  new_case signed-acpmux
  sign_channel "$d/serve" 1b
  run_join env
  check "phase 1b: exit 0 (got $rc): $(cat "$d/out")" rc_is 0
  check "phase 1b: acpmux installed" installed
  check "phase 1b: acpmux at the URL the signed file names" grep -q '^curl .*tree/121e0512465089798aba4eea7eba48644ecac9a9/cmux-tui-acpmux-x86_64-unknown-linux-musl' "$d/log/argv"
  check "phase 1b: recorded its sequence" grep -qF '"sequence":20261102000000' "$d/home/.cmux/installed.json"
  # The unsigned channel's acpmux sha256 is not used once the signed file names it.
  serve_dir "$d/serve" 0000000000000000000000000000000000000000000000000000000000000000
  sign_channel "$d/serve" 1b
  rm -f "$d/home/.local/bin/acpmux"
  run_join env
  check "phase 1b: the unsigned channel's sha256 is not used (got $rc): $(cat "$d/out")" rc_is 0

  # A signed file that does not verify ends the join, with a next: line last, before any token use.
  new_case bad-signature
  lrf_key "$d/other"
  lrf_sign "$d/serve/linux-payload.json" "$d/other" "$d/serve/linux-channel.json"
  run_join env
  check "bad signature: exit 1 (got $rc)" rc_is 1
  check "bad signature: says why" out_has "not signed by a cmux release key"
  check "bad signature: next: last" eval 'tail -n 1 "$d/out" | grep -q "^next: "'
  check "bad signature: no acpmux, no join" eval '! installed && no_redeem'
  check "bad signature: no CLI" eval '[ ! -e "$d/home/.cmux/bin/cmux" ]'

  # A lower sequence than the installed build is refused too.
  new_case lower-sequence
  mkdir -p "$d/home/.cmux"
  printf '{"commit":"%s","sequence":20991231000000,"version":"x"}\n' 2222222222222222222222222222222222222222 >"$d/home/.cmux/installed.json"
  run_join env
  check "lower sequence: exit 1 (got $rc)" rc_is 1
  check "lower sequence: next: last" eval 'tail -n 1 "$d/out" | grep -q "^next: "'
  check "lower sequence: no join" no_redeem

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
