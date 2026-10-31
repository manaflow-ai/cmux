#!/usr/bin/env python3
"""Refuse cache values the nightly app build did not compute, before save-nightly-app-caches saves.

nightly.yml's build-nightly-app runs on a reused trusted mini and holds no R2 key. It sends
save-nightly-app-caches, which holds the R2 write keys, the R2 namespace and the compilation
cache key as job outputs. This checks them against the shapes the build's own expressions give,
so a changed value can never move a save to another namespace, another key family or another
commit. Read from the environment:

  PLATFORM            runner.os-runner.arch of the build: macOS-ARM64 or macOS-X64
  HEAD_SHA            needs.decide.outputs.head_sha: 40 lower-case hex
  COMPILATION_CACHE   `success` when the compilation cache will be saved
  COMPILATION_KEY     xcode-compilation-release-<PLATFORM>-<toolchain: 64 hex>-<HEAD_SHA>
  SWIFT_PACKAGES      `success` when the Swift packages will be saved
  SPM_KEY             spm-<64 hex>, from this job's own hashFiles (empty when a lockfile is missing)

A key is checked only when it will be saved. Exit 1, with an ::error:: line, on any mismatch.
"""

from __future__ import annotations

import os
import re
import sys

PLATFORMS = ("macOS-ARM64", "macOS-X64")
HEX40 = re.compile(r"[0-9a-f]{40}")
HEX64 = r"[0-9a-f]{64}"


def problems(env: dict[str, str]) -> list[str]:
    found = []
    platform, head = env.get("PLATFORM", ""), env.get("HEAD_SHA", "")
    if platform not in PLATFORMS:
        found.append(f"cache platform {platform!r} is not one of {', '.join(PLATFORMS)}")
    if not HEX40.fullmatch(head):
        found.append(f"head sha {head!r} is not 40 lower-case hex")
    if env.get("COMPILATION_CACHE") == "success":
        key = env.get("COMPILATION_KEY", "")
        expected = re.compile(rf"xcode-compilation-release-{re.escape(platform)}-{HEX64}-{re.escape(head)}")
        if not expected.fullmatch(key):
            found.append(f"compilation cache key {key!r} is not "
                         f"xcode-compilation-release-{platform}-<64 hex toolchain>-{head}")
    if env.get("SWIFT_PACKAGES") == "success":
        key = env.get("SPM_KEY", "")
        if not re.fullmatch(rf"spm-{HEX64}", key):
            found.append(f"Swift package key {key!r} is not spm-<64 hex>")
    return found


def main() -> int:
    found = problems(dict(os.environ))
    for problem in found:
        print(f"::error title=Nightly cache handoff refused::{problem}")
    if not found:
        print("check-nightly-cache-handoff: the platform, head and keys have the shapes the build computes")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
