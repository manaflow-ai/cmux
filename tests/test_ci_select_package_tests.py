#!/usr/bin/env python3
"""scripts/ci/select_package_tests.py picks every package a change can affect, and no more."""

from __future__ import annotations

import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

from select_package_tests import GLOBAL_INPUTS, select  # noqa: E402

PACKAGES = ["Base", "Middle", "Top", "Loner", "Palette", "Splitter"]


def manifest(*paths: str) -> str:
    deps = "".join(f'        .package(path: "{path}"),\n' for path in paths)
    return f"let package = Package(\n    dependencies: [\n{deps}    ]\n)\n"


def fixture(root: Path) -> None:
    layout = {
        "Packages/macOS/Base": manifest(),
        "Packages/macOS/Middle": manifest("../Base"),
        "Packages/Shared/Top": manifest("../../macOS/Middle"),
        "Packages/macOS/Loner": manifest(),
        "Packages/macOS/CmuxCommandPalette": manifest(),
        "Packages/macOS/Palette": manifest("../CmuxCommandPalette"),
        "Packages/macOS/Splitter": manifest("../../../vendor/bonsplit"),
    }
    for directory, text in layout.items():
        (root / directory).mkdir(parents=True)
        (root / directory / "Package.swift").write_text(text, encoding="utf-8")
    (root / "vendor/bonsplit").mkdir(parents=True)
    (root / "vendor/bonsplit/Package.swift").write_text(manifest(), encoding="utf-8")


def check(root: Path, changed: list[str] | None, expected: list[str], why: str) -> None:
    actual = select(root, PACKAGES, changed)
    assert actual == expected, f"{why}: expected {expected}, got {actual}"


def job_scripts() -> set[str]:
    """Scripts the swift-package-tests job runs, plus the helpers those scripts call beside them."""
    workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
    job = workflow.split("\n  swift-package-tests:\n", 1)[1]
    job = re.split(r"\n  [A-Za-z0-9_-]+:\n", job, maxsplit=1)[0]
    found = set(re.findall(r"(?:\./)?(scripts/[A-Za-z0-9_./-]+\.(?:sh|py))", job))
    pending = list(found)
    while pending:
        script = ROOT / pending.pop()
        if not script.is_file():
            continue
        for name in re.findall(r"\$script_dir/([A-Za-z0-9_.-]+\.(?:sh|py))", script.read_text(encoding="utf-8")):
            sibling = str((script.parent / name).relative_to(ROOT))
            if sibling not in found:
                found.add(sibling)
                pending.append(sibling)
    return found


def main() -> int:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        fixture(root)
        check(root, None, PACKAGES, "an unknown diff runs everything")
        check(root, [], [], "an empty diff runs nothing")
        check(root, ["Sources/App.swift", "cmuxTests/AppTests.swift", "web/app/page.tsx", "README.md"], [],
              "app, web and docs changes reach no package")
        check(root, [
            "cmux.xcodeproj/project.pbxproj",
            "cmuxTests/RemoteTmuxInputCommandCapture.swift",
            "cmuxTests/RemoteTmuxInputCommandCaptureTests.swift",
            "cmuxTests/RemoteTmuxMirrorPaneInputMappingTests.swift",
        ], [], "app-host-only test and target-wiring changes reach no package")
        check(root, ["scripts/ci/run_with_timeout.py"], PACKAGES,
              "the transitive suite timeout runner is an input of package tests")
        check(root, ["Packages/macOS/Loner/Sources/Loner/A.swift"], ["Loner"], "a leaf change runs that package")
        check(root, ["Packages/macOS/Base/Sources/Base/A.swift"], ["Base", "Middle", "Top"],
              "a change runs every transitive dependent, across group folders")
        check(root, ["Packages/macOS/Middle/Tests/MiddleTests/T.swift"], ["Middle", "Top"],
              "dependents follow the changed package, not its dependencies")
        check(root, ["vendor/bonsplit/Sources/Bonsplit/A.swift"], ["Splitter"],
              "a path dependency outside Packages/ counts")
        check(root, ["vendor/bonsplit"], ["Splitter"], "a submodule revision bump is the bare directory path")
        check(root, ["Native/CommandPaletteNucleoFFI/src/lib.rs"], ["Palette"],
              "an extra input reaches the packages that depend on its owner")
        check(root, ["Packages/macOS/Unlisted/Sources/A.swift"], [], "a package outside the list selects nothing")
        check(root, [".github/workflows/ci.yml"], PACKAGES, "the job's own workflow runs everything")
        check(root, [".github/workflows/nightly.yml", "scripts/reload.sh"], [], "other workflows and scripts run nothing")
        check(root, ["ghostty"], PACKAGES, "the GhosttyKit revision runs everything")
        check(root, ["Loner.swift", "Sources/App.swift"], PACKAGES, "an unknown path runs everything")

        try:
            select(root, ["Missing"], [])
        except SystemExit:
            pass
        else:
            raise AssertionError("a listed package that does not exist must fail")

    # Every package the workflow lists must exist, or the job fails before testing anything.
    workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
    listed = workflow.split("          PACKAGES=(\n", 1)[1].split("          )\n", 1)[0].split()
    assert len(listed) == len(set(listed)), "PACKAGES lists a package twice"
    result = subprocess.run(
        [sys.executable, str(ROOT / "scripts/ci/select_package_tests.py"), "--root", str(ROOT), *listed],
        capture_output=True, text=True, check=False,
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout.split() == listed, "without a diff the script must print every listed package in order"

    select_step = workflow.split("      - name: Select package tests\n", 1)[1].split("      - name:", 1)[0]
    assert "git diff --no-renames --name-only HEAD^1 HEAD" in select_step, "a move out of a package must list the old path"
    assert "'^vendor/bonsplit(/|$)'" in select_step, "a Bonsplit submodule bump must run the Bonsplit tests"

    # A change to any script the job runs can break every package's tests, so
    # each one must force the full set.
    missing = sorted(job_scripts() - set(GLOBAL_INPUTS))
    if missing:
        print(f"FAIL: scripts the package test job runs are not global inputs: {missing}")
        return 1

    print("PASS: package test selection follows path dependencies and fails safe")
    return 0


if __name__ == "__main__":
    sys.exit(main())
