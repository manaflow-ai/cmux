#!/usr/bin/env bash
# Byte proof for the warm nightly-next worker: does a Release build that starts
# from empty DerivedData but reuses a compilation cache (CAS) filled by an
# earlier commit give the same bytes as a clean build of the same commit?
#
# The dedicated nightly-next worker (nightly.yml build-nightly-app on
# CI_NIGHTLY_NEXT_TRUSTED_RUNNER, scripts/ci/nightly_build_state.py) keeps only
# Swift package checkouts and Xcode's content-keyed compilation cache between
# runs; every shipped build starts from empty DerivedData. This measures that
# model, and Xcode's plain incremental build (kept DerivedData) for contrast,
# against clean builds, all at one source path with the nightly's Swift
# settings (Release, arm64, compilation caching on, no index store, the
# nightly-next import flags).
#
# What it builds: the cmux-next app executable as the Xcode target cmux-next
# links it (App/main.swift over the CmuxNextApp product; the package wrapper of
# scripts/measure/import-set-xcode.sh), so no web bundle, Rust or signing input
# is needed. The app target's run-script phases copy prebuilt helpers and are
# not compiled; they are outside this proof.
#
# Legs (each a separate DerivedData; "cas-X" is a compilation cache directory):
#   clean1   HEAD, fresh cache cas-1                       (reference)
#   clean2   HEAD, fresh cache cas-2                       (is clean deterministic?)
#   base-w   BASE, fresh cache cas-w                       (fills cas-w like the previous nightly)
#   warm     HEAD, empty DerivedData, cache cas-w          (the shipped nightly-next model)
#   hit      HEAD, empty DerivedData, cache cas-w again    (no-change floor: every job a hit)
#   base-i   BASE, fresh cache cas-i, DerivedData dd-i
#   incr     HEAD in dd-i (kept DerivedData + cas-i)        (Xcode incremental, for contrast)
# Each of warm, hit, incr, clean2 is compared file by file with clean1 over
# Build/Products/Release (every regular file and symlink; the executable,
# each object, module and resource bundle).
#
#   cmux-ci run --class exclusive --script scripts/measure/nightly-cas-identity.sh --ref SHA \
#     --arg base=<40-hex> --arg head=<40-hex> --timeout 9000 --key nightly-cas-identity-<sha8>-<n>
# base and head are commits of manaflow-ai/cmux (fetched when missing).
# Output: RESULT lines and files under .build/nightly-cas-identity. Exit 0 when
# warm and hit equal clean1 byte for byte (incr is reported, not required).
set -euo pipefail
base="" head=""
for arg in "$@"; do
  case "$arg" in
    base=*) base="${arg#base=}" ;;
    head=*) head="${arg#head=}" ;;
    *) echo "nightly-cas-identity.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$base" =~ ^[0-9a-f]{40}$ && "$head" =~ ^[0-9a-f]{40}$ ]] || { echo "nightly-cas-identity.sh: base= and head= must be 40-hex commits" >&2; exit 2; }
root="$(git rev-parse --show-toplevel)"
cd "$root"
work="$root/.build/nightly-cas-identity"
src="$work/src"
rm -rf "$work"
mkdir -p "$work"
cleanup() {
  git -C "$root" worktree remove --force "$src" >/dev/null 2>&1 || rm -rf "$src"
  rm -rf "$work"/dd-* "$work"/cas-* "$work/spm" "$work/app-exe"
}
trap cleanup EXIT
free_gb=$(( $(df -k "$root" | awk 'NR==2 {print $4}') / 1048576 ))
echo "==> free disk ${free_gb} GB"
(( free_gb >= 80 )) || { echo "nightly-cas-identity.sh: needs 80 GB free (seven Release DerivedData trees and four caches); ${free_gb} GB free" >&2; exit 1; }

for c in "$base" "$head"; do
  git cat-file -e "$c^{commit}" 2>/dev/null || git fetch --quiet --no-tags origin "$c" || { echo "nightly-cas-identity.sh: cannot fetch $c" >&2; exit 1; }
done
git worktree add --quiet --detach "$src" "$head"

