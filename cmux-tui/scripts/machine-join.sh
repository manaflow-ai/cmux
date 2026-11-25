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
# The join grants mesh membership only. Screen sharing and control stay off
# until a person at this machine allows them.
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
# `cmux machine add USER@HOST` runs over `ssh -t`).
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
  '' | signin) ;;
  *) die 2 "unknown CMUX_JOIN_STEP $step (signin, or leave it unset)" ;;
esac
if [ "$step" = signin ] && [ -n "$t" ]; then
  die 2 "the sign-in step takes no token; run the line without one"
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
# systemd user unit or LaunchAgent `host setup` writes and says where it
# stands (on a Mac no one is logged in to at the screen, it loads at the next
# login there); an acpmux without it gets a daemon that runs until the next
# reboot.
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
        # The daemon reads the join (its mesh relay) when it starts: until this
        # restart it sends no heartbeat.
        "$acpmux" daemon restart >/dev/null 2>&1 ||
          say "warning: the daemon did not restart onto the join, so it sends no heartbeat yet: run $acpmux daemon restart"
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

# 7. Once joined: the missing harnesses, then the vault.
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
    if [ "$os" = Darwin ] && "$acpmux" harness codex-runtime --help >/dev/null 2>&1; then
      if "$acpmux" harness codex-runtime install </dev/null >/dev/null 2>&1; then
        say "installed Codex (acpmux's pinned, checked runtime)"
      else
        say "warning: Codex did not install; later: $acpmux harness codex-runtime install"
      fi
    else
      say "Codex is not installed: npm install -g @openai/codex (acpmux installs it on macOS only)"
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
  install_harnesses
  pull_vault
fi

# 8. Where this machine stands.
rc=0
if "$acpmux" host doctor --help 2>/dev/null | grep -q -- '--here'; then
  "$acpmux" host doctor --here || rc=$?
elif has_capability "$acpmux"; then
  "$acpmux" host join --status || rc=$?
fi
printf '%s\n' "Screen sharing and control are off on this machine. To allow them, run here: acpmux host consent grant --screen (or --control). Your team's machines cannot turn them on."

# 9. Last: the agents' own sign-in, on this machine.
if [ "$is_joined" = 1 ]; then
  signin_step
fi
exit "$rc"
