#!/usr/bin/env python3
"""Decide whether changed paths can alter the app the Nightly publishes.

`detect_ci_change_areas` already answers "can this path change Release app
bytes" for pull requests, including the carve-outs that are easy to get wrong:
the app bundles `skills/cmux-cua` as a folder resource, so skill Markdown
outside that folder is neutral while everything inside it is a build input.
Reusing that classifier keeps one definition of an app build input.

The pull-request question is narrower than this one, though: `release_build`
asks whether a change needs a Release *compile*, and the router excuses paths
that ship in the bundle without being compiled -- `CLI/`, whose product is
copied into the app, and the `Resources/bin` scripts -- because a dedicated
lane covers each. So the bundled paths are read back out of the Xcode project
here rather than listed by hand, and a new bundled resource cannot become
skippable by being added somewhere this file does not know about.

The Nightly also does work no pull-request lane does. It signs, prebuilds
Sparkle deltas, generates the appcast, and publishes, so every path its own
workflow runs is an input. It bundles a cmux-tui client chosen by the commits
`scripts/ci/resolve-cmux-tui-client-commit.sh` looks at, and publishes remote
daemon assets built from `daemon/remote`. In the other direction the Nightly
resolves its own jobs, so pull-request CI configuration it never reads cannot
change what it ships.

Anything this script cannot classify counts as changed, so the Nightly builds.
"""

from __future__ import annotations

import argparse
import contextlib
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import detect_ci_change_areas as detect  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
NIGHTLY_WORKFLOW_PATH = ".github/workflows/nightly.yml"

# Repository paths named by the workflow: `scripts/sign-cmux-bundle.sh`,
# `./.github/actions/cache-restore`, `python3 scripts/ci/upload-r2-object.py`.
_REFERENCED_PATH_RE = re.compile(
    r"(?<![\w.-])\.?/?((?:scripts|\.github/(?:actions|scripts|workflows))"
    r"/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*)"
)


# scripts/build_remote_daemon_release_assets.sh builds the remote daemon assets
# published beside the app from this tree. No pull-request macOS lane builds
# them, which is why the router calls the sources neutral.
NIGHTLY_SHIPPED_SOURCES = ("daemon/remote/",)

TUI_CLIENT_RESOLVER = "scripts/ci/resolve-cmux-tui-client-commit.sh"
_TUI_CLIENT_PATHS_RE = re.compile(r"^PATHS=\(([^)]*)\)", re.MULTILINE)


def nightly_workflow_inputs(root: Path) -> frozenset[str]:
    """Every repository path the Nightly workflow runs.

    Derived from the workflow text so that adding a step cannot silently leave
    its script invisible to this gate. Publishing helpers the workflow reaches
    indirectly -- the appcast script runs the delta prebuilder -- come from the
    classifier's own publishing-only set.
    """
    text = (root / NIGHTLY_WORKFLOW_PATH).read_text(encoding="utf-8")
    referenced = {match.group(1).rstrip("/") for match in _REFERENCED_PATH_RE.finditer(text)}
    return frozenset({NIGHTLY_WORKFLOW_PATH, *referenced, *detect.CI_PUBLISHING_ONLY})


def bundled_paths(root: Path) -> frozenset[str]:
    """Repository paths the cmux target copies into the app bundle.

    Read from the Xcode project, because the pull-request router excuses some
    of these: it asks whether a Release compile is needed, and a script copied
    into the bundle compiles nothing. Covers the resource and copy-files
    phases, which is where `skills/cmux-cua`, `Resources/bin/*` and
    `scripts/setup-pam-tid.sh` enter the app.
    """
    project = (root / detect.MACOS_XCODE_PROJECT_PATH).read_text(encoding="utf-8")
    native_targets, target = detect._native_target(project, detect.MACOS_PRODUCT_TARGET)
    # Read the two bundling phases by section. The target also holds shell
    # script phases, whose bodies are not brace-free, so the flat index used
    # elsewhere cannot resolve every one of its phase identifiers.
    phases: dict[str, str] = {}
    for section in ("PBXCopyFilesBuildPhase", "PBXResourcesBuildPhase"):
        phases.update(detect._pbx_objects(detect._pbx_section(project, section)))
    build_files = detect._pbx_objects(detect._pbx_section(project, "PBXBuildFile"))
    references = detect._pbx_objects(detect._pbx_section(project, "PBXFileReference"))
    paths: set[str] = set()
    for phase_id in detect._pbx_list_ids(
        native_targets[target], "buildPhases", required=True
    ):
        phase = phases.get(phase_id)
        if phase is None:
            continue
        for build_file_id in detect._pbx_list_ids(phase, "files"):
            reference_id = detect._pbx_reference_id(
                detect._pbx_field(build_files[build_file_id], "fileRef")
            )
            reference = references.get(reference_id)
            if reference is None:
                # A reference from a group or a synchronized folder, which is
                # under Sources/ or Resources/ and never neutral anyway.
                continue
            if detect._pbx_field(reference, "sourceTree") != "SOURCE_ROOT":
                continue
            paths.add(detect.normalize_path(detect._pbx_field(reference, "path")))
    if not paths:
        raise ValueError("the cmux target bundles no repository path")
    return frozenset(paths)


