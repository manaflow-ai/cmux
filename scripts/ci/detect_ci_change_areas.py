#!/usr/bin/env python3
"""Classify a PR diff into CI areas that should run."""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from typing import Iterable, Optional


@dataclass(frozen=True)
class ChangeAreas:
    macos: bool
    web: bool
    agent_session_web: bool
    cli: bool
    swift_packages: bool
    release_build: bool

    @classmethod
    def all(cls) -> ChangeAreas:
        return cls(
            macos=True,
            web=True,
            agent_session_web=True,
            cli=True,
            swift_packages=True,
            release_build=True,
        )

    def as_output_lines(self) -> list[str]:
        return [
            f"macos={bool_output(self.macos)}",
            f"web={bool_output(self.web)}",
            f"agent_session_web={bool_output(self.agent_session_web)}",
            f"cli={bool_output(self.cli)}",
            f"swift_packages={bool_output(self.swift_packages)}",
            f"release_build={bool_output(self.release_build)}",
        ]


def bool_output(value: bool) -> str:
    return "true" if value else "false"


def normalize_path(path: str) -> str:
    normalized = path.strip().replace("\\", "/")
    while normalized.startswith("./"):
        normalized = normalized[2:]
    return normalized


CI_WORKFLOW_PATH = ".github/workflows/ci.yml"
GUARD_WORKFLOW_PATH = ".github/workflows/ci-guards.yml"
WEB_WORKFLOW_PATH = ".github/workflows/ci-web.yml"
MACOS_WORKFLOW_PATH = ".github/workflows/ci-macos.yml"
CLI_WORKFLOW_PATH = ".github/workflows/cli-pipe-regressions.yml"
MACOS_XCODE_PROJECT_PATH = "cmux.xcodeproj/project.pbxproj"
MACOS_PRODUCT_TARGET = "cmux"
CLI_PRODUCT_TARGET = "cmux-cli"

_LOCAL_PATH_DEPENDENCY_RE = re.compile(
    r'\.package\(\s*(?:name:\s*"[^"]*"\s*,\s*)?path:\s*"([^"]+)"'
)
_LOCAL_PATH_DECLARATION_RE = re.compile(r"\.package\([^)]*\bpath\s*:", re.DOTALL)
_PACKAGE_PRODUCT_RE = re.compile(
    r'\.(?:library|executable|plugin)\s*\(\s*name:\s*"([^"]+)"',
    re.DOTALL,
)
_PBX_OBJECT_RE = re.compile(
    r"(?m)^[ \t]*([A-Za-z0-9]+)\s+/\*[^*]*\*/\s*=\s*\{([\s\S]*?)\};[ \t]*$"
)


def is_other_workflow_config(path: str) -> bool:
    # ci.yml's macOS and web jobs read no other workflow file. An edit to one is
    # checked by the reusable guard workflow and by that workflow's own triggers.
    if path == CI_WORKFLOW_PATH:
        return False
    return path.startswith(".github/workflows/") or path == ".github/actionlint.yaml"


CI_CONTROL_PLANE_ONLY = frozenset({
    "scripts/ci/persistent_mac_route.py",
    "scripts/ci/web_validation.py",
})

# Publishing consumes finished products. These exact helpers never run in PR
# compile/test lanes. Validate publishing through its guards/release workflows.
CI_PUBLISHING_ONLY = frozenset({
    "scripts/ci/download-run-artifact.py",
    "scripts/prebuild_sparkle_deltas.sh",
    "scripts/sparkle_generate_appcast.sh",
})

CI_MACOS_ADMISSION_CONTROL_INPUTS = frozenset({
    "scripts/ci/build_input_fingerprint.py",
    "scripts/ci/find_admitted_build.py",
})

CI_MACOS_TEST_PRODUCT_INPUTS = frozenset({
    "scripts/ci/app_host_test_products.py",
    "scripts/ci/compile-app-host-test-product.sh",
    "scripts/ci/product_input_identity.py",
    "scripts/ci/peer_product_source.py",
    "scripts/ci/restore-app-host-test-product.sh",
    "scripts/ci/reuse_app_host_products.py",
    "scripts/ci/sanitize-xcode-source-packages-cache.py",
})


def forces_all_areas(path: str) -> bool:
    # Unknown direct CI implementation files remain fail-open. Narrow only
    # explicitly-owned control-plane helpers whose product-area semantics are
    # covered by a dedicated lane.
    direct_ci_python = (
        path.startswith("scripts/ci/")
        and path.endswith(".py")
        and "/" not in path[len("scripts/ci/") :]
    )
    if (
        direct_ci_python
        and path not in CI_CONTROL_PLANE_ONLY
        and path not in CI_PUBLISHING_ONLY
        and path not in CI_MACOS_ADMISSION_CONTROL_INPUTS
        and path not in CI_MACOS_TEST_PRODUCT_INPUTS
    ):
        return True
    return path == CI_WORKFLOW_PATH


_TEST_REFERENCE_RE = re.compile(r"tests/[A-Za-z0-9_./-]*")
_CI_GUARD_PROFILE_MARKER = "scripts/ci/cmux_workload_profile.py run cmux.ci.guard"
_CI_GUARD_ENTRYPOINT = "scripts/ci/workloads/ci-guard.sh"


def is_plainly_linux_runner(runs_on: str) -> bool:
    # Anything else counts as macOS: a matrix or needs expression, a list or
    # group on the following lines, or a label this does not recognize.
    value = runs_on.strip()
    if not value or re.search(r"macos|matrix\.|needs\.|inputs\.", value, re.IGNORECASE):
        return False
    return bool(re.search(r"LINUX_RUNNER|LINUX_ARM64_RUNNER|ubuntu", value))


_JOB_SPLIT_RE = re.compile(r"(?m)^  (?=[A-Za-z0-9_-]+:\s*$)")

