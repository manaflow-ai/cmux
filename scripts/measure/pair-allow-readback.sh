#!/usr/bin/env bash
# A Mac's waiting pairing request answered with no click, by the published cmux NEXT NIGHTLY's own CLI, on a fleet
# Mac. The NIGHTLY DMG is mounted read-only and its app copied into a temp folder (the Mac's own apps are untouched);
# then cmux-mobile-host's two `lists_and_allows` tests run with CMUX_PAIR_REQUESTS_CLI naming the bundled `cmux`:
#   this_mac_lists_and_allows_its_own_waiting_request_over_its_link_socket  (no --mac: this Mac's own hostd socket)
#   a_paired_mac_lists_and_allows_a_waiting_request_over_its_link_socket    (--mac: a probe phone dials over a link)
# Each runs `cmux mobile pair-requests list` and `allow ID --fingerprint FP` and asserts hostd's PairAnswer (allow).
# Leo's ask c-45c37458ea ("surely we dont need to be bottled this hard by a click").
#   cmux-ci run --class isolated --label measure --os macos --script scripts/measure/pair-allow-readback.sh --ref <sha> [--arg=dmg=URL]
set -uo pipefail
dmg=""
for arg in "$@"; do
  case "$arg" in
    dmg=https://*) dmg="${arg#dmg=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
# shellcheck source-path=SCRIPTDIR source=../cmux-next/lib/fleet-only.sh
source "$(dirname "${BASH_SOURCE[0]}")/../cmux-next/lib/fleet-only.sh"
cmux_next_require_fleet pair-allow-readback.sh "cargo test" "none (a measurement)" \
  "cmux-ci run --class isolated --label measure --os macos --script scripts/measure/pair-allow-readback.sh --ref SHA"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
export PATH="$HOME/.cargo/bin:$PATH"
if [[ -z "$dmg" ]]; then
  dmg="$(curl -fsSL --retry 3 --retry-all-errors https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
    | grep -oE 'url="https://[^"]+-macos-arm64-[0-9]+\.dmg"' | head -1 | cut -d'"' -f2)"
fi
[[ "$dmg" == https://* ]] || { echo "no nightly DMG in the feed" >&2; exit 3; }
echo "PAR host $(hostname -s) macOS $(sw_vers -productVersion) dmg $dmg step $(git -C "$root" rev-parse HEAD)"

work="$(mktemp -d "${TMPDIR:-/tmp}/pair-allow-readback.XXXXXX")"
mnt=""
cleanup() { [[ -n "$mnt" ]] && hdiutil detach "$mnt" >/dev/null 2>&1; rm -rf "$work"; }
trap cleanup EXIT
# Every call that can wait on something (the bundled CLI, cargo) runs under a bound: a 2026-11-27 run sat 6 h after the
# plist read with no output. macOS has no timeout(1); perl's alarm survives exec and SIGALRM ends the call (rc 142).
bounded() { local secs="$1"; shift; perl -e 'alarm shift; exec @ARGV or die "exec $ARGV[0]: $!"' "$secs" "$@"; }
curl -fsSL --proto '=https' --retry 3 --retry-all-errors -o "$work/nightly.dmg" "$dmg" || { echo "PAR download failed"; exit 3; }
mnt="$work/mnt"; mkdir -p "$mnt"
hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$work/nightly.dmg" >/dev/null || exit 3
src="$(find "$mnt" -maxdepth 1 -name '*.app' | head -1)"
ditto "$src" "$work/app.app"
hdiutil detach "$mnt" >/dev/null; mnt=""
plist="$work/app.app/Contents/Info.plist"
echo "PAR nightly $(plutil -extract CFBundleShortVersionString raw -o - "$plist") build $(plutil -extract CFBundleVersion raw -o - "$plist")"
# The tests come from the step's --ref, the CLI from the NIGHTLY: name the NIGHTLY's own commit too.
plutil -p "$plist" | grep -iE 'commit|sha|revision' | sed 's/^ */PAR nightly plist /'
cli="$(find "$work/app.app/Contents" -type f -perm -u+x -name cmux 2>/dev/null | head -1)"
[[ -n "$cli" ]] || { echo "PAR no cmux CLI in the bundle"; exit 3; }
echo "PAR cli ${cli#"$work/app.app/"}: $(HOME="$work" bounded 60 "$cli" --version </dev/null 2>&1 | head -1) (rc ${PIPESTATUS[0]})"
HOME="$work" bounded 60 "$cli" mobile pair-requests --help </dev/null 2>&1 | head -6 | sed 's/^/PAR help /'

cd "$root/cmux-next-ios/rust" || exit 3
export CARGO_TARGET_DIR="$root/.build/pair-allow-readback-target"
CMUX_PAIR_REQUESTS_CLI="$cli" bounded 2700 cargo test --locked -p cmux-mobile-host --test host -- lists_and_allows \
  --nocapture --test-threads=1 2>&1 | tee "$work/test.log"
status=${PIPESTATUS[0]}
[[ "$status" == 142 ]] && echo "PAR cargo test passed its 2700 s bound"
grep -E '^test .* (ok|FAILED)$|^test result' "$work/test.log" | sed 's/^/PAR /'
echo "PAR exit=$status step $(git -C "$root" rev-parse HEAD) nightly $(plutil -extract CFBundleVersion raw -o - "$plist")"
exit "$status"
