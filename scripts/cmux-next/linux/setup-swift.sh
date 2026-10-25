#!/usr/bin/env bash
# Install the Swift toolchain that CI's Linux package job uses, through swiftly, on an
# Ubuntu 24.04 host (the 360-core VM). Idempotent: every step checks before it downloads.
#
# The version comes from files, never from this script:
#   1. CI pin: the swift image (tag + digest) in .github/workflows/swift-packages-linux.yml.
#      The digest is resolved to the image's exact SWIFT_VERSION (cached per digest).
#   2. hq pin: SWIFT_VERSION in cmuxterm-hq build-fleet/swift-linux-builder/setup.sh.
# The CI pin wins; a different hq pin is printed, not used.
#
# Usage: scripts/cmux-next/linux/setup-swift.sh [--check]
#   --check   report what would change and exit 1 if anything would; change nothing.
# Env: CMUX_HQ (cmuxterm-hq checkout), SWIFTLY_HOME_DIR, SWIFTLY_BIN_DIR.
set -euo pipefail

check_only=0
case "${1:-}" in
  "") ;;
  --check) check_only=1 ;;
  -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "setup-swift: unknown argument: $1" >&2; exit 2 ;;
esac

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="$repo/.github/workflows/swift-packages-linux.yml"
export SWIFTLY_HOME_DIR="${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}"
export SWIFTLY_BIN_DIR="${SWIFTLY_BIN_DIR:-$SWIFTLY_HOME_DIR/bin}"
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/cmux/swift-image"
pending=()

say() { printf 'setup-swift: %s\n' "$*"; }
die() { printf 'setup-swift: error: %s\n' "$*" >&2; exit 1; }
# swiftly and its `swift` proxy follow any .swift-version above the working directory,
# and `install --use` writes one there; run them from / so the checkout is never touched.
in_root() { (cd / && "$@"); }
# Record a needed change. In --check mode, skip it and report; otherwise do it.
needs() {
  pending+=("$1")
  if (( check_only )); then say "would: $1"; return 1; fi
  say "doing: $1"
}

[[ "$(uname -s)" == Linux ]] || die "Linux only (this is $(uname -s))"
# shellcheck source=/dev/null
. /etc/os-release
[[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 24.04 ]] \
  || die "needs Ubuntu 24.04 (the noble image CI uses); this is ${PRETTY_NAME:-unknown}"
case "$(uname -m)" in
  x86_64) oci_arch=amd64 ;;
  aarch64) oci_arch=arm64 ;;
  *) die "unsupported architecture $(uname -m)" ;;
esac

# --- 1. System packages: swift.org's Ubuntu 24.04 toolchain deps (the list hq setup.sh
# installs), the -dev headers the packages link (CI adds libsqlite3-dev), and this
# script's own tools.
apt_packages=(
  binutils git gnupg2 libc6-dev libcurl4-openssl-dev libedit2 libgcc-13-dev libncurses-dev
  libpython3-dev libsqlite3-0 libsqlite3-dev libstdc++-13-dev libxml2-dev libz3-dev
  pkg-config tzdata unzip zlib1g-dev ca-certificates curl jq
)
missing=()
for p in "${apt_packages[@]}"; do
  dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || missing+=("$p")
