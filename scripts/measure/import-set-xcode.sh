#!/usr/bin/env bash
# Behavior test of the fleet Mac slot's import set check (HQ
# build-fleet/recipes/cmux-import-set.py) with Xcode's incremental build.
#
# Swift writes the force-load references and autolink hints of every module a
# module imports (and of the modules those import) into every object of that
# module; an incremental build compiles only the changed files. So after a leaf
# module adds or removes an import, the kept objects of the leaf and of every
# module that imports it keep the old set, and the app can link a library its
# code no longer imports (HQ #2511, pool job df80abc2).
#
# This builds the cmux-next app executable as the Xcode target `cmux-next`
# links it (App/main.swift over the CmuxNextApp product) with xcodebuild, the
# slot build's Swift settings (batch mode on, no debug info, GlobalISel off) and
# a fixed DerivedData path, and compares every incremental build with a clean
# build of the same tree at the same path: each object's force-load symbols and
# LC_LINKER_OPTION hints (in order), every prelinked Build/Products/Debug/*.o,
# the executable's bytes and ordered LC_LOAD_* list, its LinkFileList and its
# link command line. Each clean build is made twice, to show whether the clean
# build itself is deterministic.
#
#   A  this commit; B  A with `import MODULE` added to one leaf file, MODULE the
#      first probed SDK module whose import gives a __swift_FORCE_LOAD reference
#      (a module that is only an autolink hint links nothing: ld drops it)
#   rollout  clean A, then the check with no record (every Swift module cleared)
#   fix-add A->B, fix-remove B->A, repair (a stale B fixed): must equal clean
#   nofix-add A->B and nofix-remove B->A without the check: must show the defect
#
# Run alone on a worker, with the tool from the controller (owner uploads it):
#   cmux-ci run --class exclusive --script scripts/measure/import-set-xcode.sh --ref SHA \
#     --tool cmux-import-set@sha256:HEX --timeout 9000 --key import-set-xcode-<sha8>-<n>
# Args: leaf=<repo-relative Swift file> (default CmuxTheme's AppTheme.swift),
#       module=<the module it adds and removes> (default auto: the probe above;
#       no macOS module of this graph may import it already),
#       relinks=<links per linker mode in the relink probe> (default 5, 1-50),
#       only=relink (build clean A, run the relink probe and the objc stub
#       cost probe, then stop: no import set legs, one DerivedData tree).
# Output: RESULT lines; files under .build/import-set-xcode. Exit 0 when every
# expectation holds. Never changes anything outside this checkout.
set -euo pipefail
leaf="Packages/Shared/CmuxTheme/Sources/CmuxTheme/AppTheme.swift"
module="auto"
relinks=5
only=""
for arg in "$@"; do
  case "$arg" in
    leaf=*) leaf="${arg#leaf=}" ;;
    module=*) module="${arg#module=}" ;;
    relinks=*) relinks="${arg#relinks=}" ;;
    only=*) only="${arg#only=}" ;;
    *) echo "import-set-xcode.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$leaf" =~ ^Packages/[A-Za-z0-9_./+-]+\.swift$ && "$leaf" != *..* ]] || { echo "import-set-xcode.sh: leaf must be a Swift file under Packages/" >&2; exit 2; }
[[ "$relinks" =~ ^[1-9][0-9]?$ && "$relinks" -le 50 ]] || { echo "import-set-xcode.sh: relinks must be 1-50" >&2; exit 2; }
[[ -z "$only" || "$only" == relink ]] || { echo "import-set-xcode.sh: only must be relink" >&2; exit 2; }
[[ "$module" == auto || "$module" =~ ^[A-Z][A-Za-z0-9_]{1,40}$ ]] || { echo "import-set-xcode.sh: module must be a module name" >&2; exit 2; }
tool="${CMUX_CI_TOOL_CMUX_IMPORT_SET:-}"
[[ -n "$tool" && -f "$tool" ]] || { echo "import-set-xcode.sh: pass --tool cmux-import-set@sha256:HEX" >&2; exit 2; }
root="$(git rev-parse --show-toplevel)"
cd "$root"
[[ -f "$leaf" && -f App/main.swift && -d Packages/macOS/CmuxNext ]] || { echo "import-set-xcode.sh: $leaf, App/main.swift or CmuxNext missing" >&2; exit 2; }
imported() { git grep -q -E "^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*((public|internal|package|private|fileprivate)[[:space:]]+)?import[[:space:]]+(struct[[:space:]]+|class[[:space:]]+|enum[[:space:]]+|protocol[[:space:]]+|func[[:space:]]+|typealias[[:space:]]+|var[[:space:]]+|let[[:space:]]+)?$1([^A-Za-z0-9_]|$)" -- 'Packages/macOS/*.swift' 'Packages/Shared/*.swift' 'Packages/iOS/*.swift' App; }
if [[ "$module" != auto ]] && imported "$module"; then
  echo "import-set-xcode.sh: a macOS module of this graph imports $module already; choose another module=" >&2
  exit 2
