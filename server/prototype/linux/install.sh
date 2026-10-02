#!/bin/sh
# cmux server installer for Linux (PROTOTYPE, cmux-next lane 10).
#
#   curl -fsSL https://cmux.com/server/install.sh | sh
#   curl -fsSL https://cmux.com/server/install.sh | sh -s -- --version 1.4.2
#
# Design: plans/cmux-next/server.md section 4. Nothing runs before the whole
# script has downloaded: every statement is inside a function and `main` is
# called on the last line, so a cut download defines functions and exits.
#
# Trust chain:
#   1. This script embeds (GENERATED block) the URL, size and SHA-256 of one
#      bootstrap archive per target and the two release public keys.
#   2. It downloads the bootstrap archive into a private temporary directory
#      (umask 077), checks size and SHA-256, and refuses on any mismatch.
#   3. It runs only the verified binary. Root is never used unless --system is
#      given, and then only as `sudo <verified file>`; downloaded content is
#      never piped into a root shell.
#
# PROTOTYPE: the Rust `cmux server install` does not exist yet. The functions
# marked "PROTOTYPE (binary step)" do here what that command will do: fetch
# and verify the signed channel manifest, fill the content-addressed store,
# build a profile, flip `current` with one rename(2), write and start the
# systemd user unit. They are the executable specification for the Rust code.

# --- BEGIN GENERATED (CI writes this block per release) ---------------------
CMUX_RELEASE_VERSION='0.0.0-unset'
CMUX_CHANNEL_URL='https://cmux.com/server/channel/stable'
# Ed25519 public keys, base64 SubjectPublicKeyInfo DER (current, next).
CMUX_PUBKEY_CURRENT=''
CMUX_PUBKEY_NEXT=''
CMUX_BOOTSTRAP_X86_64_LINUX_URL=''
CMUX_BOOTSTRAP_X86_64_LINUX_SIZE='0'
CMUX_BOOTSTRAP_X86_64_LINUX_SHA256=''
CMUX_BOOTSTRAP_AARCH64_LINUX_URL=''
CMUX_BOOTSTRAP_AARCH64_LINUX_SIZE='0'
CMUX_BOOTSTRAP_AARCH64_LINUX_SHA256=''
# 1 only in a prototype test channel: allows http://127.0.0.1 URLs.
CMUX_TEST_CHANNEL='0'
# --- END GENERATED ----------------------------------------------------------

say() { printf 'cmux-install: %s\n' "$*"; }
warn() { printf 'cmux-install: warning: %s\n' "$*" >&2; }
die() {
  printf 'cmux-install: error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: install.sh [--version V] [--system]
       install.sh --rollback [--generation G]
       install.sh --uninstall [--purge]
       install.sh --status

  --version V      install or upgrade to channel version V (default: latest)
  --system         system install (root once, through sudo on the verified binary)
  --rollback       flip `current` back to the previous (or the given) generation
  --uninstall      stop and remove the service, shim and store; keep state
  --purge          with --uninstall: also delete state (keys, Postgres, app data)
  --status         print the installed state
USAGE
}

# ---------------------------------------------------------------- arguments
parse_args() {
  opt_version=''
  opt_system=0
  opt_action='install'
  opt_purge=0
  opt_generation=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --version)
        [ "$#" -ge 2 ] || die '--version needs a value'
        opt_version=$2
        shift 2
        ;;
      --version=*)
        opt_version=${1#--version=}
        shift
        ;;
      --system) opt_system=1; shift ;;
      --rollback) opt_action='rollback'; shift ;;
      --generation)
        [ "$#" -ge 2 ] || die '--generation needs a value'
        opt_generation=$2
        shift 2
        ;;
      --uninstall) opt_action='uninstall'; shift ;;
      --purge) opt_purge=1; shift ;;
      --status) opt_action='status'; shift ;;
      -h | --help) usage; exit 0 ;;
      *) usage >&2; die "unknown argument: $1" ;;
    esac
  done
  case "$opt_version" in
    '' | latest) opt_version='' ;;
    *[!A-Za-z0-9._-]*) die "invalid version: $opt_version" ;;
  esac
  case "$opt_generation" in
    '' | *[!0-9]*) [ -z "$opt_generation" ] || die "invalid generation: $opt_generation" ;;
  esac
}

