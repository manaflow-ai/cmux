#!/bin/sh
# cmux machine join: one pasted line adds this machine to your team's cmux
# machines. `cmux machine add` (or Add Machine in the app) prints the line:
#
#    curl -fsSL <platform>/v1/machines/join.sh | CMUX_JOIN=cmj_... sh
#
# The env form is preferred: the token is never in any process's argv.
# `curl ... | sh -s -- cmj_...` works too, but keeps the token in this sh's
# argv (visible in `ps`) while it runs.
#
# Steps: install acpmux (checked against the channel's sha256), install and
# start its service, redeem the token once through `acpmux host join` (the
# token goes on its stdin, never in argv, env, a URL or a log), then print
# this machine's join status. Run it again with no token to repair the
# install and the service, or to finish a join that was cut off; a joined
# machine never spends a new token.
#
# The join grants mesh membership. On Linux it also shares the screen with
# your own account only: the person who joined this machine can view its
# screen from their other devices with nothing to do here, and other
# accounts can't reach it (the device hub pairs only one account's own
# devices). The acpmux daemon sets that up itself, through cmux-rd
# (~/.local/bin/cmux-rd, the path its screen host unit runs): once joined,
# this script installs cmux-rd from the same channel as acpmux (checked
# against the channel's sha256), and the daemon finds it within a minute.
# A cmux-rd that does not install never fails the join: one line says why,
# and so does `acpmux share-host status`.
#
# Once joined: Claude Code (its official installer) and Codex (acpmux's
# pinned, checked runtime) are installed when missing; the person's vault (env
# vars and API keys, when their Mac shared it: `cmux machine add --vault`) is
# pulled into this machine's keychain through `acpmux host vault pull`,
# printing names only; and last, the agents' sign-in is the person's own, on
# this machine, through each vendor's own flow (`claude auth login`, `codex
# login`), offered right here on a terminal. No sign-in is ever read, copied
# or sent by this script.
#
# Knobs: CMUX_JOIN_NAME (this machine's name), CMUX_JOIN_CHANNEL (default
# feat-cmux-next), CMUX_JOIN_REPLACE=1 (swap an existing credential),
# CMUX_JOIN_HARNESSES (default claude,codex; none installs and offers
# nothing), CMUX_JOIN_INTERACTIVE=0 (never ask on the terminal),
# CMUX_JOIN_STEP=signin (only the sign-in step, on a joined machine: what
# `cmux machine add USER@HOST` runs over `ssh -t`), CMUX_JOIN_STEP=cmux-rd
# (only the cmux-rd install, on a joined Linux machine).
#
# Source: cmux-tui/scripts/machine-join.sh in manaflow-ai/cmux; the
# platform serves a copy with its own origin written in.
# Threat model: anyone who can read this machine's processes or files as
# this user (other users, logs, shell history read later, the network) never
# sees the token. The caller's own shell environment is trusted: a PATH, an
# exported bash function or a PS4 the caller set runs as this same user, who
# can read this process's environ and memory anyway.
#
# No tracing and no automatic export, even when bash inherits them through
# SHELLOPTS: either would put the token on stderr or in children's env.
set +ax
set -eu
umask 077

# 1. The token: the env form first, then `sh -s -- TOKEN`. Taken into a
# plain shell variable and dropped from the environment and the positional
# parameters before anything else runs, so no child sees it.
# `t` is unset first: a `t` the caller exported would keep its export
# attribute through the assignment and hand the token to every child.
j="${CMUX_JOIN:-}"
unset CMUX_JOIN t
t="$j"
unset j
if [ -z "$t" ] && [ "$#" -gt 0 ]; then
  t="$1"
fi
set --

say() { printf 'cmux join: %s\n' "$*" >&2; }
die() {
  code="$1"
  shift
  # A replaced binary's restart, deferred to after the redeem, still runs.
  [ "${restart_pending:-0}" = 0 ] || restart_daemon || :
  say "$*"
  exit "$code"
}

if [ -n "$t" ]; then
  case "$t" in
    cmj_*) ;;
    *) die 2 "that is not a cmux join token (it starts with cmj_)" ;;
  esac
  case "${t#cmj_}" in
    '' | *[!A-Za-z0-9_-]*) die 2 "the line was damaged; copy it again from cmux" ;;
  esac
  if [ "${#t}" -gt 4096 ]; then
    die 2 "the line was damaged; copy it again from cmux"
  fi
fi

# The platform origin. The served copy has it written in; a run from the
# source tree falls back to development. CMUX_PLATFORM_URL overrides both.
origin='@@CMUX_PLATFORM_ORIGIN@@'
case "$origin" in
  @@*) origin="https://cmux-platform-development.debussy.workers.dev" ;;
esac
origin="${CMUX_PLATFORM_URL:-$origin}"
origin="${origin%/}"
case "$origin" in
  https://*) ;;
  *) die 1 "refusing the platform origin $origin: https only" ;;
esac

files="https://files.cmux.com/cmux-tui"
join_capability="machine.join.stdin.v1"
vault_capability="machine.vault.pull.v1"
bin_dir="$HOME/.local/bin"
acpmux="$bin_dir/acpmux"
step="${CMUX_JOIN_STEP:-}"
case "$step" in
  '' | signin | cmux-rd) ;;
  *) die 2 "unknown CMUX_JOIN_STEP $step (signin, cmux-rd, or leave it unset)" ;;
esac
if [ -n "$step" ] && [ -n "$t" ]; then
  die 2 "the $step step takes no token; run the line without one"
fi

# The harnesses to install and sign in: CMUX_JOIN_HARNESSES, a comma list.
harnesses="${CMUX_JOIN_HARNESSES:-claude,codex}"
case ",$harnesses," in
  *,none,*) harnesses="" ;;
esac
case "$harnesses" in
  *[!a-z,]*) die 2 "CMUX_JOIN_HARNESSES takes claude, codex or none" ;;
