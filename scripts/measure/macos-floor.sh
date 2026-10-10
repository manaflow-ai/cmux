#!/usr/bin/env bash
# Measure how much CmuxNext code needs a newer macOS than FLOOR.
# Usage: scripts/measure/macos-floor.sh <floor major, e.g. 13> [check floor...]
#   The check floors (default: the floor) re-typecheck the same pass-1 modules
#   at each listed major, e.g. `13 14 15`. Output dir: $MACOS_FLOOR_OUT or
#   artifacts/macos-floor.
# Fleet: cmux-ci run --class isolated --script scripts/measure/macos-floor.sh --ref SHA
#        --arg=13 --arg=14 --arg=15 --artifact artifacts/macos-floor.tar.gz
# Measurement only: never land the Package.swift edits it makes.
#
# It edits Package.swift files in the tree it runs in (run it in a throwaway
# tree: nx-remote warm tree or --ref), then:
#   pass 1: builds CmuxNext at the floor with availability checking disabled,
#           so every module exists (availability attributes are still recorded);
#   pass 2: re-typechecks every first-party module from the pass-1 commands
#           with availability checking on, so each module's errors are counted
#           even when a dependency would have failed.
# Output: <out>/pass1.log, <out>/pass2-<module>.log, <out>/errors.txt.
set -uo pipefail
FLOOR="${1:?floor major}"
shift
OUT="${MACOS_FLOOR_OUT:-$(git rev-parse --show-toplevel)/artifacts/macos-floor}"
CHECK_FLOORS="${*:-$FLOOR}"
mkdir -p "$OUT"
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# Every local package: macOS platform -> FLOOR (iOS stays).
find Packages -name Package.swift -not -path '*/.build/*' -print0 |
  xargs -0 perl -pi -e "s/\.macOS\(\.v(1[0-9]|2[0-9])\)/.macOS(.v$FLOOR)/g"
git diff --stat -- Packages | tail -1

