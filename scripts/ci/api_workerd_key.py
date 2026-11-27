#!/usr/bin/env python3
"""The reuse key of backend.yml's api-workerd shards (ci500k).

Leo: "de facto, im asking for 99% fewer minutes of ci time, period." A pull request whose API Worker test inputs
hold the same blobs as a head whose twelve shards already passed has nothing new to prove (measured 2026-11-24:
57% of api-workerd's minutes ran on a hash that had already passed). backend.yml looks `api-workerd-green-<key>` up
in the Actions cache and skips the shards on a hit; the `test` job saves it after a run where every shard passed.

The key is sha256 of `git ls-tree -r HEAD -- <INPUTS>` plus the tool versions and the shard count. INPUTS is what the
suite reads: backend/ whole (its bun.lock too), and the files outside it that backend's tests import or read.
"""

import hashlib
import subprocess
import sys

KEY_VERSION = "v1"
# Keep in step with backend.yml's api-workerd job (setup-bun, setup-node, matrix).
BUN_VERSION = "1.4.4"
NODE_VERSION = "24.22.1"
SHARDS = 12

INPUTS = [
    ".github/workflows/backend.yml",
    "backend",
    "clients/ts",
    "workers/cmux-vm/sdk",
    "libs/svix-webhook",
    "libs/vm-instance-identity",
    "libs/integrations-core",
    "schemas/link-token",
    "schemas/ownership-mirror",
    "cmux-tui/crates/cmux-transport/tests/vectors/relay-frames.json",
    "cmux-tui/crates/cmux-cloud-wire/src/generated",
    "Native/OptChat/chief-kernel/src/turn_checks.md",
    "Native/OptChat/optchat-chief/evals/cases",
    "cmux-next-ios/backend/src",
    "scripts/ci/api_call_log",
    "scripts/ci/api-workerd-shard.sh",
    "scripts/cmux-next/release/bun.lock",
    "scripts/cmux-next/release/mint-link-keyset.mjs",
    "scripts/cmux-next/check-acpmux-guest-commands.ts",
    "web/services/vms/drivers/acpmuxPersonKey.ts",
    "web/services/vms/drivers/cmuxTuiDaemon.ts",
    "tests/fixtures/model-stub",
    "Packages/macOS/CmuxNext/Sources/CmuxNextCloudCredentials",
]


def key(rev: str = "HEAD", cwd: str = ".") -> str:
    """The 40-hex key of `rev`'s inputs, or "" (never reuse) when the tree cannot be listed."""
    listing = subprocess.run(["git", "ls-tree", "-r", rev, "--", *INPUTS], capture_output=True, cwd=cwd)
    if listing.returncode != 0 or not listing.stdout:
        return ""
    digest = hashlib.sha256(listing.stdout).hexdigest()
    meta = f"{KEY_VERSION} bun={BUN_VERSION} node={NODE_VERSION} shards={SHARDS} {digest}"
    return hashlib.sha256(meta.encode()).hexdigest()[:40]


if __name__ == "__main__":
    print(key(*(sys.argv[1:2] or ["HEAD"])))