esac
wants() {
  case ",$harnesses," in
    *",$1,"*) return 0 ;;
  esac
  return 1
}
# Where a harness's CLI is: PATH, then where its own installer puts it.
find_claude() {
  command -v claude 2>/dev/null && return 0
  [ -x "$HOME/.local/bin/claude" ] || return 1
  printf '%s\n' "$HOME/.local/bin/claude"
}
find_codex() {
  command -v codex 2>/dev/null && return 0
  [ -x "$acpmux" ] || return 1
  # Line breaks go, spaces stay: the runtime's path may hold them ("Application Support").
  st="$("$acpmux" harness codex-runtime status 2>/dev/null | tr -d '\r\n')" || return 1
  printf '%s' "$st" | grep -q '"ready"[[:space:]]*:[[:space:]]*true' || return 1
  p="$(printf '%s' "$st" | sed -n 's/.*"path"[[:space:]]*:[[:space:]]*"\([^"\\]*\)".*/\1/p')"
  [ -n "$p" ] && [ -x "$p" ] || return 1
  printf '%s\n' "$p"
}
# Whether a harness is signed in, by its own status command; nothing it says is shown.
signed_in() {
  case "$1" in
    claude) "$2" auth status </dev/null 2>/dev/null | tr -d ' \t\r\n' | grep -q '"loggedIn":true' ;;
    codex) "$2" login status </dev/null >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# The last step: each harness's own sign-in, on this machine. On a terminal
# it offers to run the vendor's own login right here; otherwise it says what
# to run. The person signs in; nothing here reads or moves a sign-in.
signin_step() {
  ask=0
  if [ "${CMUX_JOIN_INTERACTIVE:-1}" != 0 ] && [ -t 2 ] && (: </dev/tty) 2>/dev/null; then
    ask=1
  fi
  for h in claude codex; do
    wants "$h" || continue
    if [ "$h" = claude ]; then
      bin="$(find_claude || true)"
      label="Claude Code"
      hint="run '$bin' here and sign in with its /login"
    else
      bin="$(find_codex || true)"
      label="Codex"
      # The managed runtime is not on PATH: name the binary that was found.
      hint="run '$bin' login here"
    fi
    [ -n "$bin" ] || continue
    if signed_in "$h" "$bin"; then
      say "$label is signed in"
      continue
    fi
    if [ "$ask" = 1 ]; then
      printf 'cmux join: sign in to %s on this machine now, with its own sign-in? [Y/n] ' "$label" >&2
      ans=""
      IFS= read -r ans </dev/tty || ans=n
      case "$ans" in
        n | N | no | No | NO) ;;
        *)
          if [ "$h" = claude ]; then
            "$bin" auth login </dev/tty >/dev/tty 2>&1 || say "$label did not finish signing in; $hint"
          else
            # Over ssh no browser opens here: Codex's device sign-in shows a code to enter anywhere.
            set -- login
            [ -z "${SSH_CONNECTION:-}" ] || set -- login --device-auth
            "$bin" "$@" </dev/tty >/dev/tty 2>&1 || say "$label did not finish signing in; $hint"
            set --
          fi
          continue
          ;;
      esac
    fi
    say "sign in to $label: $hint"
  done
}

if [ "$step" = signin ]; then
  signin_step
  exit 0
fi

# 2. Platform.
os="$(uname -s)"
arch="$(uname -m)"
case "$os-$arch" in
  Darwin-arm64 | Darwin-aarch64) target="aarch64-apple-darwin"; cli_target="$target" ;;
  Darwin-x86_64) target="x86_64-apple-darwin"; cli_target="$target" ;;
  Linux-x86_64 | Linux-amd64) target="x86_64-unknown-linux-musl"; cli_target="x86_64-unknown-linux-gnu" ;;
  Linux-aarch64 | Linux-arm64) target="aarch64-unknown-linux-musl"; cli_target="aarch64-unknown-linux-gnu" ;;
  *) die 1 "unsupported platform $os-$arch (macOS or Linux, arm64 or x86_64)" ;;
esac
command -v curl >/dev/null 2>&1 || die 1 "curl is required"
if command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
elif command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$1" | awk '{print $1}'; }
else
  die 1 "shasum or sha256sum is required"
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-join.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' HUP INT TERM

# A transport failure (a reset, a timeout, DNS: curl's 5 6 7 18 28 35 52 55
# 56) is retried, 4 tries with waits of 2, 8 and 20 s: a 23 s network blip
# failed a whole join (run 44192875334). An HTTP status the server sent
# (curl's 22) is an answer, not a blip: no retry. Not --retry-all-errors: it
# needs curl 7.71.
fetch() {
  for fetch_wait in 2 8 20 ''; do
    fetch_rc=0
    curl --proto '=https' --tlsv1.2 -fsSL "$1" -o "$2" || fetch_rc=$?
    case "$fetch_rc" in
      0) return 0 ;;
      5 | 6 | 7 | 18 | 28 | 35 | 52 | 55 | 56) [ -n "$fetch_wait" ] || return "$fetch_rc" ;;
      *) return "$fetch_rc" ;;
    esac
    say "the network dropped $1 (curl exit $fetch_rc); retrying in $fetch_wait s"
    sleep "$fetch_wait"
  done
}

# The value of "name": "<hex>" in a JSON file, pretty or not.
json_hex() {
  tr -d ' \t\r\n' <"$2" | tr ',{}' '\n\n\n' |
    sed -n "s/^\"$1\":\"\\([0-9a-f]*\\)\"\$/\\1/p" | head -n 1
}

# BEGIN linux-release-verify: generated by cmux-tui/scripts/linux-release-verify-gen.py from cmux-tui/scripts/linux-release-verify.sh and web-update-keys.json; edit those, not this
# The signed Linux release file, read by the Linux installers (cmuxterm-hq
# docs/design/linux-signed-packages.md, sections 2 and 4).
#
# The one source of the function set web/public/tui/install-static.sh and
# cmux-tui/scripts/machine-join.sh carry inline: edit it here, then run
#   python3 cmux-tui/scripts/linux-release-verify-gen.py
# which writes it, and the public keys from
# Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/Resources/web-update-keys.json,
# between the "linux-release-verify" markers of both scripts.
# cmux-tui/scripts/linux-release-verify.test.sh fails when a copy differs.
#
# The caller sets clr_dir (a private directory, umask 077) and clr_state (the
# installed.json path), then:
#   clr_tools                        OpenSSL 3 and a sha256 tool, or refuse
#   clr_release pointer CHANNEL      channels/linux-CHANNEL.json, verified
#   clr_release commit SHA [pinned]  <SHA>/release.json, verified; pinned: an
#                                    explicit version, so a lower sequence is allowed
#                                    (either sets clr_fetched once the file downloaded)
#   clr_has TARGET NAME              whether the verified file names that binary
#   clr_download TARGET NAME OUT     that binary, capped at its signed size, checked
#   clr_record                       the installed version and sequence to clr_state
# Each returns 1 after setting clr_why (what failed) and clr_next (what to do);
# clr_report prints both, `next:` last. Nothing here trusts a byte it did not
# verify: the envelope's signature is checked by an embedded key before any
# payload field is read.
clr_files="https://files.cmux.com/cmux-tui"
# Whatever the release file says, no download is larger than this.
clr_cap=536870912
clr_why=""
clr_next=""

clr_refuse() { # WHY NEXT
  clr_why="$1"
  clr_next="$2"
  return 1
}

clr_report() {
  printf '%s: %s\n' "${clr_who:-cmux}" "$clr_why" >&2
  printf 'next: %s\n' "$clr_next" >&2
}

# FILE (JSON with no escapes) to one "path<TAB>value" line per scalar,
# path the keys joined by "." (array items by index). Fails on a key with a
# "." or a tab in it, an escape, or anything it cannot read.
clr_flatten() {
  if grep -q '[\\	]' "$1"; then
    return 1
  fi
  awk 'BEGIN { RS = "\001" }
function path(  p, j) { p = ""; for (j = 1; j <= d; j++) p = p (j > 1 ? "." : "") nm[j]; return p }
{
  s = $0; n = length(s); d = 0; ek = 0; i = 1
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == " " || c == "\n" || c == "\r" || c == ":") { i++; continue }
    if (c == "{") { d++; ty[d] = "o"; ek = 1; i++; continue }
    if (c == "[") { d++; ty[d] = "a"; nm[d] = 0; ek = 0; i++; continue }
    if (c == "}" || c == "]") { if (d < 1) exit 2; d--; ek = 0; i++; continue }
    if (c == ",") { if (d < 1) exit 2; if (ty[d] == "o") ek = 1; else nm[d]++; i++; continue }
    if (d < 1) exit 2
    if (c == "\"") {
      j = index(substr(s, i + 1), "\"")
      if (j == 0) exit 2
      v = substr(s, i + 1, j - 1); i += j + 1
      if (ek) { if (index(v, ".")) exit 2; nm[d] = v; ek = 0; continue }
      print path() "\t" v; continue
    }
    if (ek) exit 2
    if (!match(substr(s, i), /^[-+.0-9A-Za-z]+/)) exit 2
    print path() "\t" substr(s, i, RLENGTH); i += RLENGTH
  }
  if (d != 0) exit 2
}' "$1"
}

