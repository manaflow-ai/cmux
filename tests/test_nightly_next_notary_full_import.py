#!/usr/bin/env python3
"""cx-f58x: a nightly-next notary test of the build with the whole browser import in.

Apple returned status 7000 for nightly-next with the browser-data import
(2026-10-07) and accepted the same commit with it compiled out, so published
nightly-next builds compiled the import out until run 42176643049. The bisect inputs each compile
one part out; none submits the import as it would ship. `notary_test_import_part:
full` is that one diagnostic: the import compiled in, the registry filled,
one submission, nothing published. Its verdict says whether Apple still holds
the import (and so whether the Apple support request is needed).

This runs decide's own import block from nightly.yml in node, with a fake
`core`, and checks the outputs the build and publish jobs read.

Run 42176643049 (2026-11-06) built `full` and Apple accepted it, so the hold
is gone: published nightly-next builds carry the import again. The workflow's
own NIGHTLY_NEXT_BROWSER_DATA_IMPORT is what a published run sees, and
`compiled-out` stays the one-line switch back.
"""
from __future__ import annotations

import json
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = (ROOT / ".github/workflows/nightly.yml").read_text(encoding="utf-8")


def import_block() -> str:
    start = WORKFLOW.index("// cx-f58x notary tests: one nightly-next submission")
    end_marker = "core.setOutput('no_publish', notaryPaused || notaryTest ? 'true' : 'false');"
    end = WORKFLOW.index(end_marker, start)
    return WORKFLOW[start:end] + end_marker


def workflow_env(name: str) -> str:
    """The value nightly.yml's top-level env gives every job (what a published run sees)."""
    top = WORKFLOW.index("\nenv:\n")
    block = WORKFLOW[top + len("\nenv:\n"):]
    for line in block.splitlines():
        if line and not line.startswith(" "):
            break
        key, _, value = line.strip().partition(": ")
        if key == name:
            return value.strip().strip("'\"")
    raise KeyError(name)


def decide(env: dict[str, str], track: str = "nightly-next") -> dict[str, str]:
    script = (
        "const outputs = {}; const failures = [];\n"
        "const core = { setOutput: (k, v) => { outputs[k] = String(v); },"
        " setFailed: (m) => failures.push(String(m)), notice: () => {} };\n"
        f"const track = {json.dumps(track)};\n"
        "const continueOnly = false; const appBuildSelected = true;\n"
        "const notaryProbe = process.env.NOTARY_PROBE === 'true';\n"
        + import_block()
        + "\nconsole.log(JSON.stringify({outputs, failures}));\n"
    )
    full_env = {"PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
                "NIGHTLY_NEXT_BROWSER_DATA_IMPORT": "compiled-out", **env}
    out = subprocess.run(["node", "-e", script], capture_output=True, text=True, env=full_env, check=True)
    return json.loads(out.stdout)


class NotaryTestFullImport(unittest.TestCase):
    def test_full_builds_the_import_in_and_publishes_nothing(self):
        got = decide({"NOTARY_IMPORT_PART": "full"})
        self.assertEqual(got["failures"], [])
        out = got["outputs"]
        self.assertEqual(out["import_variant"], "full")
        self.assertEqual(out["swift_import_flags"], "")
        self.assertEqual(out["empty_browser_sources"], "false")
        self.assertEqual(out["password_readers_out"], "false")
        self.assertEqual(out["notary_test"], "true")
        self.assertEqual(out["no_publish"], "true")
        # The absence scan must not run: this build carries the import on purpose.
        self.assertEqual(out["notary_test_browser_data"], "false")

    def test_full_notarizes_while_the_import_pause_is_set(self):
        got = decide({"NOTARY_IMPORT_PART": "full", "NIGHTLY_NEXT_NOTARY_PAUSED": "1"})
        self.assertEqual(got["outputs"]["import_paused"], "false")
        self.assertEqual(got["outputs"]["no_publish"], "true")

    def test_full_is_nightly_next_only(self):
        got = decide({"NOTARY_IMPORT_PART": "full"}, track="nightly")
        self.assertTrue(any("only on nightly-next" in f for f in got["failures"]), got)

    def test_published_nightly_next_builds_carry_the_import(self):
        imported = workflow_env("NIGHTLY_NEXT_BROWSER_DATA_IMPORT")
        got = decide({"NIGHTLY_NEXT_BROWSER_DATA_IMPORT": imported})
        self.assertEqual(got["failures"], [])
        out = got["outputs"]
        self.assertEqual(out["import_variant"], "full")
        self.assertEqual(out["swift_import_flags"], "")
        self.assertEqual(out["empty_browser_sources"], "false")
        self.assertEqual(out["password_readers_out"], "false")
        self.assertEqual(out["notary_test"], "false")
        self.assertEqual(out["no_publish"], "false")

    def test_compiled_out_still_compiles_the_import_out(self):
        out = decide({})["outputs"]
        self.assertEqual(out["import_variant"], "no-browser-data")
        self.assertEqual(out["empty_browser_sources"], "true")
        self.assertEqual(out["no_publish"], "false")


if __name__ == "__main__":
    unittest.main()