fi
work="$root/.build/import-set-xcode"
rm -rf "$work"
mkdir -p "$work/app-exe/Sources/cmux-next-exe" "$work/spm" "$work/probe"
D="$work/dd" RA="$work/clean-A" RB="$work/clean-B" RA2="$work/clean-A2" RB2="$work/clean-B2"
# On exit: the DerivedData trees, packages and probe outputs removed (about
# 40-50 GB); the logs stay. The leaf file is put back by the trap set below.
trap 'rm -rf "$D" "$RA" "$RB" "$RA2" "$RB2" "$work/spm" "$work/probe"' EXIT
free_gb=$(( $(df -k "$root" | awk 'NR==2 {print $4}') / 1048576 ))
echo "==> free disk ${free_gb} GB"
(( free_gb >= 60 )) || { echo "import-set-xcode.sh: needs 60 GB free (five DerivedData trees); ${free_gb} GB free" >&2; exit 1; }
result() { echo "RESULT $*"; }
fails=0

# The Xcode this source pins for this host (as the slot build: select-ci-xcode.sh
# without xcode-select), unless the worker already exported one.
if [[ -z "${DEVELOPER_DIR:-}" && -f scripts/select-ci-xcode.sh ]]; then
  envf="$(mktemp)"
  CMUX_CI_SKIP_XCODE_SELECT=1 GITHUB_ENV="$envf" /bin/bash scripts/select-ci-xcode.sh >/dev/null
  DEVELOPER_DIR="$(sed -n 's/^DEVELOPER_DIR=//p' "$envf" | tail -1)"
  rm -f "$envf"
  export DEVELOPER_DIR
fi
unset SDKROOT
echo "IMPORT-SET-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) cpu=\"$(sysctl -n machdep.cpu.brand_string)\" cores=$(sysctl -n hw.ncpu) macos=$(sw_vers -productVersion) xcode=\"$(xcodebuild -version | tr '\n' ' ')\" rev=$(git rev-parse HEAD) tool_sha256=${CMUX_CI_TOOL_CMUX_IMPORT_SET_SHA256:-$(shasum -a 256 "$tool" | awk '{print $1}')}"

