#!/bin/sh
# The whole script is one `{ ... }` group: sh reads it to the closing brace
# before it runs any line, so a download cut short (curl | sh, or ssh's
# stdin) is a syntax error that runs nothing, never half an install.
{
set -eu

# Pairing (acpmux src/pairing): a ticket minted on another machine
# (`cmux host ticket new`) joins this one to it once cmux is installed. The
# line that command prints installs, then hands the ticket to `cmux host join`
# on stdin, so no process has it in its argv (`ps`, /proc/PID/cmdline):
#   curl -fsSL https://cmux.com/tui/install-static.sh | sh && printf '%s\n' <ticket> | ~/.cmux/bin/cmux host join --serve
# This script also takes CMUX_JOIN_TICKET=<ticket>, and still takes
# `sh -s -- <ticket>` and `--join <ticket>` with a warning: those put the ticket
# in this shell's argv. A daemon-role ticket (the other machine drives this
# one) also needs `--advertise <wss://...>` or CMUX_JOIN_ADVERTISE: the address
# the other machine reaches this one at. The ticket reaches `cmux host join`
# on stdin only, and no child inherits CMUX_JOIN_TICKET.
#
# cmux server (https://cmux.com/docs/server): `--server` also runs
# `cmux server install`, which keeps this machine's cmux session running as a
# service (systemd user unit with linger on Linux, a LaunchAgent on macOS), so
# your cmux reaches it over SSH after logouts and reboots:
#   curl -fsSL https://cmux.com/tui/install.sh | sh -s -- --server
# `--server` installs the current cmux NIGHTLY build unless `--commit <sha>` (a
# published cmux build) or CMUX_DOWNLOAD_BASE_URL picks another. `--nightly`
# picks that build without the service; `--channel nightly` is the same, and
# `--channel stable` picks the latest stable build. `--user` runs
# `cmux server install --user`: the service starts at login and stops at
# logout, and linger is left as it is. `--dry-run` prints what would happen
# and changes nothing.
want_server=""
want_nightly=""
want_stable=""
server_user=""
dry_run=""
pinned_commit=""
join_ticket="${CMUX_JOIN_TICKET:-}"
unset CMUX_JOIN_TICKET
join_ticket_in_argv=""
join_advertise="${CMUX_JOIN_ADVERTISE:-}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --advertise)
      if [ "$#" -lt 2 ]; then
        echo "cmux: --advertise needs a URL" >&2
        exit 2
      fi
      join_advertise="$2"
      shift 2
      ;;
    --advertise=*) join_advertise="${1#--advertise=}"; shift ;;
    --join)
      if [ "$#" -lt 2 ]; then
        echo "cmux: --join needs a ticket" >&2
        exit 2
      fi
      join_ticket="$2"
      join_ticket_in_argv=1
      shift 2
      ;;
    --join=*) join_ticket="${1#--join=}"; join_ticket_in_argv=1; shift ;;
    --server) want_server=1; shift ;;
    --nightly) want_nightly=1; shift ;;
    --user) want_server=1; server_user=1; shift ;;
    --channel | --channel=*)
      if [ "$1" = "--channel" ]; then
        if [ "$#" -lt 2 ]; then
          echo "cmux: --channel needs stable or nightly" >&2
          exit 2
        fi
        channel="$2"
        shift 2
      else
        channel="${1#--channel=}"
        shift
      fi
      case "$channel" in
        stable) want_stable=1 ;;
        nightly) want_nightly=1 ;;
        *)
          echo "cmux: --channel takes stable or nightly" >&2
          exit 2
          ;;
      esac
      ;;
    --dry-run) dry_run=1; shift ;;
    --commit)
      if [ "$#" -lt 2 ]; then
        echo "cmux: --commit needs a 40-character commit" >&2
        exit 2
      fi
      pinned_commit="$2"
      shift 2
      ;;
    --commit=*) pinned_commit="${1#--commit=}"; shift ;;
    cmxt1.*) join_ticket="$1"; join_ticket_in_argv=1; shift ;;
    *)
      echo "cmux: unknown argument $1 (pass --server, --user, --channel stable|nightly, --nightly, --commit <sha>, --dry-run or a pairing ticket, cmxt1.…)" >&2
      exit 2
      ;;
  esac