# ---------------------------------------------------------------- platform
detect_target() {
  os=$(uname -s)
  arch=$(uname -m)
  case "$os" in
    Linux) ;;
    *) die "this prototype supports Linux only (found $os)" ;;
  esac
  case "$arch" in
    x86_64 | amd64)
      target='x86_64-linux'
      boot_url=$CMUX_BOOTSTRAP_X86_64_LINUX_URL
      boot_size=$CMUX_BOOTSTRAP_X86_64_LINUX_SIZE
      boot_sha=$CMUX_BOOTSTRAP_X86_64_LINUX_SHA256
      ;;
    aarch64 | arm64)
      target='aarch64-linux'
      boot_url=$CMUX_BOOTSTRAP_AARCH64_LINUX_URL
      boot_size=$CMUX_BOOTSTRAP_AARCH64_LINUX_SIZE
      boot_sha=$CMUX_BOOTSTRAP_AARCH64_LINUX_SHA256
      ;;
    *) die "unsupported architecture: $arch" ;;
  esac
  [ -n "$boot_url" ] || die "this installer carries no bootstrap archive for $target"
}

layout_paths() {
  [ -n "${HOME:-}" ] || die 'HOME is not set'
  data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/cmux"
  state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/cmux/server"
  unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  shim_dir="$HOME/.local/bin"
  store_dir="$data_dir/store"
  profiles_dir="$data_dir/profiles"
  updater_state="$state_dir/updater.state"
  unit_file="$unit_dir/cmux-server.service"
  inhibit_unit_file="$unit_dir/cmux-server-inhibit.service"
  if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
    XDG_RUNTIME_DIR="/run/user/$(id -u)"
    export XDG_RUNTIME_DIR
  fi
}

# ---------------------------------------------------------------- tools
need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

allowed_url() {
  case "$1" in
    https://*) return 0 ;;
    http://127.0.0.1:*) [ "$CMUX_TEST_CHANNEL" = 1 ] && return 0 ;;
  esac
  return 1
}

download() {
  allowed_url "$1" || die "refusing non-HTTPS URL: $1"
  if command -v curl >/dev/null 2>&1; then
    if [ "$CMUX_TEST_CHANNEL" = 1 ]; then
      curl -fsSL --proto '=https,http' --retry 3 --connect-timeout 20 -o "$2" "$1"
    else
      curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 20 -o "$2" "$1"
    fi
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$2" "$1"
  else
    die 'need curl or wget'
  fi
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 -r "$1" | awk '{print $1}'
  else
    die 'no SHA-256 tool (sha256sum, shasum or openssl)'
  fi
}

size_of() { wc -c <"$1" | tr -d ' '; }

# Refuses unless file $1 has exactly size $2 and SHA-256 $3.
verify_file() {
  actual_size=$(size_of "$1")
  [ "$actual_size" = "$2" ] || die "size mismatch for $4: expected $2, got $actual_size; refusing"
  actual_sha=$(sha256_of "$1")
  [ "$actual_sha" = "$3" ] || die "SHA-256 mismatch for $4: expected $3, got $actual_sha; refusing"
}

make_temp() {
  umask 077
  tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/cmux-install.XXXXXXXX") || die 'cannot create a temporary directory'
  trap 'rm -rf "$tmp_dir"' EXIT
  trap 'exit 130' INT TERM
}

# ---------------------------------------------------------------- bootstrap
fetch_bootstrap() {
  case "$boot_sha" in
    *[!0-9a-f]* | '') die 'bootstrap SHA-256 is not set in this installer' ;;
  esac
  [ "${#boot_sha}" -eq 64 ] || die 'bootstrap SHA-256 is malformed'
  say "downloading bootstrap for $target"
  download "$boot_url" "$tmp_dir/bootstrap.tar.gz" || die "download failed: $boot_url"
  verify_file "$tmp_dir/bootstrap.tar.gz" "$boot_size" "$boot_sha" 'bootstrap archive'
  safe_untar "$tmp_dir/bootstrap.tar.gz" "$tmp_dir/bootstrap"
  boot_bin="$tmp_dir/bootstrap/bin/cmux"
  [ -f "$boot_bin" ] || die 'bootstrap archive has no bin/cmux'
  chmod 700 "$boot_bin"
  boot_version=$("$boot_bin" --version 2>/dev/null | head -n 1) || die 'verified bootstrap binary does not run'
  say "verified bootstrap: $boot_version (installer $CMUX_RELEASE_VERSION)"
}

