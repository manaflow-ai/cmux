#!/usr/bin/env python3
"""A job that builds the Ghostty source fetches its Zig packages first, cached and retried.

Zig's own package download (`zig build`, or cargo's ghostty-vt-sys build.rs running it) reads
each build.zig.zon URL once, with no retry. One GitHub archive 504 for two packages
(manaflow-ai/itijah, vancluever/arocc) failed "seven-language live conformance" in
cmux-tui-sdks run 45887126017 (2026-11-26), and its rerun went green: a false red.
.github/actions/ghostty-zig-packages (a cache restore, then scripts/ci/fetch-ghostty-zig-packages.sh:
a curl seed with retries, a stall deadline and retried attempts) already carried this for
cmux-tui.yml and cmux-tui-build-package.yml; the jobs below built without it.

This test fails when a job that
  - brings in the `ghostty` submodule (scripts/ci/init-submodule.sh ghostty, or a recursive checkout),
  - installs Zig (mlugg/setup-zig or scripts/install-zig-ci.sh), and
  - builds Ghostty (`cargo build|test|nextest|clippy|run` for cmux-tui, whose ghostty-vt-sys
    runs `zig build`, or `zig build` in the ghostty directory)
does not run the action or the fetch script before its first such build step, unless EXEMPT names
it with a reason.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"

FETCH = re.compile(r"\./\.github/actions/ghostty-zig-packages\b|scripts/ci/fetch-ghostty-zig-packages\.sh")
ZIG = re.compile(r"mlugg/setup-zig@|scripts/install-zig-ci\.sh")
GHOSTTY = re.compile(r"init-submodule\.sh\s+ghostty\b")
CARGO_BUILD = re.compile(r"\bcargo\s+(?:\+\S+\s+)?(?:build|test|nextest|clippy|run)\b")
ZIG_BUILD = re.compile(r"(?:\bzig|\$\{?CMUX_ZIG\}?\"?)\s+build\b")

# workflow file -> job id -> why it may build without the shared fetch.
EXEMPT: dict[str, dict[str, str]] = {
    "build-ghosttykit.yml": {
        "build-ghosttykit": "macOS GhosttyKit on owned minis: restores its own zig-packages actions/cache "
        "keyed on ghostty's build.zig.zon files before any zig build",
    },
    "nightly.yml": {
        "build-nightly-app": "macOS nightly on owned minis with a kept ~/.cache/zig; nightly changes go "
        "through the nightly lane",
    },
    "cloud-journey-prod.yml": {
        "journey": "checks out feat-cmux-next (or a journey_ref on it), whose tree has no "
        "ghostty-zig-packages action to call",
        "preclaim": "checks out feat-cmux-next, whose tree has no ghostty-zig-packages action to call",
    },
}


def _step_text(step: dict) -> str:
    parts = [str(step.get("uses") or ""), str(step.get("run") or "")]
    with_ = step.get("with") or {}
    if isinstance(with_, dict):
        parts += [f"{k}: {v}" for k, v in with_.items()]
    parts.append(f"working-directory: {step.get('working-directory') or ''}")
    return "\n".join(parts)


def _brings_ghostty(step: dict) -> bool:
    text = _step_text(step)
    if GHOSTTY.search(text):
        return True
    with_ = step.get("with") or {}
    return str(step.get("uses") or "").startswith("actions/checkout@") and isinstance(with_, dict) and str(
        with_.get("submodules", "")
    ).lower() in {"recursive", "true"}


def _builds_ghostty(step: dict) -> bool:
    run = str(step.get("run") or "")
    workdir = str(step.get("working-directory") or "")
    if CARGO_BUILD.search(run) and ("cmux-tui" in workdir or "cmux-tui" in run):
        return True
    if ZIG_BUILD.search(run) and (workdir.rstrip("/").endswith("ghostty") or re.search(r"cd\s+(?:\.\./)?ghostty\b", run)):
        return True
    return False


def violations(workflows: Path = WORKFLOWS, exempt: dict[str, dict[str, str]] = EXEMPT) -> list[str]:
    found: list[str] = []
    for path in sorted(workflows.glob("*.yml")):
        data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        for job_id, job in (data.get("jobs") or {}).items():
            steps = (job or {}).get("steps") or []
            if not any(_brings_ghostty(s) for s in steps) or not any(ZIG.search(_step_text(s)) for s in steps):
                continue
            first_build = next((i for i, s in enumerate(steps) if _builds_ghostty(s)), None)
            if first_build is None:
                continue
            if any(FETCH.search(_step_text(s)) for s in steps[:first_build]):
                continue
            if exempt.get(path.name, {}).get(job_id):
                continue
            found.append(
                f"{path.name}: job {job_id} builds Ghostty (step {steps[first_build].get('name') or first_build}) "
                "with no ./.github/actions/ghostty-zig-packages step before it"
            )
    return found


class ThisTree(unittest.TestCase):
    def test_every_ghostty_build_fetches_its_zig_packages_first(self) -> None:
        self.assertEqual(violations(), [], "add `uses: ./.github/actions/ghostty-zig-packages` before the build, or an EXEMPT reason")

    def test_exemptions_name_jobs_that_exist(self) -> None:
        for name, jobs in EXEMPT.items():
            data = yaml.safe_load((WORKFLOWS / name).read_text(encoding="utf-8"))
            for job_id, reason in jobs.items():
                self.assertIn(job_id, data["jobs"], f"{name}: exempt job {job_id} is gone")
                self.assertGreater(len(reason), 30, f"{name}: {job_id} needs a real reason")


class Detector(unittest.TestCase):
    def _tree(self, tmp: Path, steps: str) -> Path:
        wf = tmp / "wf"
        wf.mkdir()
        (wf / "x.yml").write_text("on: push\njobs:\n  j:\n    runs-on: x\n    steps:\n" + steps, encoding="utf-8")
        return wf

    def _check(self, steps: str) -> list[str]:
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            return violations(self._tree(Path(tmp), steps), {})

    BASE = (
        "      - run: bash scripts/ci/init-submodule.sh ghostty\n"
        "      - uses: mlugg/setup-zig@abc\n"
    )
    BUILD = "      - working-directory: cmux-tui\n        run: cargo build -p cmux-tui --locked\n"
    FETCH_STEP = "      - uses: ./.github/actions/ghostty-zig-packages\n        with:\n          source: ghostty\n"

    def test_a_cmux_tui_build_without_the_fetch_fails(self) -> None:
        self.assertEqual(len(self._check(self.BASE + self.BUILD)), 1)

    def test_the_fetch_before_the_build_passes(self) -> None:
        self.assertEqual(self._check(self.BASE + self.FETCH_STEP + self.BUILD), [])

    def test_the_fetch_after_the_build_fails(self) -> None:
        self.assertEqual(len(self._check(self.BASE + self.BUILD + self.FETCH_STEP)), 1)

    def test_a_zig_build_in_ghostty_counts(self) -> None:
        self.assertEqual(len(self._check(self.BASE + "      - run: cd ghostty && zig build -Demit-lib-vt=true\n")), 1)

    def test_the_fetch_script_counts(self) -> None:
        steps = self.BASE + "      - run: ./scripts/ci/fetch-ghostty-zig-packages.sh ghostty\n" + self.BUILD
        self.assertEqual(self._check(steps), [])

    def test_a_zig_sdk_build_without_ghostty_is_not_a_ghostty_build(self) -> None:
        steps = "      - uses: mlugg/setup-zig@abc\n      - working-directory: cmux-tui/bindings/zig\n        run: zig build test\n"
        self.assertEqual(self._check(steps), [])


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
