#!/usr/bin/env bash
# A commit's Swift in a copy of a signed nightly, kept on disk and launched cold: no dev build. The nightly is the
# golden copy; only the app's executable (Contents/MacOS/cmux: every CmuxNext module and the Rust it links through the
# pinned CCmuxAppFFI, statically) and the resource bundles its packages carry are replaced, then the copy is re-sealed
# ad hoc (lib/adhoc-seal.sh). Delete the copy, or take the commit out of it with `side-instance.sh make NAME` again.
#
#   swap-binary.sh build REF OUT [--like APP] [--repo DIR]
#       (a fleet Mac) the executable and resource bundles of REF, built Release as the nightly builds them, into OUT:
#       OUT/app/Contents/... (the overlay, post-processed by REF's own strip-release-bundle.sh, as the nightly is),
#       OUT/cmux.unstripped and OUT/build.json. --like APP takes the Xcode whose build APP's DTXcodeBuild names.
#       --swift-flags FLAGS adds Swift flags (the nightly's decide import defines, -DCMUX_NO_*).
#       --live-code: the NIGHTLY live code variant (docs/cmux-next/live-code.md): REF's live code settings
#       (scripts/live-code/lib/xcodebuild-args.sh, -DCMUX_LIVE_CODE) and its two passes (lib/two-pass.sh: link, list
#       the CmuxNext exports, relink with them interposable, check the binds), in its own root so its -Onone
#       objects never share a cache with the regular swap. The executable keeps its global symbols (strip -S -x);
#       OUT/modules/ gets what a patch compiles against (scripts/ci/nightly-steps/live-code-variant.sh modules).
#   swap-binary.sh check FROM_SHA REF [--repo DIR]
#       exit 0 when every file the diff FROM_SHA..REF changes reaches the app only through what build makes; else
#       exit 3, `swap-binary: not carried: PATH ...` (Info.plist, entitlements, the project, helpers, web bundles...)
#   swap-binary.sh place APP OUT|OUT.tgz
#       put the overlay into APP, a copy (never the original): prints `SB-PLACE replaced=... added=...`
#   swap-binary.sh seal APP SIGNED
#       re-seal APP ad hoc with SIGNED's unrestricted entitlements; prints `SB-SEAL ... signature=...`
#   swap-binary.sh diff NIGHTLY APP
#       the files of APP that differ from NIGHTLY's (added, removed, changed): what a swap and a seal touched
#   swap-binary.sh make NAME REF [--from APP] [--force] [side-instance make options]
#       build, then `side-instance.sh make NAME --from APP --swap OUT`: a side instance that runs REF, cold
#       launchable (`side-instance.sh launch NAME`); prints SB-TIME build_s= place_seal_s= total_s=
#
# The build. The app target (cmux.xcodeproj `cmux-next`) is App/main.swift over the CmuxNextApp product, linked with
# the target's OTHER_LDFLAGS; its run-script phases only copy prebuilt helpers. So build compiles that executable from
# a wrapper package at REF (main.swift plus CmuxNextApp, the Release configuration's linker flags read from REF's
# project), with the nightly's Swift settings: Release, arm64, lib/nightly-swift-defines.sh and
# lib/swift-size-opt.sh at REF, compilation caching on, no index store, unsigned (app-build-release.sh). One source
# tree and one DerivedData per host ($CMUX_SWAP_BINARY_ROOT, default ~/Library/Caches/cmux-next/swap-binary; the
# compile cache keys hold the paths), so a second commit near the first builds incrementally. A second build on the
# host while one runs uses a fresh root (cold) instead of waiting.
#
# Callers: scripts/measure/swap-nightly.sh (launch-ready.sh dmg=swap), scripts/measure/swap-binary-proof.sh (edit to
# cold launch on a fleet Mac), and `cmux app try` for a Swift diff: build on a fleet Mac, then `place` and `seal` (or
# `side-instance.sh make NAME --from APP --swap OUT`) where the copy runs.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { echo "swap-binary: $*" >&2; exit "${SB_EXIT:-1}"; }
usage() { awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit "${1:-0}"; }
# shellcheck source=lib/adhoc-seal.sh
source "$here/lib/adhoc-seal.sh"
# SWAP_BINARY_PLUTIL: a stand-in for tests (scripts/cmux-next/tests/test_swap_binary.py), as is ditto's fallback.
plist_read() { "${SWAP_BINARY_PLUTIL:-/usr/bin/plutil}" -extract "$2" raw -o - "$1" 2>/dev/null; }
copy_tree() { if command -v ditto >/dev/null; then ditto "$1" "$2"; else cp -R "$1" "$2"; fi; }