clr_get() { # FLAT PATH: the value at PATH, or nothing
  awk -F '	' -v k="$2" '$1 == k { print $2; exit }' "$1"
}

clr_sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    openssl dgst -sha256 "$1" | sed 's/.*= *//'
  fi
}

clr_size() { wc -c <"$1" | tr -d ' '; }

clr_tools() {
  clr_v="$(openssl version 2>/dev/null || true)"
  case "$clr_v" in
    "OpenSSL "[3-9].* | "OpenSSL "[1-9][0-9].*) ;;
    *)
      clr_refuse "the signed release file needs OpenSSL 3 to check its Ed25519 signature, and this host has ${clr_v:-no openssl}; nothing was installed" \
        "install OpenSSL 3 (the openssl package: Ubuntu 22.04, Debian 12, RHEL 9 and newer ship it), then run this again"
      return 1
      ;;
  esac
  command -v awk >/dev/null 2>&1 || {
    clr_refuse "awk is required to read the signed release file" "install awk, then run this again"
    return 1
  }
}

# URL OUT CAP: at most CAP bytes at URL into OUT. 0 on success; 3 when the
# response runs past CAP (cut off at CAP + 1 bytes); else curl's exit. A
# dropped connection is retried, 4 tries with waits of 2, 8 and 20 s; an
# HTTP status (curl's 22) is an answer.
clr_curl() {
  for clr_wait in 2 8 20 ''; do
    rm -f "$2.rc"
    { curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL --max-filesize "$3" "$1" ||
      echo "$?" >"$2.rc"; } | head -c "$(($3 + 1))" >"$2"
    if [ "$(clr_size "$2")" -gt "$3" ]; then
      return 3
    fi
    clr_rc=0
    [ ! -f "$2.rc" ] || clr_rc="$(cat "$2.rc")"
    case "$clr_rc" in
      0) return 0 ;;
      63) return 3 ;;
      5 | 6 | 7 | 18 | 28 | 35 | 52 | 55 | 56) [ -n "$clr_wait" ] || return "$clr_rc" ;;
      *) return "$clr_rc" ;;
    esac
    printf '%s: the network dropped %s (curl exit %s); retrying in %s s\n' "${clr_who:-cmux}" "$1" "$clr_rc" "$clr_wait" >&2
    sleep "$clr_wait"
  done
}

# FILE: the payload of the envelope in FILE, to $clr_dir/payload, when a
# signature by an embedded key covers it.
clr_verify_envelope() {
  clr_flatten "$1" >"$clr_dir/envelope.flat" || {
    clr_refuse "$2 is not a signed release envelope" "$3"
    return 1
  }
  [ "$(clr_get "$clr_dir/envelope.flat" schema)" = 1 ] || {
    clr_refuse "$2 has an unknown envelope schema" "$3"
    return 1
  }
  clr_b64="$(clr_get "$clr_dir/envelope.flat" payload)"
  case "$clr_b64" in
    '' | *[!A-Za-z0-9+/=]*)
      clr_refuse "$2 has no payload" "$3"
      return 1
      ;;
  esac
  printf '%s' "$clr_b64" | openssl base64 -d -A >"$clr_dir/payload" 2>/dev/null || {
    clr_refuse "$2 has a payload that is not base64" "$3"
    return 1
  }
  clr_good=""
  awk -F '	' '$1 ~ /^signatures\.[0-9]+\.key_id$/ { sub(/\.key_id$/, "", $1); print $1 "\t" $2 }' \
    "$clr_dir/envelope.flat" >"$clr_dir/sigs"
  while IFS='	' read -r clr_at clr_key_id; do
    clr_pub="$(clr_keys | awk -v k="$clr_key_id" '$1 == k { print $2; exit }')"
    [ -n "$clr_pub" ] || continue
    clr_sig="$(clr_get "$clr_dir/envelope.flat" "$clr_at.sig")"
    case "$clr_sig" in
      '' | *[!A-Za-z0-9+/=]*) continue ;;
    esac
    printf '%s\n%s\n%s\n' '-----BEGIN PUBLIC KEY-----' "$clr_pub" '-----END PUBLIC KEY-----' >"$clr_dir/key.pem"
    printf '%s' "$clr_sig" | openssl base64 -d -A >"$clr_dir/sig" 2>/dev/null || continue
    if openssl pkeyutl -verify -pubin -inkey "$clr_dir/key.pem" -rawin -in "$clr_dir/payload" \
      -sigfile "$clr_dir/sig" >/dev/null 2>&1; then
      clr_good="$clr_key_id"
      break
    fi
  done <"$clr_dir/sigs"
  [ -n "$clr_good" ] || {
    clr_refuse "$2 is not signed by a cmux release key this installer trusts; nothing was installed" \
      "do not install from this file; report it at https://github.com/manaflow-ai/cmux/issues (or get a newer installer if cmux rotated its keys)"
    return 1
  }
}

