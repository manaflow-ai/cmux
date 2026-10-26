#!/usr/bin/env bash
# PGO in the Release builds (plans/cmux-next/chrome-parity/p08-startup.md, section F, task 052), without a build:
# pgo/fetch-profdata.sh gives a profile only when its sha256 matches the pin, and pgo/release-env.sh hands it to
# Package.swift (CMUX_PGO_PROFDATA) only when the switch is on: Resources/build/cmux-next.pgo.conf, or
# CMUX_NEXT_PGO_USE for one build. Both Release paths share it: check-release-compile.sh and the Nightly's
# scripts/ci/run-with-helper-prebuild.py. A stub xcodebuild records what it got.
#   bash scripts/cmux-next/tests/pgo-release-profile.test.sh
# shellcheck disable=SC2015 # every `A && B || fail`: fail exits, so it runs only when A or B fails
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
FETCH="$ROOT/scripts/cmux-next/pgo/fetch-profdata.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cmux-pgo-release.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$1"; cat "$TMP/out" 2>/dev/null || true; exit 1; }
sha_of() { if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

mkdir -p "$TMP/src" "$TMP/cache"
printf 'profile bytes v1\n' > "$TMP/src/cmux-next.profdata"
sha=$(sha_of "$TMP/src/cmux-next.profdata")
printf '# comment\n%s  cmux-next.profdata\n' "$sha" > "$TMP/pin"

fetch() {
  status=0
  out=$(env -i PATH=/usr/bin:/bin HOME="$TMP" /bin/bash "$FETCH" "$@" 2>"$TMP/out") || status=$?
}

# 1. The repository's pin names no profile yet: no profile, exit 1, and the Release builds plain.
fetch --cache "$TMP/cache" --source "$TMP/src/cmux-next.profdata"
[[ $status -eq 1 && -z "$out" ]] || fail "the committed pin gave a profile (exit $status, '$out')"
grep -q 'no profile is pinned' "$TMP/out" || fail "the committed pin's refusal does not say why"

# 2. A matching profile lands at <cache>/<sha256>/cmux-next.profdata, and a second call reuses it.
fetch --pin "$TMP/pin" --cache "$TMP/cache" --source "$TMP/src/cmux-next.profdata"
[[ $status -eq 0 && "$out" == "$TMP/cache/$sha/cmux-next.profdata" ]] || fail "matching profile: exit $status, '$out'"
cmp -s "$out" "$TMP/src/cmux-next.profdata" || fail "the cached profile is not the source"
fetch --pin "$TMP/pin" --cache "$TMP/cache" --source "$TMP/missing.profdata"
[[ $status -eq 0 && "$out" == "$TMP/cache/$sha/cmux-next.profdata" ]] || fail "cached profile not reused (exit $status)"

# 3. A source whose sha256 differs from the pin is refused and leaves nothing behind.
printf 'profile bytes v2\n' > "$TMP/src/other.profdata"
fetch --pin "$TMP/pin" --cache "$TMP/cache2" --source "$TMP/src/other.profdata"
[[ $status -eq 1 && -z "$out" ]] || fail "a mismatched profile was accepted (exit $status, '$out')"
grep -q "the pin names $sha" "$TMP/out" || fail "the mismatch does not name both sha256s"
[[ -z "$(find "$TMP/cache2" -type f 2>/dev/null)" ]] || fail "a mismatched download stayed in the cache"

# 4. A cached file that no longer matches is fetched again, not used.
mkdir -p "$TMP/cache3/$sha"; printf 'corrupt\n' > "$TMP/cache3/$sha/cmux-next.profdata"
fetch --pin "$TMP/pin" --cache "$TMP/cache3" --source "$TMP/src/cmux-next.profdata"
[[ $status -eq 0 ]] && cmp -s "$out" "$TMP/src/cmux-next.profdata" || fail "a corrupt cached profile was used (exit $status)"

# 5. A pin that is not `<sha256>  cmux-next.profdata` is refused; a relative cache is a usage error.
for bad in "abc  cmux-next.profdata" "$sha  other.profdata" "$sha  cmux-next.profdata extra" \
  "$(printf '%s' "$sha" | tr 'a-f' 'A-F')  cmux-next.profdata"; do
  printf '%s\n' "$bad" > "$TMP/badpin"
  fetch --pin "$TMP/badpin" --cache "$TMP/cache" --source "$TMP/src/cmux-next.profdata"
  [[ $status -eq 1 && -z "$out" ]] || fail "pin '$bad' was accepted (exit $status)"
done
printf '%s *cmux-next.profdata\n' "$sha" > "$TMP/binpin"
fetch --pin "$TMP/binpin" --cache "$TMP/cache" --source "$TMP/src/cmux-next.profdata"
[[ $status -eq 0 ]] || fail "a binary-mode sha256sum pin was refused (exit $status)"
fetch --pin "$TMP/pin" --cache relative --source "$TMP/src/cmux-next.profdata"
[[ $status -eq 2 ]] || fail "a relative --cache was not a usage error (exit $status)"
fetch --pin "$TMP/missing-pin" --cache "$TMP/cache"
[[ $status -eq 1 ]] || fail "a missing pin file did not build plain (exit $status)"

# check-release-compile.sh with a stub xcodebuild that records its env and build settings.
mkdir -p "$TMP/bin" "$TMP/dev" "$TMP/steptmp"
cat > "$TMP/bin/xcodebuild" <<EOF
#!/bin/bash
if [[ "\$1" == "-version" ]]; then echo "Xcode 26.6"; exit 0; fi
{
  echo "profdata=\${CMUX_PGO_PROFDATA-<unset>}"
  echo "companions=\${CMUX_PGO_COMPANIONS-<unset>}"
  for arg in "\$@"; do [[ "\$arg" == LLVM_LTO=* ]] && echo "setting=\$arg"; done
} > "$TMP/seen"
exit 0
EOF
chmod +x "$TMP/bin/xcodebuild"
compile() {
  rm -f "$TMP/seen"; status=0
  env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" TMPDIR="$TMP/steptmp" CMUX_CI_STEP_KEY=test-step \
    DEVELOPER_DIR="$TMP/dev" CMUX_XCODEBUILD_HEARTBEAT_SECONDS=1 CMUX_PGO_CACHE_DIR="$TMP/cc" "$@" \
    /bin/bash "$ROOT/scripts/cmux-next/check-release-compile.sh" >"$TMP/out" 2>&1 || status=$?
}
seen() { grep -x "$1" "$TMP/seen" >/dev/null 2>&1; }
on=(CMUX_NEXT_PGO_USE=1 CMUX_PGO_PIN="$TMP/pin" CMUX_PGO_SOURCE="$TMP/src/cmux-next.profdata")

# 6. Off by default: no profile reaches the manifest, an ambient CMUX_PGO_PROFDATA included.
compile CMUX_PGO_PROFDATA=/elsewhere/x.profdata CMUX_PGO_COMPANIONS=thinlto CMUX_PGO_PIN="$TMP/pin" \
  CMUX_PGO_SOURCE="$TMP/src/cmux-next.profdata"
[[ $status -eq 0 ]] && seen 'profdata=<unset>' && seen 'companions=<unset>' && ! seen 'setting=LLVM_LTO=YES_THIN' \
  || fail "the switch off still passed PGO (exit $status): $(cat "$TMP/seen" 2>/dev/null)"

# 7. On and matching: the content-addressed path reaches the manifest and the log says so.
compile "${on[@]}"
[[ $status -eq 0 ]] && seen "profdata=$TMP/cc/$sha/cmux-next.profdata" && seen 'companions=<unset>' \
  || fail "the switch on with a matching profile did not pass it (exit $status): $(cat "$TMP/seen" 2>/dev/null)"
grep -q "PGO $TMP/cc/$sha/cmux-next.profdata" "$TMP/out" || fail "the log does not name the profile"

# 8. On but no profile matches the pin: the plain Release builds and says why.
compile CMUX_NEXT_PGO_USE=1 CMUX_PGO_CACHE_DIR="$TMP/cc-miss" CMUX_PGO_PIN="$TMP/pin" CMUX_PGO_SOURCE="$TMP/src/other.profdata"
[[ $status -eq 0 ]] && seen 'profdata=<unset>' || fail "a mismatched profile reached the build (exit $status)"
grep -q 'compiling the plain Release' "$TMP/out" || fail "the plain fallback does not say why"

# 9. Task 110's companions ship with the profile only; thinlto also sets the link's LLVM_LTO.
compile "${on[@]}" CMUX_PGO_COMPANIONS=thinlto,cmo
[[ $status -eq 0 ]] && seen 'companions=thinlto,cmo' && seen 'setting=LLVM_LTO=YES_THIN' \
  || fail "companions with the profile: exit $status: $(cat "$TMP/seen" 2>/dev/null)"
compile "${on[@]}" CMUX_PGO_COMPANIONS=cmo
[[ $status -eq 0 ]] && seen 'companions=cmo' && ! seen 'setting=LLVM_LTO=YES_THIN' || fail "cmo alone set LLVM_LTO"
compile CMUX_NEXT_PGO_USE=1 CMUX_PGO_CACHE_DIR="$TMP/cc-miss" CMUX_PGO_PIN="$TMP/pin" CMUX_PGO_SOURCE="$TMP/src/other.profdata" CMUX_PGO_COMPANIONS=thinlto
[[ $status -eq 0 ]] && seen 'companions=<unset>' && ! seen 'setting=LLVM_LTO=YES_THIN' \
  || fail "companions shipped without the profile"
compile "${on[@]}" CMUX_PGO_COMPANIONS=thinlto,fast
[[ $status -eq 2 && ! -e "$TMP/seen" ]] || fail "an unknown companion was not refused (exit $status)"

# 10. The switch's sources: the committed conf is off; a conf with use=1 turns it on with no environment; the
# environment overrides the conf both ways, and an explicit empty CMUX_PGO_COMPANIONS drops the conf's companions.
conf="$ROOT/Resources/build/cmux-next.pgo.conf"
grep -qx 'use=0' "$conf" && grep -qx 'companions=' "$conf" || fail "the committed switch is not off by default"
printf '# on\nuse=1\ncompanions=thinlto\n' > "$TMP/conf-on"
pin_src=(CMUX_PGO_PIN="$TMP/pin" CMUX_PGO_SOURCE="$TMP/src/cmux-next.profdata")
compile CMUX_PGO_CONF="$TMP/conf-on" "${pin_src[@]}"
[[ $status -eq 0 ]] && seen "profdata=$TMP/cc/$sha/cmux-next.profdata" && seen 'companions=thinlto' \
  && seen 'setting=LLVM_LTO=YES_THIN' || fail "use=1 in the conf did not turn PGO on (exit $status): $(cat "$TMP/seen" 2>/dev/null)"
compile CMUX_PGO_CONF="$TMP/conf-on" CMUX_NEXT_PGO_USE=0 "${pin_src[@]}"
[[ $status -eq 0 ]] && seen 'profdata=<unset>' && ! seen 'setting=LLVM_LTO=YES_THIN' \
  || fail "CMUX_NEXT_PGO_USE=0 did not override use=1 (exit $status)"
compile CMUX_PGO_CONF="$TMP/conf-on" CMUX_PGO_COMPANIONS= "${pin_src[@]}"
[[ $status -eq 0 ]] && seen "profdata=$TMP/cc/$sha/cmux-next.profdata" && seen 'companions=<unset>' \
  && ! seen 'setting=LLVM_LTO=YES_THIN' || fail "an empty CMUX_PGO_COMPANIONS did not override the conf (exit $status)"
compile CMUX_PGO_CONF="$TMP/missing-conf" "${pin_src[@]}"
[[ $status -eq 0 ]] && seen 'profdata=<unset>' || fail "a missing conf did not mean off (exit $status)"
printf 'use=yes\n' > "$TMP/conf-bad"
compile CMUX_PGO_CONF="$TMP/conf-bad" "${pin_src[@]}"
[[ $status -eq 2 && ! -e "$TMP/seen" ]] || fail "a switch other than 0 or 1 was not refused (exit $status)"

# 11. --print, the form the Nightly's wrapper reads: one `export` or `setting` line per result, nothing when off.
print_env() {
  status=0
  out=$(env -i PATH=/usr/bin:/bin HOME="$TMP" CMUX_PGO_CACHE_DIR="$TMP/cc" "$@" \
    /bin/bash "$ROOT/scripts/cmux-next/pgo/release-env.sh" --print 2>"$TMP/out") || status=$?
}
print_env CMUX_PGO_CONF="$TMP/conf-on" "${pin_src[@]}"
want=$(printf 'export CMUX_PGO_PROFDATA=%s\nexport CMUX_PGO_COMPANIONS=thinlto\nsetting LLVM_LTO=YES_THIN' \
  "$TMP/cc/$sha/cmux-next.profdata")
[[ $status -eq 0 && "$out" == "$want" ]] || fail "--print on: exit $status, '$out'"
print_env CMUX_PGO_PROFDATA=/elsewhere/x.profdata "${pin_src[@]}"
[[ $status -eq 0 && -z "$out" ]] || fail "--print off printed '$out' (exit $status)"

# 12. The Nightly's Release build (nightly.yml runs run-with-helper-prebuild.py, which runs the build command):
# the same switch gives the same profile and LLVM_LTO; off, an ambient CMUX_PGO_PROFDATA is dropped; a Debug
# build never runs the PGO setup. The wrapper runs from a copy with a stub prebuild helper and the real pgo dir.
mkdir -p "$TMP/repo/scripts/ci" "$TMP/repo/scripts/cmux-next"
cp "$ROOT/scripts/ci/run-with-helper-prebuild.py" "$TMP/repo/scripts/ci/"
printf '#!/bin/sh\nexit 0\n' > "$TMP/repo/scripts/ci/prebuild-app-helpers.sh"
chmod +x "$TMP/repo/scripts/ci/prebuild-app-helpers.sh"
ln -s "$ROOT/scripts/cmux-next/pgo" "$TMP/repo/scripts/cmux-next/pgo"
nightly() { # CONFIGURATION ENV...
  local configuration="$1"; shift
  rm -f "$TMP/seen"; status=0
  env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" CMUX_PGO_CACHE_DIR="$TMP/cc" "$@" \
    python3 "$TMP/repo/scripts/ci/run-with-helper-prebuild.py" --derived-data "$TMP/dd" \
    --configuration "$configuration" --archs arm64 --log "$TMP/helper.log" -- \
    xcodebuild -scheme cmux -configuration "$configuration" build >"$TMP/out" 2>&1 || status=$?
}
nightly Release CMUX_PGO_CONF="$TMP/conf-on" "${pin_src[@]}"
[[ $status -eq 0 ]] && seen "profdata=$TMP/cc/$sha/cmux-next.profdata" && seen 'companions=thinlto' \
  && seen 'setting=LLVM_LTO=YES_THIN' || fail "the Nightly's Release build did not get PGO (exit $status): $(cat "$TMP/seen" 2>/dev/null)"
nightly Release CMUX_PGO_PROFDATA=/elsewhere/x.profdata CMUX_PGO_COMPANIONS=thinlto "${pin_src[@]}"
[[ $status -eq 0 ]] && seen 'profdata=<unset>' && seen 'companions=<unset>' && ! seen 'setting=LLVM_LTO=YES_THIN' \
  || fail "the Nightly with the switch off still passed PGO (exit $status): $(cat "$TMP/seen" 2>/dev/null)"
nightly Debug CMUX_PGO_CONF="$TMP/conf-bad" CMUX_PGO_PROFDATA=/elsewhere/x.profdata "${pin_src[@]}"
[[ $status -eq 0 ]] && seen 'profdata=<unset>' || fail "a Debug build ran the PGO setup or kept an ambient profile (exit $status)"
nightly Release CMUX_PGO_CONF="$TMP/conf-bad" "${pin_src[@]}"
[[ $status -ne 0 && ! -e "$TMP/seen" ]] || fail "the Nightly built with a bad switch (exit $status)"

# 13. Package.swift reads exactly these variables and gives the flag in Release only, to both settings groups.
pkg="$ROOT/Packages/macOS/CmuxNext/Package.swift"
grep -q 'Context.environment\["CMUX_PGO_PROFDATA"\]' "$pkg" || fail "Package.swift does not read CMUX_PGO_PROFDATA"
grep -q '"-profile-use=\\(profile)"' "$pkg" || fail "Package.swift does not build -profile-use from the path"
grep -q 'return \[.unsafeFlags(flags, .when(configuration: .release))\]' "$pkg" || fail "the PGO flags are not Release-only"
[[ $(grep -c '^\] + stabilitySwiftSettings + releaseProfileSwiftSettings$' "$pkg") -eq 2 ]] \
  || fail "uiSwiftSettings and daemonSwiftSettings do not both carry releaseProfileSwiftSettings"
grep -q '"thinlto": "-lto=llvm-thin", "cmo": "-cross-module-optimization"' "$pkg" \
  || fail "the companion flags differ from lto-ab.sh's variants"
for variant in thinlto cmo; do
  want=$(bash "$ROOT/scripts/cmux-next/pgo/lto-ab.sh" --print-xcconfig "$variant" | sed -n 's/^OTHER_SWIFT_FLAGS.*(inherited) //p')
  case "$variant" in thinlto) have='-lto=llvm-thin' ;; cmo) have='-cross-module-optimization' ;; esac
  [[ "$want" == "$have" ]] || fail "lto-ab.sh's $variant Swift flag is '$want', Package.swift uses '$have'"
done

printf 'pgo-release-profile.test.sh: ok\n'