done
if [ -n "$want_stable" ] && { [ -n "$want_nightly" ] || [ -n "$pinned_commit" ]; }; then
  echo "cmux: --channel stable does not go with --nightly or --commit" >&2
  exit 2
fi
if [ -n "$join_ticket_in_argv" ]; then
  echo "cmux: a ticket on the command line is readable by other users of this machine (ps); next time paste the line \`cmux host ticket new\` prints, which passes it on stdin" >&2
fi

case "$pinned_commit" in
  "") ;;
  *[!0-9a-f]*)
    echo "cmux: --commit takes a 40-character lowercase hex commit" >&2
    exit 2
    ;;
esac
if [ -n "$pinned_commit" ] && [ "${#pinned_commit}" -ne 40 ]; then
  echo "cmux: --commit takes a 40-character lowercase hex commit" >&2
  exit 2
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "cmux: curl is required" >&2
  exit 1
fi

files_base="https://files.cmux.com/cmux-tui"
if [ -n "${CMUX_DOWNLOAD_BASE_URL:-}" ]; then
  base_url="$CMUX_DOWNLOAD_BASE_URL"
elif [ -n "$pinned_commit" ]; then
  base_url="$files_base/$pinned_commit"
elif [ -z "$want_stable" ] && { [ -n "$want_server" ] || [ -n "$want_nightly" ]; }; then
  # The cmux server verbs ship in cmux NIGHTLY builds: install the build the
  # current NIGHTLY app runs (the first cmux:sourceCommit of its update feed).
  feed_url="${CMUX_NIGHTLY_FEED_URL:-https://files-next.cmux.com/nightly-next/appcast-arm64.xml}"
  nightly_commit="$(
    curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL "$feed_url" |
      sed -n 's/.*<cmux:sourceCommit[^>]*>\([0-9a-f]\{40\}\)<.*/\1/p' | head -n 1
  )" || nightly_commit=""
  if [ "${#nightly_commit}" -ne 40 ]; then
    echo "cmux: could not read the current cmux NIGHTLY build from $feed_url; pass --commit <sha>" >&2
    exit 1
  fi
  base_url="$files_base/$nightly_commit"
else
  base_url="https://files.cmux.com/cmux-tui/latest"
fi
base_url="${base_url%/}"
install_root="${CMUX_INSTALL:-$HOME/.cmux}"
bin_dir="$install_root/bin"

os="$(uname -s)"
arch="$(uname -m)"

case "$os-$arch" in
  Darwin-arm64) artifact="cmux-tui-aarch64-apple-darwin" ;;
  Darwin-x86_64) artifact="cmux-tui-x86_64-apple-darwin" ;;
  Linux-x86_64 | Linux-amd64) artifact="cmux-tui-x86_64-unknown-linux-gnu" ;;
  Linux-aarch64 | Linux-arm64) artifact="cmux-tui-aarch64-unknown-linux-gnu" ;;
  *)
    echo "cmux: unsupported platform $os-$arch" >&2
    exit 1
    ;;
esac

if [ -n "$server_user" ]; then
  set -- --user
else
  set --
fi
if [ -n "$dry_run" ]; then
  echo "Would download $base_url/manifest.json and $artifact, check its SHA-256, and install it to $bin_dir/cmux"
  if [ -n "$want_server" ]; then
    echo "Would run: $bin_dir/cmux server install $*"
  fi
  exit 0
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-install.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL "$base_url/manifest.json" \
  -o "$tmp_dir/manifest.json"
checksum="$(
  sed -n "s/.*\"$artifact\"[[:space:]]*:[[:space:]]*\"\\([0-9a-f][0-9a-f]*\\)\".*/\\1/p" \
    "$tmp_dir/manifest.json"
)"
if [ "${#checksum}" -ne 64 ]; then
  echo "cmux: $artifact is unavailable for this release" >&2
  exit 1
fi

commit="$(
  sed -n 's/.*"commit"[[:space:]]*:[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' \
    "$tmp_dir/manifest.json"
)"
if [ "${#commit}" -ne 40 ]; then
  echo "cmux: manifest has no commit" >&2
  exit 1
fi