# pointer CHANNEL | commit SHA [pinned]
clr_release() {
  clr_pinned=""
  clr_fetched=""
  if [ "$1" = pointer ]; then
    case "$2" in
      stable | nightly | feat-cmux-next) ;;
      *)
        clr_refuse "no signed release channel $2" "pick stable, nightly or feat-cmux-next"
        return 1
        ;;
    esac
    clr_url="$clr_files/channels/linux-$2.json"
    clr_what="the $2 channel's signed release file ($clr_url)"
    clr_again="run this again in a few minutes; if it keeps failing, report it at https://github.com/manaflow-ai/cmux/issues"
  else
    case "$2" in
      *[!0-9a-f]* | '') clr_refuse "$2 is not a 40-character lowercase hex commit" "pass the full commit"; return 1 ;;
    esac
    [ "${#2}" -eq 40 ] || { clr_refuse "$2 is not a 40-character lowercase hex commit" "pass the full commit"; return 1; }
    [ "${3:-}" != pinned ] || clr_pinned=1
    clr_url="$clr_files/$2/release.json"
    clr_what="the signed release file of $2 ($clr_url)"
    clr_again="pick a commit published with a signed release file, or install the default channel without one"
  fi
  clr_rc=0
  clr_curl "$clr_url" "$clr_dir/release.json" 65536 || clr_rc=$?
  case "$clr_rc" in
    0) ;;
    3) clr_refuse "$clr_what is larger than 64 KiB; nothing was installed" "$clr_again"; return 1 ;;
    22) clr_refuse "$clr_what is not published" "$clr_again"; return 1 ;;
    *) clr_refuse "cannot download $clr_what (curl exit $clr_rc)" "check this machine's outbound HTTPS to files.cmux.com, then run this again"; return 1 ;;
  esac
  clr_fetched=1
  clr_verify_envelope "$clr_dir/release.json" "$clr_what" "$clr_again" || return 1
  clr_p="$clr_dir/release.flat"
  clr_flatten "$clr_dir/payload" >"$clr_p" || {
    clr_refuse "$clr_what has a payload this installer cannot read" "get a newer installer, then run it again"
    return 1
  }
  if [ -n "$(cut -f 1 "$clr_p" | sort | uniq -d)" ]; then
    clr_refuse "$clr_what names a field twice" "$clr_again"
    return 1
  fi
  [ "$(clr_get "$clr_p" schema)" = 1 ] || { clr_refuse "$clr_what has an unknown payload schema" "get a newer installer, then run it again"; return 1; }
  [ "$(clr_get "$clr_p" purpose)" = cmux-linux-release ] || {
    clr_refuse "$clr_what is not a Linux release file (purpose $(clr_get "$clr_p" purpose))" "$clr_again"
    return 1
  }
  clr_channel="$(clr_get "$clr_p" channel)"
  clr_commit="$(clr_get "$clr_p" commit)"
  clr_version="$(clr_get "$clr_p" version)"
  clr_tree_key="$(clr_get "$clr_p" tree_key)"
  if [ "$1" = pointer ]; then
    [ "$clr_channel" = "$2" ] || { clr_refuse "$clr_what is for the channel $clr_channel" "$clr_again"; return 1; }
    clr_exp="$(clr_get "$clr_p" expires_at)"
    case "$clr_exp" in '' | *[!0-9]*) clr_refuse "$clr_what has no expiry" "$clr_again"; return 1 ;; esac
    if [ "$clr_exp" -le "$(date +%s)" ]; then
      clr_refuse "$clr_what expired at $clr_exp (a stale copy, or the channel stopped publishing); nothing was installed" \
        "check this machine's clock; if it is right, report it at https://github.com/manaflow-ai/cmux/issues"
      return 1
    fi
  else
    [ "$clr_commit" = "$2" ] || { clr_refuse "$clr_what is for the commit $clr_commit" "$clr_again"; return 1; }
    case "$clr_channel" in
      stable | nightly | feat-cmux-next) ;;
      *) clr_refuse "$clr_what names the unknown channel $clr_channel" "$clr_again"; return 1 ;;
    esac
  fi
  case "$clr_commit" in *[!0-9a-f]* | '') clr_refuse "$clr_what has a bad commit" "$clr_again"; return 1 ;; esac
  [ "${#clr_commit}" -eq 40 ] || { clr_refuse "$clr_what has a bad commit" "$clr_again"; return 1; }
  if [ -n "$clr_tree_key" ]; then
    case "$clr_tree_key" in *[!0-9a-f]*) clr_refuse "$clr_what has a bad tree_key" "$clr_again"; return 1 ;; esac
    [ "${#clr_tree_key}" -eq 40 ] || { clr_refuse "$clr_what has a bad tree_key" "$clr_again"; return 1; }
  fi
  # The order of publication: `sequence`, or for a file from before it (phase 1)
  # the 14-digit stamp in `version`, which every later sequence is at least.
  clr_sequence="$(clr_get "$clr_p" sequence)"
  if [ -z "$clr_sequence" ]; then
    clr_sequence="$(printf '%s\n' "$clr_version" |
      sed -n 's/^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*+\([0-9]\{14\}\)\.[0-9a-f]\{12\}$/\1/p')"
  fi
  case "$clr_sequence" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
    *) clr_refuse "$clr_what has no sequence" "$clr_again"; return 1 ;;
  esac
  # Every URL under the file's own prefix, one plain file name below it.
  while IFS='	' read -r clr_at clr_u; do
    clr_rest=""
    case "$clr_u" in
      "$clr_files/$clr_commit/"*) clr_rest="${clr_u#"$clr_files/$clr_commit/"}" ;;
      "$clr_files/tree/"*)
        [ -z "$clr_tree_key" ] || case "$clr_u" in "$clr_files/tree/$clr_tree_key/"*) clr_rest="${clr_u#"$clr_files/tree/$clr_tree_key/"}" ;; esac
        ;;
    esac
    case "$clr_rest" in
      '' | [!A-Za-z0-9]* | *[!A-Za-z0-9._+-]*)
        clr_refuse "$clr_what: $clr_at points off its own prefix ($clr_u); nothing was installed" \
          "do not install from this file; report it at https://github.com/manaflow-ai/cmux/issues"
        return 1
        ;;
    esac
  done <<EOF
$(awk -F '	' '$1 ~ /(^|\.)url$/ { print $1 "\t" $2 }' "$clr_p")
EOF
  # A build older than the one installed, unless asked for by version.
  if [ -z "$clr_pinned" ] && [ -f "$clr_state" ]; then
    clr_have=""
    if clr_flatten "$clr_state" >"$clr_dir/state.flat" 2>/dev/null; then
      clr_have="$(clr_get "$clr_dir/state.flat" sequence)"
    fi
    case "$clr_have" in
      [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9])
        if [ "$clr_sequence" -lt "$clr_have" ]; then
          clr_refuse "$clr_what is older (sequence $clr_sequence) than the build installed here ($clr_have, $clr_state); nothing was installed" \
            "keep the installed build; to go back on purpose, pass --commit with the commit you want"
          return 1
        fi
        ;;
    esac
  fi
}

clr_has() { # TARGET NAME
  [ -n "$(clr_get "$clr_dir/release.flat" "targets.$1.$2.url")" ]
}

clr_download() { # TARGET NAME OUT
  clr_p="$clr_dir/release.flat"
  clr_u="$(clr_get "$clr_p" "targets.$1.$2.url")"
  clr_want="$(clr_get "$clr_p" "targets.$1.$2.sha256")"
  clr_size="$(clr_get "$clr_p" "targets.$1.$2.size")"
  [ -n "$clr_u" ] || { clr_refuse "the signed release file of $clr_commit has no $2 for $1" "pick another build, or report it at https://github.com/manaflow-ai/cmux/issues"; return 1; }
  # A binary is the file NAME-TARGET; a package (deb, rpm) one cmux-*.deb or cmux-*.rpm.
  case "$2:$clr_u" in
    deb:*/cmux-*.deb | rpm:*/cmux-*.rpm | *:*/"$2-$1") ;;
    deb:* | rpm:*) clr_refuse "the signed release file names $clr_u for the $2 of $1, not a cmux .$2" "report it at https://github.com/manaflow-ai/cmux/issues"; return 1 ;;
    *) clr_refuse "the signed release file names $clr_u for $2 $1, not a file called $2-$1" "report it at https://github.com/manaflow-ai/cmux/issues"; return 1 ;;
  esac
  case "$clr_want" in *[!0-9a-f]* | '') clr_want="" ;; esac
  [ "${#clr_want}" -eq 64 ] || { clr_refuse "the signed release file has no sha256 for $2 $1" "report it at https://github.com/manaflow-ai/cmux/issues"; return 1; }
  case "$clr_size" in *[!0-9]* | '' | 0) clr_size="" ;; esac
  if [ -z "$clr_size" ] || [ "${#clr_size}" -gt 10 ] || [ "$clr_size" -gt "$clr_cap" ]; then
    clr_refuse "the signed release file gives $2 $1 a size of ${clr_size:-nothing}, over the 512 MiB cap" "report it at https://github.com/manaflow-ai/cmux/issues"
    return 1
  fi
  clr_rc=0
  clr_curl "$clr_u" "$3" "$clr_size" || clr_rc=$?
  case "$clr_rc" in
    0) ;;
    3)
      rm -f "$3"
      clr_refuse "$clr_u is larger than its signed size of $clr_size bytes; it was cut off and nothing was installed" \
        "run this again later; if it repeats, report it at https://github.com/manaflow-ai/cmux/issues"
      return 1
      ;;
    *) clr_refuse "cannot download $clr_u (curl exit $clr_rc)" "check this machine's outbound HTTPS to files.cmux.com, then run this again"; return 1 ;;
  esac
  clr_got="$(clr_size "$3")"
  [ "$clr_got" = "$clr_size" ] || {
    rm -f "$3"
    clr_refuse "$clr_u is $clr_got bytes, not its signed $clr_size; nothing was installed" "run this again; if it repeats, report it at https://github.com/manaflow-ai/cmux/issues"
    return 1
  }
  clr_got="$(clr_sha "$3")"
  [ "$clr_got" = "$clr_want" ] || {
    rm -f "$3"
    clr_refuse "$clr_u has sha256 $clr_got, not the signed $clr_want; nothing was installed" \
      "do not install it; run this again later, and report it at https://github.com/manaflow-ai/cmux/issues if it repeats"
    return 1
  }
}

