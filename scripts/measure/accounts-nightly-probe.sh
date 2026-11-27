#!/usr/bin/env bash
# Fresh-profile, release-safe Accounts > GitHub App > repository-list probe for the published NEXT NIGHTLY.
# Usage: accounts-nightly-probe.sh [dmg=https://...] [build=VERSION]
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3
root="$PWD"; out="$root/.build/accounts-nightly-probe"
rm -rf "$out"; mkdir -p "$out"
dmg=""; build=""
for arg in "$@"; do
  case "$arg" in
    dmg=https://*) dmg="${arg#dmg=}" ;;
    build=*) build="${arg#build=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
if [[ -n "$build" ]]; then
  [[ "$build" =~ ^[0-9]+$ ]] || { echo "build=VERSION takes a NIGHTLY build number" >&2; exit 2; }
  dmg="https://files-next.cmux.com/nightly-next/cmux-nightly-next-macos-arm64-$build.dmg"
fi
if [[ -z "$dmg" ]]; then
  dmg="$(curl -fsSL --retry 3 --retry-all-errors -A 'cmux-accounts-nightly-probe/1' \
    https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
    | grep -oE 'url=\"https://[^\"]+-macos-arm64-[0-9]+\.dmg\"' | head -1 | cut -d'\"' -f2)"
fi
[[ "$dmg" == https://* ]] || { echo "no NIGHTLY DMG in appcast" >&2; exit 3; }
echo "ACCOUNTS_PROBE host=$(hostname -s) macOS=$(sw_vers -productVersion) dmg=$dmg"
work="$(mktemp -d "${TMPDIR:-/tmp}/cmux-accounts-nightly.XXXXXX")"; mkdir -p "$work/side" "$work/app"
export CMUX_SIDE_ROOT="$(cd "$work/side" && pwd -P)"; side="$root/scripts/cmux-next/side-instance.sh"; name=accounts-nightly; mnt=""
cleanup() {
  "$side" remove "$name" >/dev/null 2>&1 || true
  [[ -n "$mnt" ]] && hdiutil detach "$mnt" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM
curl -fsSL --retry 3 --retry-all-errors -A 'cmux-accounts-nightly-probe/1' -o "$work/nightly.dmg" "$dmg" || { echo "download failed" >&2; exit 3; }
mnt="$work/mnt"; mkdir -p "$mnt"
hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$work/nightly.dmg" >/dev/null || exit 3
source_app="$(find "$mnt" -maxdepth 1 -name '*.app' -print -quit)"; [[ -n "$source_app" ]] || { echo "DMG has no app" >&2; exit 3; }
ditto "$source_app" "$work/app/cmux NIGHTLY.app" || exit 3
hdiutil detach "$mnt" >/dev/null; mnt=""
"$side" make "$name" --from "$work/app/cmux NIGHTLY.app" --label "cmux Accounts NIGHTLY" >&2 || exit 3
app="$($side path "$name")"; pid_file="$CMUX_SIDE_ROOT/$name/pid"; socket="$($side socket "$name")"
# The credentials file is private to this side instance and removed with the owned temp directory.
cred="$work/credentials.env"; umask 077
printf 'CMUX_UITEST_STACK_EMAIL=%s\nCMUX_UITEST_STACK_PASSWORD=%s\n' "${CMUX_UITEST_STACK_EMAIL:-${CMUX_DOGFOOD_STACK_EMAIL:-}}" "${CMUX_UITEST_STACK_PASSWORD:-${CMUX_DOGFOOD_STACK_PASSWORD:-}}" >"$cred"
export CMUX_AUTH_CREDENTIALS_FILE="$cred" CMUX_DEV_AUTH_PROFILE=agent CMUX_DEV_AUTH_REPLACE_SESSION=1
"$side" launch "$name" --front -- --skip-onboarding >&2 || exit 3
pid="$(cat "$pid_file")"; [[ "$pid" =~ ^[0-9]+$ ]] || { echo "side instance has no pid" >&2; exit 3; }
python3 scripts/measure/accounts-nightly-probe.py --app "$app" --pid "$pid" --socket "$socket" --out "$out" --api "${CMUX_CLOUD_API:-https://cloud-api-staging.cmux.dev}" 2>&1 | tee "$out/run.log"
status=${PIPESTATUS[0]}
"$side" stop "$name" >&2 || true
tar -czf "$out/report.tgz" -C "$out" --exclude report.tgz . 2>/dev/null || true
echo "ACCOUNTS_PROBE exit=$status report=$out/report.tgz"
exit "$status"
