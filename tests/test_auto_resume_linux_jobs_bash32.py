#!/usr/bin/env python3
"""The auto-resume jobs that ran only on Ubuntu (poll-outer, poll-stapled, publish) run on bash 3.2.

A Mac mini's /bin/bash is 3.2: no `mapfile`, no `declare -A`, no `${x,,}`. Under it
poll-outer-notarizations.sh read no variants and decided nothing (exit 0), and the
publish digest check stopped on a bad substitution. Each case runs the real script or
the real workflow step under every bash on this machine (/bin/bash is 3.2 on macOS) with
fixtures and checks the result.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import textwrap
import time
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/auto-resume-nightly-notarization.yml"
POLLER = ROOT / "scripts/ci/poll-outer-notarizations.sh"


def bashes() -> list[str]:
    """Every distinct bash here: /bin/bash (3.2 on macOS) and the one on PATH."""
    found = [path for path in ("/bin/bash", shutil.which("bash")) if path and os.access(path, os.X_OK)]
    return list(dict.fromkeys(os.path.realpath(path) for path in found))


def bash_version(bash: str) -> str:
    return subprocess.run([bash, "-c", 'printf %s "$BASH_VERSION"'], capture_output=True, text=True,
                          check=True).stdout


def write_exe(path: Path, body: str) -> None:
    path.write_text(body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def step(job: str, name: str) -> str:
    workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    steps = {item.get("name"): item for item in workflow["jobs"][job]["steps"]}
    return steps[name]["run"]


def run_step(bash: str, script: str, cwd: Path, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    # GitHub runs a `run:` step as `bash --noprofile --norc -eo pipefail {0}`.
    path = cwd / ".step.sh"
    path.write_text(script, encoding="utf-8")
    return subprocess.run([bash, "--noprofile", "--norc", "-eo", "pipefail", str(path)], cwd=cwd, env=env,
                          capture_output=True, text=True, check=False, timeout=60)


class AutoResumeLinuxJobsOnBash32Tests(unittest.TestCase):
    def test_bash_candidates_include_system_bash(self) -> None:
        self.assertTrue(bashes(), "no bash found")

    def poller_tree(self, root: Path, codes: dict[str, str]) -> Path:
        """A copy of the poller with a stub recovery resolver and a stub notary poll tool."""
        tools = root / "repo/scripts/ci"
        tools.mkdir(parents=True)
        shutil.copy2(POLLER, tools / POLLER.name)
        # The resolver prints the variant's state file, like --metadata-only does.
        write_exe(tools / "resolve-notarization-recovery.py", textwrap.dedent("""\
            #!/usr/bin/env python3
            import pathlib, sys
            variant = sys.argv[5]
            print(f"STATE_FILE={pathlib.Path(sys.argv[1]).parent / (variant + '.state')}")
            """))
        # The poll tool answers per state file: 0 Accepted, 1 refused, 2 In Progress.
        table = root / "codes.json"
        table.write_text(json.dumps(codes), encoding="utf-8")
        write_exe(root / "poll", textwrap.dedent(f"""\
            #!/usr/bin/env python3
            import json, pathlib, sys
            codes = json.loads(pathlib.Path({str(table)!r}).read_text())
            sys.exit(int(codes[pathlib.Path(sys.argv[1]).stem]))
            """))
        return tools / POLLER.name

    def test_poller_decides_each_variant_on_every_bash(self) -> None:
        now = int(time.time())
        for bash in bashes():
            with self.subTest(bash=bash, version=bash_version(bash)), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                # arm64 Accepted; x86_64 a stapled-app DMG refused past its 6 h deadline (fallback);
                # universal an outer DMG refused (failed). Three keys must stay three keys.
                poller = self.poller_tree(root, {"arm64": "0", "x86_64": "1", "universal": "1"})
                meta = root / "outer"
                for variant in ("arm64", "x86_64", "universal"):
                    (meta / variant).mkdir(parents=True)
                    state = meta / variant / f"{variant}.state"
                    lines = ["submission_id=fixture"]
                    if variant == "x86_64":
                        lines += ["stapled_app=true", f"stapled_submitted_at={now - 21600 - 60}"]
                    state.write_text("\n".join(lines) + "\n", encoding="utf-8")
                variants = root / "outer-variants"
                variants.write_text("arm64\nx86_64\nuniversal\n", encoding="utf-8")
                output = root / "github-output"
                env = {**os.environ, "SOURCE_RUN_ID": "123", "SOURCE_HEAD_SHA": "0" * 40, "SOURCE_RUN_ATTEMPT": "1",
                       "CHANNEL": "nightly", "GITHUB_OUTPUT": str(output),
                       "CMUX_POLL_NOTARY_SUBMISSION_TOOL": str(root / "poll"),
                       "CMUX_OUTER_POLL_INTERVAL_SECONDS": "1", "CMUX_OUTER_POLL_BUDGET_SECONDS": "5"}
                result = subprocess.run([bash, str(poller), str(meta), str(variants), str(root / "reports")],
                                        cwd=root, env=env, capture_output=True, text=True, check=False, timeout=60)
                log = result.stdout + result.stderr
                self.assertEqual(result.returncode, 1, log)
                for line in ("arm64: accepted", "x86_64: fallback", "universal: failed"):
                    self.assertIn(line, result.stdout, log)
                written = output.read_text(encoding="utf-8").splitlines() if output.exists() else []
                self.assertEqual(written, ["decided=true", 'outer_variants=["arm64", "x86_64"]'], log)

    def test_poller_with_no_variants_decides_nothing_on_every_bash(self) -> None:
        for bash in bashes():
            with self.subTest(bash=bash), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                poller = self.poller_tree(root, {})
                (root / "outer-variants").write_text("", encoding="utf-8")
                output = root / "github-output"
                result = subprocess.run([bash, str(poller), str(root / "outer"), str(root / "outer-variants"),
                                         str(root / "reports")], cwd=root,
                                        env={**os.environ, "GITHUB_OUTPUT": str(output)},
                                        capture_output=True, text=True, check=False, timeout=60)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output.read_text(encoding="utf-8"), "decided=false\nouter_variants=[]\n")

    def test_poll_jobs_download_steps_list_variants_on_every_bash(self) -> None:
        cases = (("poll-outer", "Download outer polling metadata", "outer-notarization-metadata"),
                 ("poll-stapled", "Download stapled-app polling metadata", "stapled-app-notarization-metadata"))
        for job, name, kind in cases:
            script = step(job, name)
            for bash in bashes():
                for present, expected in ((("x86_64", "universal"), "x86_64\nuniversal\n"), ((), "")):
                    with self.subTest(job=job, bash=bash, present=present), \
                            tempfile.TemporaryDirectory() as directory:
                        root = Path(directory)
                        (root / "bin").mkdir()
                        # gh run download succeeds only for the artifacts that exist.
                        write_exe(root / "bin/gh", textwrap.dedent(f"""\
                            #!/bin/sh
                            for arg in "$@"; do
                              for variant in {' '.join(present) or 'none'}; do
                                [ "$arg" = "cmux-nightly-{kind}-$variant-abc1234" ] && exit 0
                              done
                            done
                            exit 1
                            """))
                        env = {**os.environ, "PATH": f"{root / 'bin'}:{os.environ['PATH']}", "CHANNEL": "nightly",
                               "SHORT_SHA": "abc1234", "RUNNER_TEMP": str(root), "GITHUB_RUN_ID": "1",
                               "GITHUB_REPOSITORY": "manaflow-ai/cmux"}
                        result = run_step(bash, script, root, env)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual((root / "outer-variants").read_text(encoding="utf-8"), expected)

    def test_publish_digest_check_is_case_blind_and_exact_on_every_bash(self) -> None:
        script = step("publish", "Assemble and verify all accepted publication inputs")
        for bash in bashes():
            for tamper in (False, True):
                with self.subTest(bash=bash, tamper=tamper), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    for variant in ("arm64", "x86_64", "universal"):
                        folder = root / "verified" / f"accepted-{variant}-TEST"
                        folder.mkdir(parents=True)
                        immutable = f"cmux-nightly-macos-{variant}-123.dmg"
                        payload = f"stapled-{variant}".encode()
                        (folder / immutable).write_bytes(payload)
                        feed = "appcast.xml" if variant == "universal" else f"appcast-{variant}.xml"
                        (folder / feed).write_text("<rss/>\n", encoding="utf-8")
                        digest = hashlib.sha256(payload).hexdigest()
                        recorded = digest.upper()
                        if tamper and variant == "x86_64":
                            recorded = hashlib.sha256(b"other").hexdigest().upper()
                        (folder / "cmux-nightly-notarization-recovery.json").write_text(json.dumps(
                            {"build": 123, "immutable_path": f"x/{immutable}", "final_dmg_sha256": recorded}),
                            encoding="utf-8")
                        tested = root / "tested"
                        tested.mkdir(exist_ok=True)
                        (tested / f"tested-{variant}.sha256").write_text(f"{digest}  {immutable}\n",
                                                                          encoding="utf-8")
                    env = {**os.environ, "SHORT_SHA": "TEST", "DMG_PREFIX": "cmux-nightly-macos",
                           "GITHUB_ENV": str(root / "github.env")}
                    result = run_step(bash, script, root, env)
                    if tamper:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn("x86_64 stapled DMG SHA-256 mismatch", result.stderr)
                    else:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual((root / "github.env").read_text(encoding="utf-8"), "NIGHTLY_BUILD=123\n")
                        self.assertEqual((root / "nightly-out/cmux-nightly-macos.dmg").read_bytes(),
                                         b"stapled-universal")


if __name__ == "__main__":
    unittest.main()
