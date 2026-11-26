#!/usr/bin/env bash
# launch-ready.sh dmg=swap (swap-nightly.sh): every arm is a copy of the one nightly, swapped at its commit and sealed;
# base=nightly is the nightly's own binary, sealed the same way; a commit a swap cannot carry is refused before any
# build. curl, hdiutil, ditto, plutil and the swap tool are stand-ins, so this runs on Linux:
#   bash scripts/measure/tests/swap-nightly.test.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
out="$root/out" fixture="$root/fixture"
mkdir -p "$out" "$fixture/cmux NIGHTLY.app/Contents/MacOS"
echo "nightly exe" >"$fixture/cmux NIGHTLY.app/Contents/MacOS/cmux"
export CMUX_SWAP_BINARY_ROOT="$root/cache"

curl() { # the feed, then the DMG (the fixture's folder stands for it)
  local o=""
  while [[ $# -gt 0 ]]; do [[ "$1" == -o ]] && { o="$2"; shift; }; shift; done
  if [[ -n "$o" ]]; then echo dmg >"$o"; else echo 'url="https://files-next.cmux.com/nightly-next/cmux-nightly-next-macos-arm64-1.dmg"'; fi
}
hdiutil() { if [[ "$1" == attach ]]; then cp -R "$fixture/cmux NIGHTLY.app" "$6/"; fi; }
ditto() { cp -R "$1" "$2"; }
plutil() { case "$2" in CMUXCommit) echo "${NIGHTLY_COMMIT:-$(printf 'a%.0s' {1..40})}" ;; CFBundleVersion) echo 4424316677601 ;; esac; }
export -f plutil

tool="$root/swap-binary.sh"
cat >"$tool" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$CMUX_SWAP_BINARY_ROOT/calls"
case "$1" in
  check) [[ "$3" != bad* ]] || { echo "swap-binary: not carried: cmux.xcodeproj/project.pbxproj" >&2; exit 3; } ;;
  build) mkdir -p "$3"; echo '{"build_s": 42}' >"$3/build.json" ;;
  place) echo "head exe at $3" >"$2/Contents/MacOS/cmux"; echo "SB-PLACE app=$2 replaced=MacOS/cmux,Resources/CmuxNext_CmuxNextApp.bundle added=" ;;
  seal) echo "sealed" >"$2/Contents/sealed"; echo "SB-SEAL app=$2 signature=adhoc flags=0x2(adhoc)" ;;
  diff) echo "changed Contents/MacOS/cmux"; echo "added Contents/sealed" ;;
esac
EOF
chmod +x "$tool"
export SWAP_NIGHTLY_TOOL="$tool"
fail() { echo "swap-nightly: $*" >&2; exit 1; }

# shellcheck source=../swap-nightly.sh
source "$here/swap-nightly.sh"
base="$(printf 'b%.0s' {1..40})" head="$(printf 'c%.0s' {1..40})"
log="$(swap_nightly "$out" "" base=nightly head="$head")"
grep -q '^LR nightly https://files-next.cmux.com/nightly-next/cmux-nightly-next-macos-arm64-1.dmg sha256=[0-9a-f]\{64\} version=4424316677601 commit=a\{40\}$' <<<"$log" \
  || fail "no LR nightly line with the URL and hash: $log"
grep -q "^LR swap side=base sha=nightly nightly_version=4424316677601 build_s=0 replaced=$" <<<"$log" || fail "base=nightly line: $log"
grep -q "^LR swap side=head sha=$head nightly_version=4424316677601 build_s=42 replaced=MacOS/cmux,Resources/CmuxNext_CmuxNextApp.bundle$" <<<"$log" || fail "head line: $log"
grep -q '^LR swap-sig side=base adhoc flags=0x2(adhoc)' <<<"$log" || fail "base arm not sealed: $log"
grep -q '^LR swap-diff side=head changed Contents/MacOS/cmux files=1$' <<<"$log" || fail "no per-item diff: $log"
[[ "$(cat "$out/swap-base/cmux NIGHTLY.app/Contents/MacOS/cmux")" == "nightly exe" ]] || fail "base arm's binary changed"
[[ "$(cat "$out/swap-head/cmux NIGHTLY.app/Contents/MacOS/cmux")" == "head exe at $out/swapbuild-head" ]] || fail "head arm not swapped"
[[ -f "$out/swap-base/cmux NIGHTLY.app/Contents/sealed" && -f "$out/swap-head/cmux NIGHTLY.app/Contents/sealed" ]] || fail "an arm not sealed"
[[ "$(cat "$out/nightly/cmux NIGHTLY.app/Contents/MacOS/cmux")" == "nightly exe" ]] || fail "the nightly itself changed"
! grep -q "^build nightly" "$CMUX_SWAP_BINARY_ROOT/calls" || fail "built base=nightly"
echo "swap-nightly: base=nightly is sealed only, head is swapped and sealed, the receipt names both"

# The DMG this run fetched, by its hash: a rerun on the host reuses it.
hex="$(sed -n 's/.* sha256=\([0-9a-f]*\) .*/\1/p' <<<"$log")"
rm -rf "$out" && mkdir -p "$out"
log="$(swap_nightly "$out" "sha256:$hex" head="$head")"
grep -q "^LR nightly https://files-next.cmux.com/.* sha256=$hex " <<<"$log" || fail "sha256: did not reuse the DMG: $log"
echo "swap-nightly: nightly=sha256:HEX reuses the host's DMG"

# A commit a swap cannot carry: refused before any build, exit 3.
rm -rf "$out" "$CMUX_SWAP_BINARY_ROOT/calls" && mkdir -p "$out"
set +e
log="$(swap_nightly "$out" "" base="$base" head="bad$(printf 'c%.0s' {1..37})")"; rc=$?
set -e
[[ $rc == 3 ]] || fail "refusal exit $rc, want 3"
grep -q '^LR swap refused: side=head sha=bad.* not carried: cmux.xcodeproj/project.pbxproj' <<<"$log" || fail "refusal line: $log"
! grep -q "^build " "$CMUX_SWAP_BINARY_ROOT/calls" || fail "built before refusing"
echo "swap-nightly: a commit a swap cannot carry is refused before any build"

# launch-ready.sh takes dmg=swap with base=nightly and refuses base=nightly elsewhere.
lr="$here/launch-ready.sh"
grep -q 'dmg=nightly|dmg=build|dmg=swap|dmg=https' "$lr" || fail "launch-ready.sh does not take dmg=swap"
set +e
msg="$(bash "$lr" dmg=build base=nightly 2>&1 >/dev/null)"; rc=$?
set -e
[[ $rc == 2 && "$msg" == *"base= takes a 40-hex commit"* ]] || fail "launch-ready accepted base=nightly with dmg=build ($rc: $msg)"
echo "swap-nightly: launch-ready.sh takes base=nightly only with dmg=swap"