# Unpacks tar.gz $1 into new directory $2; refuses absolute or `..` members.
safe_untar() {
  tar -tzf "$1" >"$tmp_dir/members" 2>/dev/null || die "corrupt archive: $1"
  if grep -Eq '^/|(^|/)\.\.(/|$)' "$tmp_dir/members"; then
    die "archive has unsafe member paths: $1"
  fi
  mkdir -p "$2"
  tar -xzf "$1" -C "$2" --no-same-owner --no-same-permissions || die "cannot unpack $1"
}

# ---------------------------------------------------------------- system mode
run_system_install() {
  # Only the file verified above is run as root. Nothing downloaded is piped
  # into a root shell, and the script itself never runs as root. sudo reads
  # the password from /dev/tty, so `curl | sh` still prompts.
  need sudo
  if ! "$boot_bin" server --help 2>/dev/null | grep -q 'server install'; then
    die "PROTOTYPE: the verified binary has no 'server install --system' yet (lane 10 step 5); system mode is UNVERIFIED"
  fi
  say "system install: sudo $boot_bin server install --system"
  # Not exec: the EXIT trap must still remove the temporary directory.
  sudo "$boot_bin" server install --system
  exit $?
}

# ---------------------------------------------------------------- PROTOTYPE (binary step): manifest
# Manifest format (lane 1, vm-image.md 4.5): canonical JSON, one package
# object per line, detached Ed25519 signature over the exact bytes.
fetch_manifest() {
  if [ -n "$opt_version" ]; then
    manifest_url="$CMUX_CHANNEL_URL/v/$opt_version.json"
  else
    manifest_url="$CMUX_CHANNEL_URL/latest.json"
  fi
  download "$manifest_url" "$tmp_dir/manifest.json" || die "download failed: $manifest_url"
  download "$manifest_url.sig" "$tmp_dir/manifest.json.sig" || die "download failed: $manifest_url.sig"
  verify_manifest_signature "$tmp_dir/manifest.json" "$tmp_dir/manifest.json.sig"
  parse_manifest_header "$tmp_dir/manifest.json"
}

verify_manifest_signature() {
  need openssl
  case "$(openssl version 2>/dev/null)" in
    'OpenSSL 3.'* | 'OpenSSL 4.'*) ;;
    *) die 'PROTOTYPE: needs OpenSSL 3 for Ed25519 -rawin verification (the Rust binary verifies natively)' ;;
  esac
  key_index=0
  for key in "$CMUX_PUBKEY_CURRENT" "$CMUX_PUBKEY_NEXT"; do
    key_index=$((key_index + 1))
    [ -n "$key" ] || continue
    key_file="$tmp_dir/release-key-$key_index.pem"
    {
      printf '%s\n' '-----BEGIN PUBLIC KEY-----'
      printf '%s\n' "$key"
      printf '%s\n' '-----END PUBLIC KEY-----'
    } >"$key_file"
    if openssl pkeyutl -verify -pubin -inkey "$key_file" -rawin -in "$1" -sigfile "$2" >/dev/null 2>&1; then
      if [ "$key_index" = 1 ]; then signed_by='current'; else signed_by='next'; fi
      say "manifest signature valid (release key: $signed_by)"
      return 0
    fi
  done
  die 'manifest signature is invalid for both release keys; refusing'
}

json_field() {
  # $1 = one JSON line, $2 = key. Values are strings or integers without
  # escapes; the shape check below refuses anything else.
  printf '%s\n' "$1" | sed -n "s/.*\"$2\":\"\{0,1\}\([^\",}]*\)\"\{0,1\}[,}].*/\1/p" | head -n 1
}

parse_manifest_header() {
  header=$(head -n 1 "$1")
  m_schema=$(json_field "$header" schema)
  m_sequence=$(json_field "$header" sequence)
  m_version=$(json_field "$header" version)
  m_expires=$(json_field "$header" expires)
  [ "$m_schema" = 1 ] || die "unsupported manifest schema: $m_schema"
  case "$m_sequence" in '' | *[!0-9]*) die 'manifest sequence is malformed' ;; esac
  case "$m_expires" in '' | *[!0-9]*) die 'manifest expiry is malformed' ;; esac
  case "$m_version" in '' | *[!A-Za-z0-9._-]*) die 'manifest version is malformed' ;; esac
  now=$(date +%s)
  if [ "$m_expires" -le "$now" ]; then
    die "manifest version $m_version (sequence $m_sequence) expired at $m_expires (now $now); refusing"
  fi
  last_sequence=$(state_get last_sequence 0)
  if [ "$m_sequence" -lt "$last_sequence" ]; then
    die "manifest sequence $m_sequence is lower than the last applied $last_sequence (downgrade or replay); refusing. Use --rollback to return to an installed generation"
  fi
  say "manifest version $m_version, sequence $m_sequence, expires $m_expires"
}

