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
#   clean1   HEAD, fresh cache cas-1                       (reference, kept as ref-clean1)
#   clean2   HEAD, fresh cache cas-2                       (is clean deterministic?)
#   base-w   BASE, fresh cache cas-w                       (fills cas-w like the previous nightly)
#   warm     HEAD, empty DerivedData, cache cas-w          (the shipped nightly-next model)
#   hit      HEAD, empty DerivedData, cache cas-w again    (no-change floor: every job a hit)
#   base-i   BASE, fresh cache cas-i, DerivedData dd-i
#   incr     HEAD in dd-i (kept DerivedData + cas-i)        (Xcode incremental, for contrast)
# All legs use one DerivedData path (moved aside or deleted between legs).
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
git worktree prune
mkdir -p "$work"
# Every leg builds in this one DerivedData path, as the nightly builds in
# build-universal: the linked executable's debug map and the binary modules
# keep DerivedData paths, so another path per leg would differ by path alone.
D="$work/dd"
cleanup() {
  git -C "$root" worktree remove --force "$src" >/dev/null 2>&1 || rm -rf "$src"
  rm -rf "$D" "$work"/ref-* "$work"/cas-* "$work/spm" "$work/app-exe"
}
trap cleanup EXIT
free_gb=$(( $(df -k "$root" | awk 'NR==2 {print $4}') / 1048576 ))
echo "==> free disk ${free_gb} GB"
(( free_gb >= 80 )) || { echo "nightly-cas-identity.sh: needs 80 GB free (seven Release DerivedData trees and four caches); ${free_gb} GB free" >&2; exit 1; }

for c in "$base" "$head"; do
  # A cmux-ci step checkout may have no origin remote; a commit on a pushed side
  # branch is then fetched from the public repository by its SHA.
  git cat-file -e "$c^{commit}" 2>/dev/null || git fetch --quiet --no-tags origin "$c" 2>/dev/null \
    || git fetch --quiet --no-tags https://github.com/manaflow-ai/cmux.git "$c" \
    || { echo "nightly-cas-identity.sh: cannot fetch $c" >&2; exit 1; }
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
  # The app target's extra linker flags at this commit (cmux-next in
  # cmux.xcodeproj), so the proxy links the way the shipped app does.
  extra_ldflags=""
  if grep -q '"-objc_stubs_small",' "$src/cmux.xcodeproj/project.pbxproj"; then
    extra_ldflags=' "-Xlinker", "-objc_stubs_small",'
  fi
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
                "-framework", "UniformTypeIdentifiers", "-framework", "Carbon",$extra_ldflags
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
  local compiles
  compiles=$(grep -c -E '^SwiftCompile normal' "$work/$label.log" || true)
  hits=$(grep -c -E '^Cache hit' "$work/$label.log" || true)
  result "$label build_seconds=$(( SECONDS - t0 )) swift_compile_tasks=$compiles cache_hit_lines=$hits"
  grep -A6 'Build Timing Summary' "$work/$label.log" | sed -n '3,6p' | sed "s/^/  $label timing: /" || true
}

