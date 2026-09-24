#!/usr/bin/env python3
"""scripts/ci/select_package_tests.py picks every package a change can affect, and no more."""

from __future__ import annotations

import re
import os
import json
import shutil
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
    workflow = (ROOT / ".github/workflows/ci-macos.yml").read_text(encoding="utf-8")
    job = workflow.split("\n  swift-package-tests:\n", 1)[1]
    job = re.split(r"\n  [A-Za-z0-9_-]+:\n", job, maxsplit=1)[0]
    found = set(re.findall(r"(?:\./)?(scripts/[A-Za-z0-9_./-]+\.(?:sh|py))", job))
    pending = list(found)
    while pending:
        script = ROOT / pending.pop()
        if not script.is_file():
            continue
        for name in re.findall(r"\$(?:script_dir|SCRIPT_DIR)/([A-Za-z0-9_.-]+\.(?:sh|py|txt))", script.read_text(encoding="utf-8")):
            sibling = str((script.parent / name).relative_to(ROOT))
            if sibling not in found:
                found.add(sibling)
                pending.append(sibling)
    return found


def run_package_step(workflow: str, package: str, attempts: list[tuple[str, int]], bonsplit=False):
    """Execute the real CI shell; only Swift's process boundary is substituted."""
    name = "Run Bonsplit package tests" if bonsplit else "Run Swift package unit tests"
    section = workflow.split(f"      - name: {name}\n", 1)[1].split("\n      - name:", 1)[0]
    # The next step can have a leading YAML comment at the surrounding indent.
    script = "\n".join(line[10:] if line.startswith(" " * 10) else line
                        for line in section.split("        run: |\n", 1)[1].splitlines()
                        if not line.startswith("      #"))
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        (root / "Packages/macOS" / package).mkdir(parents=True)
        (root / "vendor/bonsplit").mkdir(parents=True)
        (root / "scripts/ci").mkdir(parents=True)
        shutil.copyfile(ROOT / "scripts/ci/require_swift_test_execution.py", root / "scripts/ci/require_swift_test_execution.py")
        selected = root / "selected"
        selected.write_text(package + "\n")
        fixture = root / "attempts.json"
        fixture.write_text(json.dumps(attempts))
        swift = root / "swift"
        swift.write_text("#!/usr/bin/env python3\nimport json, os, pathlib, sys\n"
                         "root = pathlib.Path(os.environ['FIXTURE_ROOT'])\n"
                         "counter = root / 'calls'\n"
                         "count = int(counter.read_text()) if counter.exists() else 0\n"
                         "counter.write_text(str(count + 1))\n"
                         "attempts = json.loads((root / 'attempts.json').read_text())\n"
                         "output, status = attempts[min(count, len(attempts)-1)]\n"
                         "sys.stdout.write(output)\n"
                         "sys.exit(status)\n")
        swift.chmod(0o755)
        env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}", FIXTURE_ROOT=str(root),
                   SELECTED_PACKAGES=str(selected), SELECTED_COUNT="1")
        result = subprocess.run(["bash", "-c", script], cwd=root, env=env,
                                capture_output=True, text=True, timeout=15)
        count = int((root / "calls").read_text())
        return result, count


def check_package_output_behavior(workflow: str) -> None:
    padding = "build progress line without diagnostics\n" * 12000
    passed = "✔ Test run with 4 tests in 1 suites passed after 0.001 seconds.\n"
    cosmetic = "error: unexpected binary name GhosttyKit\n"
    for package in ("CmuxTerminal", "CmuxTerminalCore"):
        result, count = run_package_step(workflow, package, [(cosmetic + "error: real compiler failure\n" + padding + passed, 1)])
        assert result.returncode == 1 and count == 1, f"{package}: real error incorrectly tolerated: {result.returncode}"
        result, count = run_package_step(workflow, package, [(cosmetic + padding + passed, 1)])
        assert result.returncode == 0 and count == 1, f"{package}: cosmetic diagnostic no longer tolerated"
        result, count = run_package_step(workflow, package, [(cosmetic + "with 1 failure\n" + padding + passed, 1)])
        assert result.returncode == 1 and count == 1, f"{package}: test failure incorrectly tolerated"
    for bonsplit in (False, True):
        for signal in (5, 6):
            startup = f"Build complete!\nerror: Exited with unexpected signal code {signal}\n" + padding
            result, count = run_package_step(workflow, "CmuxSettings", [(startup, 1), (passed, 0)], bonsplit)
            assert result.returncode == 0 and count == 2, f"startup signal {signal} must retry once (bonsplit={bonsplit})"
            result, count = run_package_step(workflow, "CmuxSettings", [(startup, 1)], bonsplit)
            assert result.returncode == 1 and count == 2, "repeated startup crashes must fail after one retry"
        for output in ("Build complete!\nerror: Exited with unexpected signal code 10\n" + padding,
                       "Build complete!\nerror: Exited with unexpected signal code 5\nTest Suite started\n" + padding):
            result, count = run_package_step(workflow, "CmuxSettings", [(output, 1)], bonsplit)
            assert result.returncode == 1 and count == 1, "non-startup failures must not retry"
    print("PASS: real package CI steps reject true errors and preserve bounded startup retries")


