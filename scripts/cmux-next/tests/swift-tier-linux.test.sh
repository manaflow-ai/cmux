#!/usr/bin/env bash
# Checks that scripts/cmux-next/linux/swift-tier.sh never writes to the
# checkout and that its runner reports every red.
#
# Builds a throwaway git repo whose CmuxNext manifest has a Linux mode with a
# different dependency graph (CMUX_SWIFTPM_TARGET_LINUX=1 swaps the macOS-only
# swift-numerics for swift-system), then checks:
#   1. --update-resolved changes only Package.linux.resolved;
#   2. two builds through swift-tier.sh leave `git status --porcelain` empty,
#      and the scratch sources are hard links into the checkout; the target's
#      string catalog builds because swift-tier.sh compiled the tables of the
#      Linux mode's LinuxStringTables resource into the
#      scratch copy, and the second run rewrites none of them;
#   3. extra pins and no originHash (the shape of the committed CmuxNext seed:
#      the macOS pins minus sentry-cocoa and Sparkle) still build;
#   4. a Package.linux.resolved without a needed pin fails the build and still
#      writes nothing (--only-use-versions-from-resolved-file);
#   5. a build that fails to compile keeps the workspace state: the next run
#      reuses the dependency checkouts instead of cloning them again;
#   6. a shared pin bumped in Package.resolved fails the run until
#      --update-resolved, which takes the macOS revision;
#   7. a scratch root inside the checkout (relative, or through a symlink) is
#      refused with exit 2 and writes nothing;
#   8. control: the same Linux resolve run in the checkout itself rewrites
#      Package.resolved, which is what the scratch copy prevents;
#   9. the runner: a target that does not compile fails the run, lands in the
#      errors queue under its own target, blocks its test target, and the
#      green test target still runs;
#  10. a `[ linux ]` Failure line on that target still fails the run while
#      its blocked test target has no line of its own; with one it exits 0;
#  11. --only and --measure-incremental build a subset and time a one-file
#      edit without touching the checkout;
#  12. --only with a test target alone keeps its unselected source dependency
#      in the pruned tier, so its tests run;
#  13. an --only name or a --measure-incremental target that matches nothing
#      fails the run;
#  14. a linux-tier.json the plan cannot read fails the run;
#  15. a Skip line on a test target of a green build-all: not run, listed as
#      skipped, not counted in the 5 % budget;
#  16. --shared: a Skip line skips the package without building it; an --only
#      name that matches no package fails the run.
# Needs swift (SWIFT=..., or scripts/cmux-next/linux/setup-swift.sh), python3
# and network access to github.com/apple.
#
# Usage: swift-tier-linux.test.sh [--keep]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
[[ "$(uname -s)" == Linux ]] || { echo "skip: Linux only"; exit 0; }
swift_bin="${SWIFT:-swift}"
command -v "$swift_bin" >/dev/null 2>&1 || { echo "error: $swift_bin not found" >&2; exit 1; }
keep=0
[[ "${1:-}" == --keep ]] && keep=1

work="$(mktemp -d /tmp/cmux-swift-tier-test.XXXXXX)"
cleanup() { if ((keep)); then echo "kept $work"; else rm -rf "$work"; fi; }
trap cleanup EXIT

repo="$work/repo"
pkg="$repo/Packages/macOS/CmuxNext"
mkdir -p "$pkg/Sources/Tier" "$repo/scripts/cmux-next/linux"
cp "$root/scripts/cmux-next/linux/swift-tier.sh" "$root/scripts/cmux-next/linux/compile-xcstrings.py" \
  "$repo/scripts/cmux-next/linux/"

cat >"$pkg/Package.swift" <<'EOF'
// swift-tools-version:6.0
import Foundation
import PackageDescription