fails=0
hits=0
compare() {   # LABEL REQUIRED(yes|no): the build in $D against ref-clean1
  local rc=0
  python3 -I - "$work/ref-clean1" "$D" "$1" "$2" "$work/clean1.log" "$work/$1.log" <<'PY' || rc=$?
import glob, hashlib, os, re, struct, sys
ref_dd, other_dd, label, required, ref_log, other_log = sys.argv[1:7]
ref = os.path.join(ref_dd, "Build/Products/Release"); other = os.path.join(other_dd, "Build/Products/Release")
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

LC = {0x19: "SEGMENT_64", 0x1B: "UUID", 0x32: "BUILD_VERSION", 0x1D: "CODE_SIGNATURE", 0x2: "SYMTAB",
      0xB: "DYSYMTAB", 0x26: "FUNCTION_STARTS", 0x29: "DATA_IN_CODE", 0x80000033: "DYLD_EXPORTS_TRIE",
      0x80000034: "DYLD_CHAINED_FIXUPS", 0xC: "LOAD_DYLIB", 0x8000001C: "RPATH", 0x2A: "SOURCE_VERSION"}
def regions(data):
    """(name, offset, size) of each section and each linkedit blob of a thin 64-bit Mach-O."""
    if len(data) < 32 or struct.unpack_from("<I", data, 0)[0] != 0xFEEDFACF:
        return None
    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
    out = [("mach header + load commands", 0, 32 + sizeofcmds)]
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd == 0x19:
            segname = data[off + 8:off + 24].rstrip(b"\0").decode()
            fileoff, filesize = struct.unpack_from("<QQ", data, off + 40)
            nsects = struct.unpack_from("<I", data, off + 64)[0]
            if segname == "__LINKEDIT":
                out.append(("__LINKEDIT", fileoff, filesize))
            for i in range(nsects):
                so = off + 72 + i * 80
                sect = data[so:so + 16].rstrip(b"\0").decode()
                saddr, ssize, sfoff = struct.unpack_from("<QQI", data, so + 32)
                if sfoff:
                    out.append((f"{segname},{sect}", sfoff, ssize))
        elif cmd in (0x2, 0x1D, 0x26, 0x29, 0x80000033, 0x80000034):
            if cmd == 0x2:
                symoff, nsyms, stroff, strsize = struct.unpack_from("<IIII", data, off + 8)
                out.append(("LINKEDIT symtab", symoff, nsyms * 16)); out.append(("LINKEDIT strtab", stroff, strsize))
            else:
                doff, dsize = struct.unpack_from("<II", data, off + 8)
                out.append((f"LINKEDIT {LC.get(cmd, hex(cmd))}", doff, dsize))
        off += size
    return out

def explain(rel):
    a = open(os.path.join(ref, rel), "rb").read(); b = open(os.path.join(other, rel), "rb").read()
    print(f"    sizes {len(a)} / {len(b)}")
    ra, rb = regions(a), regions(b)
    if ra is None or rb is None:
        n = sum(1 for x, y in zip(a, b) if x != y)
        first = next((i for i, (x, y) in enumerate(zip(a, b)) if x != y), None)
        print(f"    not a thin 64-bit Mach-O; {n} differing bytes, first at {first}")
        return
    if [r[0] for r in ra] != [r[0] for r in rb]:
        print("    different region lists")
    for (name, o1, n1), (_, o2, n2) in zip(ra, rb):
        x, y = a[o1:o1 + n1], b[o2:o2 + n2]
        if x != y:
            nd = sum(1 for i, j in zip(x, y) if i != j) + abs(len(x) - len(y))
            print(f"    region {name}: {nd} bytes differ (sizes {n1}/{n2})")

def ld_block(log):
    """The link command of cmux-next-exe from an xcodebuild log, its paths kept."""
    text = open(log, errors="replace").read()
    m = re.search(r"^Ld \S*cmux-next-exe normal.*?\n\n", text, re.S | re.M)
    return m.group(0) if m else ""

a, b = walk(ref), walk(other)
only_ref = sorted(set(a) - set(b)); only_other = sorted(set(b) - set(a))
diff = sorted(k for k in set(a) & set(b) if a[k] != b[k])
same = len(set(a) & set(b)) - len(diff)
exe = "cmux-next-exe"
print(f"RESULT compare {label}: files={len(a)} equal={same} different={len(diff)} only_clean1={len(only_ref)} only_{label}={len(only_other)} executable={'equal' if a.get(exe) == b.get(exe) and exe in a else 'DIFFERENT'}")
for k in diff[:40]:
    print(f"  differs: {k}")
    if not k.endswith(".dSYM/Contents/Resources/DWARF/" + exe):
        try:
            explain(k)
        except Exception as e:
            print(f"    explain failed: {e}")
for k in only_ref[:10]:
    print(f"  only clean1: {k}")
for k in only_other[:10]:
    print(f"  only {label}: {k}")
if exe in diff:
    la, lb = ld_block(ref_log), ld_block(other_log)
    print(f"  link command: {'same' if la == lb else 'DIFFERENT'} ({len(la)} / {len(lb)} chars)")
    if la != lb:
        ta, tb = la.split(), lb.split()
        for i, (x, y) in enumerate(zip(ta, tb)):
            if x != y:
                print(f"    first differing argument {i}: {x[:160]} | {y[:160]}"); break
    fa = sorted(glob.glob(os.path.join(ref_dd, "Build/Intermediates.noindex/**/cmux-next-exe.LinkFileList"), recursive=True))
    fb = sorted(glob.glob(os.path.join(other_dd, "Build/Intermediates.noindex/**/cmux-next-exe.LinkFileList"), recursive=True))
    if fa and fb:
        xa, xb = open(fa[0]).read().split("\n"), open(fb[0]).read().split("\n")
        print(f"  LinkFileList: {'same' if xa == xb else 'DIFFERENT'} ({len(xa)} / {len(xb)} lines; same set: {sorted(xa) == sorted(xb)})")
        if xa != xb:
            for i, (x, y) in enumerate(zip(xa, xb)):
                if x != y:
                    print(f"    first differing line {i}: {x} | {y}"); break
    # Which linked object differs: hash each object the link list names, in both trees.
    if fa and fb:
        diffs = 0
        for pa, pb in zip(open(fa[0]).read().split(), open(fb[0]).read().split()):
            # clean1 was built at the same DerivedData path and then moved aside.
            if pa.startswith(other_dd + "/"):
                pa = ref_dd + pa[len(other_dd):]
            if os.path.exists(pa) and os.path.exists(pb) and open(pa, "rb").read() != open(pb, "rb").read():
                diffs += 1
                if diffs <= 10:
                    print(f"    linked object differs: {os.path.relpath(pa, ref_dd)}")
        print(f"  linked objects that differ: {diffs}")
if not a or exe not in a:
    print(f"RESULT compare {label}: clean1 has no {exe}; nothing was compared")
sys.exit(0 if a and exe in a and a.get(exe) == b.get(exe) and not (diff or only_ref or only_other) else 1)
PY
  if (( rc != 0 )) && [[ "$2" == yes ]]; then fails=$((fails + 1)); fi
  return 0
}

