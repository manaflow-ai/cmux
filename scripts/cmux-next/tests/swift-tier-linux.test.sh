#!/usr/bin/env bash
# Checks that scripts/cmux-next/linux/swift-tier.sh never writes to the
# checkout (p15-oracle-229).
#
# Builds a throwaway git repo whose CmuxNext manifest has a Linux mode with a
# different dependency graph (CMUX_SWIFTPM_TARGET_LINUX=1 swaps the macOS-only
# swift-numerics for swift-system), then checks:
#   1. --update-resolved changes only Package.linux.resolved;
#   2. two builds through swift-tier.sh leave `git status --porcelain` empty,
#      and the scratch sources are hard links into the checkout;
#   3. extra pins and no originHash (the shape of the committed CmuxNext seed:
#      the macOS pins minus sentry-cocoa and Sparkle) still build;
#   4. a Package.linux.resolved without a needed pin fails the build and still
#      writes nothing (--only-use-versions-from-resolved-file);
#   5. control: the same Linux resolve run in the checkout itself rewrites
#      Package.resolved, which is what the scratch copy prevents;
#   6. the runner (p15-oracle-004): a target that does not compile fails the
#      run, lands in the errors queue under its own target, blocks its test
#      target, and the green test target still runs;
#   7. a `[ linux ]` Failure line for that target makes the same run exit 0;
#   8. --only and --measure-incremental build a subset and time a one-file
#      edit without touching the checkout.
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
printf '.build/\n' >"$repo/.gitignore"
cp "$root/scripts/cmux-next/linux/swift-tier.sh" "$repo/scripts/cmux-next/linux/swift-tier.sh"

cat >"$pkg/Package.swift" <<'EOF'
// swift-tools-version:6.0
import Foundation
import PackageDescription

let linux = ProcessInfo.processInfo.environment["CMUX_SWIFTPM_TARGET_LINUX"] == "1"
var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-collections.git", exact: "1.1.4"),
]
var tierDependencies: [Target.Dependency] = [.product(name: "DequeModule", package: "swift-collections")]
if linux {
    dependencies.append(.package(url: "https://github.com/apple/swift-system.git", exact: "1.4.0"))
    tierDependencies.append(.product(name: "SystemPackage", package: "swift-system"))
} else {
    dependencies.append(.package(url: "https://github.com/apple/swift-numerics.git", exact: "1.0.3"))
    tierDependencies.append(.product(name: "RealModule", package: "swift-numerics"))
}
let package = Package(
    name: "CmuxNext",
    dependencies: dependencies,
    targets: [.target(name: "Tier", dependencies: tierDependencies)]
)
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
echo "ok 2 two builds leave the checkout unchanged; sources are hard links"

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

(cd "$pkg" && CMUX_SWIFTPM_TARGET_LINUX=1 "$swift_bin" package resolve >/dev/null)
[[ "$(porcelain)" == *"Packages/macOS/CmuxNext/Package.resolved"* ]] \
  || fail "control: an in-checkout Linux resolve did not touch Package.resolved"
echo "ok 5 control: an in-checkout Linux resolve rewrites Package.resolved"

# ---- the runner (p15-oracle-004): receipt, errors queue, [ linux ] lines ----
git -C "$repo" checkout -q -- Packages
cp "$work/linux.resolved" "$pkg/Package.linux.resolved" # the good pins (check 4 left stale ones)
mkdir -p "$repo/scripts/cmux-next/oracle" "$repo/tests/oracle/Expectations.d" \
  "$pkg/Sources/Bad" "$pkg/Tests/TierTests" "$pkg/Tests/BadTests"
cp "$root/scripts/cmux-next/linux/errors_queue.py" "$repo/scripts/cmux-next/linux/"
cp "$root/scripts/cmux-next/oracle/expectations.py" "$repo/scripts/cmux-next/oracle/"
# Like the CmuxNext manifest's Linux mode (p15-oracle-002), the fixture keeps
# only the targets linux-tier.json names, so the runner can prune red ones.
python3 -I - "$pkg/Package.swift" <<'PY'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
text = text.replace(
    '    targets: [.target(name: "Tier", dependencies: tierDependencies)]',
    '    targets: tierTargets',
)
text = text.replace(
    "let package = Package(",
    '''var tierTargets: [Target] = [
    .target(name: "Tier", dependencies: tierDependencies),
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

if runner >"$work/runner.out" 2>&1; then fail "a compile error without a [ linux ] line exited 0: $(cat "$work/runner.out")"; fi
python3 -I - "$work/receipt.json" "$work/queue.jsonl" <<'PY' || fail "receipt or queue: $(cat "$work/runner.out")"
import json, sys
with open(sys.argv[1]) as f:
    receipt = json.load(f)
with open(sys.argv[2]) as f:
    queue = [json.loads(line) for line in f]
def want(cond, what):
    if not cond:
        sys.exit(f"{what}: {json.dumps(receipt, indent=1)[:3000]}\n{queue}")
want(receipt["ok"] is False, "ok")
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
PY
[[ -z "$(porcelain)" ]] || fail "the runner changed the checkout: $(porcelain)"
echo "ok 6 a compile error fails the run and lands in the queue under its target"

printf 'p15-oracle-004 [ linux ] swift-tier/Bad [ Failure ]  # fixture: Bad does not compile\n' \
  >"$repo/tests/oracle/Expectations.d/swift-tier.txt"
git -C "$repo" add -A
commit expect-bad
runner >"$work/runner.out" 2>&1 || fail "an expected failure still failed the run: $(cat "$work/runner.out")"
grep -qx 'OK' "$work/runner.out" || fail "no OK line: $(cat "$work/runner.out")"
echo "ok 7 a [ linux ] Failure line makes the same run pass"

runner --only Tier,TierTests --measure-incremental Tier >"$work/runner.out" 2>&1 \
  || fail "--only run failed: $(cat "$work/runner.out")"
python3 -I - "$work/receipt.json" <<'PY' || fail "incremental: $(cat "$work/runner.out")"
import json, sys
with open(sys.argv[1]) as f:
    receipt = json.load(f)
inc = receipt["incremental"]
if not inc or inc["target"] != "Tier" or inc["status"] != "pass" or receipt["targets"]["built"] != ["Tier"]:
    sys.exit(json.dumps(receipt, indent=1)[:3000])
PY
[[ -z "$(porcelain)" ]] || fail "--measure-incremental changed the checkout: $(porcelain)"
echo "ok 8 --only and --measure-incremental time a one-file edit on a private copy"