# The test module: the first candidate no macOS module of this graph imports
# whose import alone gives an object a __swift_FORCE_LOAD_$_swift<MODULE>
# reference (that reference keeps the library's load command in the executable).
if [[ "$module" == auto ]]; then
  sdk="$(xcrun --sdk macosx --show-sdk-path)"
  cands=(Network NaturalLanguage CoreML Vision GameplayKit SpriteKit SceneKit ModelIO MetalKit CoreMIDI Intents
         CloudKit AVFoundation CoreImage Accelerate MapKit Charts TabularData StoreKit Observation RegexBuilder
         Distributed Synchronization XPC OSLog CryptoKit SwiftData AppIntents CoreBluetooth CoreAudio CoreMedia
         CoreVideo PDFKit Photos GameController EventKit Speech SoundAnalysis CreateML RealityKit MusicKit
         WeatherKit Translation FoundationModels Contacts CoreLocation os simd Dispatch)
  free=()
  for m in "${cands[@]}"; do imported "$m" || free+=("$m"); done
  (( ${#free[@]} )) || { echo "import-set-xcode.sh: every probe candidate is imported already; pass module=" >&2; exit 2; }
  printf '%s\n' "${free[@]}" | xargs -P 8 -I{} /bin/bash -c '
    printf "import %s\n" "$1" >"$2/$1.swift"
    xcrun swiftc -target arm64-apple-macos14.0 -sdk "$3" -Onone -parse-as-library -module-cache-path "$2/mc" \
      -module-name Probe$1 -c "$2/$1.swift" -o "$2/$1.o" >"$2/$1.err" 2>&1 || rm -f "$2/$1.o"' _ {} "$work/probe" "$sdk"
  module="" force_module=0
  for m in "${free[@]}"; do
    [[ -f "$work/probe/$m.o" ]] || continue
    syms="$(python3 -I -c 'import re,sys; print(" ".join(sorted({m.decode() for m in re.findall(rb"__swift_FORCE_LOAD_\$_swift[A-Za-z0-9_]+", open(sys.argv[1],"rb").read())})))' "$work/probe/$m.o")"
    echo "==> probe import $m: force-load ${syms:-none}"
    if [[ -z "$module" && " $syms " == *" __swift_FORCE_LOAD_\$_swift${m} "* ]]; then module="$m" force_module=1; fi
  done
  if [[ -z "$module" ]]; then
    module="Contacts"
    echo "==> probe: no candidate import gives its own force-load reference; module=Contacts (an autolink hint only)"
  fi
else
  force_module=1
fi
echo "==> module $module (force-load reference: $force_module)"

# The app executable package (the Xcode target cmux-next: App/main.swift over
# CmuxNextApp, with that target's linked libraries and frameworks).
cp App/main.swift "$work/app-exe/Sources/cmux-next-exe/main.swift"
cat >"$work/app-exe/Package.swift" <<EOF
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "CmuxNextAppExecutable",
    platforms: [.macOS("14.0")],
    products: [.executable(name: "cmux-next-exe", targets: ["cmux-next-exe"])],
    dependencies: [.package(path: "$root/Packages/macOS/CmuxNext")],
    targets: [
        .executableTarget(
            name: "cmux-next-exe",
            dependencies: [.product(name: "CmuxNextApp", package: "CmuxNext")],
            path: "Sources/cmux-next-exe",
            // One flag list: Xcode put .linkedLibrary("c++") before or after
            // the .linkedFramework group in two clean builds of one tree
            // (fleet step 4728fa07), which moves libc++'s load command.
            linkerSettings: [.unsafeFlags([
                "-lc++", "-framework", "Metal", "-framework", "QuartzCore", "-framework", "IOSurface",
                "-framework", "UniformTypeIdentifiers", "-framework", "Carbon",
            ])]
        ),
    ]
)
EOF
# SwiftPM reads pins only from the root package: use the pins Xcode builds the
# app with (CmuxNext's Package.resolved, the project's winning; as the Linux
# pool's sbx-remote), not the newest versions in range.
python3 -I - Packages/macOS/CmuxNext/Package.resolved \
  cmux.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved "$work/app-exe/Package.resolved" <<'PY'
import json, os, sys
pkg = json.load(open(sys.argv[1]))
proj = {p["identity"]: p for p in json.load(open(sys.argv[2]))["pins"]} if os.path.exists(sys.argv[2]) else {}
merged = {p["identity"]: p for p in pkg["pins"]}
merged.update(proj)
pkg["pins"] = sorted(merged.values(), key=lambda p: p["identity"])
pkg.pop("originHash", None)   # CmuxNext's hash is not this root package's
with open(sys.argv[3], "w") as f:
    json.dump(pkg, f, indent=2, sort_keys=True)
    f.write("\n")
PY
cp "$work/app-exe/Package.resolved" "$work/pins.json"

leaf_a="$work/leaf-A.swift" leaf_b="$work/leaf-B.swift"
cp "$leaf" "$leaf_a"
python3 -I - "$leaf_a" "$leaf_b" "$module" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().split("\n")
k = next(i for i, l in enumerate(lines) if re.match(r"^(@\w+ )*import ", l))
lines.insert(k + 1, "import " + sys.argv[3])
open(sys.argv[2], "w").write("\n".join(lines))
PY
at() { cp "$([[ "$1" == A ]] && echo "$leaf_a" || echo "$leaf_b")" "$leaf"; }
trap 'cp "$leaf_a" "$leaf" 2>/dev/null || true; rm -rf "$D" "$RA" "$RB" "$RA2" "$RB2" "$work/spm" "$work/probe" "$work/relink" "$work/stubcost"' EXIT

# The package's scheme: the executable product's, else the whole package's.
scheme="$(cd "$work/app-exe" && xcodebuild -list -json -clonedSourcePackagesDirPath "$work/spm" 2>"$work/list.err" | python3 -I -c '
import json, sys
s = (json.load(sys.stdin).get("workspace") or {}).get("schemes") or []
print(next((n for n in ("cmux-next-exe", "CmuxNextAppExecutable-Package", "CmuxNextAppExecutable") if n in s), ""))
print("schemes:", s, file=sys.stderr)')" || true
[[ -n "$scheme" ]] || { tail -20 "$work/list.err"; echo "import-set-xcode.sh: no scheme for the app executable package" >&2; exit 1; }
echo "==> scheme $scheme"
xcb() {   # LABEL: one build in $D, the slot build's Swift settings
  local t0=$SECONDS
  if ! (cd "$work/app-exe" && xcodebuild -scheme "$scheme" -configuration Debug \
      -destination 'platform=macOS,arch=arm64' -derivedDataPath "$D" -clonedSourcePackagesDirPath "$work/spm" \
      -skipPackagePluginValidation -skipMacroValidation -verbose \
      SWIFT_ENABLE_BATCH_MODE=YES DEBUG_INFORMATION_FORMAT= GCC_GENERATE_DEBUGGING_SYMBOLS=NO \
      'OTHER_SWIFT_FLAGS=$(inherited) -Xllvm -aarch64-enable-global-isel-at-O=-1' \
      build >"$work/$1.log" 2>&1); then
    grep -E 'error:|BUILD FAILED' "$work/$1.log" | head -20 || true
    tail -20 "$work/$1.log"
    echo "import-set-xcode.sh: build $1 failed" >&2
    exit 1
  fi
  result "$1 build_seconds=$(( SECONDS - t0 ))"
}
check() { python3 -I "$tool" check "$D" "$root" --configuration Debug --identity import-set-xcode-test; }
done_() { python3 -I "$tool" done "$D" "$root" --configuration Debug --commit "$(git rev-parse HEAD)"; }
fixed() {   # LABEL: the slot recipe's sequence (check, build, done, one more build on exit 3)
  local t0=$SECONDS rc=0
  touch "$work/$1.start"
  check
  xcb "$1"
  done_ || rc=$?
  if (( rc == 3 || rc == 4 )); then
    xcb "$1-again"
    rc=0
    done_ || rc=$?
  fi
  (( rc == 0 )) || { result "$1 FAIL (done exit $rc after the rebuild)"; fails=$((fails + 1)); }
  result "$1 total_seconds=$(( SECONDS - t0 ))"
}
plain() { touch "$work/$1.start"; xcb "$1"; }

# Compare a build tree with a clean build of the same tree at the same path.
compare() {   # LABEL SHIPPED_DIR CLEAN_DIR EXPECT(match|stale-objects|stale-dylib|info|probe) CLEAN_LABEL
  # probe: as match, but the caller reads the exit code and counts the result.
  local leg="${1%%~*}" rc=0
  python3 -I - "$2" "$3" "$work/$leg.start" "$1" "$4" "$module" "$work/$leg-again.log" "$work/$leg.log" "$work/$5.log" <<'PY' || rc=$?
import glob, hashlib, os, re, shlex, struct, sys
shipped, clean, start, label, expect, module, slog_again, slog, clog = sys.argv[1:10]
since = os.stat(start).st_mtime_ns
FL = re.compile(rb"__swift_FORCE_LOAD_\$_[A-Za-z0-9_$]+")
DYLIB = {0xC: "LOAD_DYLIB", 0x18 | 0x80000000: "LOAD_WEAK_DYLIB", 0x1F | 0x80000000: "REEXPORT_DYLIB",
         0x20: "LAZY_LOAD_DYLIB", 0x23 | 0x80000000: "LOAD_UPWARD_DYLIB"}
EXE = "cmux-next-exe"

def macho(path):
    """Force-load names (string-table order, first seen), LC_LINKER_OPTION
    hints (load-command order), LC_LOAD_* list (order), sha256."""
    data = open(path, "rb").read()
    if len(data) < 32 or struct.unpack_from("<I", data, 0)[0] != 0xFEEDFACF:
        return None
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off, fl, opts, dylibs = 32, [], [], []
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd == 0x2:   # LC_SYMTAB
            _symoff, _nsyms, stroff, strsize = struct.unpack_from("<IIII", data, off + 8)
            for m in FL.findall(data, stroff, stroff + strsize):
                if m.decode() not in fl:
                    fl.append(m.decode())
        elif cmd == 0x2D:   # LC_LINKER_OPTION
            count = struct.unpack_from("<I", data, off + 8)[0]
            opts.append(" ".join(s.decode() for s in data[off + 12:off + size].split(b"\0")[:count]))
        elif cmd in DYLIB:
            name_off = struct.unpack_from("<I", data, off + 8)[0]
            name = data[off + name_off:off + size].split(b"\0")[0].decode()
            dylibs.append(f"{DYLIB[cmd]} {name}")
        off += size
    return {"fl": fl, "opts": opts, "dylibs": dylibs, "sha": hashlib.sha256(data).hexdigest()}

def kind(a, b):
    """'' equal bytes; 'set' other force-load or hint set; 'order' same sets in
    another order; 'bytes' same ordered sets, other bytes."""
    if a is not None and b is not None and a["sha"] == b["sha"]:
        return ""
    if a is None or b is None or sorted(a["fl"]) != sorted(b["fl"]) or sorted(set(a["opts"])) != sorted(set(b["opts"])):
        return "set"
    if a["fl"] != b["fl"] or a["opts"] != b["opts"]:
        return "order"
    return "bytes"

base = lambda dd: os.path.join(dd, "Build", "Intermediates.noindex")
def objects(dd):
    pat = os.path.join(glob.escape(base(dd)), "*", "Debug", "*", "Objects-normal", "arm64", "*.o")
    return {os.path.relpath(p, base(dd)): p for p in glob.glob(pat)}
def products(dd):
    pat = os.path.join(glob.escape(os.path.join(dd, "Build", "Products", "Debug")), "*.o")
    return {os.path.basename(p): p for p in glob.glob(pat)}

def tally(sh, cl):
    only_sh, only_cl = sorted(set(sh) - set(cl)), sorted(set(cl) - set(sh))
    diffs = []   # (rel, kind, kept, a, b)
    for rel in sorted(set(sh) & set(cl)):
        a, b = macho(sh[rel]), macho(cl[rel])
        k = kind(a, b)
        if k:
            diffs.append((rel, k, os.stat(sh[rel]).st_mtime_ns < since, a, b))
    return only_sh, only_cl, diffs, len(set(sh) & set(cl))

ok_parts = {}
# 1. Unit objects.
osh, ocl = objects(shipped), objects(clean)
only_sh, only_cl, odiff, n = tally(osh, ocl)
kept_all = sum(1 for p in osh.values() if os.stat(p).st_mtime_ns < since)
by_mod = {}
for rel, k, kept, _a, _b in odiff:
    st = by_mod.setdefault(rel.split("/")[2].removesuffix(".build"), {"set": 0, "order": 0, "bytes": 0, "kept": 0})
    st[k] += 1
    st["kept"] += kept
cnt = lambda ds, k: sum(1 for d in ds if d[1] == k)
print(f"RESULT {label} objects={n} kept={kept_all} only_shipped={len(only_sh)} only_clean={len(only_cl)} "
      f"byte_equal={n - len(odiff)} set_differ={cnt(odiff, 'set')} order_differ={cnt(odiff, 'order')} "
      f"bytes_only_differ={cnt(odiff, 'bytes')} kept_set_differ={sum(1 for d in odiff if d[1] == 'set' and d[2])}")
mods = [f"{m}:set{s['set']}/order{s['order']}/bytes{s['bytes']}(kept {s['kept']})" for m, s in sorted(by_mod.items())]
print(f"RESULT {label} object modules that differ: {' '.join(mods)[:1500] or 'none'}")
for rel, k, kept, a, b in odiff[:3]:
    if a and b:
        print(f"RESULT {label} example {rel} {k} kept={kept} force-load only here={sorted(set(a['fl']) - set(b['fl']))} "
              f"only clean={sorted(set(b['fl']) - set(a['fl']))} hints only here={sorted(set(a['opts']) - set(b['opts']))} "
              f"only clean={sorted(set(b['opts']) - set(a['opts']))}")
ok_parts["objects"] = not only_sh and not only_cl and not odiff

# 2. Prelinked products: Build/Products/Debug/*.o, and whether each is older
# than the newest unit object of its module (a skipped relink).
psh, pcl = products(shipped), products(clean)
ponly_sh, ponly_cl, pdiff, pn = tally(psh, pcl)
pkept = sum(1 for p in psh.values() if os.stat(p).st_mtime_ns < since)
stale_prelink = []
for name, p in sorted(psh.items()):
    units = glob.glob(os.path.join(glob.escape(base(shipped)), "*", "Debug", glob.escape(name[:-2]) + ".build",
                                   "Objects-normal", "arm64", "*.o"))
    newest = max((os.stat(u).st_mtime_ns for u in units), default=0)
    if newest > os.stat(p).st_mtime_ns:
        stale_prelink.append(name[:-2])
print(f"RESULT {label} products={pn} kept={pkept} only_shipped={len(ponly_sh)} only_clean={len(ponly_cl)} "
      f"byte_equal={pn - len(pdiff)} set_differ={cnt(pdiff, 'set')} order_differ={cnt(pdiff, 'order')} "
      f"bytes_only_differ={cnt(pdiff, 'bytes')} older_than_unit_objects={len(stale_prelink)}")
print(f"RESULT {label} products that differ: {' '.join(f'{r[:-2]}:{k}(kept {kp})' for r, k, kp, _a, _b in pdiff)[:1500] or 'none'}"
      f"; older than their unit objects: {' '.join(stale_prelink)[:800] or 'none'}"
      f"; only here: {ponly_sh[:10] or 'none'}; only clean: {ponly_cl[:10] or 'none'}")
for rel, k, kept, a, b in pdiff[:2]:
    if a and b and k == "order":
        for what in ("opts", "fl"):
            i = next((i for i, (x, y) in enumerate(zip(a[what] + [""], b[what] + [""])) if x != y), None)
            if i is not None:
                print(f"RESULT {label} product {rel} {what} order from #{i}: here={a[what][i:i + 6]} clean={b[what][i:i + 6]}")
ok_parts["products"] = not ponly_sh and not ponly_cl and not pdiff and not stale_prelink

# 3. The executable: bytes and ordered load commands.
exe_sh = macho(os.path.join(shipped, "Build", "Products", "Debug", EXE))
exe_cl = macho(os.path.join(clean, "Build", "Products", "Debug", EXE))
dl_sh, dl_cl = exe_sh["dylibs"], exe_cl["dylibs"]
same_order = dl_sh == dl_cl
print(f"RESULT {label} exe_byte_equal={exe_sh['sha'] == exe_cl['sha']} load_commands={len(dl_sh)}/{len(dl_cl)} "
      f"load_order_equal={same_order} load_set_equal={sorted(dl_sh) == sorted(dl_cl)}")
print(f"RESULT {label} load commands only in this build: {[d for d in dl_sh if d not in dl_cl] or 'none'}; "
      f"only in the clean build: {[d for d in dl_cl if d not in dl_sh] or 'none'}")
if not same_order:
    i = next(i for i, (x, y) in enumerate(zip(dl_sh + [""], dl_cl + [""])) if x != y)
    short = lambda ds: [d.split(" ", 1)[1].rsplit("/", 1)[-1] for d in ds]
    print(f"RESULT {label} load order from #{i}: here={short(dl_sh[i:i + 8])} clean={short(dl_cl[i:i + 8])}")
ok_parts["exe"] = exe_sh["sha"] == exe_cl["sha"]
if not ok_parts["exe"]:
    # Where the bytes differ: header and load commands, each section, and each
    # __LINKEDIT table (symbols, strings, fixups, exports, signature).
    def regions(path):
        d = open(path, "rb").read()
        n, sizeofcmds = struct.unpack_from("<II", d, 16)
        out, off = [("header+load commands", 0, 32 + sizeofcmds)], 32
        uuid = ""
        LE = {0x26: "function starts", 0x29: "data in code", 0x1D: "code signature",
              0x80000033: "exports trie", 0x80000034: "chained fixups"}
        for _ in range(n):
            cmd, size = struct.unpack_from("<II", d, off)
            if cmd == 0x19:   # LC_SEGMENT_64
                seg = d[off + 8:off + 24].split(b"\0")[0].decode()
                nsects = struct.unpack_from("<I", d, off + 64)[0]
                for k in range(nsects):
                    so = off + 72 + 80 * k
                    sect = d[so:so + 16].split(b"\0")[0].decode()
                    addr_size = struct.unpack_from("<Q", d, so + 40)[0]
                    foff = struct.unpack_from("<I", d, so + 48)[0]
                    if foff:
                        out.append((f"{seg},{sect}", foff, addr_size))
            elif cmd == 0x2:
                symoff, nsyms, stroff, strsize = struct.unpack_from("<IIII", d, off + 8)
                out += [("symbol table", symoff, nsyms * 16), ("string table", stroff, strsize)]
            elif cmd == 0xB:   # LC_DYSYMTAB
                ind, nind = struct.unpack_from("<II", d, off + 56)
                out.append(("indirect symbols", ind, nind * 4))
            elif cmd in LE:
                dataoff, datasize = struct.unpack_from("<II", d, off + 8)
                out.append((LE[cmd], dataoff, datasize))
            elif cmd == 0x1B:
                uuid = d[off + 8:off + 24].hex()
            off += size
        return d, out, uuid
    notes = []
    try:
        da, ra, ua = regions(os.path.join(shipped, "Build", "Products", "Debug", EXE))
        db, rb, ub = regions(os.path.join(clean, "Build", "Products", "Debug", EXE))
    except Exception as e:   # a diagnostic never stops the compare
        da = db = b""
        ra, rb, ua, ub = [], [("?", 0, 0)], "", ""
        notes.append(f"region parse failed: {type(e).__name__}: {e}")
    if len(da) != len(db) or [(r[0], r[1], r[2]) for r in ra] != [(r[0], r[1], r[2]) for r in rb]:
        notes.append(f"layout differs (size {len(da)}/{len(db)})")
        lay_b = {r[0]: r for r in rb}
        notes += [f"{r[0]}:{r[2]}/{lay_b[r[0]][2]}" for r in ra if r[0] in lay_b and lay_b[r[0]][2] != r[2]][:10]
    else:
        for name, o, n in ra:
            diff_chunks, first = 0, None
            for c in range(o, o + n, 4096):
                e = min(c + 4096, o + n)
                if da[c:e] != db[c:e]:
                    diff_chunks += 1
                    if first is None:
                        first = next(i for i in range(c, e) if da[i] != db[i]) - o
            if diff_chunks:
                notes.append(f"{name}: {diff_chunks} of {(n + 4095) // 4096} 4K chunks, first at +{first}")
    print(f"RESULT {label} exe bytes differ in: {'; '.join(notes)[:1500] or 'nothing mapped'} (uuid {ua[:12]}/{ub[:12]})")

# 4. LinkFileList and the link command line.
def lfl(dd):
    ps = glob.glob(os.path.join(glob.escape(base(dd)), "*", "Debug", EXE + ".build", "Objects-normal", "arm64", "*.LinkFileList"))
    return open(ps[0]).read().splitlines() if ps else None
l_sh, l_cl = lfl(shipped), lfl(clean)
if l_sh is None or l_cl is None:
    print(f"RESULT {label} LinkFileList missing here={l_sh is None} clean={l_cl is None}")
    ok_parts["linkfilelist (diagnostic)"] = False
else:
    eq = l_sh == l_cl
    msg = f"RESULT {label} LinkFileList entries={len(l_sh)}/{len(l_cl)} equal={eq} same_set={sorted(l_sh) == sorted(l_cl)}"
    if not eq:
        i = next(i for i, (x, y) in enumerate(zip(l_sh + [""], l_cl + [""])) if x != y)
        msg += f" first difference #{i}: here={[os.path.basename(x) for x in l_sh[i:i + 5]]} clean={[os.path.basename(x) for x in l_cl[i:i + 5]]}"
    print(msg)
    ok_parts["linkfilelist (diagnostic)"] = eq

def link_cmd(log):
    """The argv of the last link of the executable in an xcodebuild log."""
    try:
        lines = open(log, errors="replace").read().splitlines()
    except OSError:
        return None
    out = None
    for i, l in enumerate(lines):
        if l.startswith("Ld ") and f"/Build/Products/Debug/{EXE} " in l:
            for c in lines[i + 1:i + 12]:
                s = c.strip()
                if not s:
                    break
                if not s.startswith("cd ") and not s.startswith("export ") and f"/Debug/{EXE}" in s:
                    try:
                        out = shlex.split(s)
                    except ValueError:
                        out = s.split()
    return out
c_sh, c_cl = link_cmd(slog_again) or link_cmd(slog), link_cmd(clog)
if c_sh is None or c_cl is None:
    print(f"RESULT {label} link command not in the log here={c_sh is None} clean={c_cl is None} (no relink in this build?)")
    ok_parts["link_command (diagnostic)"] = False
else:
    eq = c_sh == c_cl
    msg = f"RESULT {label} link command args={len(c_sh)}/{len(c_cl)} equal={eq} same_set={sorted(c_sh) == sorted(c_cl)}"
    if not eq:
        here = [a for a in c_sh if a not in c_cl][:6]
        there = [a for a in c_cl if a not in c_sh][:6]
        msg += f" only here={here} only clean={there}"
    print(msg)
    ok_parts["link_command (diagnostic)"] = eq

if expect in ("match", "info", "probe"):
    ok = all(v for k, v in ok_parts.items() if "diagnostic" not in k)
elif expect == "stale-objects":
    ok = any(k == "set" and kept for _r, k, kept, _a, _b in odiff)
else:   # stale-dylib: the executable keeps a load command of the removed module
    ok = any(f"/libswift{module}.dylib" in d or f"/{module}.framework/" in d for d in dl_sh if d not in dl_cl)
bad = [k for k, v in ok_parts.items() if not v]
print(f"RESULT {label} {'PASS' if ok else 'FAIL'} (expected {expect}; differ: {', '.join(bad) or 'nothing'})")
sys.exit(0 if ok or expect == "info" else 1)
PY
  if [[ "$4" == probe ]]; then return $rc; fi
  if (( rc != 0 )); then fails=$((fails + 1)); fi
}

# A leg that must equal a clean build of its tree. Apple ld does not link the
# same inputs to the same bytes every time (fleet step 6c0430b0: two clean
# builds of one tree differ only in __TEXT,__objc_stubs order, __stubs, the
# UUID and the signature), so the leg passes when it equals either clean build
# of the tree, objects and products included.
match_any() {   # LEG REF1 LABEL1 REF2 LABEL2
  if compare "$1" "$D" "$2" probe "$3"; then
    result "$1 PASS (equals clean build $3)"
  elif compare "$1~vs-$5" "$D" "$4" probe "$5"; then
    result "$1 PASS (equals clean build $5, the other clean build of this tree)"
  else
    result "$1 FAIL (equals neither clean build of this tree)"
    fails=$((fails + 1))
  fi
}

# Link the clean A executable again with its own link command, relinks= times
# per linker mode, while its DerivedData is in place: is the link
# deterministic, does a linker option make it so, and what does the option
# cost (executable size, __objc_stubs size, link seconds)?
relink_probe() {
  python3 -I - "$work/clean-A.log" "$work/relink" "$relinks" <<'PY' || true   # mask-ok: a diagnostic never fails the run
import hashlib, os, shlex, statistics, struct, subprocess, sys, time
log, out, count = sys.argv[1], sys.argv[2], int(sys.argv[3])
os.makedirs(out, exist_ok=True)
lines = open(log, errors="replace").read().splitlines()
cwd, argv = None, None
for i, l in enumerate(lines):
    if l.startswith("Ld ") and "/Build/Products/Debug/cmux-next-exe " in l:
        for c in lines[i + 1:i + 12]:
            s = c.strip()
            if not s:
                break
            if s.startswith("cd "):
                cwd = shlex.split(s)[1]
            elif not s.startswith("export ") and "/Debug/cmux-next-exe" in s:
                argv = shlex.split(s)
if not argv:
    print("RESULT relink no link command in clean-A.log")
    sys.exit(0)
def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()[:12]
def sections(p):
    d = open(p, "rb").read()
    if struct.unpack_from("<I", d, 0)[0] != 0xFEEDFACF:   # thin 64-bit only (a Debug build is thin)
        return {}
    n = struct.unpack_from("<I", d, 16)[0]; o = 32; got = {}
    for _ in range(n):
        c, s = struct.unpack_from("<II", d, o)
        if c == 0x19:   # LC_SEGMENT_64
            for k in range(struct.unpack_from("<I", d, o + 64)[0]):
                q = o + 72 + 80 * k
                got[d[q:q + 16].split(b"\0")[0].decode()] = struct.unpack_from("<Q", d, q + 40)[0]
        o += s
    return got
exe_sha = sha(argv[argv.index("-o") + 1])
for name, extra in (("default", []), ("reproducible", ["-Xlinker", "-reproducible"]),
                    ("objc_stubs_small", ["-Xlinker", "-objc_stubs_small"]), ("O0", ["-Xlinker", "-O0"])):
    shas, err, secs, sizes = [], "", [], set()
    for n in range(count):
        a = list(argv)
        # The same file name: the linker signature's identifier is the output's name.
        exe = os.path.join(out, f"{name}-{n}", "cmux-next-exe")
        os.makedirs(os.path.dirname(exe), exist_ok=True)
        a[a.index("-o") + 1] = exe
        if "-dependency_info" in a:
            a[a.index("-dependency_info") + 2] = os.path.join(out, f"{name}-{n}.dat")
        t = time.monotonic()
        r = subprocess.run(a + extra, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if r.returncode:
            err = r.stdout.decode(errors="replace").strip().splitlines()[-1:]
            break
        secs.append(time.monotonic() - t)
        shas.append(sha(exe))
        sizes.add((os.path.getsize(exe), sections(exe).get("__objc_stubs", 0)))
        os.remove(exe)
    print(f"RESULT relink {name}: links={len(shas)} distinct_outputs={len(set(shas))} "
          f"counts={sorted(((shas.count(h), h) for h in set(shas)), reverse=True)} exe_and_objc_stubs_bytes={sorted(sizes)} "
          f"link_seconds_median={round(statistics.median(secs), 2) if secs else 0} "
          f"xcodebuild_output={exe_sha} {'error=' + str(err) if err else ''}")
PY
  rm -rf "$work/relink"
}

# The run time cost of -objc_stubs_small: one Objective-C message send through
# a selector stub, 200 million times, linked with the default (fast) stubs and
# with small stubs, 7 runs each; the median nanoseconds per send.
stub_cost_probe() {
  local dir="$work/stubcost"
  mkdir -p "$dir"
  cat >"$dir/bench.m" <<'M'
#import <Foundation/Foundation.h>
#include <mach/mach_time.h>
@interface Box : NSObject { @public long n; }
- (void)bump;
@end
@implementation Box
- (void)bump { n++; }
@end
int main(void) {
  @autoreleasepool {
    Box *b = [Box new];
    const long count = 200000000;
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    uint64_t t = mach_absolute_time();
    for (long i = 0; i < count; i++) [b bump];
    uint64_t e = mach_absolute_time() - t;
    printf("%.4f %ld\n", (double)e * tb.numer / tb.denom / count, b->n);
  }
  return 0;
}
M
  python3 -I - "$dir" <<'PY' || true   # mask-ok: a diagnostic never fails the run
import os, statistics, struct, subprocess, sys
d = sys.argv[1]
def stubs(p):
    b = open(p, "rb").read()
    if struct.unpack_from("<I", b, 0)[0] != 0xFEEDFACF:
        return -1
    n = struct.unpack_from("<I", b, 16)[0]; o = 32
    for _ in range(n):
        c, s = struct.unpack_from("<II", b, o)
        if c == 0x19:
            for k in range(struct.unpack_from("<I", b, o + 64)[0]):
                q = o + 72 + 80 * k
                if b[q:q + 16].split(b"\0")[0] == b"__objc_stubs":
                    return struct.unpack_from("<Q", b, q + 40)[0]
        o += s
    return 0
built, ns = [], {}
for name, flag in (("default", []), ("objc_stubs_small", ["-Wl,-objc_stubs_small"])):
    exe = os.path.join(d, name)
    # -fobjc-msgsend-selector-stubs is clang's default for arm64 macOS; say it so the stubs are certain.
    r = subprocess.run(["xcrun", "clang", "-O2", "-fobjc-arc", "-fobjc-msgsend-selector-stubs", "-framework", "Foundation",
                        os.path.join(d, "bench.m"), "-o", exe, *flag], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if r.returncode:
        print(f"RESULT stubcost {name}: build failed {r.stdout.decode(errors='replace').strip().splitlines()[-1:]}")
        continue
    built.append((name, exe)); ns[name] = []
# Interleaved runs, so drift (clock, heat, another job) falls on both modes alike.
for _ in range(7):
    for name, exe in built:
        ns[name].append(float(subprocess.run([exe], stdout=subprocess.PIPE, check=True).stdout.split()[0]))
for name, exe in built:
    v = ns[name]
    print(f"RESULT stubcost {name}: objc_stubs_bytes={stubs(exe)} ns_per_send_min={round(min(v), 4)} "
          f"median={round(statistics.median(v), 4)} max={round(max(v), 4)}")
PY
  rm -rf "$dir"
}

# A clean build into a reference directory; the index is not compared.
reference() {   # LABEL SIDE DIR
  at "$2"; plain "$1"; mv "$D" "$3"; rm -rf "$3/Index.noindex"
}

echo "==> leaf $leaf, module $module"
echo "==> clean references at the test DerivedData path, each twice"
at A; plain clean-A; relink_probe
if [[ "$only" == relink ]]; then
  stub_cost_probe
  result "only=relink: stopped after the relink and stub cost probes"
  exit 0
fi
mv "$D" "$RA"; rm -rf "$RA/Index.noindex"
python3 -I - "$work/pins.json" "$work/app-exe/Package.resolved" <<'PY'
import json, sys
want = {p["identity"]: p["state"] for p in json.load(open(sys.argv[1]))["pins"]}
got = {p["identity"]: p["state"] for p in json.load(open(sys.argv[2]))["pins"]}
moved = sorted(k for k in want if k in got and got[k] != want[k])   # a pin the graph does not use is dropped
print(f"RESULT pins kept={not moved} pins={len(want)} moved={[(k, want[k].get('version'), (got.get(k) or {}).get('version')) for k in moved[:8]] or 'none'}")
PY
if (( force_module )) && python3 -I - "$RA/Build/Products/Debug/cmux-next-exe" "$module" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read(); n = struct.unpack_from("<I", d, 16)[0]; o = 32; m = sys.argv[2]
for _ in range(n):
    c, s = struct.unpack_from("<II", d, o)
    if c in (0xC, 0x80000018):
        name = d[o + struct.unpack_from("<I", d, o + 8)[0]:o + s].split(b"\0")[0].decode()
        if f"/libswift{m}.dylib" in name or f"/{m}.framework/" in name:
            sys.exit(0)
    o += s
sys.exit(1)
PY
then
  force_module=0
  echo "==> note: the clean A executable links $module already (a dependency); nofix-remove expects stale objects only"
fi
reference clean-A2 A "$RA2"
reference clean-B B "$RB"
reference clean-B2 B "$RB2"
python3 -I - "$RA" "$RB" "$module" <<'PY'
import collections, glob, os, re, struct, sys
for dd in sys.argv[1:3]:
    c = collections.Counter()
    for p in glob.glob(os.path.join(glob.escape(dd), "Build", "Intermediates.noindex", "*", "Debug", "*", "Objects-normal", "arm64", "*.o")):
        c.update({m.decode() for m in re.findall(rb"__swift_FORCE_LOAD_\$_swift[A-Za-z0-9_]+", open(p, "rb").read())})
    print(f"RESULT force-load names in {os.path.basename(dd)} objects (objects): " + " ".join(f"{k}:{v}" for k, v in c.most_common(12)))
PY
echo "==> clean vs clean (is the clean build deterministic)"
compare clean-A2 "$RA2" "$RA" info clean-A
compare clean-B2 "$RB2" "$RB" info clean-B

echo "==> rollout: a warm slot at A without a record (every Swift module compiled in full once)"
at A; plain base-A
fixed rollout
match_any rollout "$RA" clean-A "$RA2" clean-A2

echo "==> cost: check and done without a change, and a no-op build"
t0=$(python3 -c 'import time; print(time.time())')
check >"$work/noop-check.txt"; cat "$work/noop-check.txt"
t1=$(python3 -c 'import time; print(time.time())')
plain noop
t2=$(python3 -c 'import time; print(time.time())')
done_ || { result "no-change FAIL (done exit $?)"; fails=$((fails + 1)); }
t3=$(python3 -c 'import time; print(time.time())')
result "no-change check_seconds=$(python3 -c "print(round($t1-$t0,2))") noop_build_seconds=$(python3 -c "print(round($t2-$t1,1))") done_seconds=$(python3 -c "print(round($t3-$t2,2))")"

echo "==> fix-add: A -> B with the check"
at B; fixed fix-add; match_any fix-add "$RB" clean-B "$RB2" clean-B2
echo "==> fix-remove: B -> A with the check"
at A; fixed fix-remove; match_any fix-remove "$RA" clean-A "$RA2" clean-A2
echo "==> nofix-add: A -> B without the check (the defect)"
at B; plain nofix-add; compare nofix-add "$D" "$RB" stale-objects clean-B
echo "==> repair: the stale B with the check (the record still says A)"
fixed repair; match_any repair "$RB" clean-B "$RB2" clean-B2
echo "==> nofix-remove: B -> A without the check (the defect)"
at A; plain nofix-remove
compare nofix-remove "$D" "$RA" "$( (( force_module )) && echo stale-dylib || echo stale-objects)" clean-A
result "fails=$fails"
exit $(( fails > 0 ))