# `changes` routes every other job and `ci-status` is the required gate, so an
# edit to either always runs every area.
_ROUTING_JOBS = frozenset({"changes", "ci-status"})


def split_workflow_jobs(workflow: str) -> Optional[tuple[str, dict[str, str]]]:
    """Return the text before `jobs:` and each job's block, or None if unreadable."""
    preamble, found, body = workflow.partition("\njobs:\n")
    if not found:
        return None
    jobs: dict[str, str] = {}
    for block in _JOB_SPLIT_RE.split(body):
        name, _, _ = block.partition(":")
        if not block.strip():
            continue
        if not re.fullmatch(r"[A-Za-z0-9_-]+", name) or name in jobs:
            return None
        jobs[name] = block
    return (preamble, jobs) if jobs else None


def job_is_plainly_linux(block: str) -> bool:
    runs_on = re.search(r"(?m)^    runs-on:[ \t]*(.*)$", block)
    return bool(runs_on) and is_plainly_linux_runner(runs_on.group(1))


def ci_workflow_change_is_linux_only(base: str, head: str) -> bool:
    """True when base and head ci.yml differ only in jobs that run on Linux.

    Triggers, env, permissions and concurrency live before `jobs:` and reach
    every job, so any change there is not Linux-only. Unreadable input and an
    unchanged file are not Linux-only either, so the caller fails open.
    """
    base_parts = split_workflow_jobs(base)
    head_parts = split_workflow_jobs(head)
    if base_parts is None or head_parts is None:
        return False
    (base_preamble, base_jobs), (head_preamble, head_jobs) = base_parts, head_parts
    if base_preamble != head_preamble:
        return False
    changed = {
        name
        for name in base_jobs.keys() | head_jobs.keys()
        if base_jobs.get(name) != head_jobs.get(name)
    }
    if not changed or changed & _ROUTING_JOBS:
        return False
    return all(
        job_is_plainly_linux(jobs[name])
        for name in changed
        for jobs in (base_jobs, head_jobs)
        if name in jobs
    )


def macos_job_test_references(
    workflow: str,
    indirect_guard_references: frozenset[str] = frozenset(),
) -> Optional[tuple[frozenset[str], frozenset[str]]]:
    """Return the tests/ paths ci.yml names in non-Linux jobs and in all jobs.

    A macOS job that runs tests through a glob yields the glob's literal prefix.
    Returns None when the jobs cannot be read, so the caller fails open.
    """
    _, found, body = workflow.partition("\njobs:\n")
    if not found:
        return None
    macos: set[str] = set()
    everywhere: set[str] = set()
    jobs = 0
    for block in re.split(r"(?m)^  (?=[A-Za-z0-9_-]+:\s*$)", body):
        runs_on = re.search(r"(?m)^    runs-on:[ \t]*(.*)$", block)
        if not runs_on:
            continue
        jobs += 1
        references = set(_TEST_REFERENCE_RE.findall(block))
        if _CI_GUARD_PROFILE_MARKER in block:
            references |= set(indirect_guard_references)
        everywhere |= references
        if not is_plainly_linux_runner(runs_on.group(1)):
            macos |= references
    if jobs == 0:
        return None
    return frozenset(macos), frozenset(everywhere)


# Set by ci.yml when the trusted base router classifies a routing-policy PR:
# the PR's own checkout, whose workflows may name tests the base has never seen.
HEAD_TEST_REFERENCE_ROOT_ENV = "CMUX_CI_HEAD_TEST_REFERENCE_ROOT"


def load_macos_job_test_references(
    root: Path = Path("."),
) -> Optional[tuple[frozenset[str], frozenset[str]]]:
    """Test references from the workflows under `root`, merged with the PR
    head's when HEAD_TEST_REFERENCE_ROOT_ENV is set. A path either side names
    in a macOS job stays macOS-relevant; a head read failure keeps the base."""
    references = _load_macos_job_test_references(root)
    head_root = os.environ.get(HEAD_TEST_REFERENCE_ROOT_ENV, "")
    if references is None or not head_root:
        return references
    head_references = _load_macos_job_test_references(Path(head_root))
    if head_references is None:
        return references
    return (
        references[0] | head_references[0],
        references[1] | head_references[1],
    )


def _load_macos_job_test_references(root: Path) -> Optional[tuple[frozenset[str], frozenset[str]]]:
    macos: set[str] = set()
    everywhere: set[str] = set()
    try:
        guard_entrypoint = (root / _CI_GUARD_ENTRYPOINT).read_text(encoding="utf-8")
        indirect_guard_references = frozenset(
            _TEST_REFERENCE_RE.findall(guard_entrypoint)
        )
        if not indirect_guard_references:
            return None
        for workflow_path in (CI_WORKFLOW_PATH, GUARD_WORKFLOW_PATH, WEB_WORKFLOW_PATH, MACOS_WORKFLOW_PATH):
            references = macos_job_test_references(
                (root / workflow_path).read_text(encoding="utf-8"),
                indirect_guard_references,
            )
            if references is None:
                return None
            workflow_macos, workflow_everywhere = references
            macos.update(workflow_macos)
            everywhere.update(workflow_everywhere)
    except OSError:
        return None
    return frozenset(macos), frozenset(everywhere)


def is_guard_only_test(path: str, references: Optional[tuple[frozenset[str], frozenset[str]]]) -> bool:
    # A tests/ file is macOS-neutral only when a CI workflow names it and every
    # job that names it runs on Linux. An unnamed file may be imported by a test a
    # macOS job runs, so it stays macOS-relevant.
    if references is None or not path.startswith("tests/"):
        return False
    macos, everywhere = references
    if path not in everywhere:
        return False
    return not any(path.startswith(reference) for reference in macos)


SHARED_WEB_WORKFLOW_EXACT = frozenset({
    "scripts/benchmark-diff-viewer.sh",
    "scripts/build-diff-sidecar.sh",
    "scripts/generate-diff-sidecar-types.sh",
    "scripts/install-rust-ci.sh",
    "scripts/run-diff-sidecar-cargo.sh",
    "Sources/Panels/CmuxDiffViewerURLSchemeHandler.swift",
    "Sources/Panels/DiffSidecarBridge.swift",
})