if [[ -z "${DEVELOPER_DIR:-}" && -f scripts/select-ci-xcode.sh ]]; then
  envf="$(mktemp)"
  CMUX_CI_SKIP_XCODE_SELECT=1 GITHUB_ENV="$envf" /bin/bash scripts/select-ci-xcode.sh >/dev/null
  DEVELOPER_DIR="$(sed -n 's/^DEVELOPER_DIR=//p' "$envf" | tail -1)"
  rm -f "$envf"
  export DEVELOPER_DIR
fi
unset SDKROOT
echo "CAS-IDENTITY-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) cores=$(sysctl -n hw.ncpu) macos=$(sw_vers -productVersion) build=$(sw_vers -buildVersion) xcode=\"$(xcodebuild -version | tr '\n' ' ')\" script_rev=$(git rev-parse HEAD) base=$base head=$head commits=$(git rev-list --count "$base..$head")"

result() { echo "RESULT $*"; }

at() {   # SHA: put the source tree at SHA (same path for every leg)
  git -C "$src" checkout --quiet --force --detach "$1"
  git -C "$src" clean -qfdx
  mkdir -p "$work/app-exe/Sources/cmux-next-exe"
  cp "$src/App/main.swift" "$work/app-exe/Sources/cmux-next-exe/main.swift"
  cat >"$work/app-exe/Package.swift" <<EOF
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "CmuxNextAppExecutable",
    platforms: [.macOS("14.0")],
    products: [.executable(name: "cmux-next-exe", targets: ["cmux-next-exe"])],
    dependencies: [.package(path: "$src/Packages/macOS/CmuxNext")],
    targets: [
        .executableTarget(
            name: "cmux-next-exe",
            dependencies: [.product(name: "CmuxNextApp", package: "CmuxNext")],
            path: "Sources/cmux-next-exe",
            linkerSettings: [.unsafeFlags([
                "-lc++", "-framework", "Metal", "-framework", "QuartzCore", "-framework", "IOSurface",
                "-framework", "UniformTypeIdentifiers", "-framework", "Carbon",
            ])]
        ),
    ]
)
EOF
  python3 -I - "$src/Packages/macOS/CmuxNext/Package.resolved" \
    "$src/cmux.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" "$work/app-exe/Package.resolved" <<'PY'
import json, os, sys
pkg = json.load(open(sys.argv[1]))
proj = {p["identity"]: p for p in json.load(open(sys.argv[2]))["pins"]} if os.path.exists(sys.argv[2]) else {}
merged = {p["identity"]: p for p in pkg["pins"]}
merged.update(proj)
pkg["pins"] = sorted(merged.values(), key=lambda p: p["identity"])
pkg.pop("originHash", None)
with open(sys.argv[3], "w") as f:
    json.dump(pkg, f, indent=2, sort_keys=True)
    f.write("\n")
PY
}

scheme=""
xcb() {   # LABEL DD CAS [keep]: one Release build; DD is emptied first unless keep
  local label="$1" dd="$2" cas="$3" keep="${4:-}" t0=$SECONDS
  [[ -n "$keep" ]] || rm -rf "$dd"
  mkdir -p "$dd" "$cas"
  # The nightly worker links DerivedData/CompilationCache.noindex to its kept cache.
  if [[ ! -L "$dd/CompilationCache.noindex" ]]; then
    rm -rf "$dd/CompilationCache.noindex"
    ln -s "$cas" "$dd/CompilationCache.noindex"
  fi
  if [[ -z "$scheme" ]]; then
    scheme="$(cd "$work/app-exe" && xcodebuild -list -json -clonedSourcePackagesDirPath "$work/spm" 2>"$work/list.err" | python3 -I -c '
import json, sys
s = (json.load(sys.stdin).get("workspace") or {}).get("schemes") or []
print(next((n for n in ("cmux-next-exe", "CmuxNextAppExecutable-Package", "CmuxNextAppExecutable") if n in s), ""))')" || true
    [[ -n "$scheme" ]] || { tail -20 "$work/list.err"; echo "nightly-cas-identity.sh: no scheme" >&2; exit 1; }
    echo "==> scheme $scheme"
  fi
  if ! (cd "$work/app-exe" && xcodebuild -scheme "$scheme" -configuration Release \
      -destination 'generic/platform=macOS' -derivedDataPath "$dd" -clonedSourcePackagesDirPath "$work/spm" \
      -skipPackagePluginValidation -skipMacroValidation -showBuildTimingSummary \
      ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
      COMPILATION_CACHE_ENABLE_CACHING=YES COMPILATION_CACHE_LIMIT_SIZE=3221225472 \
      COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO \
      'OTHER_SWIFT_FLAGS=$(inherited) -DCMUX_NO_PASSWORD_IMPORT -DCMUX_NO_BROWSER_DATA_IMPORT' \
      build >"$work/$label.log" 2>&1); then
    grep -E 'error:|BUILD FAILED' "$work/$label.log" | head -20 || true
    tail -20 "$work/$label.log"
    echo "nightly-cas-identity.sh: build $label failed" >&2
    exit 1
  fi
  local compiles hits
  compiles=$(grep -c -E '^SwiftCompile normal' "$work/$label.log" || true)
  hits=$(grep -c -E '^Cache hit' "$work/$label.log" || true)
  result "$label build_seconds=$(( SECONDS - t0 )) swift_compile_tasks=$compiles cache_hit_lines=$hits"
  grep -A6 'Build Timing Summary' "$work/$label.log" | sed -n '3,6p' | sed "s/^/  $label timing: /" || true
}