# ---------------------------------------------------------------- updater state
state_get() {
  value=''
  if [ -f "$updater_state" ]; then
    value=$(sed -n "s/^$1=//p" "$updater_state" | tail -n 1)
  fi
  if [ -n "$value" ]; then printf '%s\n' "$value"; else printf '%s\n' "$2"; fi
}

state_set() {
  mkdir -p "$state_dir"
  chmod 700 "$state_dir"
  : >"$updater_state.tmp"
  if [ -f "$updater_state" ]; then
    grep -v "^$1=" "$updater_state" >"$updater_state.tmp" || true
  fi
  printf '%s=%s\n' "$1" "$2" >>"$updater_state.tmp"
  mv -f "$updater_state.tmp" "$updater_state"
}

# ---------------------------------------------------------------- PROTOTYPE (binary step): store
install_packages() {
  mkdir -p "$store_dir"
  : >"$tmp_dir/profile-entries"
  grep '^{"name":' "$tmp_dir/manifest.json" >"$tmp_dir/packages" || die 'manifest lists no packages'
  while IFS= read -r line; do
    p_name=$(json_field "$line" name)
    p_version=$(json_field "$line" version)
    p_url=$(json_field "$line" url)
    p_sha=$(json_field "$line" sha256)
    p_size=$(json_field "$line" size)
    p_kind=$(json_field "$line" kind)
    case "$p_name" in '' | *[!a-z0-9-]*) die "bad package name: $p_name" ;; esac
    case "$p_sha" in *[!0-9a-f]* | '') die "bad sha256 for $p_name" ;; esac
    [ "${#p_sha}" -eq 64 ] || die "bad sha256 for $p_name"
    case "$p_size" in '' | *[!0-9]*) die "bad size for $p_name" ;; esac
    allowed_url "$p_url" || die "refusing non-HTTPS package URL for $p_name"
    pkg_dir="$store_dir/$p_sha"
    if [ -d "$pkg_dir" ] && [ -f "$pkg_dir/.cmux-package" ]; then
      say "store hit: $p_name $p_version (${p_sha%"${p_sha#????????????}"})"
    else
      say "fetching $p_name $p_version ($p_size bytes)"
      download "$p_url" "$tmp_dir/pkg" || die "download failed: $p_url"
      verify_file "$tmp_dir/pkg" "$p_size" "$p_sha" "package $p_name"
      staging="$store_dir/.staging.$p_sha.$$"
      rm -rf "$staging"
      mkdir -p "$staging/bin"
      case "$p_kind" in
        bin)
          p_bin=$(json_field "$line" bin)
          case "$p_bin" in '' | *[!A-Za-z0-9._-]*) die "bad bin name for $p_name" ;; esac
          cp "$tmp_dir/pkg" "$staging/bin/$p_bin"
          chmod 755 "$staging/bin/$p_bin"
          ;;
        tar.gz)
          safe_untar "$tmp_dir/pkg" "$staging"
          ;;
        *) die "unknown package kind for $p_name: $p_kind" ;;
      esac
      printf 'name=%s\nversion=%s\nsha256=%s\n' "$p_name" "$p_version" "$p_sha" >"$staging/.cmux-package"
      chmod -R a-w "$staging"
      chmod u+w "$staging"
      mv "$staging" "$pkg_dir" || die "cannot place $p_name in the store"
      chmod u-w "$pkg_dir"
      rm -f "$tmp_dir/pkg"
    fi
    printf '%s %s %s\n' "$p_name" "$p_version" "$p_sha" >>"$tmp_dir/profile-entries"
  done <"$tmp_dir/packages"
}