PKG=Packages/macOS/CmuxNext
swift package --package-path "$PKG" resolve >"$OUT/resolve.log" 2>&1 || { tail -20 "$OUT/resolve.log"; exit 2; }
# Remote packages with a newer floor (iroh-ffi says 14): lower them in the checkout for measurement only.
for f in "$PKG"/.build/checkouts/*/Package.swift; do
  grep -n -E '\.macOS\("?\.?(v)?1[4-9]|\.macOS\("1[4-9]' "$f" && perl -pi -e "s/\.macOS\(\"1[4-9]\.0\"\)/.macOS(\"$FLOOR.0\")/; s/\.macOS\(\.v1[4-9]\)/.macOS(.v$FLOOR)/" "$f"
done

# Measurement-only: below 14 the two-parameter onChange is unavailable and this
# one SwiftUI expression exceeds the solver limit; give the closure explicit types.
perl -pi -e 's/\.onChange\(of: model\.selection\) \{ _, id in/.onChange(of: model.selection) { (_: String?, id: String?) in/' \
  "$PKG/Sources/CmuxNextHistory/HistoryPageView.swift"
echo "pass 1: build with availability checking off"
swift build --package-path "$PKG" -v -debug-info-format none \
  -Xswiftc -Xfrontend -Xswiftc -disable-availability-checking \
  -Xswiftc -Xfrontend -Xswiftc -solver-expression-time-threshold=600 \
  -Xswiftc -Xfrontend -Xswiftc -solver-scope-threshold=100000000 \
  >"$OUT/pass1.log" 2>&1 &
BPID=$!
while kill -0 "$BPID" 2>/dev/null; do sleep 60; echo "pass1 running: $(wc -l <"$OUT/pass1.log") log lines"; done
wait "$BPID"; echo "pass1 exit $?"
grep -E "error:" "$OUT/pass1.log" | sort | uniq | head -40 >"$OUT/pass1-errors.txt"
wc -l <"$OUT/pass1-errors.txt"

echo "pass 2: typecheck each module with checking on"
for CF in $CHECK_FLOORS; do
mkdir -p "$OUT/check$CF"
python3 - "$OUT" "$CF" <<'PY'
import os, re, shlex, subprocess, sys, concurrent.futures as cf
out, floor = sys.argv[1], sys.argv[2]
logdir = os.path.join(out, "check" + floor)
log = open(os.path.join(out, "pass1.log"), errors="replace").read().splitlines()
cmds = {}
for line in log:
    if "-module-name" not in line or "swiftc" not in line.split(" ")[0] and "swift-frontend" not in line.split(" ")[0] and "swiftc" not in line[:300]:
        continue
    try:
        argv = shlex.split(line)
    except ValueError:
        continue
    idx = next((i for i, a in enumerate(argv) if a.endswith("/swiftc") or a == "swiftc"), None)
    if idx is None:
        continue
    argv = argv[idx:]
    mod = argv[argv.index("-module-name") + 1]
    if "-frontend" in argv:
        continue
    cmds[mod] = argv
drop1 = {"-c", "-emit-module", "-emit-dependencies", "-incremental", "-emit-objc-header",
         "-parseable-output", "-serialize-diagnostics", "-emit-module-interface",
         "-enable-batch-mode", "-whole-module-optimization", "-emit-executable", "-emit-library",
         "-static", "-explicit-module-build", "-emit-localized-strings", "-save-temps", "-validate-clang-modules-once", "-enable-library-evolution", "-emit-symbol-graph"}
drop2 = {"-emit-module-path", "-output-file-map", "-emit-objc-header-path", "-emit-module-interface-path",
         "-emit-private-module-interface-path", "-o", "-emit-module-source-info-path",
         "-emit-api-descriptor-path", "-emit-symbol-graph-dir", "-index-store-path",
         "-emit-package-module-interface-path", "-emit-abi-descriptor-path", "-supplementary-output-file-map", "-dependency-scan-serialize-diagnostics-path", "-emit-localized-strings-path"}
def clean(argv):
    res, i = [], 0
    while i < len(argv):
        a = argv[i]
        if a in drop1: i += 1; continue
        if a in drop2: i += 2; continue
        if a == "-Xfrontend" and i + 1 < len(argv) and argv[i+1] == "-disable-availability-checking": i += 2; continue
        if a == "-disable-availability-checking": i += 1; continue
        res.append(a); i += 1
    res = [re.sub(r"-apple-macos(x?)[0-9.]+", lambda m: f"-apple-macos{m.group(1)}{floor}.0", a) if "-apple-macos" in a else a for a in res]
    return res + ["-typecheck", "-continue-building-after-errors", "-Xfrontend", "-solver-expression-time-threshold=600", "-Xfrontend", "-solver-scope-threshold=100000000"]
first_party = {m: a for m, a in cmds.items() if m.lower().startswith("cmux")}
print(f"modules: {len(cmds)} total, {len(first_party)} first-party")
def run(item):
    mod, argv = item
    p = subprocess.run(clean(argv), capture_output=True, text=True, errors="replace")
    txt = p.stdout + p.stderr
    open(os.path.join(logdir, f"{mod}.log"), "w").write(txt)
    return mod, p.returncode, txt
errs = []
with cf.ThreadPoolExecutor(max_workers=6) as ex:
    for mod, rc, txt in ex.map(run, sorted(first_party.items())):
        e = [l for l in re.sub(r"\x1b\[[0-9;]*m", "", txt).splitlines() if re.match(r"^/.*: error:", l)]
        uniq = sorted(set(e))
        print(f"{mod}: rc={rc} errors={len(uniq)}")
        errs += [f"{mod}\t{l}" for l in uniq]
open(os.path.join(logdir, "errors.txt"), "w").write("\n".join(errs) + "\n")
print("floor", floor, "total unique errors", len(errs))
PY
done

# Rows: floor 13 errors with the macOS version each needs, so higher floors are a filter.
tar -czf "$ROOT/artifacts/macos-floor.tar.gz" -C "$OUT" --exclude pass1.log . && cp "$OUT/pass1.log" "$OUT/../macos-floor-pass1.log" 2>/dev/null
for CF in $CHECK_FLOORS; do
  sed -E 's/\x1b\[[0-9;]*m//g' "$OUT/check$CF/errors.txt" | sed -E "s/^([^\t]*)\t.*: error: (.*)/\1\t\2/" | sed -E "s/'[^']*'/X/g" | sort | uniq -c | sort -rn | head -40
done
exit 0
