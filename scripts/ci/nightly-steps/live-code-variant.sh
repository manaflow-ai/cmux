#!/usr/bin/env bash
# The NIGHTLY's opt-in live code variant (Leo's design, 2026-11-04: "The opt-in injectable nightly"), made by
# nightly.yml's build-live-code-variant and sign-live-code-variant after a nightly-next build reaches the feed. The default nightly does not change: the variant is
# a copy of that build's own signed app with only the executable and the package resource bundles replaced by the
# same commit's live code build (scripts/cmux-next/swap-binary.sh build --live-code: -Onone CmuxNext, its exports
# interposable, linked -no_fixup_chains), then re-sealed with the team identity, hardened runtime and the nightly's
# own entitlements (read from the nightly's signature, so the variant can never ask for more), and notarized by
# notarize-nightly-dmg.sh as the nightly is. Its module outputs are kept beside it, keyed by commit.
#
#   live-code-variant.sh build COMMIT OUT [SWIFT_FLAGS]   (fleet Mac, no secret) the overlay into OUT/overlay and
#                                                         OUT/live-code-modules-<commit>.tar.gz
#   live-code-variant.sh graft DMG OVERLAY APP_OUT        the nightly DMG's app copied to APP_OUT with OVERLAY placed
#                                                         in; prints the nightly's entitlements file path. Runs no
#                                                         bundle code.
#   live-code-variant.sh prepare PREFIX BUILD ARTIFACT  (sign-live-code-variant, no secret) the published nightly DMG
#                                                         grafted with ARTIFACT/overlay.tar.gz into ./variant; writes
#                                                         VARIANT_APP, VARIANT_ENTITLEMENTS and the names to GITHUB_ENV
#   live-code-variant.sh sign APP ENTITLEMENTS            (signing keychain open, APPLE_SIGNING_IDENTITY) frameworks
#                                                         the overlay added, then the main bundle (main-only)
#   live-code-variant.sh names PREFIX BUILD               the published names, as KEY=VALUE lines for GITHUB_ENV
#   live-code-variant.sh publish BUILD COMMIT DMG MODULES RUN_URL
#                                                         (the nightly-next R2 keys) uploads DMG and MODULES write-once,
#                                                         then live-code-<commit>.json naming both (sizes, SHA-256s)
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
die() { echo "live-code-variant: $*" >&2; exit 1; }