let linux = ProcessInfo.processInfo.environment["CMUX_SWIFTPM_TARGET_LINUX"] == "1"
var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-collections.git", .upToNextMinor(from: "1.1.0")),
]
var tierDependencies: [Target.Dependency] = [.product(name: "DequeModule", package: "swift-collections")]
// The Linux mode takes the catalog as compiled tables, as the CmuxNext manifest does.
let tierResources: [Resource] = [.process("Tier.xcstrings")] + (linux ? [.process("LinuxStringTables")] : [])
if linux {
    dependencies.append(.package(url: "https://github.com/apple/swift-system.git", exact: "1.4.0"))
    tierDependencies.append(.product(name: "SystemPackage", package: "swift-system"))
} else {
    dependencies.append(.package(url: "https://github.com/apple/swift-numerics.git", exact: "1.0.3"))
    tierDependencies.append(.product(name: "RealModule", package: "swift-numerics"))
}
let package = Package(
    name: "CmuxNext",
    defaultLocalization: "en",
    dependencies: dependencies,
    targets: [.target(name: "Tier", dependencies: tierDependencies, resources: tierResources)]
)
EOF
cat >"$pkg/Sources/Tier/Tier.xcstrings" <<'EOF'
{"sourceLanguage": "en", "version": "1.0", "strings": {"tier.title": {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "Tier"}}}}}}
EOF
cat >"$pkg/Sources/Tier/Tier.swift" <<'EOF'
import DequeModule
public let tierQueue = Deque<Int>()
EOF

fail() { echo "FAIL: $*" >&2; exit 1; }
porcelain() { git -C "$repo" status --porcelain --untracked-files=all; }
commit() { git -C "$repo" -c user.name=t -c user.email=t@t commit -qam "$1"; }
inode() { stat -c %i "$1"; }
scratch="$work/scratch"
copy="$scratch/src/Packages/macOS/CmuxNext"
tier() { SWIFT="$swift_bin" "$repo/scripts/cmux-next/linux/swift-tier.sh" --scratch "$scratch" "$@"; }

# The macOS pins: what a macOS resolve of the fixture writes.
(cd "$pkg" && "$swift_bin" package resolve >/dev/null)
printf '.build/\n.swiftpm/\n' >"$repo/.gitignore"
git -C "$repo" init -q
git -C "$repo" add -A
commit fixture

tier --update-resolved >/dev/null
grep -q '"swift-system"' "$pkg/Package.linux.resolved" || fail "--update-resolved missed the Linux-only pin"
[[ "$(porcelain)" == "?? Packages/macOS/CmuxNext/Package.linux.resolved" ]] \
  || fail "--update-resolved changed more than Package.linux.resolved: $(porcelain)"
git -C "$repo" add -A
commit linux-pins
echo "ok 1 --update-resolved writes only Package.linux.resolved"

for run in 1 2; do
  tier build >/dev/null || fail "build run $run failed"
  [[ -z "$(porcelain)" ]] || fail "build run $run changed the checkout: $(porcelain)"
done
[[ "$(inode "$pkg/Sources/Tier/Tier.swift")" == "$(inode "$copy/Sources/Tier/Tier.swift")" ]] \
  || fail "the scratch sources are not hard links into the checkout"
[[ "$(inode "$pkg/Package.linux.resolved")" != "$(inode "$copy/Package.resolved")" ]] \
  || fail "the scratch Package.resolved is a hard link"
[[ -L "$copy/Sources/Tier/LinuxStringTables" && -f "$copy/Sources/Tier/LinuxStringTables/en.lproj/Tier.strings" ]] \
  || fail "swift-tier.sh did not compile the string tables into the scratch copy"
grep -q '^0 files updated' "$scratch/build/cmux-linux-string-tables.log" \
  || fail "the second run rewrote string tables: $(cat "$scratch/build/cmux-linux-string-tables.log")"
echo "ok 2 two builds leave the checkout unchanged; sources are hard links; string tables compiled once"

cp "$pkg/Package.linux.resolved" "$work/linux.resolved"
python3 -I - "$pkg/Package.linux.resolved" "$pkg/Package.resolved" <<'PY'
import json, sys
linux_path, mac_path = sys.argv[1], sys.argv[2]
with open(linux_path) as f:
    linux = json.load(f)
with open(mac_path) as f:
    mac = json.load(f)
