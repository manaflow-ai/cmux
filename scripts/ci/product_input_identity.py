#!/usr/bin/env python3
"""Identify compiled app-host product inputs independently of CI orchestration."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Iterable

CI_WORKFLOW = ".github/workflows/ci.yml"
IDENTITY_SCHEMA = "cmux-app-host-product-inputs/v1"
MACOS_ADMISSION_JOB = "macos-compile-admission"

# These checked-in CI helpers can change the actual product or its relocation
# contract. Other scripts/ci files are admission/control-plane implementation,
# not product bytes.
PRODUCT_CI_INPUTS = frozenset({
    "scripts/ci/app_host_test_products.py",
    "scripts/ci/compile-app-host-test-product.sh",
    "scripts/ci/sanitize-xcode-source-packages-cache.py",
})

BUILD_ENV_KEYS = (
    "CMUX_CI_XCODE_APP",
    "CMUX_CI_REQUIRED_MACOS_SDK_MAJOR",
    "CMUX_SKIP_ZIG_BUILD",
)

# Product recipe projection is fail-closed: every named admission step is part
# of product identity unless it is explicitly classified as orchestration-only.
# New/unknown steps therefore invalidate reuse until their role is reviewed.
NON_PRODUCT_RECIPE_STEPS = frozenset({
    "Start compile admission timers",
    "Clear stale git locks (self-hosted reused workspace)",
    "Diagnose checkout network failure",
    "Record hosted source preparation",
    "Measure hosted queue-to-start",
    "Identify reusable compiled products",
    "Reuse exact compatible compiled products",
    "Record compiled-product reuse metrics",
    "Observe persistent Mac compile candidate",
    "Download persistent Mac compile product",
    "Revalidate persistent Mac compile product",
    "Capture Ghostty revision",
    "Cache GhosttyKit.xcframework",
    "Cache Swift packages",
    "Compute test compilation cache key",
    "Restore test compilation cache",
    "Validate Swift warning budget",
    "Run early CLI binary smoke checks",
    "Start product publication timer",
    "Choose product artifact publication",
    "Upload compiled app-host test product",
    "Record compile admission metrics",
    "Upload compile admission metrics",
    "Seed node-local compiled product cache",
})


def normalize_path(path: str) -> str:
    value = path.strip().replace("\\", "/")
    while value.startswith("./"):
        value = value[2:]
    return value


def reaches_product(path: str) -> bool:
    """Whether a tracked path can change the reusable app-host test product."""
    path = normalize_path(path)
    if not path:
        return False
    if path in PRODUCT_CI_INPUTS:
        return True
    if path.startswith("scripts/ci/"):
        return False
    if path.startswith((".github/", "tests/", "tests_v2/", "docs/", "design/", "plans/", "ios/", "web/", "cmux-tui/")):
        return False
    if path.startswith("webviews/") and not path.startswith("webviews/src/agent-session/"):
        return False
    name = path.rsplit("/", 1)[-1]
    if name in {"CLAUDE.md", "AGENTS.md"}:
        return False
    if path == "README.md" or (path.startswith("README.") and path.endswith(".md")):
        return False
    if path.startswith("skills/") and path.endswith(".md") and not path.startswith("skills/cmux-cua/"):
        return False
    return True


def source_fingerprint(tree_lines: Iterable[str]) -> str:
    digest = hashlib.sha256()
    selected: list[str] = []
    for raw in tree_lines:
        line = raw.rstrip("\n")
        if not line:
            continue
        if "\t" not in line:
            raise ValueError("invalid git tree line")
        metadata, path = line.split("\t", 1)
        fields = metadata.split()
        if len(fields) != 3:
            raise ValueError("invalid git tree metadata")
        mode, kind, object_id = fields
        if kind not in {"blob", "commit"}:
            continue
        if not re.fullmatch(r"[0-7]{6}", mode):
            raise ValueError("invalid git tree mode")
        if not re.fullmatch(r"[0-9a-f]{40,64}", object_id):
            raise ValueError("invalid git object id")
        path = normalize_path(path)
        if reaches_product(path):
            selected.append(f"{mode} {kind} {object_id}\t{path}")
    for line in sorted(selected):
        digest.update(line.encode("utf-8") + b"\n")
    return digest.hexdigest()


def github_tree_lines(entries: object) -> list[str]:
    if not isinstance(entries, list):
        raise ValueError("invalid GitHub tree")
    lines: list[str] = []
    for entry in entries:
        if not isinstance(entry, dict):
            raise ValueError("invalid GitHub tree entry")
        kind = entry.get("type")
        if kind == "tree":
            continue
        if kind not in {"blob", "commit"}:
            raise ValueError("unsupported GitHub tree entry")
        path = entry.get("path")
        mode = entry.get("mode")
        object_id = entry.get("sha")
        if not all(isinstance(value, str) and value for value in (path, mode, object_id)):
            raise ValueError("incomplete GitHub tree entry")
        lines.append(f"{mode} {kind} {object_id}\t{path}")
    return lines


def _job_block(workflow: str, job_name: str) -> str:
    lines = workflow.splitlines()
    marker = f"  {job_name}:"
    for index, line in enumerate(lines):
        if line != marker:
            continue
        body = [line]
        for following in lines[index + 1 :]:
            if following.startswith("  ") and not following.startswith("    ") and following.strip():
                break
            body.append(following)
        return "\n".join(body) + "\n"
    raise ValueError(f"workflow job {job_name!r} not found")


def _step_blocks(job: str) -> list[tuple[str, str]]:
    lines = job.splitlines()
    starts = [
        index
        for index, line in enumerate(lines)
        if line.startswith("      - ")
    ]
    blocks: list[tuple[str, str]] = []
    names: set[str] = set()
    for position, index in enumerate(starts):
        end = starts[position + 1] if position + 1 < len(starts) else len(lines)
        first = lines[index]
        marker = "      - name: "
        if not first.startswith(marker):
            raise ValueError("macOS admission workflow contains an unnamed step")
        name = first[len(marker):]
        if not name or name in names:
            raise ValueError(f"macOS admission workflow step name is not unique: {name!r}")
        names.add(name)
        blocks.append((name, "\n".join(lines[index:end]) + "\n"))
    if not blocks:
        raise ValueError("macOS admission workflow has no steps")
    return blocks


def recipe_projection(workflow: str) -> dict[str, object]:
    job = _job_block(workflow, MACOS_ADMISSION_JOB)
    environment: dict[str, str] = {}
    for key in BUILD_ENV_KEYS:
        match = re.search(rf"(?m)^      {re.escape(key)}:\s*(.+?)\s*$", job)
        if match is None:
            raise ValueError(f"build environment key {key!r} not found")
        environment[key] = match.group(1)
    steps = {
        name: block
        for name, block in _step_blocks(job)
        if name not in NON_PRODUCT_RECIPE_STEPS
    }
    if not steps:
        raise ValueError("macOS admission product recipe is empty")
    return {"environment": environment, "steps": steps}


def recipe_fingerprint(workflow: str) -> str:
    raw = json.dumps(recipe_projection(workflow), sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(raw).hexdigest()


def algorithm_fingerprint() -> str:
    return hashlib.sha256(Path(__file__).read_bytes()).hexdigest()


def identity_from_tree_lines(tree_lines: Iterable[str], workflow: str) -> dict[str, str]:
    return {
        "schema": IDENTITY_SCHEMA,
        "algorithm": algorithm_fingerprint(),
        "source": source_fingerprint(tree_lines),
        "recipe": recipe_fingerprint(workflow),
    }


def local_identity(revision: str = "HEAD") -> dict[str, str]:
    tree_lines = subprocess.check_output(
        ["git", "-c", "core.quotepath=off", "ls-tree", "-r", revision],
        text=True,
    ).splitlines()
    workflow = subprocess.check_output(
        ["git", "show", f"{revision}:{CI_WORKFLOW}"],
        text=True,
    )
    return identity_from_tree_lines(tree_lines, workflow)


def identity_key(value: dict[str, str], extra: Iterable[str] = ()) -> str:
    digest = hashlib.sha256()
    digest.update(
        json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")
    )
    digest.update(b"\n")
    for item in sorted(extra):
        digest.update(b"extra:" + item.encode("utf-8") + b"\n")
    return digest.hexdigest()


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", default="HEAD")
    parser.add_argument("--key", action="store_true")
    parser.add_argument("--extra", action="append", default=[])
    args = parser.parse_args(argv)
    value = local_identity(args.revision)
    if args.key:
        print(identity_key(value, args.extra))
    else:
        if args.extra:
            parser.error("--extra requires --key")
        print(json.dumps(value, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