# ---------------------------------------------------------------- PROTOTYPE (binary step): profile + flip
build_profile() {
  generation=$m_sequence
  profile="$profiles_dir/$generation"
  manifest_sha=$(sha256_of "$tmp_dir/manifest.json")
  if [ -f "$profile/manifest.sha256" ] && [ "$(cat "$profile/manifest.sha256")" = "$manifest_sha" ]; then
    say "profile $generation present"
    return 0
  fi
  [ ! -e "$profile" ] || die "profile $generation exists with a different manifest; refusing"
  mkdir -p "$profiles_dir"
  staging="$profiles_dir/.staging.$generation.$$"
  rm -rf "$staging"
  mkdir -p "$staging/bin"
  while read -r e_name e_version e_sha; do
    for f in "$store_dir/$e_sha/bin/"*; do
      [ -e "$f" ] || continue
      ln -s "$f" "$staging/bin/$(basename "$f")"
    done
    printf '%s %s %s\n' "$e_name" "$e_version" "$e_sha" >>"$staging/packages"
  done <"$tmp_dir/profile-entries"
  cp "$tmp_dir/manifest.json" "$staging/manifest.json"
  cp "$tmp_dir/manifest.json.sig" "$staging/manifest.json.sig"
  printf '%s\n' "$manifest_sha" >"$staging/manifest.sha256"
  mv "$staging" "$profile" || die "cannot create profile $generation"
  say "profile $generation built"
}

list_generations() {
  for p in "$profiles_dir"/*; do
    g=${p##*/}
    case "$g" in '' | *[!0-9]*) continue ;; esac
    printf '%s\n' "$g"
  done | sort -n
}

current_generation() {
  if [ -L "$data_dir/current" ]; then
    basename "$(readlink "$data_dir/current")"
  fi
}

# Points `current` at profiles/$1 with one rename(2).
flip_current() {
  link_tmp="$data_dir/.current.$$"
  rm -f "$link_tmp"
  ln -s "profiles/$1" "$link_tmp"
  mv -T "$link_tmp" "$data_dir/current" || die 'atomic flip of current failed'
}

install_shim() {
  mkdir -p "$shim_dir"
  if [ "$(readlink "$shim_dir/cmux" 2>/dev/null)" != "$data_dir/current/bin/cmux" ]; then
    ln -sfn "$data_dir/current/bin/cmux" "$shim_dir/cmux"
    say "CLI shim: $shim_dir/cmux"
  fi
}

# ---------------------------------------------------------------- PROTOTYPE (binary step): service
render_unit() {
  cat <<UNIT
# Generated by the cmux server installer. Changes are overwritten.
[Unit]
Description=cmux server (session host and server roles)
Wants=cmux-server-inhibit.service

[Service]
# PROTOTYPE: cmux-host-run stands in for the frozen \`cmux host run\`. It
# returns after the session host answers identify with lifecycle_ready, so
# \`systemctl --user start\` completes at readiness (Type=forking + PIDFile).
Type=forking
PIDFile=%t/cmux-server.pid
ExecStart=$data_dir/current/bin/cmux-host-run start
Environment=CMUX_SERVER_STATE=$state_dir
# SIGTERM to the session host only: it hands off, and the terminal hosts
# stay alive for the next owner to adopt (docs/cloud-guest-upgrades.md).
KillMode=process
Restart=on-failure
RestartSec=1
TimeoutStartSec=60
NoNewPrivileges=yes

[Install]
WantedBy=default.target
UNIT
}

# Picks the inhibitors the user service may hold, one per kind. logind maps a
# combined --what=sleep:idle to the polkit action inhibit-handle-lid-switch,
# so each kind is requested (and checked) on its own. Stock polkit lets a
# lingering user (no session, polkit "any") block idle but not sleep
# (org.freedesktop.login1.inhibit-block-sleep: any=no).
choose_inhibit() {
  inhibit_what=''
  inhibit_exec=''
  for kind in sleep idle; do
    if systemd-inhibit --what="$kind" --mode=block --who=cmux-install --why=probe true >/dev/null 2>&1; then
      inhibit_what="$inhibit_what${inhibit_what:+ }$kind"
      inhibit_exec="$inhibit_exec/usr/bin/systemd-inhibit --what=$kind --mode=block --who=cmux-server --why=\"cmux server is running\" "
    else
      warn "logind refused a $kind inhibitor for this user; the health role reports it."
      [ "$kind" != sleep ] || warn 'fix once with a polkit rule (system mode installs it): see server/prototype/linux/README.md'
    fi
  done
}