SHARED_WEB_WORKFLOW_PREFIXES = (
    "Native/DiffSidecar/",
    "Packages/macOS/CmuxBrowser/Sources/CmuxBrowser/DiffViewer/",
)


# Everything cli-pipe-regressions.yml runs besides the cmux-cli target's own
# compile inputs, which cli_target_inputs() reads from the Xcode project.
CLI_LANE_EXACT_INPUTS = frozenset({
    CLI_WORKFLOW_PATH,
    # Checked-out submodules: bonsplit is a local package of the project the
    # lane resolves, and ghostty supplies the GhosttyKit.xcframework binary
    # target that CmuxTerminalCore (in the cmux-cli closure) re-vends.
    "vendor/bonsplit",
    "ghostty",
    "scripts/download-prebuilt-ghosttykit.sh",
    "scripts/ghosttykit-checksums.txt",
    "scripts/validate-xcframework-archive.py",
    "scripts/select-ci-xcode.sh",
    "scripts/install-rust-ci.sh",
    # install-rust-ci.sh installs the toolchain this file names.
    "Native/DiffSidecar/rust-toolchain.toml",
    # .github/actions/cache-restore runs these two.
    "scripts/ci/r2-cache.sh",
    "scripts/ci/cache_restore_receipt.py",
    "scripts/ci/sanitize-xcode-source-packages-cache.py",
    # The regression scripts the lane runs, and what they import or read.
    "tests/test_cli_broken_pipe_writes.py",
    "tests/test_cli_socket_operation_deadline.py",
    "tests/test_cli_config_doctor.py",
    "tests/test_cli_glaeda_execution.py",
    "tests/fixtures/glaeda-external-request.json",
    "tests/fixtures/glaeda-external-result.json",
    "scripts/generate-cmux-config-schema.py",
    "web/data/cmux.schema.json",
    "skills/cmux-settings/scripts/cmux-settings",
})

CLI_LANE_INPUT_PREFIXES = (
    "CLI/",
    # The lane builds the cmux-cli scheme of this project and keys its package
    # cache on the project's Package.resolved.
    "cmux.xcodeproj/",
    ".github/actions/cache-restore/",
    # The lane runs `swift test` in this package directly.
    "Packages/macOS/CmuxFoundation/",
)

# ---------------------------------------------------------------------------
# swift-package-tests lane
#
# ci-macos.yml's swift-package-tests job already narrows which packages it
# builds, with scripts/ci/select_package_tests.py. This area answers the prior
# question the job cannot answer for itself: is the lane worth a macOS runner
# on this pull request at all? The answer is yes exactly when that same script
# would pick at least one package, so the two cannot disagree.
#
# Only paths that feed a package are offered to the selector. That is
# deliberate on both sides:
#
#   * select_package_tests.py fails open, so an unrecognized path (or an edit
#     to the lane's own workflow) selects all 33 packages. On main that is
#     right, because the lane is running regardless and only its list is in
#     question. Routing a pull request that way would be the 30-minute sweep
#     under another name: over the last 200 merged pull requests it would have
#     queued 34 full 33-package runs. Those changes keep their existing
#     coverage from the push to main.
#   * A package outside the job's own list selects nothing, so the lane would
#     start, check out submodules, and test zero packages. Asking the selector
#     instead of matching `Packages/` by prefix keeps those runs unqueued.
# ---------------------------------------------------------------------------

SWIFT_PACKAGE_ROOT_PREFIX = "Packages/"
# The job's package list, as a shell array inside its "Select package tests"
# step. Reading it here keeps one list rather than a copy that can drift.
_SWIFT_PACKAGE_JOB_LIST_RE = re.compile(
    r"(?m)^[ \t]*PACKAGES=\(\n(?P<body>(?:[ \t]*[A-Za-z0-9_]+\n)+)[ \t]*\)\n"
)


@lru_cache(maxsize=1)
def _select_package_tests() -> Optional[object]:
    """Import the package-test job's own selector, or None when unavailable."""
    directory = str(Path(__file__).resolve().parent)
    sys.path.insert(0, directory)
    try:
        import select_package_tests

        return select_package_tests
    except Exception as error:  # pragma: no cover - defensive
        print(f"Could not load the package-test selector: {error}", file=sys.stderr)
        return None
    finally:
        if sys.path and sys.path[0] == directory:
            sys.path.pop(0)


@lru_cache(maxsize=1)
def swift_package_test_packages() -> Optional[tuple[str, ...]]:
    """The packages ci-macos.yml's swift-package-tests job runs, in job order."""
    root = Path(__file__).resolve().parents[2]
    try:
        workflow = (root / MACOS_WORKFLOW_PATH).read_text(encoding="utf-8")
    except OSError as error:
        print(f"Could not read {MACOS_WORKFLOW_PATH}: {error}", file=sys.stderr)
        return None
    matches = _SWIFT_PACKAGE_JOB_LIST_RE.findall(workflow)
    if len(matches) != 1:
        print(
            f"Expected one PACKAGES=( ... ) list in {MACOS_WORKFLOW_PATH}, "
            f"found {len(matches)}",
            file=sys.stderr,
        )
        return None
    return tuple(dict.fromkeys(matches[0].split()))


def is_swift_package_input(path: str) -> bool:
    """True for a path that can feed a package's tests and nothing wider.

    The lane's global inputs (its workflow, the scripts its steps run, the
    pinned toolchain) are excluded on purpose: they make the selector pick
    every package, which is the sweep this routing exists to avoid.
    """
    select = _select_package_tests()
    return select is not None and select.is_routed_input(path, Path(__file__).resolve().parents[2])


