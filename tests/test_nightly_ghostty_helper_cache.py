#!/usr/bin/env python3
"""nightly.yml's build-nightly-ghostty-cli-helper keeps the helper's own cache.

scripts/build-ghostty-cli-helper.sh reuses a helper only when the manifest it
wrote equals the current build's inputs and the binary's sha256 equals the
manifest's. A hosted macos-15 runner starts with an empty cache directory, so
the job restores that directory with actions/cache. The cache key must name
every input the script's manifest names, so a key never hides a changed input,
and it must be exact (no restore-keys), so an entry for other inputs is never
restored and then rebuilt into the same key.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "nightly.yml"
SCRIPT = ROOT / "scripts" / "build-ghostty-cli-helper.sh"


def main() -> int:
    failures: list[str] = []
    job = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["build-nightly-ghostty-cli-helper"]
    steps = job["steps"]
    names = [step.get("name", "") for step in steps]
    try:
        key_at = names.index("Key the Ghostty CLI helper cache")
        cache_at = names.index("Cache the Ghostty CLI helper")
        build_at = names.index("Build Ghostty CLI helper")
    except ValueError as error:
        print(f"FAIL: {error}")
        return 1
    if not key_at < cache_at < build_at:
        failures.append("the key, then the cache, must come before the helper build")
    script = SCRIPT.read_text(encoding="utf-8")
    default_root = re.search(r'CACHE_ROOT="\$HOME/([^"]+)"', script)
    cache = steps[cache_at]
    if not default_root or cache["with"]["path"] != "~/" + default_root.group(1):
        failures.append("the cache path must be the script's default CACHE_ROOT")
    if "restore-keys" in cache["with"]:
        failures.append("the helper cache must restore an exact key only")
    if cache["with"]["key"] != "${{ steps.helper-cache-key.outputs.key }}":
        failures.append("the helper cache must use the key step's key")
    key_run = steps[key_at]["run"]
    # Each manifest field of ghostty_cache_metadata, and what the key reads for it.
    for field, needle in (
        ("ghostty", "git -C ghostty rev-parse HEAD"),
        ("script", "scripts/build-ghostty-cli-helper.sh"),
        ("zig_version and zig_sha256", 'shasum -a 256 "$zig"'),
        ("the PATH Zig the script may pick", "command -v zig"),
        ("sdk", "xcrun --sdk macosx --show-sdk-version"),
        ("macos", "sw_vers -productVersion"),
        ("host_arch", "uname -m"),
        ("requested_target", "NIGHTLY_COMPILE_ARCHS"),
    ):
        if needle not in key_run:
            failures.append(f"the key does not read {field} ({needle})")
    for field in ("ghostty=", "script=", "zig_version=", "zig_sha256=", "sdk=", "macos=", "host_arch=", "requested_target="):
        if field not in script:
            failures.append(f"the script's manifest no longer names {field}; update this guard and the key")
    if 'echo "key=ghostty-cli-helper-v1-' not in key_run:
        failures.append("the key step must write a versioned key")
    for failure in failures:
        print(f"FAIL: {failure}")
    if not failures:
        print("ok: the Ghostty CLI helper cache is keyed on every manifest input")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
