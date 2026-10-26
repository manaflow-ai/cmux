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
#      Package.resolved, which is what the scratch copy prevents.
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
