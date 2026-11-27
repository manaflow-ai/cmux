#!/usr/bin/env python3
"""A pull request that adds a dependency whose license texts do not match goes red at its own head.

cmux#59540 (merged as a54ca466) added jpeg-encoder 0.6.1, `(MIT OR Apache-2.0) AND IJG`. license_match.py had no IJG
signature, so the nightly's "Generate third-party notices (cmux-next)" failed for about 3 hours after the merge
(cmux#60807 added IJG). Leo's proxy: "why didn't #59540's own CI catch the IJG license before it merged?" Because
cmux-next-guards.yml rust-notices-tree, the pull request copy of that step, was skipped on feat-cmux-next pull requests
(scripts/ci/affected-jobs.json pull_request_skip, and the land tier). This holds the class:

  * the job runs on every pull request head (no land-tier or pull_request_skip clause in its `if:`), and its path
    filter takes every dependency manifest and lockfile (Cargo, npm/bun/pnpm/yarn, SwiftPM) and the notices tooling;
  * it generates through the nightly step's own script (app-third-party-notices.sh `pr`), so the two cannot drift;
  * a fixture crate with a license id license_match.py has no text for makes that script exit non-zero, through the
    real rust_notices.py and license_match.py, and the same crate with a matched license passes.

Stdlib only (the job runs it with `python3 -I` on a sparse checkout). Run: python3 -I tests/test_rust_notices_pr_check.py
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
NOTICES = ROOT / "cmux-tui/build-support/notices"
GUARDS = ROOT / ".github/workflows/cmux-next-guards.yml"
NIGHTLY = ROOT / ".github/workflows/nightly.yml"
STEP_SCRIPT = "scripts/ci/nightly-steps/app-third-party-notices.sh"
AFFECTED = ROOT / "scripts/ci/affected-jobs.json"
JOB = "rust-notices-tree"

# test_rust_notices.py, loaded by path (`python3 -I` puts no script folder on sys.path); it puts its own folder there,
# so rust_notices and license_match import as the generator imports them.
_spec = importlib.util.spec_from_file_location("test_rust_notices", NOTICES / "test_rust_notices.py")
trn = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(trn)

# An id license_match.py has no signature for, as IJG was before cmux#60807. Made up, so no later review can add it.
UNREVIEWED = "Fixture-Unreviewed-1.0"
IJG_TEXT = (
    "The authors make NO WARRANTY or representation. This software is copyright (C) the Independent JPEG Group. "
    "If you use this software, you must acknowledge: this software is based in part on the work of the Independent "
    "JPEG Group.\n"
)


def fixture(root: Path, license: str) -> "trn.Fixture":
    """test_rust_notices's fixture workspace plus jpegish 0.6.1 (a normal dependency of the app) under `license`, shipping
    an MIT text and the IJG text, as jpeg-encoder does."""
    saved = (trn.REGISTRY, trn.LOCK_EDGES, trn.APP_MANIFEST)
    files = {"LICENSE-MIT": trn.MIT_SIG + "jpegish\n", "LICENSE-IJG": IJG_TEXT}
    trn.REGISTRY = saved[0] + [("jpegish", "0.6.1", license, "", files, trn.CRATES_IO)]
    trn.LOCK_EDGES = {**saved[1], "app": saved[1]["app"] + ["jpegish"]}
    assert "\n\n[dev-dependencies]" in saved[2]
    trn.APP_MANIFEST = saved[2].replace("\n\n[dev-dependencies]", '\njpegish = "0.6"\n\n[dev-dependencies]', 1)
    root.mkdir(parents=True, exist_ok=True)
    try:
        return trn.Fixture(root)
    finally:
        trn.REGISTRY, trn.LOCK_EDGES, trn.APP_MANIFEST = saved


def job_block(text: str, job: str) -> str:
    match = re.search(rf"^  {re.escape(job)}:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)", text, re.M | re.S)
    assert match, f"no job {job}"
    return match.group(1)


def step_block(job_text: str, name: str) -> str:
    match = re.search(rf"^      - (?:&\w+\n\s+)?name: {re.escape(name)}\n(.*?)(?=^      - |\Z)", job_text, re.M | re.S)
    assert match, f"no step {name!r}"
    return match.group(1)


class RouteTest(unittest.TestCase):
    def setUp(self) -> None:
        self.job = job_block(GUARDS.read_text(encoding="utf-8"), JOB)

    def test_it_runs_on_every_pull_request_head(self) -> None:
        condition = re.search(r"^    if: (.*)$", self.job, re.M).group(1)
        # The land tier (CI_LAND_TIER) and pull_request_skip (PR_SKIP_IF, the full-ci clause) skipped it on #59540.
        self.assertNotIn("CI_LAND_TIER", condition)
        self.assertNotIn("!startsWith(github.event.pull_request.base.ref, 'feat-cmux-next')", condition)
        self.assertNotIn("draft", condition)
        listed = json.loads(AFFECTED.read_text(encoding="utf-8"))["pull_request_skip"]["workflows"]
        self.assertNotIn(JOB, listed.get(".github/workflows/cmux-next-guards.yml", {}))

    def pattern(self) -> re.Pattern[str]:
        match = re.search(r"^\s+pattern='([^']+)'$", step_block(self.job, "Changed notice inputs"), re.M)
        self.assertIsNotNone(match)
        return re.compile(match.group(1))

    def test_every_dependency_manifest_and_lockfile_runs_it(self) -> None:
        pattern = self.pattern()
        for path in (
            "cmux-tui/Cargo.lock", "cmux-tui/Cargo.toml", "cmux-tui/crates/cmux-app-host/Cargo.toml",
            "Native/DiffSidecar/Cargo.lock", "cmux-next-ios/rust/Cargo.toml",
            "package.json", "web/package.json", "webviews/bun.lock", "web/bun.lockb", "package-lock.json",
            "npm-shrinkwrap.json", "mux/pnpm-lock.yaml", "yarn.lock",
            "Packages/macOS/CmuxNext/Package.resolved", "cmux.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
            "cmux-tui/build-support/notices/license_match.py", "cmux-tui/build-support/notices/reviewed.json",
            "scripts/cmux-next/generate-third-party-notices.sh", "scripts/cmux-next/notices/compose_notices.py",
            "scripts/cmux-next/remote-browser-host.pin.json", STEP_SCRIPT,
        ):
            self.assertRegex(path, pattern, path)
        for path in ("README.md", "cmux-tui/crates/cmux-app-host/src/lib.rs", "web/src/app.tsx", "Cargo.toml.orig",
                     "docs/package.json.md"):
            self.assertNotRegex(path, pattern, path)

    def test_it_generates_through_the_nightly_steps_script(self) -> None:
        nightly = step_block(NIGHTLY.read_text(encoding="utf-8"), "Generate third-party notices (cmux-next)")
        self.assertRegex(nightly, rf"run: bash {re.escape(STEP_SCRIPT)}\n")
        pr = step_block(self.job, "Generate the Rust notices from this tree (as the nightly does)")
        self.assertIn(f"run: bash {STEP_SCRIPT} pr\n", pr)
        self.assertIn('CMUX_NOTICES_ALLOW_CARGO: "1"', pr)
        self.assertIn("steps.inputs.outputs.run == 'true'", pr)
        # The `pr` mode is the nightly's own generate(): one command for both.
        script = (ROOT / STEP_SCRIPT).read_text(encoding="utf-8")
        arm = re.search(r"^  pr\)\n(.*?)^    ;;", script, re.M | re.S)
        self.assertIsNotNone(arm, "app-third-party-notices.sh has no pr mode")
        self.assertRegex(arm.group(1), r"(?m)^\s+CMUX_NOTICES_OUT=\S+ generate$")


class UnmatchedLicenseTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def generate(self, license: str) -> tuple[int, str]:
        fx = fixture(self.tmp / "fx", license)
        err = io.StringIO()
        old = os.environ.get("CARGO_HOME")
        os.environ["CARGO_HOME"] = str(fx.cargo_home)
        try:
            with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
                code = trn.rust_notices.main(fx.args("--out", str(self.tmp / "out"), "--files-out", str(self.tmp / "files")))
        finally:
            if old is None:
                os.environ.pop("CARGO_HOME", None)
            else:
                os.environ["CARGO_HOME"] = old
        return code, err.getvalue()

    def test_a_license_with_no_text_signature_fails_the_generator(self) -> None:
        code, err = self.generate(f"(MIT OR Apache-2.0) AND {UNREVIEWED}")
        self.assertEqual(code, 1, err)
        self.assertIn("jpegish 0.6.1", err)
        self.assertIn(f"{UNREVIEWED}: unknown license id", err)

    def test_the_same_crate_with_a_matched_license_passes(self) -> None:
        code, err = self.generate("(MIT OR Apache-2.0) AND IJG")
        self.assertEqual(code, 0, err)


class StepScriptGoesRedTest(unittest.TestCase):
    """The job's command, `bash app-third-party-notices.sh pr`, in a workspace whose generator runs the real
    rust_notices.py on the fixture: the unmatched license fails the step."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)
        self.ws = self.tmp / "ws"
        (self.ws / STEP_SCRIPT).parent.mkdir(parents=True)
        shutil.copy(ROOT / STEP_SCRIPT, self.ws / STEP_SCRIPT)
        self.runner_temp = self.tmp / "runner-temp"
        self.runner_temp.mkdir()

    def run_step(self, license: str) -> subprocess.CompletedProcess[str]:
        fx = fixture(self.tmp / "fx", license)
        argv = [sys.executable, str(NOTICES / "rust_notices.py"),
                *fx.args("--out", '"$CMUX_NOTICES_OUT"', "--files-out", str(self.tmp / "files"), fmt="markdown")]
        command = " ".join(a if a == '"$CMUX_NOTICES_OUT"' else shlex.quote(a) for a in argv)
        generator = self.ws / "scripts/cmux-next/generate-third-party-notices.sh"
        generator.parent.mkdir(parents=True, exist_ok=True)
        generator.write_text(
            "#!/bin/bash\nset -euo pipefail\n"
            f'echo "$*" > {shlex.quote(str(self.tmp / "args"))}\n'
            f"CARGO_HOME={shlex.quote(str(fx.cargo_home))} {command}\n"
        )
        generator.chmod(0o755)
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(self.tmp), "RUNNER_TEMP": str(self.runner_temp),
               "CMUX_NOTICES_ALLOW_CARGO": "1"}
        return subprocess.run(["bash", STEP_SCRIPT, "pr"], cwd=self.ws, env=env, capture_output=True, text=True, timeout=120)

    def test_an_unmatched_license_fails_the_step(self) -> None:
        result = self.run_step(f"(MIT OR Apache-2.0) AND {UNREVIEWED}")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("jpegish 0.6.1", result.stderr)
        self.assertIn(f"{UNREVIEWED}: unknown license id", result.stderr)
        self.assertEqual((self.tmp / "args").read_text().split(),
                         ["--tui-source", "tree", "--cargo-trees", f"{self.runner_temp}/cmux-notices-cargo-trees",
                          "--write-cargo-trees"])

    def test_a_matched_license_passes_and_writes_outside_the_checkout(self) -> None:
        result = self.run_step("(MIT OR Apache-2.0) AND IJG")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        out = self.runner_temp / "notices-pr/THIRD_PARTY_LICENSES.md"
        self.assertIn("jpegish", out.read_text(encoding="utf-8"))
        self.assertFalse((self.ws / "THIRD_PARTY_LICENSES.md").exists())


if __name__ == "__main__":
    unittest.main()