at "$head"
xcb clean1 "$D" "$work/cas-1"
mv "$D" "$work/ref-clean1"
rm -rf "$work/cas-1"
xcb clean2 "$D" "$work/cas-2"
compare clean2 yes
rm -rf "$D" "$work/cas-2"

at "$base"
xcb base-w "$D" "$work/cas-w"
rm -rf "$D"

at "$head"
xcb warm "$D" "$work/cas-w"
(( hits > 0 )) || { result "warm read no compilation cache entry (cache_hit_lines=0): the cache was not used"; fails=$((fails + 1)); }
compare warm yes
rm -rf "$D"
xcb hit "$D" "$work/cas-w"
(( hits > 0 )) || { result "hit read no compilation cache entry (cache_hit_lines=0): the cache was not used"; fails=$((fails + 1)); }
compare hit yes
echo "==> warm cache size: $(du -sh "$work/cas-w" | awk '{print $1}')"
rm -rf "$D" "$work/cas-w"

at "$base"
xcb base-i "$D" "$work/cas-i"
at "$head"
xcb incr "$D" "$work/cas-i" keep
compare incr no

if (( fails )); then
  result "FAIL: $fails required comparison(s) differ from clean1"
  exit 1
fi
result "PASS: warm (empty DerivedData + cache from base) and hit equal clean1 byte for byte"