# check_paths: the changed paths on stdin; prints the ones a swap cannot carry. Carried: the Swift packages the app
# links (the app links two Packages/iOS ones too) and the app's main.swift, except the package sources other bundle
# phases compile into their own helpers (the server helper, the CEF shim, the Computer Use and remote helpers). Not in
# the app at all (ignored): the repository's tooling, docs, tests, the iPhone app, the server code. Anything else (the
# project, Resources/ with Info.plist and the entitlements, the helpers and their sources, web bundles, Ghostty) is not
# carried. Plain bash so a Linux test runs it.
check_paths() {
  local path
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    case "$path" in
      # Compiled into helpers by their own phases (bundle-server-helper.sh, build-cef-shim.sh, the helper builds).
      Packages/macOS/CmuxNext/Sources/CmuxNextServerHelper*|Packages/macOS/CmuxNext/Sources/CmuxNextCompat/Mutex.swift) echo "$path" ;;
      Packages/macOS/CmuxNext/CEFShim/*|Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/Shim/*) echo "$path" ;;
      Packages/macOS/CmuxComputerUseHelper/*|Packages/macOS/CmuxRemote/*) echo "$path" ;;
      Packages/*) ;;      # carried: the packages the executable links, their resources, the FFI pin
      App/*) ;;           # carried: main.swift
      .agents/*|.claude/*|.codex/*|.cmux/*|.github/*|.greptile/*|docs/*|plans/*|skills/*|design/*|tests/*|tests_v2/*) ;;
      scripts/cmux-next/bundle-*|scripts/cmux-next/embed-*|scripts/cmux-next/build-*|scripts/strip-release-bundle.sh) echo "$path" ;;
      scripts/*) ;;       # tooling (the bundle phases above excepted)
      cmux-next-ios/*|ios/*|backend/*|web/*|workers/*|release-notes/*|examples/*|experiments/*|Prototypes/*|art/*|images/*) ;;
      *.md|LICENSE|.gitignore|.gitattributes) ;;
      *) echo "$path" ;;
    esac
  done
}

fetch_commit() { # REPO SHA: SHA in REPO, fetched when missing
  git -C "$1" cat-file -e "$2^{commit}" 2>/dev/null && return 0
  git -C "$1" fetch -q --no-tags origin "$2" 2>/dev/null \
    || git -C "$1" fetch -q --no-tags "${CMUX_SWAP_BINARY_FETCH_URL:-https://github.com/manaflow-ai/cmux.git}" "$2"
}

cmd_check() {
  local from="${1:?FROM_SHA}" ref="${2:?REF}" repo
  shift 2
  repo="$(git -C "$here" rev-parse --show-toplevel)"
  [[ "${1:-}" == --repo ]] && repo="${2:?--repo DIR}"
  fetch_commit "$repo" "$from" || SB_EXIT=3 die "cannot fetch $from (the nightly's commit)"
  fetch_commit "$repo" "$ref" || SB_EXIT=3 die "cannot fetch $ref"
  local bad
  bad="$(git -C "$repo" diff --no-renames --name-only "$from" "$ref" | check_paths)"
  if [[ -n "$bad" ]]; then
    echo "swap-binary: not carried: $(echo "$bad" | head -20 | tr '\n' ' ')$( (( $(echo "$bad" | wc -l) > 20 )) && echo "(and $(( $(echo "$bad" | wc -l) - 20 )) more)")" >&2
    exit 3
  fi
}

# select_xcode [APP]: DEVELOPER_DIR for the Xcode whose build APP's DTXcodeBuild names, else this host's pinned one.
select_xcode() {
  local like="${1:-}" want="" x
  [[ -n "$like" ]] && want="$(plist_read "$like/Contents/Info.plist" DTXcodeBuild || true)"
  if [[ -n "$want" ]]; then
    for x in /Applications/Xcode*.app; do
      [[ "$(plist_read "$x/Contents/version.plist" ProductBuildVersion || true)" == "$want" ]] || continue
      export DEVELOPER_DIR="$x/Contents/Developer"
      echo "swap-binary: Xcode $x ($want, as the nightly)" >&2
      return 0
    done
    echo "SB-WARN no Xcode of build $want (the nightly's) on this host: the binary may differ by toolchain" >&2
  fi
  if [[ -z "${DEVELOPER_DIR:-}" && -f "$src/scripts/select-ci-xcode.sh" ]]; then
    local envf; envf="$(mktemp)"
    CMUX_CI_SKIP_XCODE_SELECT=1 GITHUB_ENV="$envf" /bin/bash "$src/scripts/select-ci-xcode.sh" >/dev/null 2>&1 || true
    DEVELOPER_DIR="$(sed -n 's/^DEVELOPER_DIR=//p' "$envf" | tail -1)"; rm -f "$envf"
    if [[ -n "$DEVELOPER_DIR" ]]; then export DEVELOPER_DIR; else unset DEVELOPER_DIR; fi
  fi
}

# wrapper SRC DIR: the package that links App/main.swift over CmuxNextApp as the app target does at SRC.
wrapper() {
  local src="$1" dir="$2"
  rm -rf "$dir"; mkdir -p "$dir/Sources/cmux-next-exe"
  cp "$src/App/main.swift" "$dir/Sources/cmux-next-exe/main.swift"
  python3 -I - "$src" "$dir" <<'PY'
import json, os, re, sys
src, out = sys.argv[1:]
pbx = open(os.path.join(src, "cmux.xcodeproj/project.pbxproj")).read()
# The app target's Release configuration: the XCBuildConfiguration whose PRODUCT_NAME is cmux.
# One match per configuration: each chunk ends where the next configuration starts, so a match never spans two.
blocks = [m.group(1) for chunk in pbx.split("isa = XCBuildConfiguration;")[1:]
          for m in [re.match(r"\s*buildSettings = \{(.*?)\n\t\t\t\};\s*name = Release;", chunk, re.S)] if m]
conf = next((b for b in blocks if re.search(r"\n\s*PRODUCT_NAME = cmux;", b)), None)
if conf is None:
    sys.exit("swap-binary: no Release configuration with PRODUCT_NAME = cmux in cmux.xcodeproj")
def setting(name):
    m = re.search(r"\n\s*" + name + r" = \((.*?)\);", conf, re.S)
    if m:
        return [v.strip().strip('"') for v in m.group(1).split(",") if v.strip()]
    m = re.search(r"\n\s*" + name + r" = (.*?);", conf)
    return [m.group(1).strip('"')] if m else []
flags = setting("OTHER_LDFLAGS")
for path in setting("LD_RUNPATH_SEARCH_PATHS"):
    if path != "$(inherited)":
        flags += ["-Xlinker", "-rpath", "-Xlinker", path]
if setting("LD_EXPORT_SYMBOLS") == ["NO"]:
    flags += ["-Xlinker", "-no_exported_symbols"]
target = (setting("MACOSX_DEPLOYMENT_TARGET") or ["14.0"])[0]
open(os.path.join(out, "Package.swift"), "w").write(f"""// swift-tools-version: 6.2
// swap-binary.sh: the cmux-next app target's executable (App/main.swift over CmuxNextApp), its Release link flags.
import PackageDescription
let package = Package(
    name: "CmuxNextAppExecutable",
    platforms: [.macOS("{target}")],
    products: [.executable(name: "cmux-next-exe", targets: ["cmux-next-exe"])],
    dependencies: [.package(path: {json.dumps(os.path.join(src, "Packages/macOS/CmuxNext"))})],
    targets: [
        .executableTarget(
            name: "cmux-next-exe",
            dependencies: [.product(name: "CmuxNextApp", package: "CmuxNext")],
            path: "Sources/cmux-next-exe",
            linkerSettings: [.unsafeFlags({json.dumps(flags)})]
        ),
    ]
)
""")
# The package's pins with the project's on top, as Xcode resolves the app.
pkg = json.load(open(os.path.join(src, "Packages/macOS/CmuxNext/Package.resolved")))
proj_path = os.path.join(src, "cmux.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
merged = {p["identity"]: p for p in pkg["pins"]}
if os.path.exists(proj_path):
    merged.update({p["identity"]: p for p in json.load(open(proj_path))["pins"]})
pkg["pins"] = sorted(merged.values(), key=lambda p: p["identity"])
pkg.pop("originHash", None)
json.dump(pkg, open(os.path.join(out, "Package.resolved"), "w"), indent=2, sort_keys=True)
print("swap-binary: link flags " + " ".join(flags), file=sys.stderr)
PY
}

cmd_build() {
  local ref="${1:?REF}" out="${2:?OUT}" like="" repo live="" extra_flags=""
  shift 2
  repo="$(git -C "$here" rev-parse --show-toplevel)"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --like) like="${2:?--like APP}"; shift 2 ;;
      --live-code) live=1; shift ;;
      --swift-flags) extra_flags="${2?--swift-flags FLAGS}"; shift 2 ;;
      --repo) repo="${2:?--repo DIR}"; shift 2 ;;
      *) usage 1 ;;
    esac
  done
  # shellcheck source=lib/fleet-only.sh
  source "$here/lib/fleet-only.sh"
  cmux_next_require_fleet swap-binary.sh "xcodebuild" "none (a measurement step)" \
    "cmux-ci run --class exclusive --label measure --display --script scripts/measure/swap-binary-proof.sh --ref <feat-cmux-next sha> --arg head=<sha>"
  [[ "$(uname)" == Darwin ]] || die "build runs on a Mac"
  local root="${CMUX_SWAP_BINARY_ROOT:-$HOME/Library/Caches/cmux-next/swap-binary${live:+-live-code}}" cold=""
  # Package.swift links CmuxNextApp statically for a live code build (appLinksStatically): one image to repoint.
  [[ -z "$live" ]] || export CMUX_LIVE_CODE_BUILD=1
  mkdir -p "$root" "$out"; root="$(cd "$root" && pwd -P)"; out="$(cd "$out" && pwd -P)"
  # One build per host root (host_build_lock.py: flock on fd 9, never waited for); a busy root builds in a new one.
  exec 9>>"$root/lock"
  if ! python3 -I "$here/host_build_lock.py" acquire "$root/lock" --fd 9 >&2; then
    root="$(mktemp -d "${TMPDIR:-/tmp}/swap-binary.XXXXXX")"; cold=1
    # shellcheck disable=SC2064 # this root, now
    trap "rm -rf '$root'" EXIT
    echo "SB-WARN the host's build root is busy: building cold in $root" >&2
  fi
  src="$root/src"
  if [[ ! -d "$src/.git" ]]; then
    # A shallow step checkout may refuse a local clone: then an empty repository that fetches REF from GitHub.
    rm -rf "$src"; git clone -q --no-checkout "$repo" "$src" 2>/dev/null || { rm -rf "$src"; git init -q "$src"; }
  fi
  fetch_commit "$src" "$ref" || git -C "$src" fetch -q --no-tags "$repo" "$ref" || die "cannot fetch $ref"
  ref="$(git -C "$src" rev-parse "$ref^{commit}")"
  git -C "$src" -c advice.detachedHead=false checkout -q --force --detach "$ref"
  git -C "$src" clean -qfdx
  select_xcode "$like"
  unset SDKROOT
  wrapper "$src" "$root/app-exe"
  # The nightly's Swift settings at REF (app-build-release.sh for track nightly-next).
  local defines="" settings=()
  if [[ -f "$src/scripts/cmux-next/lib/nightly-swift-defines.sh" ]]; then
    # shellcheck disable=SC1091
    defines="$(source "$src/scripts/cmux-next/lib/nightly-swift-defines.sh"; echo "${CMUX_NIGHTLY_NEXT_SWIFT_DEFINES:-}")"
  fi
  if [[ -f "$src/scripts/cmux-next/lib/swift-size-opt.sh" ]]; then
    # shellcheck disable=SC1091
    while IFS= read -r s; do settings+=("$s"); done < <(source "$src/scripts/cmux-next/lib/swift-size-opt.sh"; swift_size_opt_xcodebuild_args)
  fi
  [[ -z "$extra_flags" ]] || defines="${defines:+$defines }$extra_flags"
  local dead_strip=YES live_args=()
  if [[ -n "$live" ]]; then
    [[ -f "$src/scripts/live-code/lib/two-pass.sh" ]] || die "$ref has no scripts/live-code/lib/two-pass.sh (no live code build)"
    # shellcheck disable=SC1091
    source "$src/scripts/live-code/lib/two-pass.sh"
    defines="${defines:+$defines }$(live_code_swift_flags | paste -sd ' ' -)"
    dead_strip=NO
  fi
  # live_args LIST: REF's live code settings for this wrapper build. Not EXCLUDED_SOURCE_FILE_NAMES (it skips the app
  # target's Embed Frameworks copy, which the wrapper has none of) nor DEAD_CODE_STRIPPING (set above).
  live_args_for() {
    live_args=()
    [[ -n "$live" ]] || return 0
    local a
    while IFS= read -r a; do
      case "$a" in EXCLUDED_SOURCE_FILE_NAMES=*|DEAD_CODE_STRIPPING=*) ;; *) live_args+=("$a") ;; esac
    done < <(live_code_xcodebuild_args Release "${1:-}")
  }
  live_args_for ""
  local scheme log="$out/xcodebuild.log" t0=$SECONDS status=0
  scheme="$(cd "$root/app-exe" && xcodebuild -list -json -clonedSourcePackagesDirPath "$root/dd/SourcePackages" 2>"$out/list.err" | python3 -I -c '
import json, sys
s = (json.load(sys.stdin).get("workspace") or {}).get("schemes") or []
print(next((n for n in ("cmux-next-exe", "CmuxNextAppExecutable-Package", "CmuxNextAppExecutable") if n in s), ""))')" || true
  [[ -n "$scheme" ]] || { tail -20 "$out/list.err" >&2; die "no scheme for the wrapper package"; }
  xcb() {
    (cd "$root/app-exe" && xcodebuild -scheme "$scheme" -configuration Release \
      -destination 'generic/platform=macOS' -derivedDataPath "$root/dd" \
      -skipPackagePluginValidation -skipMacroValidation -showBuildTimingSummary \
      ARCHS=arm64 ONLY_ACTIVE_ARCH=YES "DEAD_CODE_STRIPPING=$dead_strip" \
      COMPILATION_CACHE_ENABLE_CACHING=YES COMPILATION_CACHE_LIMIT_SIZE=10737418240 \
      COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO \
      "OTHER_SWIFT_FLAGS=\$(inherited)${defines:+ $defines}" ${settings[@]+"${settings[@]}"} \
      ${live_args[@]+"${live_args[@]}"} \
      build >"${xcb_log:-$log}" 2>&1)
  }
  # The kept DerivedData's explicit modules, as check-release-compile.sh keeps them right: cleared when a binary
  # target's headers changed (swiftpm-binary-module-guard.sh), and once more after a stale-module failure.
  if [[ -f "$src/scripts/ci/swiftpm-binary-module-guard.sh" ]]; then
    # shellcheck disable=SC1091
    (cd "$root/app-exe" && source "$src/scripts/ci/swiftpm-binary-module-guard.sh" \
      && xcode_binary_module_guard "$root/app-exe" "$root/dd" -scheme "$scheme") >&2 || true
  fi
  # Bundles of a target an earlier commit had would stay in the kept products and be copied as this commit's.
  rm -rf "$root/dd/Build/Products/Release"/*.bundle
  xcb || status=$?
  if [[ $status != 0 && -x "$src/scripts/cmux-next/stale-pcm-retry-needed.sh" ]] && "$src/scripts/cmux-next/stale-pcm-retry-needed.sh" "$log"; then
    echo "SB-WARN stale precompiled modules in $root/dd: cleared, building again" >&2
    "$src/scripts/cmux-next/clear-stale-scheme-build-state.sh" "$root/dd" >&2 && status=0 && { xcb || status=$?; }
  fi
  local build_s=$((SECONDS - t0))
  if [[ $status != 0 ]]; then
    grep -E 'error:|BUILD FAILED' "$log" | head -30 >&2 || true
    die "the build of $ref failed (status $status, $log)"
  fi
  local products="$root/dd/Build/Products/Release"
  [[ -f "$products/cmux-next-exe" ]] || die "no executable in $products"
  if [[ -n "$live" ]]; then
    # Pass 2: the same build with the exported CmuxNext symbols interposable; only the link reruns.
    live_code_list "$products/cmux-next-exe" "$out" || die "the live code build of $ref exports no CmuxNext symbol"
    live_args_for "$out/interposable.txt"
    status=0; xcb_log="$out/xcodebuild-relink.log" xcb || status=$?
    [[ $status == 0 ]] || { grep -E 'error:|BUILD FAILED' "$out/xcodebuild-relink.log" | head -30 >&2 || true; die "the live code relink of $ref failed"; }
    live_code_check "$products/cmux-next-exe" "$out" \
      || die "the relinked executable binds CmuxNext symbols it does not export, or no bind was read ($out/missing-2.txt)"
    build_s=$((SECONDS - t0))
  fi
  rm -rf "$out/app"; mkdir -p "$out/app/Contents/MacOS" "$out/app/Contents/Resources"
  cp "$products/cmux-next-exe" "$out/cmux.unstripped"
  cp "$products/cmux-next-exe" "$out/app/Contents/MacOS/cmux"
  local b
  for b in "$products"/*.bundle; do [[ -d "$b" ]] && ditto "$b" "$out/app/Contents/Resources/$(basename "$b")"; done
  # A framework the executable loads by @rpath (the app target's Release link merges mergeable ones such as Iroh into
  # the executable; this link may not): from the products, so place can add what the nightly does not ship.
  local lib fw
  while IFS= read -r lib; do
    fw="${lib#@rpath/}"; fw="${fw%%/*}"
    [[ "$fw" == *.framework ]] || continue
    b="$(find "$products" -maxdepth 2 -name "$fw" -type d | head -1)"
    [[ -n "$b" ]] || continue
    mkdir -p "$out/app/Contents/Frameworks"; ditto "$b" "$out/app/Contents/Frameworks/$fw"
    echo "SB-WARN the executable loads $fw dynamically; the overlay carries it" >&2
  done < <(otool -L "$products/cmux-next-exe" | awk 'NR > 1 && $1 ~ /^@rpath\// { print $1 }')
  # As the nightly ships it: the symbol map, the executable stripped, the strings tables binary (REF's own script).
  # A live code executable keeps its global symbols: a patch binds to them by name (strip -S -x, not a full strip).
  local strip_tool=""
  if [[ -n "$live" ]]; then
    strip_tool="$root/strip-keep-globals"
    printf '#!/bin/sh\n# swap-binary.sh --live-code: every strip keeps global symbols\nfor a; do last=$a; done\nexec strip -S -x "$last"\n' > "$strip_tool"
    chmod +x "$strip_tool"
  fi
  if [[ -f "$src/scripts/strip-release-bundle.sh" ]]; then
    CMUX_STRIP_TOOL="${strip_tool:-${CMUX_STRIP_TOOL:-strip}}" bash "$src/scripts/strip-release-bundle.sh" "$out/app" >"$out/strip.log" 2>&1 \
      || { tail -20 "$out/strip.log" >&2; die "strip-release-bundle.sh failed"; }
  fi
  [[ -z "$live" ]] || { rm -rf "$out/modules"; mkdir -p "$out/modules"
    # What a patch compiles against: each module's interface and binary module, beside the logs the build wrote.
    (cd "$products" && find . -maxdepth 2 \( -name '*.swiftmodule' -o -name '*.swiftinterface' \) -print0 \
      | xargs -0 -I{} ditto {} "$out/modules/{}") || die "cannot copy the modules from $products"
    # The .o index: every object the link read, by path, size and SHA-256.
    find "$root/dd/Build/Intermediates.noindex" -name '*.o' -type f -print0 | xargs -0 shasum -a 256 > "$out/objects.sha256" || true; }
  python3 -I - "$out/build.json" "$ref" "$build_s" "$(xcodebuild -version | tr '\n' ' ')" "$defines" "${cold:-0}" \
    "$(grep -c '^SwiftCompile normal' "$log" || true)" "${live:-0}" <<'PY'
import json, sys
p, ref, secs, xcode, defines, cold, compiles, live = sys.argv[1:]
json.dump({"ref": ref, "build_s": int(secs), "xcode": xcode.strip(), "swift_defines": defines, "cold_root": cold == "1",
           "swift_compiles": int(compiles or 0), "configuration": "Release", "archs": "arm64",
           "live_code": live == "1"}, open(p, "w"), indent=2)
PY
  echo "SB-BUILD ref=$ref build_s=$build_s swift_compiles=$(grep -c '^SwiftCompile normal' "$log" || true) out=$out"
}

cmd_place() {
  local app="${1:?APP}" build="${2:?OUT}" tmp="" exe
  [[ -f "$app/Contents/Info.plist" ]] || die "no app at $app"
  [[ "$app" != /Applications/* ]] || die "place works on a copy, never an installed app ($app)"
  if [[ -f "$build" ]]; then
    tmp="$(mktemp -d)"; tar -xzf "$build" -C "$tmp"; build="$tmp"
  fi
  [[ -f "$build/app/Contents/MacOS/cmux" ]] || die "no overlay at $build/app (swap-binary.sh build REF $build)"
  exe="$(plist_read "$app/Contents/Info.plist" CFBundleExecutable || true)"
  [[ -n "$exe" && -f "$app/Contents/MacOS/$exe" ]] || die "$app has no executable"
  local replaced=() added=() item name
  # Globs in byte order, the same on every host: a UTF-8 locale (a Mac shell) folds case, so
  # CmuxNext_CmuxNextApp.bundle and cmux-symbols.bin swapped places in SB-PLACE (test_swap_binary).
  # LC_ALL, not LC_COLLATE: a caller's LC_ALL overrides a function's LC_COLLATE, which then did nothing.
  local LC_ALL=C
  # A file replaced, never rewritten in place: the copy is a clone whose blocks the original shares.
  rm -f "$app/Contents/MacOS/$exe"; cp "$build/app/Contents/MacOS/cmux" "$app/Contents/MacOS/$exe"
  replaced+=("MacOS/$exe")
  # A resource bundle is merged, the build's files over the nightly's: the bundles' generated web output (agent pane,
  # pages; gitignored, built by build-web-bundles.sh before the nightly's compile) is only in the nightly's, and check
  # refuses a commit that changes webviews/.
  for item in "$build/app/Contents/Resources"/*; do
    [[ -e "$item" ]] || continue
    name="$(basename "$item")"
    if [[ -d "$item" && -d "$app/Contents/Resources/$name" ]]; then
      replaced+=("Resources/$name"); cp -R "$item/." "$app/Contents/Resources/$name/"
    else
      if [[ -e "$app/Contents/Resources/$name" ]]; then replaced+=("Resources/$name"); else added+=("Resources/$name"); fi
      rm -rf "$app/Contents/Resources/$name"; copy_tree "$item" "$app/Contents/Resources/$name"
    fi
  done
  # A framework the build's executable loads that the nightly does not ship (the nightly's Release link merges some
  # into the executable; build collects the ones it did not): added, signed ad hoc by the seal. The nightly's own stay.
  for item in "$build/app/Contents/Frameworks"/*; do
    [[ -e "$item" ]] || continue
    name="$(basename "$item")"
    [[ -e "$app/Contents/Frameworks/$name" ]] && continue
    mkdir -p "$app/Contents/Frameworks"; copy_tree "$item" "$app/Contents/Frameworks/$name"; added+=("Frameworks/$name")
  done
  [[ -z "$tmp" ]] || rm -rf "$tmp"
  # Every @rpath library the executable loads must be in the copy, or dyld stops it at launch.
  if command -v otool >/dev/null; then
    local lib missing=()
    while IFS= read -r lib; do
      lib="${lib#@rpath/}"
      [[ -e "$app/Contents/Frameworks/$lib" ]] || missing+=("$lib")
    done < <(otool -L "$app/Contents/MacOS/$exe" | awk 'NR > 1 && $1 ~ /^@rpath\// { print $1 }')
    [[ ${#missing[@]} == 0 ]] || die "the executable loads what $app does not ship: ${missing[*]}"
  fi
  local IFS=,
  echo "SB-PLACE app=$app replaced=${replaced[*]} added=${added[*]:-}"
}

cmd_seal() {
  local app="${1:?APP}" signed="${2:?SIGNED}" ent
  ent="$(mktemp)"
  cmux_adhoc_seal "$app" "$signed" "$ent" || { rm -f "$ent"; die "the re-sealed $app does not verify"; }
  rm -f "$ent"
  echo "SB-SEAL app=$app signature=$(codesign -dv "$app" 2>&1 | sed -n 's/^Signature=//p;s/^CodeDirectory .*flags=\([^ ]*\).*/flags=\1/p' | tr '\n' ' ')"
}