render_inhibit_unit() {
  cat <<UNIT
# Generated by the cmux server installer. Changes are overwritten.
# PROTOTYPE: the Rust health role holds the logind inhibitors as D-Bus fds.
# Holds: $inhibit_what
[Unit]
Description=cmux server sleep and idle inhibitor
PartOf=cmux-server.service
After=cmux-server.service
StartLimitIntervalSec=120
StartLimitBurst=3

[Service]
ExecStart=${inhibit_exec}/bin/sleep infinity
Restart=on-failure
RestartSec=5

[Install]
WantedBy=cmux-server.service
UNIT
}

# Writes $2 from function $1 only when the content changed. Sets units_changed.
write_unit() {
  "$1" >"$tmp_dir/unit.new"
  if [ -f "$2" ] && cmp -s "$tmp_dir/unit.new" "$2"; then
    return 0
  fi
  mkdir -p "$unit_dir"
  cp "$tmp_dir/unit.new" "$2.tmp"
  mv -f "$2.tmp" "$2"
  units_changed=1
  say "wrote $2"
}

ensure_linger() {
  user=$(id -un)
  if [ "$(loginctl show-user "$user" -p Linger --value 2>/dev/null)" = yes ]; then
    linger_state='on'
    return 0
  fi
  if loginctl enable-linger "$user" 2>"$tmp_dir/linger.err"; then
    linger_state='enabled (polkit allowed it without sudo)'
    say "linger $linger_state"
    return 0
  fi
  linger_state='refused'
  warn "loginctl enable-linger was refused: $(head -n 1 "$tmp_dir/linger.err")"
  warn 'without linger the server stops at logout and does not start at boot.'
  warn "run this once, then run the installer again:  sudo loginctl enable-linger $user"
  return 1
}

user_manager_ready() {
  systemctl --user show-environment >/dev/null 2>&1
}

start_service() {
  need systemctl
  need loginctl
  units_changed=0
  choose_inhibit
  write_unit render_unit "$unit_file"
  if [ -n "$inhibit_what" ]; then
    write_unit render_inhibit_unit "$inhibit_unit_file"
    inhibit_units='cmux-server-inhibit.service'
  else
    rm -f "$inhibit_unit_file"
    inhibit_units=''
  fi
  if ! ensure_linger; then
    user_manager_ready || die 'no systemd user manager (linger is off and there is no login session)'
  fi
  user_manager_ready || die "systemd user manager is not reachable at $XDG_RUNTIME_DIR"
  if [ "$units_changed" = 1 ]; then
    systemctl --user daemon-reload || die 'systemctl --user daemon-reload failed'
  fi
  # shellcheck disable=SC2086 # inhibit_units is empty or one unit name
  systemctl --user enable cmux-server.service $inhibit_units >/dev/null 2>&1 ||
    die 'cannot enable cmux-server.service'
  if [ "$restart_needed" = 1 ] && systemctl --user is-active --quiet cmux-server.service; then
    say 'restarting cmux-server.service for the new generation (session host hand-off)'
    systemctl --user restart cmux-server.service || die 'restart failed'
  else
    # `start` blocks until the session host is ready (Type=forking) and is a
    # no-op when the unit is already active.
    systemctl --user start cmux-server.service || die 'cmux-server.service did not become ready'
  fi
  if [ -n "$inhibit_units" ] && { [ "$units_changed" = 1 ] || ! systemctl --user is-active --quiet "$inhibit_units"; }; then
    systemctl --user reset-failed "$inhibit_units" >/dev/null 2>&1 || true
    systemctl --user restart "$inhibit_units" || warn 'the inhibitor did not start'
  fi
}

print_status() {
  gen=$(current_generation)
  printf 'cmux server status\n'
  printf '  generation: %s\n' "${gen:-none}"
  if [ -n "$gen" ] && [ -f "$profiles_dir/$gen/packages" ]; then
    while read -r s_name s_version s_sha; do
      printf '  package:    %s %s %s\n' "$s_name" "$s_version" "$s_sha"
    done <"$profiles_dir/$gen/packages"
  fi
  printf '  last_sequence: %s\n' "$(state_get last_sequence none)"
  printf '  profiles:   %s\n' "$(list_generations | tr '\n' ' ')"
  printf '  store:      %s packages\n' "$(find "$store_dir" -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')"
  printf '  linger:     %s\n' "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || echo unknown)"
  printf '  service:    %s (%s)\n' "$(systemctl --user is-active cmux-server.service 2>/dev/null)" \
    "$(systemctl --user is-enabled cmux-server.service 2>/dev/null)"
  printf '  main pid:   %s\n' "$(systemctl --user show cmux-server.service -p MainPID --value 2>/dev/null)"
  printf '  inhibitor:  %s\n' "$(systemd-inhibit --list --no-pager 2>/dev/null | awk '$1 == "cmux-server" {print $6}' | tr '\n' ' ')"
}