def swift_package_test_selection(paths: Iterable[str]) -> tuple[str, ...]:
    """The job's packages that `paths` can affect, or () when none can."""
    candidates = [path for path in paths if is_swift_package_input(path)]
    if not candidates:
        return ()
    select = _select_package_tests()
    packages = swift_package_test_packages()
    if select is None or not packages:
        # The lane's own list is unreadable. Keep the existing behaviour
        # (unrouted on pull requests, full suite on main) rather than guess.
        return ()
    try:
        root = Path(__file__).resolve().parents[2]
        return tuple(select.select(root, list(packages), candidates))
    except (Exception, SystemExit) as error:
        print(f"Could not select package tests: {error}", file=sys.stderr)
        return ()


# The lane runs `python3 scripts/ci/<helper>.py`, which puts scripts/ci first
# on sys.path. A new scripts/ci module named like a stdlib module would shadow
# that import in the lane's helpers.
_STDLIB_MODULE_NAMES: Optional[frozenset[str]] = (
    frozenset(sys.stdlib_module_names) if hasattr(sys, "stdlib_module_names") else None
)


def shadows_cli_lane_import(path: str) -> bool:
    if not path.startswith("scripts/ci/"):
        return False
    name = path[len("scripts/ci/") :].split("/", 1)[0]
    if "/" not in path[len("scripts/ci/") :]:
        if not name.endswith(".py"):
            return False
        name = name[: -len(".py")]
    if _STDLIB_MODULE_NAMES is None:
        return True
    return name in _STDLIB_MODULE_NAMES


@dataclass(frozen=True)
class CliTargetInputs:
    """Compile inputs of the cmux-cli Xcode target outside CLI/."""

    package_directories: frozenset[str]
    source_file_names: frozenset[str]


def is_cli_change(
    path: str,
    cli_inputs: Optional[CliTargetInputs] = None,
    macos_ios_packages: Optional[frozenset[str]] = None,
) -> bool:
    if path in CLI_LANE_EXACT_INPUTS or path.startswith(CLI_LANE_INPUT_PREFIXES):
        return True
    if shadows_cli_lane_import(path):
        return True
    if cli_inputs is None:
        # The target graph could not be read: anything that could reach an
        # Xcode build keeps the lane, except CI implementation files the lane
        # never runs.
        if path.startswith("scripts/ci/") or is_other_workflow_config(path):
            return False
        return is_macos_change(path, macos_ios_packages)
    for directory in cli_inputs.package_directories:
        if path == directory or path.startswith(f"{directory}/"):
            # A package's test sources never reach the cmux-cli binary.
            # CmuxFoundation's tests, which the lane runs, matched above.
            return not path.startswith(f"{directory}/Tests/")
    return path.rsplit("/", 1)[-1] in cli_inputs.source_file_names


def is_web_change(path: str) -> bool:
    # The diff-sidecar validation lives in ci-web.yml even for native-only
    # inputs. Mark those inputs web-routed explicitly so ordinary macOS changes
    # do not need to wake the reusable web workflow.
    if path in SHARED_WEB_WORKFLOW_EXACT or path.startswith(SHARED_WEB_WORKFLOW_PREFIXES):
        return True
    if path.startswith(
        (
            "web/",
            "webviews/",
            "Resources/agent-session-react/",
            "Resources/agent-session-solid/",
            "Resources/markdown-viewer/",
            "config/",
            "workers/",
        )
    ):
        return True
    if path == "CHANGELOG.md":
        return True
    return path in {
        "package.json",
        "bun.lock",
        "biome.json",
        ".vercelignore",
        "vercel.json",
        "bunfig.toml",
        ".npmrc",
        ".github/workflows/web-validation.yml",
        "scripts/ci/web_validation.py",
        "tests/test_web_validation.py",
        "scripts/build-agent-session-web.sh",
        "scripts/build-webviews-app.sh",
        "scripts/check-webviews-react-compiler.mjs",
    }


def is_agent_session_web_change(path: str) -> bool:
    if path.startswith(
        (
            "webviews/src/agent-session/",
            "Resources/agent-session-react/",
            "Resources/agent-session-solid/",
        )
    ):
        return True
    return path in {
        "package.json",
        "bun.lock",
        "webviews/package.json",
        "webviews/bun.lock",
        "scripts/build-agent-session-web.sh",
        "Resources/markdown-viewer/marked.min.js",
    }


def _pbx_section(project: str, name: str) -> str:
    begin = f"/* Begin {name} section */"
    end = f"/* End {name} section */"
    if project.count(begin) != 1 or project.count(end) != 1:
        raise ValueError(f"expected one {name} section")
    start = project.index(begin) + len(begin)
    finish = project.index(end, start)
    return project[start:finish]


def _pbx_objects(section: str) -> dict[str, str]:
    objects: dict[str, str] = {}
    for match in _PBX_OBJECT_RE.finditer(section):
        identifier, body = match.groups()
        if identifier in objects:
            raise ValueError(f"duplicate pbx object {identifier}")
        objects[identifier] = body
    if not objects:
        raise ValueError("pbx section contained no readable objects")
    return objects


def _pbx_field(body: str, field: str, *, required: bool = True) -> Optional[str]:
    matches = re.findall(
        rf"(?:^|;)\s*{re.escape(field)}\s*=\s*([^;]+);",
        body,
        flags=re.MULTILINE,
    )
    if len(matches) > 1:
        raise ValueError(f"duplicate pbx field {field}")
    if not matches:
        if required:
            raise ValueError(f"missing pbx field {field}")
        return None
    value = matches[0].strip()
    if len(value) >= 2 and value[0] == value[-1] == '"':
        value = value[1:-1]
    return value


def _pbx_reference_id(value: str) -> str:
    match = re.fullmatch(r"([A-Za-z0-9]+)(?:\s+/\*[^*]*\*/)?", value.strip())
    if match is None:
        raise ValueError(f"unreadable pbx reference {value!r}")
    return match.group(1)


