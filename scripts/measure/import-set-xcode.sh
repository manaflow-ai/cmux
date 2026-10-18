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
# LC_LINKER_OPTION hints, and the executable's ordered LC_LOAD_* list.
#
#   A  this commit; B  A with `import Contacts` added to one leaf file
#   rollout  clean A, then the check with no record (every Swift module cleared)
#   fix-add A->B, fix-remove B->A, repair (a stale B fixed): must equal clean
#   nofix-add A->B and nofix-remove B->A without the check: must show the defect
#
# Run alone on a worker, with the tool from the controller (owner uploads it):
#   cmux-ci run --class exclusive --script scripts/measure/import-set-xcode.sh --ref SHA \
#     --tool cmux-import-set@sha256:HEX --timeout 9000 --key import-set-xcode-<sha8>-<n>
# Args: leaf=<repo-relative Swift file> (default CmuxTheme's AppTheme.swift),
#       module=<the module it adds and removes> (default Contacts; no macOS
#       module of this graph may import it already).
# Output: RESULT lines; files under .build/import-set-xcode. Exit 0 when every
# expectation holds. Never changes anything outside this checkout.
set -euo pipefail
leaf="Packages/Shared/CmuxTheme/Sources/CmuxTheme/AppTheme.swift"
module="Contacts"
for arg in "$@"; do
  case "$arg" in
    leaf=*) leaf="${arg#leaf=}" ;;
    module=*) module="${arg#module=}" ;;
    *) echo "import-set-xcode.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$leaf" =~ ^Packages/[A-Za-z0-9_./+-]+\.swift$ && "$leaf" != *..* ]] || { echo "import-set-xcode.sh: leaf must be a Swift file under Packages/" >&2; exit 2; }
[[ "$module" =~ ^[A-Z][A-Za-z0-9_]{1,40}$ ]] || { echo "import-set-xcode.sh: module must be a module name" >&2; exit 2; }
tool="${CMUX_CI_TOOL_CMUX_IMPORT_SET:-}"
[[ -n "$tool" && -f "$tool" ]] || { echo "import-set-xcode.sh: pass --tool cmux-import-set@sha256:HEX" >&2; exit 2; }
root="$(git rev-parse --show-toplevel)"
cd "$root"
[[ -f "$leaf" && -f App/main.swift && -d Packages/macOS/CmuxNext ]] || { echo "import-set-xcode.sh: $leaf, App/main.swift or CmuxNext missing" >&2; exit 2; }
if git grep -q -E "^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*((public|internal|package|private|fileprivate)[[:space:]]+)?import[[:space:]]+$module([^A-Za-z0-9_]|$)" -- 'Packages/macOS/*.swift' 'Packages/Shared/*.swift' App; then
  echo "import-set-xcode.sh: a macOS module of this graph imports $module already; choose another module=" >&2
  exit 2
fi
work="$root/.build/import-set-xcode"
rm -rf "$work"
mkdir -p "$work/app-exe/Sources/cmux-next-exe" "$work/spm"
D="$work/dd" RA="$work/clean-A" RB="$work/clean-B"
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

