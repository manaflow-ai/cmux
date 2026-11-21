#!/bin/bash
# Compile and execute the production SSH attempt owner and its Swift Testing
# suite without the shell package's UI/transport dependencies.
set -euo pipefail
repo_root=$(git rev-parse --show-toplevel)
proof_ref="${1:-HEAD}"
proof_dir=$(mktemp -d "${TMPDIR:-/tmp}/ssh-attempt-proof.XXXXXX")
trap 'python3 - "$proof_dir" <<'"'"'PY'"'"'
import shutil, sys
shutil.rmtree(sys.argv[1])
PY' EXIT
mkdir -p "$proof_dir/Sources/CmuxMobileShell" "$proof_dir/Tests/CmuxMobileShellTests"
cat > "$proof_dir/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "SSHConnectionLifecycle", platforms: [.macOS(.v14)], targets: [
    .target(name: "CmuxMobileShell"),
    .testTarget(name: "CmuxMobileShellTests", dependencies: ["CmuxMobileShell"])
])
SWIFT
source_root=Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell
test_root=Packages/iOS/CmuxMobileShell/Tests/CmuxMobileShellTests
for name in MobileSSHConnectionAttempts MobileSSHConnectionAttemptSuperseded; do
    git -C "$repo_root" show "$proof_ref:$source_root/$name.swift" > "$proof_dir/Sources/CmuxMobileShell/$name.swift"
done
for name in MobileSSHConnectionAttemptTests SSHConnectionAttemptGate SSHConnectionAttemptHarness; do
    git -C "$repo_root" show "$proof_ref:$test_root/$name.swift" > "$proof_dir/Tests/CmuxMobileShellTests/$name.swift"
done
# These two records were nested in the required files at the failing revision.
if git -C "$repo_root" cat-file -e "$proof_ref:$source_root/MobileSSHConnectionAttempt.swift" 2>/dev/null; then
    git -C "$repo_root" show "$proof_ref:$source_root/MobileSSHConnectionAttempt.swift" > "$proof_dir/Sources/CmuxMobileShell/MobileSSHConnectionAttempt.swift"
fi
if git -C "$repo_root" cat-file -e "$proof_ref:$test_root/SSHConnectionAttemptFailure.swift" 2>/dev/null; then
    git -C "$repo_root" show "$proof_ref:$test_root/SSHConnectionAttemptFailure.swift" > "$proof_dir/Tests/CmuxMobileShellTests/SSHConnectionAttemptFailure.swift"
fi
# This small proof target contains only Swift Testing tests; the real package
# test lane still compiles and runs all of CmuxMobileShellTests.
swift test --disable-xctest --package-path "$proof_dir" --jobs 2 --filter MobileSSHConnectionAttemptTests