def main() -> int:
    check_package_output_behavior((ROOT / ".github/workflows/ci-macos.yml").read_text())
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        fixture(root)
        check(root, None, PACKAGES, "an unknown diff runs everything")
        check(root, [], [], "an empty diff runs nothing")
        check(root, ["Sources/App.swift", "cmuxTests/AppTests.swift", "web/app/page.tsx", "README.md"], [],
              "app, web and docs changes reach no package")
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

        # Exercise the CLI used by the workflow, including mixed package/global
        # inputs. Full-suite selection retains its existing fail-open policy.
        for extra in (".github/workflows/ci-macos.yml", "unknown.conf"):
            changed_file = root / "changed.txt"
            changed_file.write_text("Packages/macOS/Loner/Sources/A.swift\n" + extra + "\n")
            command = [sys.executable, str(ROOT / "scripts/ci/select_package_tests.py"),
                       "--root", str(root), "--changed-files", str(changed_file)]
            targeted = subprocess.run(command + ["--routed-inputs-only"] + PACKAGES,
                                      text=True, capture_output=True, check=True)
            assert targeted.stdout.splitlines() == ["Loner"], targeted
            full = subprocess.run(command + PACKAGES, text=True, capture_output=True, check=True)
            assert full.stdout.splitlines() == PACKAGES, full

        # Targeted PR selection must preserve declared local dependencies,
        # including submodule revision paths, rather than dropping them before
        # the dependency-aware selector sees the diff.
        for path in ("vendor/bonsplit", "vendor/bonsplit/Sources/Bonsplit/A.swift"):
            changed_file = root / "changed.txt"
            changed_file.write_text(path + "\n.github/workflows/ci-macos.yml\n")
            result = subprocess.run(
                [sys.executable, str(ROOT / "scripts/ci/select_package_tests.py"),
                 "--root", str(root), "--changed-files", str(changed_file),
                 "--routed-inputs-only", *PACKAGES],
                text=True, capture_output=True, check=True,
            )
            assert result.stdout.splitlines() == ["Splitter"], (path, result.stdout)

        # Check the actual PR router too: a normal package selector result is
        # insufficient if the lane never starts. These are current declared
        # local dependencies of packages in the workflow's test inventory.
        for path in ("vendor/bonsplit", "vendor/stack-auth-swift-sdk-prerelease"):
            changed_file = root / "router-changed.txt"
            changed_file.write_text(path + "\n")
            outputs = root / "router-outputs.txt"
            outputs.unlink(missing_ok=True)
            result = subprocess.run(
                [sys.executable, str(ROOT / "scripts/ci/detect_ci_change_areas.py"),
                 "--event-name", "pull_request", "--files-from", str(changed_file),
                 "--github-output", str(outputs)],
                cwd=ROOT, text=True, capture_output=True, check=True,
            )
            assert "swift_packages=true" in outputs.read_text().splitlines(), (path, result.stdout)

        try:
            select(root, ["Missing"], [])
        except SystemExit:
            pass
        else:
            raise AssertionError("a listed package that does not exist must fail")

    # Every package the workflow lists must exist, or the job fails before testing anything.
    workflow = (ROOT / ".github/workflows/ci-macos.yml").read_text(encoding="utf-8")
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