linux.pop("originHash", None)
known = {pin["identity"] for pin in linux["pins"]}
linux["pins"] += [pin for pin in mac["pins"] if pin["identity"] not in known]
linux["pins"].sort(key=lambda pin: pin["identity"])
with open(linux_path, "w") as f:
    json.dump(linux, f, indent=2)
    f.write("\n")
PY
grep -q '"swift-numerics"' "$pkg/Package.linux.resolved" || fail "the seed fixture has no extra pin"
commit seed-shape
tier build >/dev/null || fail "extra pins without originHash did not build"
[[ -z "$(porcelain)" ]] || fail "the seed-shape build changed the checkout: $(porcelain)"
cp "$work/linux.resolved" "$pkg/Package.linux.resolved"
commit linux-pins-again
echo "ok 3 extra pins and no originHash still build"

cp "$pkg/Package.resolved" "$pkg/Package.linux.resolved"
commit stale-linux-pins
if tier build >/dev/null 2>"$work/stale.err"; then fail "a stale Package.linux.resolved resolved silently"; fi
grep -q 'out-of-date resolved file' "$work/stale.err" || fail "unexpected error: $(cat "$work/stale.err")"
[[ -z "$(porcelain)" ]] || fail "a failed build changed the checkout: $(porcelain)"
echo "ok 4 a missing pin fails and writes nothing"

cp "$work/linux.resolved" "$pkg/Package.linux.resolved"
cp "$pkg/Sources/Tier/Tier.swift" "$work/Tier.swift"
echo 'public let tierBroken: Int = "not an int"' >>"$pkg/Sources/Tier/Tier.swift"
commit compile-error
checkout_dir="$scratch/build/checkouts/swift-collections"
if tier build >/dev/null 2>&1; then fail "the compile error built"; fi
[[ -d "$checkout_dir" ]] || fail "no dependency checkout after the first failed build"
checkout_inode="$(inode "$checkout_dir")"
if tier build >/dev/null 2>&1; then fail "the compile error built"; fi
[[ -f "$scratch/build/workspace-state.json" ]] || fail "a failed build dropped the workspace state"
[[ "$(inode "$checkout_dir")" == "$checkout_inode" ]] \
  || fail "the second failed build cloned swift-collections again"
[[ -z "$(porcelain)" ]] || fail "a failed compile changed the checkout: $(porcelain)"
cp "$work/Tier.swift" "$pkg/Sources/Tier/Tier.swift"
commit compile-fixed
echo "ok 5 a failed compile keeps the workspace state"

collections_url="https://github.com/apple/swift-collections.git"
old_revision="$(git ls-remote "$collections_url" refs/tags/1.1.0 'refs/tags/1.1.0^{}' | sort -k2 | tail -n1 | cut -f1)"
[[ -n "$old_revision" ]] || fail "no swift-collections 1.1.0 tag"
python3 -I - "$pkg/Package.resolved" "$old_revision" <<'PY'
import json, sys
path, revision = sys.argv[1], sys.argv[2]
with open(path) as f:
    resolved = json.load(f)
pin = next(pin for pin in resolved["pins"] if pin["identity"] == "swift-collections")
if pin["state"]["revision"] == revision:
    sys.exit("the fixture already pins swift-collections 1.1.0")
pin["state"] = {"revision": revision, "version": "1.1.0"}
with open(path, "w") as f:
    json.dump(resolved, f, indent=2)
    f.write("\n")
PY
commit bump-shared-pin
if tier build >/dev/null 2>"$work/drift.err"; then fail "a drifted shared pin built"; fi
grep -q 'shared pin swift-collections differs from Package.resolved' "$work/drift.err" \
  || fail "unexpected drift error: $(cat "$work/drift.err")"
[[ -z "$(porcelain)" ]] || fail "the drift check changed the checkout: $(porcelain)"
tier --update-resolved >/dev/null
grep -q "\"revision\" : \"$old_revision\"" "$pkg/Package.linux.resolved" \
  || fail "--update-resolved kept the old Linux revision of swift-collections"
[[ "$(porcelain)" == " M Packages/macOS/CmuxNext/Package.linux.resolved" ]] \
  || fail "--update-resolved changed more than Package.linux.resolved: $(porcelain)"
