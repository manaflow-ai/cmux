#!/usr/bin/env python3
"""Behavioral coverage for main's owned-Mac signing claim prerequisite.

Carried from feat-cmux-next's test_ci_signing_owned_mac.py; no workflow routes
onto owned signing runners until it also has admission and credential cleanup.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CLAIM = "scripts/ci/signing-runner-claim.sh"
SIGNING_HOOKS = [line.split()[0] for line in
                 (ROOT / "scripts/ci/glaeda-signing-hooks.txt").read_text().splitlines()
                 if line.strip() and not line.startswith("#")]
FIRST_SIGNING_HOOK = "2695209c13db5fe7514daf76d3e8e547b9569ad9a545225e52f7e07dd83d69e4"
OLD_HOOK = "fb0442d31e23f01326118b7d6be2effd0ba91bff9a0b59c62016c39bc23116da"


class ClaimScriptTests(unittest.TestCase):
    def run_claim(self, tmp: Path, **env: str) -> subprocess.CompletedProcess:
        security = tmp / "security"
        security.write_text('#!/bin/sh\n[ "$1" = delete-keychain ] && rm -f "$KEYCHAINS/$2-db"\n'
                            'echo "$@" >> "$KEYCHAINS/calls"\n')
        security.chmod(0o755)
        environ = {"PATH": "/usr/bin:/bin", "HOME": os.fspath(tmp), "KEYCHAINS": os.fspath(tmp / "keychains"),
                   "CMUX_SECURITY_TOOL": os.fspath(security), "CMUX_KEYCHAIN_DIR": os.fspath(tmp / "keychains"),
                   "CMUX_FLEET_DIR": os.fspath(tmp / "no-fleet"), **env}
        return subprocess.run(["bash", os.fspath(ROOT / CLAIM)], env=environ, capture_output=True, text=True,
                              timeout=30, check=False)

    def test_claim(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            (tmp / "keychains").mkdir()
            ephemeral = self.run_claim(tmp, RUNNER_NAME="blacksmith-6vcpu-macos-26-abc")
            self.assertEqual(ephemeral.returncode, 0, ephemeral.stdout + ephemeral.stderr)
            self.assertIn("is ephemeral", ephemeral.stdout)
            for env in ({"RUNNER_NAME": "cmux12-glaeda-3"}, {"RUNNER_NAME": "cmux12-glaeda"},
                        {"RUNNER_NAME": "mini", "CMUX_FLEET_DIR": raw},
                        {"RUNNER_NAME": "cmux12-glaeda", "GLAEDA_JOB_CLAIM": "light"}):
                with self.subTest(env):
                    refused = self.run_claim(tmp, **env)
                    self.assertEqual(refused.returncode, 1, refused.stdout)
                    self.assertIn("did not give the job the whole mini", refused.stdout)
            for sha in ("", OLD_HOOK, SIGNING_HOOKS[0][:12], "x" * 64, ".*", ".*.*", "[0-9a-f]*",
                        SIGNING_HOOKS[0] + " ", "#", SIGNING_HOOKS[0][:63] + "."):
                with self.subTest(sha=sha):
                    refused = self.run_claim(tmp, RUNNER_NAME="cmux12-glaeda-3", GLAEDA_JOB_CLAIM="exclusive",
                                             GLAEDA_HOOK_SHA256=sha)
                    self.assertEqual(refused.returncode, 1, refused.stdout)
                    self.assertIn("is not one", refused.stdout)
            for sha in SIGNING_HOOKS:
                with self.subTest(listed=sha):
                    passed = self.run_claim(tmp, RUNNER_NAME="cmux12-glaeda-3", GLAEDA_JOB_CLAIM="exclusive",
                                            GLAEDA_HOOK_SHA256=sha)
                    self.assertEqual(passed.returncode, 0, passed.stdout + passed.stderr)
            (tmp / "keychains" / "build.keychain-db").write_text("left by a killed job")
            claimed = self.run_claim(tmp, RUNNER_NAME="cmux12-glaeda-3", GLAEDA_JOB_CLAIM="exclusive",
                                     GLAEDA_HOOK_SHA256=FIRST_SIGNING_HOOK)
            self.assertEqual(claimed.returncode, 0, claimed.stdout + claimed.stderr)
            self.assertIn("holds the whole mini", claimed.stdout)
            self.assertIn("removed the signing keychain build.keychain", claimed.stdout)
            self.assertFalse((tmp / "keychains" / "build.keychain-db").exists())


if __name__ == "__main__":
    unittest.main()