clr_record() {
  mkdir -p "$(dirname "$clr_state")" &&
    printf '{"commit":"%s","sequence":%s,"version":"%s"}\n' "$clr_commit" "$clr_sequence" "$clr_version" \
      >"$clr_state.new" &&
    mv -f "$clr_state.new" "$clr_state"
}
clr_keys() { # The trusted release keys: id, then the PEM body of the Ed25519 public key.
  printf '%s\n' 'e5d7bbcacc70703d MCowBQYDK2VwAyEAuroy2ajE6JWnMjkx3FNdn88SJN4DCMfLpqZjkwx45WY='
}
# END linux-release-verify
clr_who="cmux join"
clr_dir="$tmp"
clr_state="$HOME/.cmux/installed.json"
# A refusal of the signed release file: what failed, then a next: line, last.
die_clr() {
  [ "${restart_pending:-0}" = 0 ] || restart_daemon || :
  clr_report
  exit 1
}

has_capability() {
  [ -x "$1" ] && "$1" capabilities 2>/dev/null | grep -qx "$join_capability"
}

# Whether the installed acpmux is kept current by something other than this
# line: a Mac (its app), or a Linux box whose user manager has
# acpmux-update.timer enabled (asked of systemd: a unit file it does not read
# counts for nothing) or the owner's ~/.acpmux/no-auto-update marker (updates
# turned off on purpose).
updated_elsewhere() {
  [ "$os" != "Linux" ] ||
    [ -e "$HOME/.acpmux/no-auto-update" ] ||
    systemctl --user is-enabled --quiet acpmux-update.timer >/dev/null 2>&1
}

# 3. acpmux from the channel, checked against its sha256 before it touches
# ~/.local/bin. The join token only ever goes to a binary with the channel's
# sha256: on a mismatch the channel's build replaces it (the old one stays as
# acpmux.prev). A repair run with no token keeps a different binary that can
# join when something else updates it: on Linux, its acpmux-update.timer
# (step 4 installs it) or the owner's no-auto-update marker; a Mac's app. A
# Linux box with neither gets the channel's build, whose step 4 adds the
# timer. The installed one stays when the channel cannot be read.
channel="${CMUX_JOIN_CHANNEL:-feat-cmux-next}"
case "$channel" in
  '' | *[!a-z0-9-]*) die 1 "refusing the channel $channel: lowercase letters, digits and - only" ;;
esac
# On Linux, the signed release file of the channel (cmuxterm-hq
# docs/design/linux-signed-packages.md): its Ed25519 signature is checked
# against the keys above before any field is read, and the CLI and acpmux come
# only from the URLs it lists. A file that downloads but does not verify ends
# the join. macOS is outside that file (no darwin target in it).
signed=""
if [ "$os" = Linux ]; then
  clr_tools || die_clr
  case "$channel" in
    stable | nightly | feat-cmux-next)
      if clr_release pointer "$channel"; then
        signed=1
      elif [ -n "$clr_fetched" ]; then
        die_clr
      else
        say "warning: $clr_why"
      fi
      ;;
  esac
fi
want=""
acpmux_signed=""
if [ -n "$signed" ] && clr_has "$target" cmux-tui-acpmux; then
  acpmux_signed=1
  want="$(clr_get "$clr_dir/release.flat" "targets.$target.cmux-tui-acpmux.sha256")"
fi
# The unsigned channel file, for what the signed file does not name yet:
# cmux-rd, and acpmux until phase 1b (cmuxterm-hq
# docs/design/linux-signed-packages.md section 6) publishes cmux-tui-acpmux in
# the signed file. Phase-1b pending: remove the acpmux half once it does.
channel_read=""
if fetch "$files/channels/$channel.json" "$tmp/channel.json"; then # unsigned: phase-1b pending
  key="$(json_hex key "$tmp/channel.json")"
  [ -n "$acpmux_signed" ] || want="$(json_hex "cmux-tui-acpmux-$target" "$tmp/channel.json")"
  if [ "${#key}" -ne 40 ] || [ "${#want}" -ne 64 ]; then
    die 1 "the $channel channel has no acpmux build for $target"
  fi
  channel_read=1
fi

# cmux-rd, the screen host's program, installed once joined on Linux (step
# 7): from the channel acpmux came from, checked against the channel's
# sha256 and moved into place in one step. The daemon notices it within a minute and sets up
# the screen host. cmux-rd links glibc: its builds are the gnu targets. A
# failure never fails the join: one line, and the reason in the share
# host's folder, where `acpmux share-host status` reads it. A cmux-rd that
# is a symlink to a file was put there on purpose (a test build, say) and is
# kept; a symlink to nothing or to a directory is replaced. The channel's
# bytes without the execute bit (which the daemon refuses) are made executable.
rd="$bin_dir/cmux-rd"
rd_state="${ACPMUX_HOME:-$HOME/.acpmux}/share-host/cmux-rd-install"
case "$cli_target" in
  *-linux-gnu) rd_target="$cli_target" ;;
  *) rd_target="" ;;