commit linux-pins-follow
tier build >/dev/null || fail "the build after --update-resolved failed"
echo "ok 6 a drifted shared pin fails until --update-resolved takes the macOS revision"

expect_refused() {
  local status=0
  (cd "$repo" && SWIFT="$swift_bin" scripts/cmux-next/linux/swift-tier.sh --scratch "$1" build) \
    >/dev/null 2>&1 || status=$?
  [[ "$status" == 2 ]] || fail "--scratch $1 exited $status, not 2"
  [[ -z "$(porcelain)" ]] || fail "--scratch $1 changed the checkout: $(porcelain)"
}
expect_refused ./inside
expect_refused Packages/inside
ln -s "$repo/Packages" "$work/packages-link"
expect_refused "$work/packages-link/inside"
expect_refused "$scratch/../repo/inside"
echo "ok 7 a scratch root inside the checkout is refused"

(cd "$pkg" && CMUX_SWIFTPM_TARGET_LINUX=1 "$swift_bin" package resolve >/dev/null)
[[ "$(porcelain)" == *"Packages/macOS/CmuxNext/Package.resolved"* ]] \
  || fail "control: an in-checkout Linux resolve did not touch Package.resolved"
echo "ok 8 control: an in-checkout Linux resolve rewrites Package.resolved"

# ---- the runner: receipt, errors queue, [ linux ] lines ----
git -C "$repo" checkout -q -- Packages # the committed pins (check 6 made them agree)
mkdir -p "$repo/scripts/cmux-next/oracle" "$repo/tests/oracle/Expectations.d" \
  "$pkg/Sources/Bad" "$pkg/Tests/TierTests" "$pkg/Tests/BadTests"
cp "$root/scripts/cmux-next/linux/errors_queue.py" "$repo/scripts/cmux-next/linux/"
cp "$root/scripts/cmux-next/oracle/expectations.py" "$repo/scripts/cmux-next/oracle/"
# Like the CmuxNext manifest's Linux mode, the fixture keeps
# only the targets linux-tier.json names, so the runner can prune red ones.
python3 -I - "$pkg/Package.swift" <<'PY'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
old = '    targets: [.target(name: "Tier", dependencies: tierDependencies, resources: tierResources)]'
assert old in text, "the fixture manifest changed: update the runner fixture"
text = text.replace(old, '    targets: tierTargets')
text = text.replace(
    "let package = Package(",
    '''var tierTargets: [Target] = [
    .target(name: "Tier", dependencies: tierDependencies, resources: tierResources),
    .target(name: "Bad"),
    .testTarget(name: "TierTests", dependencies: ["Tier"]),
    .testTarget(name: "BadTests", dependencies: ["Bad"]),
]
let tierFile = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("linux-tier.json")
if linux, let data = try? Data(contentsOf: tierFile),
   let tier = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    let waves = (tier["waves"] as? [[String]] ?? []).flatMap { $0 }
    let keep = Set(waves + (tier["testTargets"] as? [String] ?? []))
    tierTargets = tierTargets.filter { keep.contains($0.name) }
}
let package = Package(''',
)
with open(path, "w") as f:
    f.write(text)