# ---------------------------------------------------------------- actions
do_install() {
  detect_target
  make_temp
  fetch_bootstrap
  if [ "$opt_system" = 1 ]; then
    run_system_install
  fi
  [ "$(id -u)" != 0 ] || die 'refusing to install a user-mode server as root; use --system'
  # From here on the verified binary will own the work: `cmux server install`.
  fetch_manifest
  before=$(current_generation)
  install_packages
  build_profile
  restart_needed=0
  if [ "$before" != "$generation" ]; then
    flip_current "$generation"
    say "current -> generation $generation (was ${before:-none})"
    [ -z "$before" ] || restart_needed=1
  else
    say "current is already generation $generation (no change)"
  fi
  state_set last_sequence "$m_sequence"
  state_set current_generation "$generation"
  install_shim
  start_service
  print_status
}

do_rollback() {
  before=$(current_generation)
  [ -n "$before" ] || die 'nothing is installed'
  if [ -n "$opt_generation" ]; then
    target_gen=$opt_generation
  else
    target_gen=$(list_generations | awk -v cur="$before" '$1 < cur {g=$1} END {print g}')
  fi
  [ -n "$target_gen" ] || die 'no earlier generation to roll back to'
  [ -d "$profiles_dir/$target_gen" ] || die "generation $target_gen is not installed"
  [ "$target_gen" != "$before" ] || { say "already at generation $before"; print_status; return 0; }
  flip_current "$target_gen"
  state_set current_generation "$target_gen"
  say "rolled back: current -> generation $target_gen (was $before)"
  systemctl --user restart cmux-server.service || die 'restart after rollback failed'
  print_status
}

do_uninstall() {
  if [ -L "$data_dir/current" ] && [ -x "$data_dir/current/bin/cmux" ]; then
    "$data_dir/current/bin/cmux" server stop --session server --end-terminals --force >/dev/null 2>&1 || true
  fi
  # One unit per call: systemctl aborts the whole call when one unit is missing.
  for unit in cmux-server-inhibit.service cmux-postgres.service cmux-server.service; do
    # KillMode=process leaves terminal hosts after a stop by design; uninstall
    # ends every process of the unit before it stops it.
    systemctl --user kill --kill-whom=all "$unit" >/dev/null 2>&1 || true
    systemctl --user disable --now "$unit" >/dev/null 2>&1 || true
  done
  # cmux-postgres.service belongs to the postgres role (tests/pg-user-mode.sh in
  # this prototype); its data directory is state and stays.
  rm -f "$unit_file" "$inhibit_unit_file" "$unit_dir/cmux-postgres.service"
  rm -rf "$unit_dir/cmux-server.service.wants"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  if [ "$(readlink "$shim_dir/cmux" 2>/dev/null)" = "$data_dir/current/bin/cmux" ]; then
    rm -f "$shim_dir/cmux"
  fi
  if [ -d "$data_dir" ]; then
    chmod -R u+w "$data_dir"
    rm -rf "$data_dir/store" "$data_dir/profiles" "$data_dir/current"
    rmdir "$data_dir" 2>/dev/null || true
  fi
  if [ "$opt_purge" = 1 ]; then
    # PROTOTYPE: the binary takes a final Postgres base backup first (server.md 4.4).
    rm -rf "$state_dir"
    rmdir "${state_dir%/server}" 2>/dev/null || true
    say "purged state: $state_dir"
  else
    say "kept state: $state_dir"
  fi
  say "uninstalled (linger left as is; 'sudo loginctl disable-linger' turns it off)"
}

main() {
  parse_args "$@"
  layout_paths
  case "$opt_action" in
    install) do_install ;;
    rollback) do_rollback ;;
    uninstall) do_uninstall ;;
    status) print_status ;;
  esac
}

main "$@"