done
if (( ${#missing[@]} == 0 )); then
  say "apt packages: present (${#apt_packages[@]})"
elif needs "apt-get install ${missing[*]}"; then
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${missing[@]}" >/dev/null
fi

# --- 2. The CI pin.
[[ -f "$workflow" ]] || die "missing $workflow"
image="$(sed -nE 's/^[[:space:]]*container:[[:space:]]*([^[:space:]]*\/swift:[^[:space:]]+).*/\1/p' "$workflow" | head -1)"
[[ "$image" =~ ^([^:]+)/swift:([0-9]+\.[0-9]+)-noble@(sha256:[0-9a-f]{64})$ ]] \
  || die "no swift:<major.minor>-noble@sha256 container in $workflow (found: '${image:-nothing}')"
registry_repo="${BASH_REMATCH[1]}/swift"
ci_minor="${BASH_REMATCH[2]}"
ci_digest="${BASH_REMATCH[3]}"

# The tag names only major.minor; the digest fixes the patch release. Read it from the
# image config, as `docker inspect` would, without pulling the image.
resolve_image_version() {
  local host="${registry_repo%%/*}" name="${registry_repo#*/}" token index manifest config
  [[ "$host" == public.ecr.aws ]] || return 1
  token="$(curl -fsSL "https://public.ecr.aws/token/?scope=repository:$name:pull" | jq -er .token)" || return 1
  local auth=(-H "Authorization: Bearer $token")
  index="$(curl -fsSL "${auth[@]}" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
    "https://$host/v2/$name/manifests/$ci_digest")" || return 1
  manifest="$(jq -er --arg a "$oci_arch" '.manifests[] | select(.platform.os == "linux" and .platform.architecture == $a) | .digest' <<<"$index" | head -1)" || return 1
  config="$(curl -fsSL "${auth[@]}" \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    "https://$host/v2/$name/manifests/$manifest" | jq -er .config.digest)" || return 1
  curl -fsSL "${auth[@]}" "https://$host/v2/$name/blobs/$config" \
    | jq -er '.config.Env[] | select(startswith("SWIFT_VERSION=")) | sub("^SWIFT_VERSION=swift-"; "") | sub("-RELEASE$"; "")'
}

cache_file="$cache_dir/${ci_digest#sha256:}-$oci_arch"
if [[ -s "$cache_file" ]]; then
  ci_version="$(cat "$cache_file")"
else
  ci_version="$(resolve_image_version)" || die "could not read SWIFT_VERSION of $registry_repo@$ci_digest ($oci_arch)"
  mkdir -p "$cache_dir" && printf '%s\n' "$ci_version" >"$cache_file"
fi
[[ "$ci_version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ && ( "$ci_version" == "$ci_minor" || "$ci_version" == "$ci_minor".* ) ]] \
  || die "image $ci_digest reports Swift '$ci_version', not $ci_minor.x as its tag says"
say "CI pin: Swift $ci_version (swift:$ci_minor-noble@${ci_digest:0:19}..., $workflow)"

# --- 3. The hq pin, for comparison.
find_hq() {
  local c common
  common="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  for c in "${CMUX_HQ:-}" "${common:+$(dirname "$(dirname "$common")")/cmuxterm-hq}" \
           "$HOME/fun/cmuxterm-hq" "$HOME/cmuxterm-hq" "$HOME/Projects/cmuxterm-hq"; do
    [[ -n "$c" && -d "$c/build-fleet" ]] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}
hq_setup=build-fleet/swift-linux-builder/setup.sh
if hq="$(find_hq)"; then
  # Prefer hq main, the source of truth, over whatever the checkout has out.
  hq_text="$(git -C "$hq" show "origin/main:$hq_setup" 2>/dev/null || cat "$hq/$hq_setup" 2>/dev/null || true)"
  hq_version="$(sed -nE 's/^SWIFT_VERSION="\$\{SWIFT_VERSION:-([0-9.]+)\}".*/\1/p' <<<"$hq_text" | head -1)"
  if [[ -z "$hq_version" ]]; then
    say "hq pin: no SWIFT_VERSION default in $hq/$hq_setup; using the CI pin"
  elif [[ "$hq_version" == "$ci_version" ]]; then
    say "hq pin: Swift $hq_version, same as CI"
  else
    say "hq pin: Swift $hq_version ($hq/$hq_setup) differs from the CI pin $ci_version; using CI's $ci_version"
  fi
else
  say "hq pin: no cmuxterm-hq checkout found (set CMUX_HQ); using the CI pin"
fi

# --- 4. swiftly.
swiftly="$SWIFTLY_BIN_DIR/swiftly"
if [[ -x "$swiftly" && -f "$SWIFTLY_HOME_DIR/config.json" ]]; then
  say "swiftly: present ($("$swiftly" --version 2>/dev/null || echo unknown version))"
elif needs "install swiftly into $SWIFTLY_HOME_DIR"; then
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  url="https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz"
  curl -fsSL -o "$work/swiftly.tgz" "$url"
  curl -fsSL -o "$work/swiftly.tgz.sig" "$url.sig"
  curl -fsSL -o "$work/keys.asc" https://www.swift.org/keys/all-keys.asc
  install -d -m 700 "$work/gnupg"
  gpg --homedir "$work/gnupg" --batch --quiet --import "$work/keys.asc" 2>/dev/null
  gpg --homedir "$work/gnupg" --batch --quiet --verify "$work/swiftly.tgz.sig" "$work/swiftly.tgz" 2>/dev/null \
    || die "swiftly signature does not verify against swift.org's keys"
  tar -xzf "$work/swiftly.tgz" -C "$work" swiftly
  # The profile is left alone: callers source $SWIFTLY_HOME_DIR/env.sh (see README.md).
  in_root "$work/swiftly" init --assume-yes --no-modify-profile --skip-install --quiet-shell-followup >/dev/null
fi

# --- 5. The toolchain, as swiftly's global default (in_root: see its definition).
swift_version() {
  in_root "$SWIFTLY_BIN_DIR/swift" --version 2>/dev/null | sed -nE 's/.*Swift version ([0-9.]+).*/\1/p' | head -1
}
current="$(swift_version || true)"
if [[ "$current" == "$ci_version" ]]; then
  say "toolchain: Swift $ci_version is the default"
elif [[ ! -x "$swiftly" ]]; then
  needs "install Swift $ci_version and make it the default" || true
elif in_root "$swiftly" list 2>/dev/null | grep -qE "^Swift $ci_version( |$)"; then
  needs "make the installed Swift $ci_version the default (now: ${current:-none})" \
    && in_root "$swiftly" use --global-default --assume-yes "$ci_version" >/dev/null
elif needs "install Swift $ci_version and make it the default (now: ${current:-none})"; then
  # swiftly verifies the toolchain's signature itself.
  in_root "$swiftly" install --assume-yes "$ci_version"
  in_root "$swiftly" use --global-default --assume-yes "$ci_version" >/dev/null
fi

if (( check_only )); then
  (( ${#pending[@]} == 0 )) && { say "up to date"; exit 0; }
  say "${#pending[@]} change(s) needed"; exit 1
fi
version_line="$(in_root "$SWIFTLY_BIN_DIR/swift" --version 2>&1 | head -1)"
[[ "$version_line" == *"Swift version $ci_version"* ]] || die "after setup, swift reports: $version_line"
say "${#pending[@]} change(s) made; $version_line"
say "use it: . \"$SWIFTLY_HOME_DIR/env.sh\""