def _pbx_list_ids(body: str, field: str, *, required: bool = False) -> list[str]:
    matches = re.findall(
        rf"(?:^|;)\s*{re.escape(field)}\s*=\s*\(([\s\S]*?)\);",
        body,
        flags=re.MULTILINE,
    )
    if len(matches) > 1:
        raise ValueError(f"duplicate pbx list {field}")
    if not matches:
        if required:
            raise ValueError(f"missing pbx list {field}")
        if re.search(
            rf"(?:^|;)\s*{re.escape(field)}\s*=",
            body,
            flags=re.MULTILINE,
        ):
            raise ValueError(f"unreadable pbx list {field}")
        return []
    identifiers: list[str] = []
    for entry in matches[0].split(","):
        if not entry.strip():
            continue
        identifiers.append(_pbx_reference_id(entry))
    return identifiers


def _gitlink(root: Path, directory: str) -> bool:
    try:
        output = subprocess.check_output(
            ["git", "-C", str(root), "ls-files", "--stage", "--", directory],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError):
        return False
    for line in output.splitlines():
        metadata, separator, indexed_path = line.partition("\t")
        if separator and indexed_path == directory and metadata.split()[0] == "160000":
            return True
    return False


def _repository_relative_directory(root: Path, directory: str, label: str) -> str:
    repository = root.resolve()
    resolved = (root / directory).resolve()
    try:
        relative = resolved.relative_to(repository)
    except ValueError as error:
        raise ValueError(f"{label} escapes repository: {directory}") from error
    if not relative.parts:
        raise ValueError(f"{label} cannot be the repository root")
    return relative.as_posix()


def _package_manifest(root: Path, directory: str) -> Optional[str]:
    manifest = root / directory / "Package.swift"
    try:
        return manifest.read_text(encoding="utf-8")
    except OSError:
        if _gitlink(root, directory):
            # Gitlinks are external package inputs. The routing checkout does not
            # initialize them, and a Packages/iOS change cannot modify their tree.
            return None
        raise ValueError(f"missing package manifest: {directory}/Package.swift")


def _local_path_dependencies(root: Path, directory: str, manifest: str) -> set[str]:
    declarations = _LOCAL_PATH_DECLARATION_RE.findall(manifest)
    relative_paths = _LOCAL_PATH_DEPENDENCY_RE.findall(manifest)
    if len(declarations) != len(relative_paths):
        raise ValueError(f"could not parse every local dependency in {directory}/Package.swift")

    repository = root.resolve()
    dependencies: set[str] = set()
    for relative in relative_paths:
        resolved = (root / directory / relative).resolve()
        try:
            dependency = resolved.relative_to(repository).as_posix()
        except ValueError as error:
            raise ValueError(
                f"local dependency escapes repository: {directory} -> {relative}"
            ) from error
        dependencies.add(dependency)
    return dependencies


def _native_target(project: str, target_name: str) -> tuple[dict[str, str], str]:
    native_targets = _pbx_objects(_pbx_section(project, "PBXNativeTarget"))
    roots = [
        identifier
        for identifier, body in native_targets.items()
        if _pbx_field(body, "name") == target_name
    ]
    if len(roots) != 1:
        raise ValueError(f"expected one {target_name} native target")
    return native_targets, roots[0]


def _reachable_target_products(project: str, target_name: str = MACOS_PRODUCT_TARGET) -> list[str]:
    native_targets, root = _native_target(project, target_name)
    roots = [root]

    target_dependencies: dict[str, str] = {}
    dependency_ids = {
        dependency
        for body in native_targets.values()
        for dependency in _pbx_list_ids(body, "dependencies")
    }
    if dependency_ids:
        dependency_objects = _pbx_objects(_pbx_section(project, "PBXTargetDependency"))
        for identifier in dependency_ids:
            body = dependency_objects.get(identifier)
            if body is None:
                raise ValueError(f"missing target dependency {identifier}")
            target = _pbx_reference_id(_pbx_field(body, "target"))
            if target not in native_targets:
                raise ValueError(f"target dependency {identifier} has no local native target")
            target_dependencies[identifier] = target

    products: list[str] = []
    visited: set[str] = set()
    pending = roots[:]
    while pending:
        target = pending.pop()
        if target in visited:
            continue
        visited.add(target)
        body = native_targets[target]
        products.extend(_pbx_list_ids(body, "packageProductDependencies"))
        for dependency in _pbx_list_ids(body, "dependencies"):
            target = target_dependencies.get(dependency)
            if target is None:
                raise ValueError(f"unresolved target dependency {dependency}")
            pending.append(target)
    if not products:
        raise ValueError(f"{target_name} target reaches no package products")
    return products


def macos_ios_package_closure(root: Path) -> frozenset[str]:
    """Return Packages/iOS package directories reachable by the macOS product.

    Xcode's cmux target (plus native targets it depends on) supplies the local
    Swift-package roots. Package.swift path dependencies supply every transitive
    edge. Anything the lightweight parsers cannot prove is rejected so the
    caller can keep conservative macOS routing.
    """
    return frozenset(
        directory
        for directory in local_package_closure(root, MACOS_PRODUCT_TARGET)
        if directory.startswith("Packages/iOS/")
    )