fails=0
compare() {   # LABEL OTHER_DD REQUIRED(yes|no)
  local rc=0
  python3 -I - "$work/dd-clean1/Build/Products/Release" "$2/Build/Products/Release" "$1" "$3" <<'PY' || rc=$?
import hashlib, os, sys
ref, other, label, required = sys.argv[1:5]
def walk(top):
    out = {}
    for d, dirs, files in os.walk(top):
        for n in dirs + files:
            p = os.path.join(d, n)
            rel = os.path.relpath(p, top)
            if os.path.islink(p):
                out[rel] = "link:" + os.readlink(p)
            elif os.path.isfile(p):
                h = hashlib.sha256()
                with open(p, "rb") as f:
                    for chunk in iter(lambda: f.read(1 << 20), b""):
                        h.update(chunk)
                out[rel] = h.hexdigest()
    return out
a, b = walk(ref), walk(other)
only_ref = sorted(set(a) - set(b)); only_other = sorted(set(b) - set(a))
diff = sorted(k for k in set(a) & set(b) if a[k] != b[k])
same = len(set(a) & set(b)) - len(diff)
exe = "cmux-next-exe"
print(f"RESULT compare {label}: files={len(a)} equal={same} different={len(diff)} only_clean1={len(only_ref)} only_{label}={len(only_other)} executable={'equal' if a.get(exe) == b.get(exe) and exe in a else 'DIFFERENT'}")
for k in diff[:40]:
    print(f"  differs: {k}")
for k in only_ref[:10]:
    print(f"  only clean1: {k}")
for k in only_other[:10]:
    print(f"  only {label}: {k}")
sys.exit(1 if (diff or only_ref or only_other) else 0)
PY
  if (( rc != 0 )) && [[ "$3" == yes ]]; then fails=$((fails + 1)); fi
  return 0
}

at "$head"
xcb clean1 "$work/dd-clean1" "$work/cas-1"
xcb clean2 "$work/dd-clean2" "$work/cas-2"
compare clean2 "$work/dd-clean2" yes
rm -rf "$work/dd-clean2" "$work/cas-2"

at "$base"
xcb base-w "$work/dd-base-w" "$work/cas-w"
rm -rf "$work/dd-base-w"
xcb base-i "$work/dd-i" "$work/cas-i"

at "$head"
xcb warm "$work/dd-warm" "$work/cas-w"
compare warm "$work/dd-warm" yes
rm -rf "$work/dd-warm"
xcb hit "$work/dd-hit" "$work/cas-w"
compare hit "$work/dd-hit" yes
rm -rf "$work/dd-hit"
xcb incr "$work/dd-i" "$work/cas-i" keep
compare incr "$work/dd-i" no

du -sh "$work/cas-w" 2>/dev/null | sed 's/^/==> warm cache size: /' || true
if (( fails )); then
  result "FAIL: $fails required comparison(s) differ from clean1"
  exit 1
fi
result "PASS: warm (empty DerivedData + cache from base) and hit equal clean1 byte for byte"