PY
cat >"$pkg/linux-tier.json" <<'EOF'
{
  "waves": [["Tier", "Bad"]],
  "testTargets": ["TierTests", "BadTests"]
}
EOF
cat >"$pkg/Sources/Bad/Bad.swift" <<'EOF'
public let bad: Int = "not an int"
EOF
cat >"$pkg/Tests/TierTests/TierTests.swift" <<'EOF'
import Testing
@testable import Tier
@Test func queueStartsEmpty() { #expect(tierQueue.isEmpty) }
@Test func queueCountIsZero() { #expect(tierQueue.count == 0) }
EOF
cat >"$pkg/Tests/BadTests/BadTests.swift" <<'EOF'
import Testing
@testable import Bad
@Test func badIsSet() { #expect(bad == 1) }
EOF
git -C "$repo" add -A
commit runner-fixture
runner() {
  CMUX_LINUX_OUT="$work/out" tier --all --receipt "$work/receipt.json" --errors-queue "$work/queue.jsonl" \
    --jobs 8 --workers 4 "$@"
}
# receipt_check CODE: run the Python CODE with `receipt` and `queue` loaded;
# CODE calls want(condition, what).
receipt_check() {
  python3 -I - "$work/receipt.json" "$work/queue.jsonl" "$1" <<'PY' || fail "receipt: $(cat "$work/runner.out")"
import json, sys
with open(sys.argv[1]) as f:
    receipt = json.load(f)
with open(sys.argv[2]) as f:
    queue = [json.loads(line) for line in f]
def want(cond, what):
    if not cond:
        sys.exit(f"{what}: {json.dumps(receipt, indent=1)[:3000]}\n{queue}")
exec(sys.argv[3])
PY
}
# expect_lines LINE...: the fixture's swift-tier.txt holds exactly these lines.
expect_lines() {
  printf '%s\n' "$@" >"$repo/tests/oracle/Expectations.d/swift-tier.txt"
  git -C "$repo" add -A
  commit "expectations: $*"
}

if runner >"$work/runner.out" 2>&1; then fail "a compile error without a [ linux ] line exited 0: $(cat "$work/runner.out")"; fi
receipt_check '
want(receipt["ok"] is False, "ok")
want([u["case"] for u in receipt["unexpected"]] == ["Bad"], "only the compile error is unexpected")
want(receipt["targets"]["built"] == ["Tier"], "built")
want(receipt["targets"]["failed"] == ["Bad"], "failed")
want(receipt["test_targets"]["blocked"] == ["BadTests"], "blocked")
want(receipt["test_targets"]["run"] == ["TierTests"], "run")
want(receipt["tests"]["executed"] == 2 and receipt["tests"]["passed"] == 2, "tests")
want(receipt["checkout_resolved_unchanged"] is True, "resolved")
want(receipt["sha"] and receipt["toolchain"].startswith("Swift version"), "header")
compile_entries = [q for q in queue if q["kind"] == "compile"]
want(len(compile_entries) == 1 and compile_entries[0]["target"] == "Bad", "queue")
want(compile_entries[0]["files"][0]["path"] == "Packages/macOS/CmuxNext/Sources/Bad/Bad.swift", "queue path")
'
[[ -z "$(porcelain)" ]] || fail "the runner changed the checkout: $(porcelain)"
echo "ok 9 a compile error fails the run and lands in the queue under its target"

expect_lines 'p15-oracle-004 [ linux ] swift-tier/Bad [ Failure ]  # fixture: Bad does not compile'
if runner >"$work/runner.out" 2>&1; then fail "a line on Bad hid its blocked BadTests: $(cat "$work/runner.out")"; fi
grep -q 'UNEXPECTED Failure: swift-tier/BadTests (test blocked by Bad)' "$work/runner.out" \
  || fail "no blocked red for BadTests: $(cat "$work/runner.out")"
expect_lines 'p15-oracle-004 [ linux ] swift-tier/Bad [ Failure ]  # fixture: Bad does not compile' \
  'p15-oracle-004 [ linux ] swift-tier/BadTests [ Failure ]  # fixture: blocked by Bad'
runner >"$work/runner.out" 2>&1 || fail "expected failures still failed the run: $(cat "$work/runner.out")"
grep -qx 'OK' "$work/runner.out" || fail "no OK line: $(cat "$work/runner.out")"
echo "ok 10 a line on a target fails the run until its blocked dependent has its own line"

runner --only Tier,TierTests --measure-incremental Tier >"$work/runner.out" 2>&1 \
  || fail "--only run failed: $(cat "$work/runner.out")"
receipt_check '
inc = receipt["incremental"]
want(inc and inc["target"] == "Tier" and inc["status"] == "pass", "incremental")
want(receipt["targets"]["built"] == ["Tier"], "built")
'
[[ -z "$(porcelain)" ]] || fail "--measure-incremental changed the checkout: $(porcelain)"
echo "ok 11 --only and --measure-incremental time a one-file edit on a private copy"

runner --only TierTests >"$work/runner.out" 2>&1 || fail "--only TierTests failed: $(cat "$work/runner.out")"
receipt_check '
want(receipt["test_targets"]["run"] == ["TierTests"] and receipt["tests"]["passed"] == 2, "TierTests ran")
want(receipt["setup"]["passed"] == ["resolve", "string-tables", "test-product"], "the test product linked")
'
echo "ok 12 --only with a test target keeps its source dependency in the tier"

if runner --only Tier,Typo >"$work/runner.out" 2>&1; then fail "--only Typo exited 0: $(cat "$work/runner.out")"; fi
receipt_check 'want(receipt["targets"]["missing"] == ["Typo"] and receipt["targets"]["built"] == ["Tier"], "missing Typo")'
if runner --only Tier --measure-incremental Nope >"$work/runner.out" 2>&1; then
  fail "--measure-incremental Nope exited 0: $(cat "$work/runner.out")"
fi
receipt_check 'want([(u["case"], u["what"]) for u in receipt["unexpected"]] == [("Nope", "incremental build")], "Nope")'
echo "ok 13 an --only or --measure-incremental name that matches nothing fails the run"

printf '{ broken\n' >"$pkg/linux-tier.json"
commit broken-tier
if runner >"$work/runner.out" 2>&1; then fail "an unreadable linux-tier.json exited 0: $(cat "$work/runner.out")"; fi
receipt_check 'want(receipt["setup"]["failed"] == ["plan"], "plan setup red")'
echo "ok 14 a linux-tier.json the plan cannot read fails the run"

cat >"$pkg/linux-tier.json" <<'EOF'
{
  "waves": [["Tier"]],
  "testTargets": ["TierTests"]
}
EOF
commit green-tier
expect_lines 'p15-oracle-004 [ linux ] swift-tier/TierTests [ Skip ]  # fixture: a green build-all with a Skip line'
runner >"$work/runner.out" 2>&1 || fail "a Skip line failed a green run: $(cat "$work/runner.out")"
receipt_check '
want("build-all" in receipt["wall_seconds"] and "build-targets" not in receipt["wall_seconds"], "the green build-all path ran")
want(receipt["test_targets"]["skipped"] == ["TierTests"] and receipt["test_targets"]["run"] == [], "TierTests skipped")
want(receipt["cases"]["TierTests"]["build"] == "skip" and not receipt["linux_share_over_budget"], "no budget red")
'
echo "ok 15 a Skip line on a green build-all keeps the test target out of the run"

mini="$repo/Packages/Shared/Mini"
mkdir -p "$mini/Sources/Mini"
cat >"$mini/Package.swift" <<'EOF'
// swift-tools-version:6.0
import PackageDescription
let package = Package(name: "Mini", targets: [.target(name: "Mini")])
EOF
echo 'public let mini: Int = "not an int"' >"$mini/Sources/Mini/Mini.swift"
printf '%s\n' 'p15-oracle-004 [ linux ] swift-shared/Mini [ Skip ]  # fixture: never built' \
  >"$repo/tests/oracle/Expectations.d/swift-shared.txt"
git -C "$repo" add -A
commit shared-fixture
shared() {
  CMUX_LINUX_OUT="$work/out" tier --shared --receipt "$work/receipt.json" --errors-queue "$work/queue.jsonl" \
    --jobs 8 --workers 4 "$@"
}
shared --only Mini >"$work/runner.out" 2>&1 || fail "a skipped package failed the run: $(cat "$work/runner.out")"
receipt_check 'want(receipt["packages"]["skipped"] == ["Mini"] and receipt["packages"]["built"] == [], "Mini skipped")'
if shared --only Mini,Typo >"$work/runner.out" 2>&1; then fail "shared --only Typo exited 0: $(cat "$work/runner.out")"; fi
receipt_check 'want(receipt["targets"]["missing"] == ["Typo"], "missing Typo")'
[[ -z "$(porcelain)" ]] || fail "the shared runner changed the checkout: $(porcelain)"
echo "ok 16 --shared honors Skip lines and fails on an --only name that matches nothing"