def tui_client_paths(root: Path) -> frozenset[str]:
    """Paths that select which cmux-tui client the Nightly bundles.

    The resolver publishes a client per commit touching these, and the Nightly
    installs the newest one into cmux.app, so a change to any of them changes
    what ships even when the app itself is untouched.
    """
    text = (root / TUI_CLIENT_RESOLVER).read_text(encoding="utf-8")
    match = _TUI_CLIENT_PATHS_RE.search(text)
    if match is None:
        raise ValueError(f"{TUI_CLIENT_RESOLVER} no longer declares PATHS")
    paths = frozenset(
        detect.normalize_path(entry.strip().strip('"\''))
        for entry in match.group(1).split()
        if entry.strip()
    )
    if not paths:
        raise ValueError(f"{TUI_CLIENT_RESOLVER} declares an empty PATHS")
    return paths


def runs_in_nightly(path: str, nightly_inputs: frozenset[str]) -> bool:
    # `.github/actions/cache-restore` is a directory reference; its action.yml
    # and any helper beside it are the same input.
    return any(path == entry or path.startswith(f"{entry}/") for entry in nightly_inputs)


def is_pull_request_ci_config(path: str) -> bool:
    """Configuration that only selects pull-request work.

    The Nightly resolves its own jobs and reads none of these files. Reached
    only after the workflow, bundled and client-selecting paths above, which is
    where the workflow files the Nightly does depend on are matched -- its own,
    and the two that decide which cmux-tui client it installs.
    """
    return path == detect.CI_WORKFLOW_PATH or detect.is_other_workflow_config(path)


def _reaches_the_app(areas: detect.ChangeAreas) -> bool:
    return areas.release_build or areas.cli


def build_inputs_changed(paths: list[str], root: Path = ROOT) -> tuple[bool, str]:
    """Return whether the Nightly must build, and the reason to report."""
    nightly_inputs = nightly_workflow_inputs(root)
    bundled = bundled_paths(root)
    tui_client = tui_client_paths(root)
    candidates: list[str] = []
    for raw_path in paths:
        path = detect.normalize_path(raw_path)
        if not path:
            continue
        if runs_in_nightly(path, nightly_inputs):
            return True, f"{path} runs in the Nightly workflow"
        if runs_in_nightly(path, bundled):
            return True, f"{path} is copied into the app the Nightly publishes"
        if runs_in_nightly(path, tui_client):
            return True, f"{path} selects the cmux-tui client the Nightly bundles"
        if path.startswith(NIGHTLY_SHIPPED_SOURCES):
            return True, f"{path} is built into what the Nightly publishes"
        if is_pull_request_ci_config(path):
            continue
        candidates.append(path)
    if not candidates:
        return False, "only pull-request CI configuration changed"
    # `cli` covers the cmux-cli target, whose product the cmux target copies
    # into the bundle; a CLI-only change ships without needing a Release
    # compile, which is the only thing `release_build` answers.
    if not _reaches_the_app(detect.classify_files(candidates)):
        return False, "no changed path reaches the app the Nightly publishes"
    named = next(
        (path for path in candidates if _reaches_the_app(detect.classify_files([path]))),
        None,
    )
    return True, f"{named} reaches the app the Nightly publishes" if named else (
        "a changed path reaches the app the Nightly publishes"
    )


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--files-from",
        default="-",
        help="Newline-delimited changed paths; `-` reads standard input.",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        text = sys.stdin.read() if args.files_from == "-" else Path(args.files_from).read_text(encoding="utf-8")
        paths = [line for line in text.splitlines() if line.strip()]
        if not paths:
            raise ValueError("no changed paths to classify")
        # The classifier narrates its routing on stdout; keep stdout to the
        # machine-readable result its caller parses.
        with contextlib.redirect_stdout(sys.stderr):
            changed, reason = build_inputs_changed(paths)
    except Exception as error:  # noqa: BLE001 - an unclassifiable change must build
        changed, reason = True, f"could not classify the change: {error}"
    print(reason, file=sys.stderr)
    print(json.dumps({"build_inputs_changed": changed, "reason": reason}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