def local_package_closure(root: Path, target_name: str) -> frozenset[str]:
    """Return every local package directory `target_name` can compile."""
    project_path = root / MACOS_XCODE_PROJECT_PATH
    project = project_path.read_text(encoding="utf-8")

    local_references = _pbx_objects(_pbx_section(project, "XCLocalSwiftPackageReference"))
    local_paths = {
        identifier: _repository_relative_directory(
            root,
            _pbx_field(body, "relativePath"),
            "Xcode local package path",
        )
        for identifier, body in local_references.items()
    }
    product_dependencies = _pbx_objects(
        _pbx_section(project, "XCSwiftPackageProductDependency")
    )

    explicit_roots: set[str] = set()
    unowned_products: set[str] = set()
    for identifier in _reachable_target_products(project, target_name):
        body = product_dependencies.get(identifier)
        if body is None:
            raise ValueError(f"missing package product dependency {identifier}")
        product_name = _pbx_field(body, "productName")
        package_reference = _pbx_field(body, "package", required=False)
        if package_reference is None:
            unowned_products.add(product_name)
            continue
        package_path = local_paths.get(_pbx_reference_id(package_reference))
        if package_path is None:
            # The product belongs to an XCRemoteSwiftPackageReference.
            continue
        explicit_roots.add(package_path)

    manifests: dict[str, Optional[str]] = {}

    # Some hand-maintained Xcode product entries omit their package reference.
    # Resolve those from the manifests of Xcode's local package references.
    # Zero or multiple owners means the graph is ambiguous and must fail open.
    local_package_paths = set(local_paths.values())
    for product_name in unowned_products:
        owners: list[str] = []
        for directory in local_package_paths:
            if directory not in manifests:
                manifests[directory] = _package_manifest(root, directory)
            manifest = manifests[directory]
            if manifest is not None and product_name in _PACKAGE_PRODUCT_RE.findall(manifest):
                owners.append(directory)
        if len(owners) != 1:
            raise ValueError(
                f"could not uniquely resolve package product {product_name!r}: {owners}"
            )
        explicit_roots.add(owners[0])

    if not explicit_roots:
        raise ValueError(f"{target_name} target has no readable local package roots")

    visited: set[str] = set()
    pending = list(explicit_roots)
    while pending:
        directory = pending.pop()
        if directory in visited:
            continue
        visited.add(directory)
        if directory not in manifests:
            manifests[directory] = _package_manifest(root, directory)
        manifest = manifests[directory]
        if manifest is None:
            continue
        for dependency in _local_path_dependencies(root, directory, manifest):
            if dependency not in visited:
                pending.append(dependency)

    return frozenset(visited)


_PBX_FLAT_OBJECT_RE = re.compile(
    # An Xcode object identifier: at least eight characters and, unlike the
    # lowerCamelCase field names of a nested dictionary, never lowercase first.
    r"(?<![A-Za-z0-9])([A-Z0-9][A-Za-z0-9]{7,})(?:\s+/\*[^*]*\*/)?\s*=\s*\{([^{}]*)\};"
)


def _pbx_flat_objects(project: str) -> dict[str, str]:
    """Index every brace-free pbx object by identifier.

    Build phases, build files and file references hold no nested dictionary, so
    one pass indexes them all. The Sources build phase section has no End
    marker in this project and some lines hold two build files, so this does
    not go through _pbx_section. A repeated identifier is unreadable input.
    """
    objects: dict[str, str] = {}
    for identifier, body in _PBX_FLAT_OBJECT_RE.findall(project):
        if identifier in objects:
            raise ValueError(f"duplicate pbx object {identifier}")
        objects[identifier] = body
    if not objects:
        raise ValueError("project file contained no readable objects")
    return objects


def _flat_object(objects: dict[str, str], identifier: str) -> str:
    body = objects.get(identifier)
    if body is None:
        raise ValueError(f"missing pbx object {identifier}")
    return body


def cli_target_inputs(root: Path) -> CliTargetInputs:
    """Read the cmux-cli target's compiled file names and package closure.

    Files outside CLI/ that the target compiles (shared Sources/ helpers) are
    matched by file name; Swift requires those to be unique within the module.
    """
    project = (root / MACOS_XCODE_PROJECT_PATH).read_text(encoding="utf-8")
    native_targets, target = _native_target(project, CLI_PRODUCT_TARGET)
    if _pbx_list_ids(native_targets[target], "dependencies"):
        raise ValueError(f"{CLI_PRODUCT_TARGET} gained target dependencies")
    objects = _pbx_flat_objects(project)
    names: set[str] = set()
    for phase_id in _pbx_list_ids(native_targets[target], "buildPhases", required=True):
        phase = _flat_object(objects, phase_id)
        kind = _pbx_field(phase, "isa")
        if kind == "PBXFrameworksBuildPhase":
            # Frameworks come from packageProductDependencies, read below.
            continue
        if kind != "PBXSourcesBuildPhase":
            raise ValueError(f"{CLI_PRODUCT_TARGET} has an unrouted {kind}")
        for build_file in _pbx_list_ids(phase, "files"):
            reference = _pbx_reference_id(
                _pbx_field(_flat_object(objects, build_file), "fileRef")
            )
            file_path = _pbx_field(_flat_object(objects, reference), "path")
            names.add(file_path.rsplit("/", 1)[-1])
    if not names:
        raise ValueError(f"{CLI_PRODUCT_TARGET} compiles no sources")
    return CliTargetInputs(
        package_directories=local_package_closure(root, CLI_PRODUCT_TARGET),
        source_file_names=frozenset(names),
    )


@lru_cache(maxsize=1)
def load_cli_target_inputs() -> Optional[CliTargetInputs]:
    root = Path(__file__).resolve().parents[2]
    try:
        return cli_target_inputs(root)
    except Exception as error:
        print(
            "Could not derive the cmux-cli target inputs; routing every "
            f"macOS-relevant change to the CLI lane: {error}",
            file=sys.stderr,
        )
        return None


@lru_cache(maxsize=1)
def load_macos_ios_package_closure() -> Optional[frozenset[str]]:
    root = Path(__file__).resolve().parents[2]
    try:
        return macos_ios_package_closure(root)
    except Exception as error:
        print(
            "Could not derive macOS local-package dependency closure; "
            f"keeping Packages/iOS macOS-relevant: {error}",
            file=sys.stderr,
        )
        return None


