#!/usr/bin/env bash
# The live code NIGHTLY variant (nightly.yml build-live-code-variant, sign-live-code-variant), proven on a fleet Mac with no secret: the newest
# nightly-next build's own commit built -interposable (scripts/ci/nightly-steps/live-code-variant.sh build), grafted
# into that build's signed app (graft: the commit check is real, the two are the same commit), sealed ad hoc with the
# nightly's own entitlements and the hardened runtime in place of the Team identity the workflow signs with, and
# packed into a DMG. Notarization needs release-next and runs only in the workflow.
#   cmux-ci run --class exclusive --label measure --script scripts/measure/live-code-variant-proof.sh --ref SHA \
#     [--arg nightly=URL] --artifact .build/live-code-variant-proof/report.tgz --timeout 7200
# Prints LCV-NIGHTLY, LCV-BUILD (BUILD SUCCEEDED and its seconds), LCV-ARTIFACT name=size lines, LCV-SEAL and
# LCV-PROOF {json}. report.tgz keeps the logs, cost.json and the interposable list.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3
root="$PWD"
out="$root/.build/live-code-variant-proof"
rm -rf "$out" && mkdir -p "$out"
nightly=""
for arg in "$@"; do
  case "$arg" in
    nightly=https://*) nightly="${arg#nightly=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
work="$(mktemp -d "${TMPDIR:-/tmp}/live-code-variant-proof.XXXXXX")"
trap 'rm -rf "$work"' EXIT
echo "LCV host $(hostname -s) macOS $(sw_vers -productVersion) xcode=\"$(xcodebuild -version 2>/dev/null | tr '\n' ' ')\""
if [[ -z "$nightly" ]]; then
  nightly="$(curl -fsSL --proto '=https' --retry 3 --retry-all-errors -H "Cache-Control: no-cache" https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
    | grep -oE 'url="https://[^"]+-macos-arm64-[0-9]+\.dmg"' | head -1 | cut -d'"' -f2)"
fi
curl -fsSL --proto '=https' --retry 3 --retry-all-errors -o "$work/nightly.dmg" "$nightly" || { echo "LCV download failed"; exit 3; }
mkdir -p "$work/mnt"
hdiutil attach -nobrowse -readonly -mountpoint "$work/mnt" "$work/nightly.dmg" >/dev/null || exit 3
src="$(find "$work/mnt" -maxdepth 1 -name '*.app' | head -1)"
commit="$(plutil -extract CMUXCommit raw -o - "$src/Contents/Info.plist")"
version="$(plutil -extract CFBundleVersion raw -o - "$src/Contents/Info.plist")"
hdiutil detach "$work/mnt" >/dev/null
echo "LCV-NIGHTLY $nightly version=$version commit=$commit"

tool="$root/scripts/ci/nightly-steps/live-code-variant.sh"
t0=$(date +%s)
CMUX_SWAP_BINARY_ROOT="$work/swap-root" bash "$tool" build "$commit" "$work/lc" > "$out/build.log" 2>&1
rc=$?
build_s=$(( $(date +%s) - t0 ))
cp "$work/lc/overlay/"{xcodebuild.log,xcodebuild-relink.log,cost.json,interposable.txt,build.json} "$out/" 2>/dev/null
if [[ $rc -ne 0 ]]; then
  echo "LCV-BUILD FAILED rc=$rc after ${build_s}s"; tail -40 "$out/build.log"
  tar -C "$out" -czf "$out/report.tgz" --exclude report.tgz . ; exit 1
fi
succeeded="$(grep -c '\*\* BUILD SUCCEEDED \*\*' "$out/xcodebuild.log" "$out/xcodebuild-relink.log" 2>/dev/null | paste -sd' ' -)"
echo "LCV-BUILD BUILD SUCCEEDED ($succeeded) in ${build_s}s"
mkdir -p "$work/tree/overlay"
tar -C "$work/tree/overlay" -xzf "$work/lc/overlay.tar.gz"
ents="$(bash "$tool" graft "$work/nightly.dmg" "$work/tree/overlay" "$work/variant/cmux NIGHTLY.app" 2>"$out/graft.log")" \
  || { echo "LCV graft failed"; cat "$out/graft.log"; exit 1; }
app="$work/variant/cmux NIGHTLY.app"
cp "$ents" "$out/nightly.entitlements"
# The workflow seals with the Team identity (live-code-variant.sh sign); here an ad hoc seal of the same shape.
/usr/bin/codesign --force --options runtime --entitlements "$ents" --sign - "$app" 2>>"$out/graft.log" \
  && /usr/bin/codesign --verify --deep --strict "$app" 2>>"$out/graft.log"
seal=$?
flags="$(/usr/bin/codesign -dv "$app" 2>&1 | sed -n 's/^CodeDirectory .*flags=0x[0-9a-f]*(\([^)]*\)).*/\1/p')"
echo "LCV-SEAL rc=$seal flags=$flags live_mark=$(plutil -extract CMUXLiveCodeBuild raw -o - "$app/Contents/Info.plist")"
dmg="$work/variant-$version-live-code.dmg"
hdiutil create -quiet -volname "cmux NIGHTLY" -srcfolder "$work/variant" -format UDZO "$dmg" || { echo "LCV dmg failed"; exit 1; }
modules="$work/lc/live-code-modules-$commit.tar.gz"
size() { stat -f %z "$1"; }
exe="$app/Contents/MacOS/cmux"
interposable=$(wc -l < "$out/interposable.txt" | tr -d ' ')
for f in "$work/nightly.dmg" "$dmg" "$modules" "$work/lc/overlay.tar.gz" "$exe"; do echo "LCV-ARTIFACT $(basename "$f")=$(size "$f")"; done
printf 'LCV-PROOF {"nightly":"%s","version":"%s","commit":"%s","build_s":%s,"seal_rc":%s,"flags":"%s","interposable":%s,"nightly_dmg_bytes":%s,"variant_dmg_bytes":%s,"modules_bytes":%s,"exe_bytes":%s}\n' \
  "$nightly" "$version" "$commit" "$build_s" "$seal" "$flags" "$interposable" "$(size "$work/nightly.dmg")" "$(size "$dmg")" \
  "$(size "$modules")" "$(size "$exe")" | tee "$out/proof.txt"
tar -C "$out" -czf "$work/report.tgz" . && mv "$work/report.tgz" "$out/report.tgz"
[[ $seal -eq 0 ]]