esac
rd_failed() {
  say "warning: cmux-rd did not install ($1), so this machine's screen is not shared yet; run the line again without a token to retry"
  { mkdir -p "${rd_state%/*}" && printf '%s\n' "$1" >"$rd_state"; } 2>/dev/null || true
}
install_cmux_rd() {
  if [ -L "$rd" ] && [ -f "$rd" ]; then
    say "keeping $rd (a symlink someone put there)"
    rm -f "$rd_state"
    return 0
  fi
  if [ ! -L "$rd" ] && [ -e "$rd" ] && [ ! -f "$rd" ]; then
    rd_failed "$rd is not a file: remove it, then run the line again"
    return 0
  fi
  [ -n "$channel_read" ] || {
    rd_failed "the $channel channel could not be read"
    return 0
  }
  rd_want="$(json_hex "cmux-tui-rd-$rd_target" "$tmp/channel.json")"
  [ "${#rd_want}" -eq 64 ] || {
    rd_failed "the $channel channel has no cmux-rd build for $rd_target"
    return 0
  }
  if [ ! -f "$rd" ] || [ "$(sha256 "$rd")" != "$rd_want" ]; then
    fetch "$files/tree/$key/cmux-tui-rd-$rd_target" "$tmp/cmux-rd" || { # unsigned: not in the release file
      rd_failed "cannot download cmux-rd for $rd_target"
      return 0
    }
    got="$(sha256 "$tmp/cmux-rd")"
    [ "$got" = "$rd_want" ] || {
      rd_failed "checksum verification failed for cmux-rd ($got, the channel says $rd_want)"
      return 0
    }
    # Each step checked: under `set -e` a read-only or full ~/.local would end the join here.
    # A symlink to a directory would take the new file inside it, so it goes first.
    if ! { mkdir -p "$bin_dir" &&
      install -m 755 "$tmp/cmux-rd" "$bin_dir/.cmux-rd.new"; } 2>/dev/null; then
      rm -f "$bin_dir/.cmux-rd.new" 2>/dev/null || true
      rd_failed "cannot write it to $bin_dir"
      return 0
    fi
    # The file that is moved into place is the one checked: the copy in bin, not only the
    # download (another writer of bin, a short write).
    got="$(sha256 "$bin_dir/.cmux-rd.new" 2>/dev/null || true)"
    [ "$got" = "$rd_want" ] || {
      rm -f "$bin_dir/.cmux-rd.new" 2>/dev/null || true
      rd_failed "checksum verification failed for the copy in $bin_dir ($got, the channel says $rd_want)"
      return 0
    }
    # Only a file (or nothing) is replaced: mv onto a directory moves the file inside it.
    # A directory that appeared since the first look is named, never filled.
    if [ ! -L "$rd" ] && [ -e "$rd" ] && [ ! -f "$rd" ]; then
      rm -f "$bin_dir/.cmux-rd.new" 2>/dev/null || true
      rd_failed "$rd is not a file: remove it, then run the line again"
      return 0
    fi
    if ! { { [ ! -L "$rd" ] || rm -f "$rd"; } &&
      mv -f "$bin_dir/.cmux-rd.new" "$rd"; } 2>/dev/null; then
      rm -f "$bin_dir/.cmux-rd.new" 2>/dev/null || true
      rd_failed "cannot write it to $bin_dir"
      return 0
    fi
    # What is at $rd now is what the daemon runs: a regular executable file, or nothing
    # installed (a directory that appeared between the look and the mv took the file).
    if [ -L "$rd" ] || [ ! -f "$rd" ] || [ ! -x "$rd" ]; then
      [ ! -d "$rd" ] || [ -L "$rd" ] || rm -f "$rd/.cmux-rd.new" 2>/dev/null || true
      rd_failed "$rd is not a file: remove it, then run the line again"
      return 0
    fi
    say "installed cmux-rd to $rd"
  elif [ ! -x "$rd" ]; then
    chmod 755 "$rd" || {
      rd_failed "cannot make $rd executable"
      return 0
    }
  fi
  rm -f "$rd_state"
  # Cisco's OpenH264, downloaded from Cisco on this machine: the screen
  # host's encoder, never bundled. The host's enable fetches it too.
  "$rd" openh264-install </dev/null >/dev/null 2>&1 ||
    say "warning: Cisco's OpenH264 did not download yet; the screen host fetches it when it starts, or run: $rd openh264-install"
}

# CMUX_JOIN_STEP=cmux-rd: only that, on a joined machine (what a test of
# the install path runs after its own join).
if [ "$step" = cmux-rd ]; then
  [ "$os" != Linux ] || [ -z "$rd_target" ] || install_cmux_rd
  exit 0
fi

replaced=0
restart_pending=0
if [ -z "$want" ]; then
  if [ -n "$t" ] || ! has_capability "$acpmux"; then
    die 1 "cannot read the $channel channel from files.cmux.com: check this machine's outbound HTTPS, then paste the line again"
  fi
  say "cannot read the $channel channel; keeping the installed acpmux"
elif [ -x "$acpmux" ] && [ "$(sha256 "$acpmux")" = "$want" ]; then
  :
elif [ -z "$t" ] && has_capability "$acpmux" && updated_elsewhere; then
  say "keeping the installed acpmux (its updates bring it to $channel)"
else
  if [ -n "$acpmux_signed" ]; then
    clr_download "$target" cmux-tui-acpmux "$tmp/acpmux" || die_clr
  else
    fetch "$files/tree/$key/cmux-tui-acpmux-$target" "$tmp/acpmux" || # unsigned: phase-1b pending
      die 1 "cannot download acpmux for $target"
    got="$(sha256 "$tmp/acpmux")"
    [ "$got" = "$want" ] ||
      die 1 "checksum verification failed for acpmux ($got, the channel says $want); nothing was installed"
  fi
  mkdir -p "$bin_dir"
  install -m 755 "$tmp/acpmux" "$bin_dir/.acpmux.new"
  if [ -e "$acpmux" ]; then
    # Staged and renamed, never copied over: processes started before an
    # earlier update can still run acpmux.prev, and writing over a running
    # binary fails with "Text file busy" where a rename does not.
    { cp -p "$acpmux" "$bin_dir/.acpmux.prev.new" &&
      mv -f "$bin_dir/.acpmux.prev.new" "$bin_dir/acpmux.prev"; } || {
      rm -f "$bin_dir/.acpmux.prev.new" "$bin_dir/.acpmux.new"
      die 1 "cannot keep the installed acpmux as $bin_dir/acpmux.prev; nothing was installed"
    }
    replaced=1
  fi
  mv -f "$bin_dir/.acpmux.new" "$acpmux"
  say "installed acpmux to $acpmux"
fi

# Best effort: the cmux CLI to ~/.cmux/bin/cmux, as install-static.sh does.
# On Linux only from the signed release file; on macOS (outside it) from the
# unsigned manifest, as before.
install_cli() {
  cli="$HOME/.cmux/bin/cmux"
  if [ -n "$signed" ]; then
    sum="$(clr_get "$clr_dir/release.flat" "targets.$cli_target.cmux-tui.sha256")"
    if [ -x "$cli" ] && [ -n "$sum" ] && [ "$(sha256 "$cli")" = "$sum" ]; then
      return 0
    fi
    clr_download "$cli_target" cmux-tui "$tmp/cmux" || {
      say "warning: $clr_why"
      return 1
    }
  elif [ "$os" = Darwin ]; then
    fetch "$files/latest/manifest.json" "$tmp/manifest.json" || return 1 # unsigned: macOS only
    sum="$(json_hex "cmux-tui-$cli_target" "$tmp/manifest.json")"
    commit="$(json_hex commit "$tmp/manifest.json")"
    [ "${#sum}" -eq 64 ] && [ "${#commit}" -eq 40 ] || return 1
    if [ -x "$cli" ] && [ "$(sha256 "$cli")" = "$sum" ]; then
      return 0
    fi
    fetch "$files/$commit/cmux-tui-$cli_target" "$tmp/cmux" || return 1 # unsigned: macOS only
    [ "$(sha256 "$tmp/cmux")" = "$sum" ] || return 1
  else
    say "warning: no signed release file for the $channel channel, so the cmux CLI is not installed"
    return 1
  fi
  mkdir -p "$HOME/.cmux/bin"
  # Renamed into place, as acpmux is: a running cmux cannot be written over.
  { install -m 755 "$tmp/cmux" "$cli.new" && mv -f "$cli.new" "$cli"; } || {
    rm -f "$cli.new"
    return 1
  }
  case ":$PATH:" in
    *":$HOME/.cmux/bin:"*) ;;
    *)
      case "$(basename "${SHELL:-sh}")" in
        zsh) profile="$HOME/.zshrc" ;;
        bash) profile="$HOME/.bashrc" ;;
        *) profile="" ;;
      esac
      if [ -n "$profile" ] && ! grep -F "$HOME/.cmux/bin" "$profile" >/dev/null 2>&1; then
        printf '\n# cmux\nexport PATH="%s:$PATH"\n' "$HOME/.cmux/bin" >>"$profile"
      fi
      ;;
  esac
  [ -z "$signed" ] || clr_record || say "warning: could not write $clr_state"
  say "installed cmux to $cli"
}
install_cli || say "warning: the cmux CLI did not install (acpmux is enough to join); retry later with the same line without a token"