def is_macos_neutral(
    path: str,
    macos_ios_packages: Optional[frozenset[str]],
) -> bool:
    if path in CI_CONTROL_PLANE_ONLY or path in CI_PUBLISHING_ONLY:
        return True
    # Review configuration is not a build input. Keep this exact: unknown
    # policy files retain native coverage, and Linux guards still validate PRs.
    if path in {
        ".coderabbit.yaml",
        ".greptile/rules.md",
        ".github/review-bot-rules/user-facing-errors.md",
    }:
        return True
    # Backend/deploy inputs are covered by required web CI and never enter the
    # desktop Xcode product. Keep the root config carveout narrow because
    # config/IrohRelayPolicyProduction.xcconfig is a real macOS build input.
    if path.startswith(("workers/", "config/iroh/")) or path in {
        ".vercelignore",
        "vercel.json",
    }:
        return True
    # CLI/ is a standalone Xcode tool target with a dedicated required lane.
    # App/shared source remains routed through app-host macOS CI.
    if path.startswith("CLI/"):
        return True
    # Keep current-main's guaranteed iOS-only test carveouts even if the
    # package graph cannot be parsed and the broader router fails open.
    if path.startswith((
        "Packages/iOS/CmuxMobileShellUI/Tests/",
        "Packages/iOS/CmuxMobileShell/Tests/",
    )):
        return True
    # Agent instructions at any depth, and skill documentation. The app bundles
    # skills/cmux-cua as a folder resource, and skill scripts and manifests are
    # executable inputs, so only Markdown outside that folder is neutral.
    if path.rsplit("/", 1)[-1] in {"CLAUDE.md", "AGENTS.md"}:
        return True

    if (
        path.startswith("Packages/iOS/")
        and macos_ios_packages is not None
        and not any(
            path == package or path.startswith(f"{package}/")
            for package in macos_ios_packages
        )
    ):
        return True

    # `cmux-tui/` is the standalone cmux-tui Rust project, gated by its own
    # workflow. Packages/iOS is decided above from the desktop package graph;
    # an unknown graph deliberately falls through as macOS-relevant.
    if path.startswith(
        (
            "docs/",
            "design/",
            "plans/",
            "ios/",
            "web/",
            "webviews/",
            "cmux-tui/",
            "cmux-browser/",
            "daemon/remote/",
        )
    ):
        return True
    if path == "README.md" or (path.startswith("README.") and path.endswith(".md")):
        return True
    return path.startswith("skills/") and path.endswith(".md") and not path.startswith("skills/cmux-cua/")


def is_macos_change(
    path: str,
    macos_ios_packages: Optional[frozenset[str]],
) -> bool:
    if path.startswith("webviews/src/agent-session/"):
        return True
    if path == "docs/cli-contract.md":
        return True
    if path in {"package.json", "bun.lock", "biome.json"}:
        return True
    if path.startswith(("Resources/agent-session-react/", "Resources/agent-session-solid/")):
        return True
    return not is_macos_neutral(path, macos_ios_packages)


_PACKAGE_TESTS_RE = re.compile(r"Packages/[^/]+/[^/]+/Tests/")


def is_test_only_source(path: str) -> bool:
    # The Release app builds only the cmux target, so test sources cannot reach
    # it. A new test file also edits project.pbxproj, which is not matched here.
    return path.startswith(("cmuxTests/", "cmuxUITests/")) or bool(_PACKAGE_TESTS_RE.match(path))


RELEASE_BUILD_NEUTRAL_INPUTS = frozenset({
    # Runtime script contents are copied into the app bundle; changing them does
    # not exercise Swift/Release compilation. Their focused regression suite is
    # the useful signal, so avoid paying for a universal app build.
    "Resources/bin/open",
    "tests/test_open_wrapper.py",
})


def is_release_build_neutral(path: str) -> bool:
    return is_test_only_source(path) or path in RELEASE_BUILD_NEUTRAL_INPUTS


def test_registry_change_is_linux_only(base: str, head: str) -> bool:
    """Ignore only Linux registrations; native execution entries must match."""
    try:
        import tomllib

        def native_entries(text: str) -> list[dict]:
            registry = tomllib.loads(text)
            if set(registry) != {"version", "test"} or registry["version"] != 1:
                raise ValueError("unknown registry schema")
            entries = registry["test"]
            if not isinstance(entries, list) or not entries:
                raise ValueError("missing test entries")
            seen = set()
            native = []
            for entry in entries:
                if not isinstance(entry, dict) or set(entry) - {"path", "lane", "requirements", "reason"}:
                    raise ValueError("unknown test entry")
                path, lane = entry.get("path"), entry.get("lane")
                if not isinstance(path, str) or not isinstance(lane, str) or path in seen:
                    raise ValueError("missing or duplicate test identity")
                seen.add(path)
                if lane != "linux-guard":
                    native.append(entry)
                elif entry.get("requirements"):
                    raise ValueError("guard entry with runtime requirements")
            return native

        return native_entries(base) == native_entries(head)
    except (ImportError, ValueError, TypeError, KeyError):
        return False


def test_registry_linux_only(base_path: Optional[Path]) -> bool:
    if base_path is None:
        return False
    root = Path(os.environ.get("CMUX_CI_HEAD_TEST_REFERENCE_ROOT") or Path.cwd())
    try:
        return test_registry_change_is_linux_only(
            base_path.read_text(encoding="utf-8"),
            (root / "tests/test-execution.toml").read_text(encoding="utf-8"),
        )
    except OSError:
        return False


