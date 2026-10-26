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
#   5. a build that fails to compile keeps the workspace state: the next run
#      reuses the dependency checkouts instead of cloning them again;
#   6. a shared pin bumped in Package.resolved fails the run until
#      --update-resolved, which takes the macOS revision;
#   7. a scratch root inside the checkout (relative, or through a symlink) is
#      refused with exit 2 and writes nothing;
#   8. control: the same Linux resolve run in the checkout itself rewrites
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
    .package(url: "https://github.com/apple/swift-collections.git", .upToNextMinor(from: "1.1.0")),
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
