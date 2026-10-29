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
# install and the service; a joined machine never spends a new token.
#
# The join grants mesh membership only. Screen sharing and control stay off
# until a person at this machine allows them.
#
# Knobs: CMUX_JOIN_NAME (this machine's name), CMUX_JOIN_CHANNEL (default
# feat-cmux-next), CMUX_JOIN_REPLACE=1 (swap an existing credential).
#
# Source: cmux-tui/scripts/machine-join.sh in manaflow-ai/cmux; the
# platform serves a copy with its own origin written in.
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
bin_dir="$HOME/.local/bin"
acpmux="$bin_dir/acpmux"

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

fetch() { curl --proto '=https' --tlsv1.2 -fsSL "$1" -o "$2"; }

# The value of "name": "<hex>" in a JSON file, pretty or not.
json_hex() {
  tr -d ' \t\r\n' <"$2" | tr ',{}' '\n\n\n' |
    sed -n "s/^\"$1\":\"\\([0-9a-f]*\\)\"\$/\\1/p" | head -n 1
}

has_capability() {
  [ -x "$1" ] && "$1" capabilities 2>/dev/null | grep -qx "$join_capability"
}

# 3. acpmux from the channel, checked against its sha256 before it touches
# ~/.local/bin. The join token only ever goes to a binary with the channel's
# sha256: on a mismatch the channel's build replaces it (the old one stays as
# acpmux.prev). A repair run with no token keeps a different binary that can
# join (the update timer owns updates), and keeps the installed one when the
# channel cannot be read.
channel="${CMUX_JOIN_CHANNEL:-feat-cmux-next}"
case "$channel" in
  '' | *[!a-z0-9-]*) die 1 "refusing the channel $channel: lowercase letters, digits and - only" ;;
esac
want=""
if fetch "$files/channels/$channel.json" "$tmp/channel.json"; then
  key="$(json_hex key "$tmp/channel.json")"
  want="$(json_hex "cmux-tui-acpmux-$target" "$tmp/channel.json")"
  if [ "${#key}" -ne 40 ] || [ "${#want}" -ne 64 ]; then
    die 1 "the $channel channel has no acpmux build for $target"
  fi
fi
replaced=0
if [ -z "$want" ]; then
  if [ -n "$t" ] || ! has_capability "$acpmux"; then
    die 1 "cannot read the $channel channel from files.cmux.com: check this machine's outbound HTTPS, then paste the line again"
  fi
  say "cannot read the $channel channel; keeping the installed acpmux"
elif [ -x "$acpmux" ] && [ "$(sha256 "$acpmux")" = "$want" ]; then
  :
elif [ -z "$t" ] && has_capability "$acpmux"; then
  say "keeping the installed acpmux (its update timer brings it to $channel)"
else
  fetch "$files/tree/$key/cmux-tui-acpmux-$target" "$tmp/acpmux" ||
    die 1 "cannot download acpmux for $target"
  got="$(sha256 "$tmp/acpmux")"
  [ "$got" = "$want" ] ||
    die 1 "checksum verification failed for acpmux ($got, the channel says $want); nothing was installed"
  mkdir -p "$bin_dir"
  install -m 755 "$tmp/acpmux" "$bin_dir/.acpmux.new"
  if [ -e "$acpmux" ]; then
    cp -p "$acpmux" "$bin_dir/acpmux.prev"
    replaced=1
  fi
  mv -f "$bin_dir/.acpmux.new" "$acpmux"
  say "installed acpmux to $acpmux"
fi

# Best effort: the cmux CLI to ~/.cmux/bin/cmux, as install-static.sh does.
install_cli() {
  base="$files/latest"
  fetch "$base/manifest.json" "$tmp/manifest.json" || return 1
  sum="$(json_hex "cmux-tui-$cli_target" "$tmp/manifest.json")"
  commit="$(json_hex commit "$tmp/manifest.json")"
  [ "${#sum}" -eq 64 ] && [ "${#commit}" -eq 40 ] || return 1
  cli="$HOME/.cmux/bin/cmux"
  if [ -x "$cli" ] && [ "$(sha256 "$cli")" = "$sum" ]; then
    return 0
  fi
  fetch "$files/$commit/cmux-tui-$cli_target" "$tmp/cmux" || return 1
  [ "$(sha256 "$tmp/cmux")" = "$sum" ] || return 1
  mkdir -p "$HOME/.cmux/bin"
  install -m 755 "$tmp/cmux" "$cli"
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
  say "installed cmux to $cli"
}
install_cli || say "warning: the cmux CLI did not install (acpmux is enough to join); retry later with the same line without a token"