def classify_files(paths: Iterable[str], *, ci_workflow_linux_only: bool = False,
                   test_registry_linux_only: bool = False) -> ChangeAreas:
    macos = False
    web = False
    agent_session_web = False
    cli = False
    release_build = False
    # Collected across the diff: the lane is selected from the whole change,
    # not path by path, because the selector resolves package dependencies.
    swift_package_candidates: list[str] = []
    test_references = load_macos_job_test_references()
    macos_ios_packages = load_macos_ios_package_closure()
    cli_inputs = load_cli_target_inputs()

    for raw_path in paths:
        path = normalize_path(raw_path)
        if not path:
            continue
        if path == "tests/test-execution.toml":
            # The guard workflow references this registry too, but native
            # Python lanes consume it indirectly through their lane runner.
            # A Linux reference alone cannot prove native execution unchanged.
            if not test_registry_linux_only:
                macos = True
                release_build = True
            continue
        if is_cli_change(path, cli_inputs, macos_ios_packages):
            cli = True
        if path == CI_WORKFLOW_PATH and ci_workflow_linux_only:
            continue
        # Before every `continue` below: a package source or test selects the
        # package-test lane even when the path is otherwise macOS-neutral (a
        # Packages/iOS package outside the desktop closure) or test-only.
        if is_swift_package_input(path):
            swift_package_candidates.append(path)
        if forces_all_areas(path):
            macos = True
            web = True
            agent_session_web = True
            release_build = True
            # ci.yml calls the CLI lane. An unowned scripts/ci helper cannot
            # reach it: is_cli_change() above already routed the helpers the
            # lane runs and any module that could shadow their imports.
            if path == CI_WORKFLOW_PATH:
                cli = True
            continue
        if path in CI_MACOS_ADMISSION_CONTROL_INPUTS:
            # These helpers decide whether compile admission is required.
            # Exercise the macOS admission path and its Linux contracts, but
            # they cannot affect web or Release app bytes.
            macos = True
            continue
        if path in CI_MACOS_TEST_PRODUCT_INPUTS:
            # These helpers own the reusable Debug/test product and its
            # admission/restore contract. Exercise macOS admission/consumption,
            # but they cannot affect the web deployment or Release app bytes.
            macos = True
            continue
        if path == MACOS_WORKFLOW_PATH:
            # A reusable macOS workflow edit must exercise every hosted Mac job
            # body it owns, including the Release check.
            macos = True
            release_build = True
            continue
        if path == WEB_WORKFLOW_PATH:
            # A reusable web workflow edit must exercise every job body it owns.
            web = True
            agent_session_web = True
            continue
        # Web validation's own inputs still select its checks in CI, even when
        # the path is a workflow or guard that is neutral for macOS.
        if is_web_change(path):
            web = True
        if is_other_workflow_config(path) or is_guard_only_test(path, test_references):
            continue
        if is_agent_session_web_change(path):
            agent_session_web = True
        if is_macos_change(path, macos_ios_packages):
            macos = True
            if not is_release_build_neutral(path):
                release_build = True

    return ChangeAreas(
        macos=macos,
        web=web,
        agent_session_web=agent_session_web,
        cli=cli,
        swift_packages=bool(swift_package_test_selection(swift_package_candidates)),
        release_build=release_build,
    )


def ci_workflow_linux_only(base_path: Optional[Path]) -> bool:
    if base_path is None:
        return False
    try:
        base = base_path.read_text(encoding="utf-8")
        head = Path(CI_WORKFLOW_PATH).read_text(encoding="utf-8")
    except OSError:
        return False
    linux_only = ci_workflow_change_is_linux_only(base, head)
    print(f"ci.yml changed; only Linux jobs differ: {bool_output(linux_only)}")
    return linux_only


def run_git(args: list[str]) -> str:
    return subprocess.check_output(["git", *args], text=True, stderr=subprocess.STDOUT).strip()


def changed_files(base_sha: str, head_sha: str) -> list[str]:
    merge_base = run_git(["merge-base", base_sha, head_sha])
    output = run_git(["diff", "--name-only", merge_base, head_sha])
    return [line for line in output.splitlines() if line.strip()]


def write_outputs(areas: ChangeAreas, output_path: Optional[str]) -> None:
    if not output_path:
        return
    with Path(output_path).open("a", encoding="utf-8") as handle:
        for line in areas.as_output_lines():
            handle.write(f"{line}\n")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event-name", default=os.environ.get("GITHUB_EVENT_NAME", ""))
    parser.add_argument("--base-sha", default="")
    parser.add_argument("--head-sha", default="")
    parser.add_argument(
        "--github-output",
        default=os.environ.get("GITHUB_OUTPUT"),
        help="Path to append GitHub Actions step outputs to.",
    )
    parser.add_argument(
        "--ci-workflow-base",
        type=Path,
        help="The base revision of ci.yml, to compare its jobs with the checked-out one.",
    )
    parser.add_argument(
        "--test-registry-base",
        type=Path,
        help="Base test registry; Linux-only entry changes do not select native CI.",
    )
    parser.add_argument(
        "--files-from",
        type=Path,
        help="Read changed files from this newline-delimited file instead of git.",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)

    if args.event_name not in {"pull_request", "merge_group"}:
        areas = ChangeAreas.all()
        print(f"Non-PR event '{args.event_name or 'unknown'}'; running all CI areas.")
        write_outputs(areas, args.github_output)
        print("Resolved areas: " + " ".join(areas.as_output_lines()))
        return 0

    files: list[str] = []
    try:
        if args.files_from:
            files = args.files_from.read_text(encoding="utf-8").splitlines()
        else:
            if not args.base_sha or not args.head_sha:
                raise RuntimeError("pull_request event is missing base/head SHA")
            files = changed_files(args.base_sha, args.head_sha)
        if files:
            areas = classify_files(
                files,
                ci_workflow_linux_only=ci_workflow_linux_only(args.ci_workflow_base),
                test_registry_linux_only=test_registry_linux_only(args.test_registry_base),
            )
        else:
            areas = ChangeAreas.all()
            print("PR diff is empty; running all CI areas.")
    except Exception as error:
        areas = ChangeAreas.all()
        print(f"Could not classify diff, running all CI areas: {error}", file=sys.stderr)

    if files:
        print("Changed files:")
        for path in files:
            print(path)
    else:
        print("Changed files: (none)")

    write_outputs(areas, args.github_output)
    print("Resolved areas: " + " ".join(areas.as_output_lines()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