if [ -n "$t" ] && ! has_capability "$acpmux"; then
  die 1 "this acpmux is too old: update ($acpmux has no $join_capability; the $channel channel does not carry it yet)"
fi

# 4. The service and the daemon. `daemon service install` writes the same
# systemd user unit or LaunchAgent `host setup` writes and says where it
# stands (on a Mac no one is logged in to at the screen, it loads at the next
# login there); an acpmux without it gets a daemon that runs until the next
# reboot. On Linux it also installs and starts acpmux-update.timer with the
# script `host setup` runs (`acpmux machine self-update` every 15 minutes),
# unless ~/.acpmux/no-auto-update says not to; a re-run keeps both as they are.
if "$acpmux" daemon service --help >/dev/null 2>&1; then
  if [ "$os" = "Linux" ] && command -v loginctl >/dev/null 2>&1; then
    loginctl enable-linger "$(id -un)" >/dev/null 2>&1 ||
      say "warning: loginctl enable-linger was refused; the daemon stops when you log out"
  fi
  if svc="$("$acpmux" daemon service install 2>&1)"; then
    [ -z "$svc" ] || say "$svc"
  else
    say "warning: the acpmux service did not install${svc:+: $svc}"
  fi
else
  say "warning: this acpmux cannot install its service yet; the daemon runs until the next reboot"
fi
# When the user unit acpmux.service is loaded (`daemon service install`'s,
# or a fleet-written one with Restart=), systemd owns the daemon: starts and
# restarts go through it, after reset-failed. `acpmux daemon restart` under
# such a unit is an exit systemd restarts too, and two of those within a few
# seconds hit the unit's start limit (start-limit-hit, no daemon at all).
daemon_unit="acpmux.service"
unit_loaded() {
  [ "$os" = "Linux" ] && command -v systemctl >/dev/null 2>&1 &&
    [ "$(systemctl --user show -p LoadState --value "$daemon_unit" 2>/dev/null)" = loaded ]
}
unit_next_step="run: systemctl --user reset-failed $daemon_unit; systemctl --user start $daemon_unit"
# daemon_up start|restart: 0 once the daemon runs (under its unit: active).
daemon_up() {
  if unit_loaded; then
    systemctl --user reset-failed "$daemon_unit" >/dev/null 2>&1 || :
    systemctl --user "$1" "$daemon_unit" >/dev/null 2>&1 &&
      systemctl --user is-active --quiet "$daemon_unit" >/dev/null 2>&1
  elif [ "$1" = restart ]; then
    "$acpmux" daemon restart >/dev/null 2>&1
  else
    "$acpmux" daemon start >/dev/null
  fi
}
# The one restart a run does (restart_pending), after any redeem. Returns 1
# when the unit is not active after it: the caller fails on that.
restart_daemon() {
  restart_pending=0
  if daemon_up restart; then
    ! unit_loaded || say "restarted $daemon_unit; it is active"
  elif unit_loaded; then
    say "$daemon_unit is not active after its restart: $unit_next_step"
    return 1
  else
    say "warning: the daemon did not restart onto the new acpmux or the join, so it sends no heartbeat yet: run $acpmux daemon restart"
  fi
}
# A replaced binary takes over a running daemon by a restart, which keeps
# its sessions. That restart waits for the redeem below, so a join that
# redeems restarts the daemon once, not twice; any exit from here on runs
# it (see die).
if [ "$replaced" = 1 ]; then
  restart_pending=1
fi
if ! daemon_up start; then
  if unit_loaded; then
    say "warning: $daemon_unit did not start: $unit_next_step"
  else
    say "warning: the acpmux daemon did not start: run $acpmux daemon start"
  fi
fi

# 5. The name: CMUX_JOIN_NAME, else the first label of the host name (the
# platform keeps the label the token was minted with).
name="${CMUX_JOIN_NAME:-}"
if [ -z "$name" ]; then
  name="$(hostname 2>/dev/null || uname -n)"
  name="${name%%.*}"
fi

# 6. Redeem, once. A machine already joined spends nothing unless
# CMUX_JOIN_REPLACE=1. A join cut off between redeem and its local commit
# (joinIncomplete: a pending proposal is on disk) wins over a present
# credential: any rerun resumes it, with no token when acpmux can recover it
# from the hub. A revoked or expired enrollment takes a fresh line, joined
# with --replace.
status_json() { "$acpmux" host join --status --json 2>/dev/null | tr -d ' \t\r\n'; }
fresh_line="paste a new line: cmux machine add (or Add Machine in the app)"
is_joined=0
joined=0
resume=0
revoked=0
replace="${CMUX_JOIN_REPLACE:-}"
if has_capability "$acpmux"; then
  st="$(status_json || true)"
  case "$st" in
    *'"joinIncomplete":true'*) resume=1 ;;
    *'"revoked":true'*) revoked=1 ;;
    *'"credentialPresent":true'*'"revoked":false'* | *'"revoked":false'*'"credentialPresent":true'*) joined=1 ;;
  esac
fi
if [ "$resume" = 1 ]; then
  say "resuming a join that did not finish"
elif [ "$revoked" = 1 ]; then
  [ -n "$t" ] || die 3 "this machine's enrollment was revoked or has expired; $fresh_line"
  replace=1
elif [ "$joined" = 1 ] && [ -n "$t" ] && [ "$replace" != 1 ]; then
  say "already joined; nothing redeemed (CMUX_JOIN_REPLACE=1 swaps the credential)"
  t=""
