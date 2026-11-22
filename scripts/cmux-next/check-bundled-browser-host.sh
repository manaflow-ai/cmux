#!/usr/bin/env bash
# Checks the browser host in a built cmux-next app bundle.
#
#   scripts/cmux-next/check-bundled-browser-host.sh <app> [--require] [--hardened]
#
# The daemon runs the browser host as the sibling of its own executable
# (current_exe().parent()/cmux-browser-host), so the host must be the regular
# file Contents/Resources/bin/cmux-browser-host, in the directory of the real
# bin/cmux that bin/cmux-tui links to. When it is there, this checks that:
#   - it is an executable Mach-O with the same architectures as bin/cmux,
#   - its sha256 is the one the bundle phase recorded (browser_host_sha256= in
#     bin/cmux-tui.version, when the bundle has that file and field),
#   - `codesign --verify --strict` passes on it,
#   - with --hardened (release signing), it has the hardened runtime and the
#     same signing authority as bin/cmux,
#   - `cmux-browser-host version` runs and names itself (skipped, with a note,
#     when the binary has no slice for this machine).
# When it is missing, the check fails with --require or when bin/cmux-tui.version
# records a browser_host_sha256 (the bundle phase placed one); else it prints a
# note and passes: a cmux-tui build that published no browser host bundles none.
set -euo pipefail

usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; }

app=""
require=0
hardened=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --require) require=1 ;;
    --hardened) hardened=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
    *) [[ -z "$app" ]] || { usage >&2; exit 2; }; app="$1" ;;
  esac
  shift
done
[[ -n "$app" && -d "$app" ]] || { echo "error: app bundle not found: ${app:-<none>}" >&2; exit 2; }

bin_dir="$app/Contents/Resources/bin"
daemon="$bin_dir/cmux"
host="$bin_dir/cmux-browser-host"
version_file="$bin_dir/cmux-tui.version"
fail() { echo "error: check-bundled-browser-host: $*" >&2; exit 1; }

recorded=""
if [[ -f "$version_file" ]]; then
  recorded="$(awk -F= '$1=="browser_host_sha256"{print $2}' "$version_file")"
fi

if [[ ! -e "$host" && ! -L "$host" ]]; then
  if (( require )) || [[ -n "$recorded" ]]; then
    fail "$host is missing${recorded:+, but $version_file records browser_host_sha256=$recorded}"
  fi
  echo "note: check-bundled-browser-host: $app carries no bin/cmux-browser-host (its cmux-tui build published none)"
  exit 0
fi

[[ -f "$daemon" && ! -L "$daemon" ]] || fail "$daemon is not the regular daemon binary"
[[ -f "$host" && ! -L "$host" ]] || fail "$host is not a regular file"
[[ -x "$host" ]] || fail "$host is not executable"
# The daemon starts as bin/cmux-tui (a link to cmux); both names resolve into bin/.
if [[ -L "$bin_dir/cmux-tui" ]]; then
  [[ "$(readlink "$bin_dir/cmux-tui")" == cmux ]] || fail "bin/cmux-tui does not link to cmux"
fi
/usr/bin/file -b "$host" | grep -q 'Mach-O' || fail "$host is not a Mach-O file"

host_archs="$(lipo -archs "$host" | tr ' ' '\n' | sort | tr '\n' ' ')"
daemon_archs="$(lipo -archs "$daemon" | tr ' ' '\n' | sort | tr '\n' ' ')"
[[ "$host_archs" == "$daemon_archs" ]] || fail "$host has architectures '$host_archs', bin/cmux has '$daemon_archs'"

sha256="$(shasum -a 256 "$host" | awk '{print $1}')"
if [[ -n "$recorded" && "$recorded" != "$sha256" ]]; then
  fail "$host has sha256 $sha256, but $version_file records $recorded"
fi

/usr/bin/codesign --verify --strict --verbose=2 "$host" 2>&1 | sed 's/^/codesign: /'
/usr/bin/codesign --verify --strict "$host" || fail "codesign --verify failed on $host"
sign_info() { /usr/bin/codesign -d --verbose=2 "$1" 2>&1 | grep -E '^(CodeDirectory|Signature|Authority|TeamIdentifier)' | sed 's/hashes=.*//' || true; }
echo "browser host signature: $(sign_info "$host" | tr '\n' ';')"
echo "daemon signature:       $(sign_info "$daemon" | tr '\n' ';')"
if (( hardened )); then
  /usr/bin/codesign -d --verbose=2 "$host" 2>&1 | grep -q 'flags=.*runtime' \
    || fail "$host is not signed with the hardened runtime"
  host_authority="$(/usr/bin/codesign -d --verbose=2 "$host" 2>&1 | grep -m1 '^Authority=' || true)"
  daemon_authority="$(/usr/bin/codesign -d --verbose=2 "$daemon" 2>&1 | grep -m1 '^Authority=' || true)"
  [[ -n "$host_authority" && "$host_authority" == "$daemon_authority" ]] \
    || fail "$host is signed by '${host_authority:-nobody}', bin/cmux by '${daemon_authority:-nobody}'"
fi

machine="$(uname -m)"
if lipo "$host" -verify_arch "$machine" 2>/dev/null; then
  version="$("$host" version 2>&1 | head -n 1)" || fail "$host version failed: $version"
  [[ "$version" == "cmux-browser-host "* ]] || fail "$host version printed '$version'"
  echo "browser host version: $version"
else
  echo "note: check-bundled-browser-host: $host has no $machine slice; did not run version"
fi
echo "check-bundled-browser-host: OK $host (sha256 $sha256, archs ${host_archs% }) beside $daemon"