cmd="${1:-}"; shift || true
case "$cmd" in
  build)
    commit="${1:?COMMIT}" out="${2:?OUT}" flags="${3:-}"
    [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "COMMIT must be a full 40-hex sha, not '$commit'"
    mkdir -p "$out"; out="$(cd "$out" && pwd -P)"
    bash "$root/scripts/cmux-next/swap-binary.sh" build "$commit" "$out/overlay" --live-code --swift-flags "$flags"
    o="$out/overlay"
    [[ -f "$o/app/Contents/MacOS/cmux" && -s "$o/interposable.txt" && -d "$o/modules" ]] || die "the build left no live code overlay in $o"
    # The module outputs a patch compiles against (docs: "Per-nightly artifacts"): interfaces and binary modules,
    # the compile command lines (pass 1's xcodebuild.log, EMIT_FRONTEND_COMMAND_LINES), the relink's log, the
    # interposable list, the bind check and the .o index.
    keep=(modules xcodebuild.log xcodebuild-relink.log interposable.txt cost.json objects.sha256 build.json)
    for f in exports-2.txt binds-2.txt fixups-2.txt named-2.txt missing-2.txt; do [[ ! -f "$o/$f" ]] || keep+=("$f"); done
    tar -C "$o" -czf "$out/live-code-modules-$commit.tar.gz" "${keep[@]}"
    tar -C "$o" -czf "$out/overlay.tar.gz" app build.json
    ls -l "$out"
    ;;
  graft)
    dmg="${1:?DMG}" overlay="${2:?OVERLAY}" app_out="${3:?APP_OUT}"
    [[ ! -e "$app_out" ]] || die "$app_out exists"
    mnt="$(mktemp -d)"
    hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mnt" >/dev/null || die "cannot attach $dmg"
    trap 'hdiutil detach "$mnt" >/dev/null 2>&1 || hdiutil detach -force "$mnt" >/dev/null 2>&1 || true; rmdir "$mnt" 2>/dev/null || true' EXIT
    src="$(find "$mnt" -maxdepth 1 -name '*.app' -type d | head -1)"
    [[ -n "$src" ]] || die "$dmg holds no app"
    mkdir -p "$(dirname "$app_out")"
    ditto "$src" "$app_out"
    ents="$(dirname "$app_out")/nightly.entitlements"
    # The nightly's entitlements, as signed: the variant asks for exactly these.
    /usr/bin/codesign -d --entitlements - --xml "$app_out" > "$ents" 2>/dev/null || die "cannot read the nightly's entitlements"
    plutil -lint "$ents" >/dev/null || die "the nightly's entitlements are not a plist"
    want="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["ref"])' "$overlay/build.json")"
    have="$(plutil -extract CMUXCommit raw -o - "$app_out/Contents/Info.plist" 2>/dev/null || true)"
    [[ "$want" == "$have" ]] || die "the overlay is of $want, the nightly of ${have:-no CMUXCommit}: not the same commit"
    bash "$root/scripts/cmux-next/swap-binary.sh" place "$app_out" "$overlay" >&2
    # The Live mode mark (docs/cmux-next/live-code.md): a live code build's Info.plist says so.
    /usr/libexec/PlistBuddy -c 'Delete :CMUXLiveCodeBuild' "$app_out/Contents/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c 'Add :CMUXLiveCodeBuild bool true' "$app_out/Contents/Info.plist"
    echo "$ents"
    ;;
  prepare)
    prefix="${1:?PREFIX}" build="${2:?BUILD}" art="${3:?ARTIFACT}"
    [[ "$build" =~ ^[0-9]+$ ]] || die "BUILD must be a number, not '$build'"
    curl -fsSL --retry 5 --speed-limit 1000 --speed-time 120 -o nightly.dmg \
      "${NIGHTLY_NEXT_FEED_BASE:?}/$prefix-arm64-$build.dmg"
    mkdir overlay && tar -C overlay -xzf "$art/overlay.tar.gz"
    ents="$(bash "$0" graft nightly.dmg overlay "$PWD/variant/cmux.app")"
    { echo "VARIANT_APP=$PWD/variant/cmux.app"; echo "VARIANT_ENTITLEMENTS=$ents"
      bash "$0" names "$prefix" "$build"; } >> "${GITHUB_ENV:?}"
    ;;
  sign)
    app="${1:?APP}" ents="${2:?ENTITLEMENTS}"
    [[ -n "${APPLE_SIGNING_IDENTITY:-}" ]] || die "no APPLE_SIGNING_IDENTITY"
    # Frameworks the overlay added (swap-binary place's added=): signed as sign-cmux-bundle.sh signs frameworks.
    for fw in "$app/Contents/Frameworks"/*; do
      [[ -e "$fw" ]] || continue
      /usr/bin/codesign --verify --strict "$fw" >/dev/null 2>&1 && continue
      "$root/scripts/codesign-retry.sh" --force --options runtime --timestamp --sign "$APPLE_SIGNING_IDENTITY" --deep "$fw"
    done
    CMUX_SIGN_MODE=main-only "$root/scripts/sign-cmux-bundle.sh" "$app" "$ents" "$APPLE_SIGNING_IDENTITY"
    flags="$(/usr/bin/codesign -dv "$app" 2>&1 | sed -n 's/^CodeDirectory .*flags=\(0x[0-9a-f]*\)(\([^)]*\)).*/\2/p')"
    [[ "$flags" == *runtime* ]] || die "the variant is not signed with the hardened runtime ($flags)"
    team="$(/usr/bin/codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    [[ "$team" =~ ^[A-Z0-9]{10}$ ]] || die "the variant has no Team ID ('$team')"
    [[ -z "${APPLE_TEAM_ID:-}" || "$team" == "$APPLE_TEAM_ID" ]] || die "signed by team $team, not APPLE_TEAM_ID"
    echo "live-code-variant: signed by team $team, hardened runtime"
    ;;
  names)
    prefix="${1:?PREFIX}" build="${2:?BUILD}"
    [[ "$build" =~ ^[0-9]+$ ]] || die "BUILD must be a number, not '$build'"
    echo "LIVE_CODE_DMG_IMMUTABLE=$prefix-arm64-$build-live-code.dmg"
    echo "LIVE_CODE_DMG_RELEASE=$prefix-arm64-live-code.dmg"
    ;;
  publish)
    build="${1:?BUILD}" commit="${2:?COMMIT}" dmg="${3:?DMG}" modules="${4:?MODULES}" run_url="${5:?RUN_URL}"
    [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "COMMIT must be a full 40-hex sha, not '$commit'"
    r2=("$root/scripts/ci/publish-nightly-next-r2.py" upload)
    python3 "${r2[@]}" --file "$dmg" --file "$modules"
    record="$(dirname "$dmg")/live-code-$commit.json"
    python3 -I - "$build" "$commit" "$run_url" "${NIGHTLY_NEXT_FEED_BASE:?}" "$dmg" "$modules" > "$record" <<'PY'
import hashlib, json, os, sys
build, commit, run, base, *files = sys.argv[1:]
def entry(path):
    with open(path, "rb") as f:
        digest = hashlib.sha256(f.read()).hexdigest()
    return {"url": f"{base}/{os.path.basename(path)}", "size": os.path.getsize(path), "sha256": digest}
print(json.dumps({"schema": 1, "build": int(build), "commit": commit, "run": run,
                  "dmg": entry(files[0]), "modules": entry(files[1])}, indent=1))
PY
    python3 "${r2[@]}" --file "$record"
    cat "$record"
    ;;
  *)
    awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0" >&2
    exit 2
    ;;
esac