# The app executable package (the Xcode target cmux-next: App/main.swift over
# CmuxNextApp, with that target's linked libraries and frameworks).
cp App/main.swift "$work/app-exe/Sources/cmux-next-exe/main.swift"
cat >"$work/app-exe/Package.swift" <<EOF
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "CmuxNextAppExecutable",
    platforms: [.macOS("14.0")],
    dependencies: [.package(path: "$root/Packages/macOS/CmuxNext")],
    targets: [
        .executableTarget(
            name: "cmux-next-exe",
            dependencies: [.product(name: "CmuxNextApp", package: "CmuxNext")],
            path: "Sources/cmux-next-exe",
            linkerSettings: [
                .linkedLibrary("c++"), .linkedFramework("Metal"), .linkedFramework("QuartzCore"),
                .linkedFramework("IOSurface"), .linkedFramework("UniformTypeIdentifiers"), .linkedFramework("Carbon"),
            ]
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
with open(sys.argv[3], "w") as f:
    json.dump(pkg, f, indent=2, sort_keys=True)
    f.write("\n")
PY

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
# On exit: the leaf file back, and the DerivedData trees and packages removed
# (about 20-30 GB); the logs stay.
trap 'cp "$leaf_a" "$leaf" 2>/dev/null || true; rm -rf "$D" "$RA" "$RB" "$work/spm"' EXIT

xcb() {   # LABEL: one build in $D, the slot build's Swift settings
  local t0=$SECONDS
  if ! (cd "$work/app-exe" && xcodebuild -scheme cmux-next-exe -configuration Debug \
      -destination 'platform=macOS,arch=arm64' -derivedDataPath "$D" -clonedSourcePackagesDirPath "$work/spm" \
      -skipPackagePluginValidation -skipMacroValidation \
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

# Compare $D (this build) with a clean build of the same tree at the same path.
compare() {   # LABEL CLEAN_DIR EXPECT(match|stale-objects|stale-dylib)
  python3 -I - "$D" "$2" "$work/$1.start" "$1" "$3" "$module" <<'PY' || fails=$((fails + 1))
import glob, hashlib, os, re, struct, sys
shipped, clean, start, label, expect, module = sys.argv[1:7]
since = os.stat(start).st_mtime
FL = re.compile(rb"__swift_FORCE_LOAD_\$_[A-Za-z0-9_$]+")
DYLIB = {0xC: "LOAD_DYLIB", 0x18 | 0x80000000: "LOAD_WEAK_DYLIB", 0x1F | 0x80000000: "REEXPORT_DYLIB",
         0x20: "LAZY_LOAD_DYLIB", 0x23 | 0x80000000: "LOAD_UPWARD_DYLIB"}

def macho(path):
    data = open(path, "rb").read()
    if len(data) < 32 or struct.unpack_from("<I", data, 0)[0] != 0xFEEDFACF:
        return None
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off, fl, opts, dylibs = 32, set(), [], []
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd == 0x2:   # LC_SYMTAB: the force-load names in the string table
            _symoff, _nsyms, stroff, strsize = struct.unpack_from("<IIII", data, off + 8)
            fl.update(m.decode() for m in FL.findall(data, stroff, stroff + strsize))
        elif cmd == 0x2D:   # LC_LINKER_OPTION
            count = struct.unpack_from("<I", data, off + 8)[0]
            opts.append(" ".join(s.decode() for s in data[off + 12:off + size].split(b"\0")[:count]))
        elif cmd in DYLIB:
            name_off = struct.unpack_from("<I", data, off + 8)[0]
            dylibs.append(f"{DYLIB[cmd]} {data[off + name_off:off + size].split(b'\0')[0].decode()}")
        off += size
    return {"fl": sorted(fl), "opts": sorted(set(opts)), "dylibs": dylibs,
            "sha": hashlib.sha256(data).hexdigest()}

def objects(dd):
    base = os.path.join(dd, "Build", "Intermediates.noindex")
    out = {}
    for p in glob.glob(os.path.join(glob.escape(base), "*", "Debug", "*", "Objects-normal", "arm64", "*.o")):
        out[os.path.relpath(p, base)] = p
    return out

sh, cl = objects(shipped), objects(clean)
only_sh, only_cl = sorted(set(sh) - set(cl)), sorted(set(cl) - set(sh))
byte_diff, sem_diff, by_mod = 0, [], {}
for rel in sorted(set(sh) & set(cl)):
    a, b = macho(sh[rel]), macho(cl[rel])
    mod = rel.split("/")[2].removesuffix(".build")
    kept = os.stat(sh[rel]).st_mtime < since
    st = by_mod.setdefault(mod, [0, 0, 0, 0])   # objects, kept, byte-differ, semantic-differ
    st[0] += 1
    st[1] += kept
    if a is None or b is None or a["sha"] != b["sha"]:
        byte_diff += 1
        st[2] += 1
        if a is None or b is None or a["fl"] != b["fl"] or a["opts"] != b["opts"]:
            st[3] += 1
            sem_diff.append((rel, kept, a, b))
exe_sh = macho(os.path.join(shipped, "Build", "Products", "Debug", "cmux-next-exe"))
exe_cl = macho(os.path.join(clean, "Build", "Products", "Debug", "cmux-next-exe"))
only_dl_sh = [d for d in exe_sh["dylibs"] if d not in exe_cl["dylibs"]]
only_dl_cl = [d for d in exe_cl["dylibs"] if d not in exe_sh["dylibs"]]
same_order = exe_sh["dylibs"] == exe_cl["dylibs"]
n = len(set(sh) & set(cl))
print(f"RESULT {label} objects={n} only_shipped={len(only_sh)} only_clean={len(only_cl)} byte_equal={n - byte_diff} "
      f"semantic_differ={len(sem_diff)} kept_semantic_differ={sum(1 for x in sem_diff if x[1])} "
      f"exe_byte_equal={exe_sh['sha'] == exe_cl['sha']} load_commands={len(exe_sh['dylibs'])} load_order_equal={same_order}")
print(f"RESULT {label} load commands only in this build: {only_dl_sh or 'none'}; only in the clean build: {only_dl_cl or 'none'}")
mods = [f"{m}:{s[3]}/{s[0]}(kept {s[1]})" for m, s in sorted(by_mod.items()) if s[3]]
print(f"RESULT {label} modules with objects whose force-load or autolink set differs (differ/objects): {' '.join(mods) or 'none'}")
bmods = [f"{m}:{s[2]}" for m, s in sorted(by_mod.items()) if s[2] and not s[3]]
print(f"RESULT {label} modules with byte-only differences (same force-load and autolink sets): {' '.join(bmods) or 'none'}")
for rel, kept, a, b in sem_diff[:3]:
    extra = sorted(set(a["fl"]) - set(b["fl"])) if a and b else "?"
    missing = sorted(set(b["fl"]) - set(a["fl"])) if a and b else "?"
    print(f"RESULT {label} example {rel} kept={kept} force-load only here={extra} only clean={missing}")
if expect == "match":
    ok = not only_sh and not only_cl and not sem_diff and same_order
elif expect == "stale-objects":
    ok = any(kept for _r, kept, _a, _b in sem_diff)
else:
    ok = any(module in d for d in only_dl_sh) or (any(kept for _r, kept, _a, _b in sem_diff) and not same_order)
print(f"RESULT {label} {'PASS' if ok else 'FAIL'} (expected {expect})")
sys.exit(0 if ok else 1)
PY
}

echo "==> leaf $leaf, module $module"
echo "==> clean references at the test DerivedData path"
at A; plain clean-A; mv "$D" "$RA"
at B; plain clean-B; mv "$D" "$RB"
grep -q "$module" <(python3 -I - "$RB/Build/Products/Debug/cmux-next-exe" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read(); n = struct.unpack_from("<I", d, 16)[0]; o = 32
for _ in range(n):
    c, s = struct.unpack_from("<II", d, o)
    if c in (0xC, 0x80000018): print(d[o + struct.unpack_from("<I", d, o + 8)[0]:o + s].split(b"\0")[0].decode())
    o += s
PY
) || echo "==> note: the clean B executable has no load command naming $module (the force-load legs still apply)"

echo "==> rollout: a warm slot at A without a record (every Swift module compiled in full once)"
at A; plain base-A
fixed rollout
compare rollout "$RA" match

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
at B; fixed fix-add; compare fix-add "$RB" match
echo "==> fix-remove: B -> A with the check"
at A; fixed fix-remove; compare fix-remove "$RA" match
echo "==> nofix-add: A -> B without the check (the defect)"
at B; plain nofix-add; compare nofix-add "$RB" stale-objects
echo "==> repair: the stale B with the check (the record still says A)"
fixed repair; compare repair "$RB" match
echo "==> nofix-remove: B -> A without the check (the defect)"
at A; plain nofix-remove; compare nofix-remove "$RA" stale-dylib
result "fails=$fails"
exit $(( fails > 0 ))