artifact_base_url="$base_url"
case "$artifact_base_url" in
  */latest) artifact_base_url="${artifact_base_url%/latest}/$commit" ;;
esac

curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL "$artifact_base_url/$artifact" \
  -o "$tmp_dir/cmux"

if command -v shasum >/dev/null 2>&1; then
  actual="$(shasum -a 256 "$tmp_dir/cmux" | awk '{print $1}')"
elif command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "$tmp_dir/cmux" | awk '{print $1}')"
else
  echo "cmux: shasum or sha256sum is required" >&2
  exit 1
fi

if [ "$actual" != "$checksum" ]; then
  echo "cmux: checksum verification failed" >&2
  exit 1
fi

mkdir -p "$bin_dir"
# Staged and renamed into place: a running cmux cannot be written over
# ("Text file busy"), and a rename never leaves a half-written binary.
install -m 755 "$tmp_dir/cmux" "$bin_dir/.cmux.new"
mv -f "$bin_dir/.cmux.new" "$bin_dir/cmux"

case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *)
    shell_name="$(basename "${SHELL:-sh}")"
    case "$shell_name" in
      zsh) profile="$HOME/.zshrc"; line="export PATH=\"$bin_dir:\$PATH\"" ;;
      bash) profile="$HOME/.bashrc"; line="export PATH=\"$bin_dir:\$PATH\"" ;;
      fish)
        profile="$HOME/.config/fish/config.fish"
        line="fish_add_path \"$bin_dir\""
        mkdir -p "$(dirname "$profile")"
        ;;
      *) profile=""; line="" ;;
    esac
    if [ -n "$profile" ] && ! grep -F "$bin_dir" "$profile" >/dev/null 2>&1; then
      printf '\n# cmux\n%s\n' "$line" >>"$profile"
      echo "Added cmux to PATH in $profile"
    else
      echo "Add $bin_dir to PATH to run cmux from a new shell."
    fi
    ;;
esac

echo "Installed cmux to $bin_dir/cmux"

# Remote hosting (plans/cmux-next/remote-hosts.md): with CMUX_HOST=1 this
# machine serves its cmux sessions to its owner's other machines over the
# tailnet. A tagged machine names its owner with CMUX_HOST_OWNER=<login>.
if [ "${CMUX_HOST:-}" = "1" ]; then
  if [ -n "${CMUX_HOST_OWNER:-}" ]; then
    set -- --owner "$CMUX_HOST_OWNER"
  else
    set --
  fi
  if ! "$bin_dir/cmux" host enable "$@"; then
    echo "cmux: installed, but remote hosting is not on; fix the error above, then run: $bin_dir/cmux host enable $*" >&2
    exit 1
  fi
fi

# cmux server: keep this machine's cmux session running as a service.
if [ -n "$want_server" ]; then
  if [ -n "$server_user" ]; then
    set -- --user
  else
    set --
  fi
  if ! "$bin_dir/cmux" server install "$@"; then
    echo "cmux: installed, but the cmux server service is not set up; fix the error above, then run: $bin_dir/cmux server install $*" >&2
    exit 1
  fi
fi

# Join the minting machine. `--serve` also turns remote hosting on when this
# machine is signed in to Tailscale, unless CMUX_HOST already did (or is 0).
if [ -n "$join_ticket" ]; then
  if [ -z "${CMUX_HOST:-}" ]; then
    set -- --serve
  else
    set --
  fi
  if [ -n "$join_advertise" ]; then
    set -- "$@" --advertise "$join_advertise"
  fi
  # `printf` is a builtin: the ticket goes to the join on stdin, never argv.
  if ! printf '%s\n' "$join_ticket" | "$bin_dir/cmux" host join "$@"; then
    printf '%s\n' "cmux: installed, but this machine did not join; fix the error above, then run: printf '%s\\n' <ticket> | $bin_dir/cmux host join (a new ticket if this one expired)" >&2
    exit 1
  fi
fi

curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsS --max-time 2 \
  -H 'content-type: application/json' \
  -d "{\"product\":\"tui\",\"platform\":\"$os-$arch\",\"method\":\"curl\"}" \
  https://cmux.com/api/install-events >/dev/null 2>&1 || true
}