if [ -n "$t" ] && ! has_capability "$acpmux"; then
  die 1 "this acpmux is too old: update ($acpmux has no $join_capability; the $channel channel does not carry it yet)"
fi

# 4. The service and the daemon. `daemon service install` writes the same
# systemd user unit or LaunchAgent `host setup` writes; an acpmux without it
# gets a daemon that runs until the next reboot.
if "$acpmux" daemon service --help >/dev/null 2>&1; then
  if [ "$os" = "Linux" ] && command -v loginctl >/dev/null 2>&1; then
    loginctl enable-linger "$(id -un)" >/dev/null 2>&1 ||
      say "warning: loginctl enable-linger was refused; the daemon stops when you log out"
  fi
  "$acpmux" daemon service install >/dev/null || say "warning: the acpmux service did not install"
else
  say "warning: this acpmux cannot install its service yet; the daemon runs until the next reboot"
fi
# A replaced binary takes over a running daemon by a restart, which keeps
# its sessions; with none running, the restart fails and start starts one.
if [ "$replaced" = 1 ] && "$acpmux" daemon restart >/dev/null 2>&1; then
  :
else
  "$acpmux" daemon start >/dev/null || say "warning: the acpmux daemon did not start: run $acpmux daemon start"
fi

# 5. The name: CMUX_JOIN_NAME, else the first label of the host name (the
# platform keeps the label the token was minted with).
name="${CMUX_JOIN_NAME:-}"
if [ -z "$name" ]; then
  name="$(hostname 2>/dev/null || uname -n)"
  name="${name%%.*}"
fi

# 6. Redeem, once. A machine already joined spends nothing unless
# CMUX_JOIN_REPLACE=1.
status_json() { "$acpmux" host join --status --json 2>/dev/null | tr -d ' \t\r\n'; }
joined=0
if [ -n "$t" ]; then
  st="$(status_json || true)"
  case "$st" in
    *'"credentialPresent":true'*'"revoked":false'* | *'"revoked":false'*'"credentialPresent":true'*) joined=1 ;;
  esac
  if [ "$joined" = 1 ] && [ "${CMUX_JOIN_REPLACE:-}" != 1 ]; then
    say "already joined; nothing redeemed (CMUX_JOIN_REPLACE=1 swaps the credential)"
    t=""
  fi
fi
if [ -n "$t" ]; then
  set -- host join --hub "$origin" --name "$name" --json
  if [ "${CMUX_JOIN_REPLACE:-}" = 1 ]; then
    set -- "$@" --replace
  fi
  # printf is a shell builtin: the token reaches acpmux on stdin only.
  rc=0
  printf '%s\n' "$t" | "$acpmux" "$@" >"$tmp/join.json" 2>"$tmp/join.err" || rc=$?
  t=""
  set --
  case "$rc" in
    0)
      if tr -d ' \t\r\n' <"$tmp/join.json" | grep -q '"alreadyJoined":true'; then
        say "already joined; nothing redeemed"
      else
        say "joined as $name"
        "$acpmux" daemon restart >/dev/null 2>&1 || true
      fi
      ;;
    2) die 2 "the line was damaged; copy it again from cmux" ;;
    3) die 3 "this line was used or expired; make a new one: cmux machine add (or Add Machine in the app)" ;;
    4) die 4 "cannot reach $origin: check this machine's outbound HTTPS, then paste a new line" ;;
    5)
      store="$(status_json | sed -n 's/.*"credentialPath":"\([^"]*\)".*/\1/p')"
      die 5 "could not store the machine credential in ${store:-$HOME/.acpmux}: free disk / fix permissions, then paste a new line"
      ;;
    *)
      # acpmux redacts its errors; cut anything token-shaped anyway.
      sed 's/cmj_[A-Za-z0-9_-]*/[redacted token]/g' "$tmp/join.err" >&2
      die "$rc" "joining failed (acpmux exit $rc); paste a new line, or run: $acpmux host join --status"
      ;;
  esac
fi

# 7. Where this machine stands.
rc=0
if "$acpmux" host doctor --help 2>/dev/null | grep -q -- '--here'; then
  "$acpmux" host doctor --here || rc=$?
elif has_capability "$acpmux"; then
  "$acpmux" host join --status || rc=$?
fi
printf '%s\n' "Screen sharing and control are off on this machine. To allow them, run here: acpmux host consent grant --screen (or --control). Your team's machines cannot turn them on."
exit "$rc"
