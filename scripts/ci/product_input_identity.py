#!/usr/bin/env python3
"""Identify compiled app-host product inputs independently of CI orchestration."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Iterable, Optional

CI_WORKFLOW = ".github/workflows/ci-macos.yml"
E2E_WORKFLOW = ".github/workflows/test-e2e.yml"
IDENTITY_SCHEMA = "cmux-app-host-product-inputs/v2"
MACOS_ADMISSION_JOB = "macos-compile-admission"
E2E_BUILD_JOB = "build"

# A product profile is the set of schemes one producer builds. The app-host
# profile carries the whole app; the cli profile carries only what the host-free
# CLI lane consumes -- the cmux-cli product and its test bundle.
#
# This is the single source of truth. compile-app-host-test-product.sh asks for
# the scheme list rather than repeating it: if the built schemes and the
# identity ever disagree, a partial product reuses under a full product's key
# and a consumer silently tests something that was never built.
PRODUCT_PROFILES = {
    # The app/UI scheme builds first so its warning log keeps the runtime
    # job's warning-budget scope; later schemes reuse the same app objects.
    "app-host": ("cmux", "cmux-unit", "cmux-numeric-locale", "cmux-cli-tests"),
    "cli": ("cmux-cli-tests",),
}
DEFAULT_PRODUCT_PROFILE = "app-host"


def resolve_profile(name: str | None = None) -> str:
    """Name the product profile, defaulting to the full app-host product."""
    resolved = name or os.environ.get("CMUX_PRODUCT_PROFILE") or DEFAULT_PRODUCT_PROFILE
    if resolved not in PRODUCT_PROFILES:
        raise SystemExit(
            f"unknown product profile {resolved!r}; "
            f"expected one of {', '.join(sorted(PRODUCT_PROFILES))}"
        )
    return resolved


def profile_schemes(name: str | None = None) -> tuple[str, ...]:
    return PRODUCT_PROFILES[resolve_profile(name)]

# These checked-in CI helpers can change the actual product or its relocation
# contract. Other scripts/ci files are admission/control-plane implementation,
# not product bytes.
PRODUCT_CI_INPUTS = frozenset({
    "scripts/ci/app_host_test_products.py",
    "scripts/ci/compile-app-host-test-product.sh",
    "scripts/ci/canonical-build-root.sh",
    "scripts/ci/sanitize-xcode-source-packages-cache.py",
})

# workers/ is Cloudflare Worker source and stays out of product identity, with
# one exception. cmux.xcodeproj's "Build Plain Text Paste Worker" phase declares
# workers/cmux-paste-text/main.m as an input and compiles it into the app-host
# bundle as bin/cmux-paste-text-worker, which cmuxTests loads and executes.
# Changing it changes product bytes, so it has to invalidate reuse.
PRODUCT_WORKER_PREFIXES = ("workers/cmux-paste-text/",)

# Developer and maintenance tooling that neither the Xcode build nor any macOS
# CI lane reads: no build phase, compile helper, bundled-resource script, or
# ci-macos.yml / test-e2e.yml step names them, and no native test executes
# them. agent-chat/ is the standalone chat server a user starts with cmux-chat;
# the app only connects to it. Each keeps its own Linux guard. Keep this exact:
# scripts/ also holds the build phases' helpers, which must stay product inputs.
NON_PRODUCT_TOOLING_PREFIXES = (
    ".claude/",
    "agent-chat/",
    "scripts/git-hooks/",
)
NON_PRODUCT_TOOLING = frozenset({
    "scripts/benchmark-dev-fleet-warm-slots.py",
    "scripts/check-pbxproj.sh",
    "scripts/check-test-determinism.py",
    "scripts/dev-fleet-warm-slot.py",
    "scripts/install-git-hooks.sh",
    "scripts/merge-xcstrings.py",
    "scripts/normalize-pbxproj.py",
    "scripts/prune_nightly_release_assets.py",
})

REQUIRED_PRODUCT_JOB_ENV_KEYS = frozenset({
    "CMUX_CI_XCODE_APP",
    "CMUX_CI_REQUIRED_MACOS_SDK_MAJOR",
    "CMUX_SKIP_ZIG_BUILD",
})

E2E_REQUIRED_PRODUCT_JOB_ENV_KEYS = frozenset({
    "TEST_REF",
    "CMUX_CI_MAX_MACOS_SDK_MAJOR",
    "CMUX_SKIP_ZIG_BUILD",
    "CMUX_PRODUCT_RUNNER",
})

NON_PRODUCT_JOB_ENV_KEYS = frozenset({
    # Where an owned Mac keeps its build state between jobs (owned_build_state.py).
    "CMUX_OWNED_STATE_ROOT",
    "CMUX_NODE_PRODUCT_CACHE_ROOT",
    "CMUX_NODE_PRODUCT_CACHE_MAX_BYTES",
    "CMUX_NODE_PRODUCT_CACHE_WAIT_SECONDS",
    "CMUX_PRODUCT_RUNNER",
    # Read only by the changed-suites steps that test the finished product.
    "CMUX_CI_APP_HOST_ISOLATION_REQUIRED",
    "CMUX_APP_HOST_SHARD",
    "CMUX_APP_HOST_UNIT_SELECTORS",
    "CMUX_APP_HOST_CAPTURE_XCRESULTS",
    "CMUX_UNIT_TEST_TIMEOUT_SECONDS",
    "CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS",
    "CMUX_XCODEBUILD_NONINTERACTIVE_RESTART_BUDGET",
    "CMUX_XCODEBUILD_NONINTERACTIVE_POST_TEST_TIMEOUT_SECONDS",
    "SWIFT_BACKTRACE",
})

IGNORED_JOB_LEVEL_KEYS = frozenset({
    "name",
    "needs",
    "if",
    "runs-on",
    "timeout-minutes",
    "permissions",
    "outputs",
})

# Product recipe projection is fail-closed: every named admission step is part
# of product identity unless it is explicitly classified as orchestration-only.
# New/unknown steps therefore invalidate reuse until their role is reviewed.
NON_PRODUCT_RECIPE_STEPS = frozenset({
    "Reject stale pull request rerun",
    "Start compile admission timers",
    "Clear stale git locks (self-hosted reused workspace)",
    "Retry checkout after transient network failure",
    "Diagnose checkout network failure",
    "Record hosted source preparation",
    "Measure hosted queue-to-start",
    "Identify reusable compiled products",
    "Reuse exact compatible compiled products",
    "Record compiled-product reuse metrics",
    "Cache GhosttyKit.xcframework",
    "Cache Swift packages",
    "Compute test compilation cache key",
    "Restore test compilation cache",
    # Like the compilation cache, a seed DerivedData decides how much is
    # rebuilt, never what the product is: Xcode rebuilds every input that
    # differs from the seed, and replay only ages byte-identical files.
    "Start the DerivedData seed download",
    "Adopt the nightly DerivedData seed",
    "Forget the adopted-build inode override",
    # An owned Mac's kept DerivedData and packages decide how much is rebuilt
    # and fetched, like the seed above, never what the product is.
    "Reuse this owned Mac's build state",
    "Adopt this owned Mac's DerivedData",
    "Keep this owned Mac's DerivedData",
    "Keep this owned Mac's build state",
    "Validate Swift warning budget",
    "Run early CLI binary smoke checks",
    "Start product publication timer",
    "Choose product artifact publication",
    "Upload compiled app-host test product",
    "Record compile admission metrics",
    "Upload compile admission metrics",
    "Seed node-local compiled product cache",
    "Report evidence collection outcomes",
    # A changed-suites run tests the product after it is packaged and
    # uploaded; nothing here can change its bytes.
    "Prepare isolated DerivedData",
    "Restore compiled app-host test product",
    "Prepare isolated app-host home",
    "Enumerate built app-host tests",
    "Upload built app-host test inventory",
    "Enable XCTest automation mode",
    "Run changed app-host suites",
    "Report a changed-suites failure apart from the compile",
    "Collect app-host failure diagnostics",
    "Upload app-host failure diagnostics",
    "Clean up isolated app-host home",
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
    if path.startswith(PRODUCT_WORKER_PREFIXES):
        return True
    if path.startswith("scripts/ci/"):
        return False
    if path in NON_PRODUCT_TOOLING or path.startswith(NON_PRODUCT_TOOLING_PREFIXES):
        return False
    if path.startswith((".github/", "tests/", "tests_v2/", "docs/", "design/", "plans/", "ios/", "web/", "workers/", "config/iroh/", "cmux-tui/", "cmux-browser/", "daemon/remote/")):
        return False
    if path in {".vercelignore", "vercel.json"}:
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
    _, found, steps_body = job.partition("\n    steps:\n")
    if not found:
        raise ValueError("macOS admission workflow has no steps section")
    lines = steps_body.splitlines()
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


def _job_level_blocks(job: str) -> list[tuple[str, str]]:
    """Split exact four-space job keys without interpreting YAML expressions."""
    lines = job.splitlines()
    starts: list[tuple[int, str]] = []
    for index, line in enumerate(lines[1:], start=1):
        if not line.startswith("    ") or line.startswith("      "):
            continue
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = re.match(r"^    ([A-Za-z0-9_-]+):(?:\s.*)?$", line)
        if match is None:
            raise ValueError("macOS admission workflow has an unreadable job-level key")
        starts.append((index, match.group(1)))
    if not starts:
        raise ValueError("macOS admission workflow has no job-level controls")

    blocks: list[tuple[str, str]] = []
    names: set[str] = set()
    for position, (index, name) in enumerate(starts):
        if name in names:
            raise ValueError(f"macOS admission job-level key is not unique: {name!r}")
        names.add(name)
        end = starts[position + 1][0] if position + 1 < len(starts) else len(lines)
        blocks.append((name, "\n".join(lines[index:end]) + "\n"))
    return blocks


def _product_job_environment(block: str) -> dict[str, str]:
    """Keep every job env value unless it is explicitly orchestration-only."""
    lines = block.splitlines()
    if not lines or lines[0].strip() != "env:":
        raise ValueError("macOS admission env block is unreadable")

    values: dict[str, str] = {}
    seen: set[str] = set()
    for line in lines[1:]:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = re.match(r"^      ([A-Za-z_][A-Za-z0-9_]*):\s*(.*?)\s*$", line)
        if match is None:
            raise ValueError("macOS admission env contains an unsupported value shape")
        name, value = match.groups()
        if name in seen:
            raise ValueError(f"macOS admission env key is not unique: {name!r}")
        seen.add(name)
        if name not in NON_PRODUCT_JOB_ENV_KEYS:
            values[name] = value

    missing = REQUIRED_PRODUCT_JOB_ENV_KEYS - seen
    if missing:
        raise ValueError(
            "macOS admission is missing required product env keys: "
            + ", ".join(sorted(missing))
        )
    return values


def recipe_projection(workflow: str) -> dict[str, object]:
    job = _job_block(workflow, MACOS_ADMISSION_JOB)
    controls: dict[str, object] = {}
    seen_job_keys: set[str] = set()
    for name, block in _job_level_blocks(job):
        seen_job_keys.add(name)
        if name in IGNORED_JOB_LEVEL_KEYS:
            continue
        if name == "env":
            controls["env"] = _product_job_environment(block)
            continue
        if name == "defaults":
            # shell / working-directory semantics can change every retained step.
            controls["defaults"] = block
            continue
        if name == "steps":
            continue
        raise ValueError(f"unclassified macOS admission job-level key: {name!r}")

    if "env" not in controls or "steps" not in seen_job_keys:
        raise ValueError("macOS admission job is missing product controls")

    steps = {
        name: block
        for name, block in _step_blocks(job)
        if name not in NON_PRODUCT_RECIPE_STEPS
    }
    if not steps:
        raise ValueError("macOS admission product recipe is empty")
    return {"job_controls": controls, "steps": steps}


def recipe_fingerprint(workflow: str) -> str:
    raw = json.dumps(recipe_projection(workflow), sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(raw).hexdigest()


def _e2e_product_job_environment(block: str) -> dict[str, str]:
    """Keep every E2E build env value so new build controls fail closed."""
    lines = block.splitlines()
    if not lines or lines[0].strip() != "env:":
        raise ValueError("E2E build env block is unreadable")

    values: dict[str, str] = {}
    seen: set[str] = set()
    for line in lines[1:]:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = re.match(r"^      ([A-Za-z_][A-Za-z0-9_]*):\s*(.*?)\s*$", line)
        if match is None:
            raise ValueError("E2E build env contains an unsupported value shape")
        name, value = match.groups()
        if name in seen:
            raise ValueError(f"E2E build env key is not unique: {name!r}")
        seen.add(name)
        values[name] = value

    missing = E2E_REQUIRED_PRODUCT_JOB_ENV_KEYS - seen
    if missing:
        raise ValueError(
            "E2E build is missing required product env keys: "
            + ", ".join(sorted(missing))
        )
    return values


def e2e_recipe_projection(workflow: str) -> dict[str, object]:
    """Project the dispatch build recipe conservatively.

    Every named step is retained. That is intentionally broader than the
    compile-admission projection: this workflow is now a reusable-product
    producer, so an inserted pre-build source mutation, a new build env value,
    or a changed setup action must invalidate its products.
    """
    job = _job_block(workflow, E2E_BUILD_JOB)
    controls: dict[str, object] = {}
    seen_job_keys: set[str] = set()
    for name, block in _job_level_blocks(job):
        seen_job_keys.add(name)
        if name in IGNORED_JOB_LEVEL_KEYS:
            continue
        if name == "env":
            controls["env"] = _e2e_product_job_environment(block)
            continue
        if name == "defaults":
            controls["defaults"] = block
            continue
        if name == "steps":
            continue
        raise ValueError(f"unclassified E2E build job-level key: {name!r}")

    if "env" not in controls or "steps" not in seen_job_keys:
        raise ValueError("E2E build job is missing product controls")

    steps = dict(_step_blocks(job))
    if not steps:
        raise ValueError("E2E build product recipe is empty")
    return {"job_controls": controls, "steps": steps}


def e2e_recipe_fingerprint(workflow: str) -> str:
    raw = json.dumps(
        e2e_recipe_projection(workflow),
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(raw).hexdigest()


def algorithm_fingerprint() -> str:
    return hashlib.sha256(Path(__file__).read_bytes()).hexdigest()


def identity_from_tree_lines(
    tree_lines: Iterable[str],
    workflow: str,
    e2e_workflow: Optional[str] = None,
    *,
    profile: str | None = None,
) -> dict[str, str]:
    tree_lines = list(tree_lines)
    resolved = resolve_profile(profile)
    value = {
        "schema": IDENTITY_SCHEMA,
        "algorithm": algorithm_fingerprint(),
        "source": source_fingerprint(tree_lines),
        "recipe": recipe_fingerprint(workflow),
        # Two profiles over one revision build different products. Keeping the
        # profile out of the identity would let the cli product answer an
        # app-host consumer's cache lookup.
        "profile": resolved,
        "schemes": " ".join(PRODUCT_PROFILES[resolved]),
    }
    if e2e_workflow is not None:
        value["e2e_recipe"] = e2e_identity_fingerprint(e2e_workflow, tree_lines)
    return value


_CI_HELPER_REFERENCE_RE = re.compile(r"scripts/ci/[A-Za-z0-9_.-]+")


def e2e_identity_fingerprint(workflow: str, tree_lines: Iterable[str]) -> str:
    """The E2E recipe plus the content of every scripts/ci file its build job names.

    reaches_product() keeps scripts/ci out of the shared source fingerprint,
    so an E2E-only helper would otherwise
    change E2E products without changing their key. Deriving the list from the
    job, rather than naming helpers here, keeps them out of the macOS identity.
    """
    helpers = set(_CI_HELPER_REFERENCE_RE.findall(_job_block(workflow, E2E_BUILD_JOB)))
    helper_lines = sorted(line for line in tree_lines if line.rpartition("\t")[2] in helpers)
    raw = json.dumps(
        {"recipe": e2e_recipe_fingerprint(workflow), "helpers": helper_lines},
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(raw).hexdigest()


def local_identity(revision: str = "HEAD", profile: str | None = None) -> dict[str, str]:
    tree_lines = subprocess.check_output(
        ["git", "-c", "core.quotepath=off", "ls-tree", "-r", revision],
        text=True,
    ).splitlines()
    workflow = subprocess.check_output(
        ["git", "show", f"{revision}:{CI_WORKFLOW}"],
        text=True,
    )
    e2e_workflow = subprocess.check_output(
        ["git", "show", f"{revision}:{E2E_WORKFLOW}"],
        text=True,
    )
    return identity_from_tree_lines(tree_lines, workflow, e2e_workflow, profile=profile)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", default="HEAD")
    parser.add_argument("--profile", default=None)
    parser.add_argument(
        "command",
        nargs="?",
        choices=("identity", "schemes"),
        default="identity",
        help="`schemes` prints the profile's scheme list for the build script.",
    )
    args = parser.parse_args(argv)
    if args.command == "schemes":
        print(" ".join(profile_schemes(args.profile)))
        return 0
    print(json.dumps(local_identity(args.revision, args.profile), sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