fi
[ "$joined" = 0 ] || is_joined=1
if [ -n "$t" ] || [ "$resume" = 1 ]; then
  with_token=0
  [ -z "$t" ] || with_token=1
  while :; do
    # A resume leaves out --name: the pending proposal keeps its own. One
    # with no token leaves out --hub too, so acpmux asks the pending hub; a
    # token only ever goes to this script's origin.
    set -- host join
    [ "$resume" = 1 ] && [ "$with_token" = 0 ] || set -- "$@" --hub "$origin"
    [ "$resume" = 1 ] || set -- "$@" --name "$name"
    set -- "$@" --json
    if [ "$replace" = 1 ]; then
      set -- "$@" --replace
    fi
    # printf is a shell builtin: the token reaches acpmux on stdin only.
    # acpmux's stderr is redacted on its way to disk (acpmux redacts its own
    # errors; anything token-shaped is cut anyway), and its exit status comes
    # back through a file, since a pipeline's status is its last command's.
    # A resume with no token gives acpmux an empty stdin.
    rc=0
    {
      rc=0
      if [ "$with_token" = 1 ]; then
        printf '%s\n' "$t" | "$acpmux" "$@" 2>&1 >"$tmp/join.json" || rc=$?
      else
        "$acpmux" "$@" </dev/null 2>&1 >"$tmp/join.json" || rc=$?
      fi
      printf '%s\n' "$rc" >"$tmp/join.rc"
    } | sed 's/cmj_[A-Za-z0-9_-]*/[redacted token]/g' >"$tmp/join.err"
    rc="$(cat "$tmp/join.rc")"
    set --
    # The hub revoked the pending proposal: only --replace with a fresh token
    # starts over, and the token on hand was never redeemed.
    if [ "$rc" = 3 ] && grep -q 'revoked:' "$tmp/join.err"; then
      [ "$with_token" = 1 ] || die 3 "this machine's enrollment was revoked or has expired; $fresh_line"
      if [ "$replace" != 1 ]; then
        replace=1
        continue
      fi
    fi
    break
  done
  t=""
  if [ "$rc" = 2 ] && [ "$resume" = 1 ]; then
    cat "$tmp/join.err" >&2
    die 2 "the join that did not finish could not resume: paste the same line again (same CMUX_JOIN_NAME), or $fresh_line"
  fi
  case "$rc" in
    0)
      is_joined=1
      if tr -d ' \t\r\n' <"$tmp/join.json" | grep -q '"alreadyJoined":true'; then
        say "already joined; nothing redeemed"
      else
        if [ "$resume" = 1 ]; then say "joined"; else say "joined as $name"; fi
        # The daemon reads the join (its mesh relay) when it starts: until
        # the restart below it sends no heartbeat.
        restart_pending=1
      fi
      ;;
    2) die 2 "the line was damaged; copy it again from cmux" ;;
    3)
      # acpmux's own reason (an enrollment that cannot authorize a
      # replacement, say), already redacted; a revocation says it above.
      grep -q 'revoked:' "$tmp/join.err" || cat "$tmp/join.err" >&2
      die 3 "this line was used or expired; make a new one: cmux machine add (or Add Machine in the app)"
      ;;
    4)
      # A resume needs its original line, and one with no token asked the
      # pending hub, not $origin.
      if [ "$resume" = 1 ]; then
        die 4 "the hub could not be reached; rerun the same line once this machine's outbound HTTPS works"
      fi
      die 4 "cannot reach $origin: check this machine's outbound HTTPS, then paste a new line"
      ;;
    5)
      store="$(status_json | sed -n 's/.*"credentialPath":"\([^"]*\)".*/\1/p')"
      die 5 "could not store the machine credential in ${store:-$HOME/.acpmux}: free disk / fix permissions, then paste a new line"
      ;;
    *)
      cat "$tmp/join.err" >&2
      die "$rc" "joining failed (acpmux exit $rc); paste a new line, or run: $acpmux host join --status"
      ;;
  esac
fi
# The one restart: onto a replaced binary, a new join, or both.
if [ "$restart_pending" = 1 ] && ! restart_daemon; then
  die 1 "the acpmux daemon is not running: $unit_next_step"
fi

# 7. Once joined: cmux-rd on Linux (above), the missing harnesses, then
# the vault.
install_harnesses() {
  if wants claude && [ -z "$(find_claude || true)" ]; then
    # Claude Code's own native installer (https://claude.ai/install.sh).
    if ! command -v bash >/dev/null 2>&1; then
      say "warning: Claude Code needs bash to install; later: curl -fsSL https://claude.ai/install.sh | bash"
    elif fetch https://claude.ai/install.sh "$tmp/claude-install.sh" &&
      bash "$tmp/claude-install.sh" </dev/null >/dev/null; then
      say "installed Claude Code"
    else
      say "warning: Claude Code did not install; later: curl -fsSL https://claude.ai/install.sh | bash"
    fi
  fi
  if wants codex && [ -z "$(find_codex || true)" ]; then
    if "$acpmux" harness codex-runtime --help >/dev/null 2>&1; then
      if "$acpmux" harness codex-runtime install </dev/null >/dev/null 2>&1; then
        say "installed Codex (acpmux's pinned, checked runtime)"
      else
        say "warning: Codex did not install; later: $acpmux harness codex-runtime install"
      fi
    else
      say "Codex is not installed: update acpmux, then run $acpmux harness codex-runtime install"
    fi
  fi
}

# The vault: env var names and a count only; acpmux keeps the values in
# this machine's keychain and never prints them.
pull_vault() {
  "$acpmux" capabilities 2>/dev/null | grep -qx "$vault_capability" || return 0
  vrc=0
  # Read into memory only: acpmux's answer never reaches disk.
  v="$("$acpmux" host vault pull --json </dev/null 2>/dev/null)" || vrc=$?
  v="$(printf '%s' "$v" | tr -d ' \t\r\n')"
  # The env names in acpmux's answer, as one space-separated list (names only).
  names="$(printf '%s' "$v" | sed -n 's/.*"env":\[\([^]]*\)\].*/\1/p' | tr ',' '\n' |
    sed -n 's/^"\([A-Za-z_][A-Za-z0-9_]*\)"$/\1/p' | tr '\n' ' ')"
  count=0
  for n in $names; do count=$((count + 1)); done
  case "$v" in
    *'"state":"not_granted"'*)
      say "vault: not shared with this machine (from your Mac: cmux machine vault grant $name)"
      ;;
    # The hub has no vault: nothing to pull, nothing to say.
    *'"state":"off"'*) ;;
    *'"state":"ok"'*)
      if [ "$count" = 0 ]; then
        say "vault: no env vars yet"
      else
        say "vault: $count env vars (${names% })"
      fi
      ;;
    *'"state":"partial"'*)
      say "warning: the vault pull got $count env vars${names:+ (${names% })}, not all of them; retry: $acpmux host vault pull"
      ;;
    *) say "warning: the vault pull did not finish (acpmux exit $vrc); retry: $acpmux host vault pull" ;;
  esac
  v=""
}

if [ "$is_joined" = 1 ]; then
  if [ "$os" = Linux ] && [ -n "$rd_target" ]; then
    install_cmux_rd
  fi
  install_harnesses
  pull_vault
fi

# 8. Where this machine stands.
rc=0
if "$acpmux" host doctor --help 2>/dev/null | grep -q -- '--here'; then
  "$acpmux" host doctor --here --fix || rc=$?
elif has_capability "$acpmux"; then
  "$acpmux" host join --status || rc=$?
fi
if [ "$os" != Linux ]; then
  printf '%s\n' "Screen sharing and control are off on this machine. To allow them, run here: acpmux host consent grant --screen (or --control). Your team's machines cannot turn them on."
elif [ "$is_joined" != 1 ]; then
  # Only a join's daemon sets cmux-rd's host up (acpmux share_host/linux.rs).
  printf '%s\n' "This machine is not joined, so its screen is not shared."
elif [ -f "$rd" ] && [ -x "$rd" ]; then
  # A regular executable file (a directory is executable too, and runs nothing).
  # The daemon runs cmux-rd's enable at its start, and within a minute of
  # cmux-rd arriving or changing (acpmux share_host/linux.rs).
  printf '%s\n' "Your own account can view this machine's screen from your other devices, with nothing to do here. Other accounts can't reach it."
else
  why=""
  [ ! -f "$rd_state" ] || why=" ($(head -n 1 "$rd_state"))"
  printf '%s\n' "This machine's screen is not shared: cmux-rd is not installed at $rd$why. Run the line again without a token to retry; once cmux-rd is there, your own account can view this screen from your other devices within a minute, with nothing to do here. Other accounts can't reach it."
fi

# 9. Last: the agents' own sign-in, on this machine.
# FUTURE_HOOK: cmux-share-prepare-json
# The share-host-helper-process lane will replace this named no-op with one
# best-effort `cmux share prepare --json` call once that verb lands. Keep it
# after sign-in so it runs once at the end of a join.
prepare_share_hook() { :; }
if [ "$is_joined" = 1 ]; then
  signin_step
  prepare_share_hook
fi
exit "$rc"