cmd_diff() {
  python3 -I - "${1:?NIGHTLY}" "${2:?APP}" <<'PY'
import filecmp, os, sys
a, b = sys.argv[1:]
def files(root):
    out = {}
    for d, dirs, names in os.walk(root):
        for n in names:
            p = os.path.join(d, n)
            out[os.path.relpath(p, root)] = p
    return out
fa, fb = files(a), files(b)
for rel in sorted(set(fa) | set(fb)):
    if rel not in fa: print("added", rel)
    elif rel not in fb: print("removed", rel)
    else:
        sa, sb = os.lstat(fa[rel]), os.lstat(fb[rel])
        if sa.st_size != sb.st_size or (sa.st_mtime != sb.st_mtime and not filecmp.cmp(fa[rel], fb[rel], shallow=False)):
            print("changed", rel)
PY
}

cmd_make() {
  local name="${1:?NAME}" ref="${2:?REF}" from="/Applications/cmux NEXT.app" force="" rest=()
  shift 2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from) from="${2%/}"; shift 2 ;;
      --force) force=1; shift ;;
      *) rest+=("$1"); shift ;;
    esac
  done
  local commit t0=$SECONDS out
  commit="$(plist_read "$from/Contents/Info.plist" CMUXCommit || true)"
  if [[ -n "$commit" && -z "$force" ]]; then cmd_check "$commit" "$ref"; fi
  out="${CMUX_SWAP_BINARY_ROOT:-$HOME/Library/Caches/cmux-next/swap-binary}/out/$name"
  cmd_build "$ref" "$out" --like "$from"
  local t1=$SECONDS
  "$here/side-instance.sh" make "$name" --from "$from" --swap "$out" ${rest[@]+"${rest[@]}"}
  echo "SB-TIME build_s=$((t1 - t0)) place_seal_s=$((SECONDS - t1)) total_s=$((SECONDS - t0))"
}

cmd="${1:-}"; [[ -n "$cmd" ]] || usage 1; shift
case "$cmd" in
  -h|--help) usage ;;
  build) cmd_build "$@" ;;
  check) cmd_check "$@" ;;
  place) cmd_place "$@" ;;
  seal) cmd_seal "$@" ;;
  diff) cmd_diff "$@" ;;
  make) cmd_make "$@" ;;
  check-paths) check_paths ;;  # for tests: the paths on stdin a swap cannot carry
  wrapper) wrapper "$@" ;;     # for tests: the wrapper package of a checkout (wrapper SRC DIR)
  *) usage 1 ;;
esac
