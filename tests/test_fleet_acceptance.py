#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "fleet_acceptance.py"
SPEC = importlib.util.spec_from_file_location("fleet_acceptance", MODULE_PATH)
assert SPEC and SPEC.loader
f = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(f)


class FleetAcceptanceTests(unittest.TestCase):
    def test_receipt_schema_is_bounded(self):
        document = {
            "schema": f.SCHEMA,
            "nodeId": "cmux-fixture-001",
            "enrollmentGeneration": 1,
            "role": "cmux_linux_ci",
            "source": {
                "repository": "manaflow-ai/cmux",
                "commit": "1" * 40,
            },
            "toolchainGeneration": "sha256:" + "a" * 64,
            "glaedaGeneration": "sha256:" + "b" * 64,
            "workloadGeneration": "sha256:" + "c" * 64,
            "checks": {
                "workload": "pass",
                "semanticVerifier": "pass",
                "artifact": "pass",
                "processSettlement": "pass",
            },
        }
        self.assertLess(
            len(f.canonical(document)),
            f.MAX_RECEIPT_BYTES,
        )

    def test_toolchain_hash_is_canonical(self):
        payload = {
            "cmuxXcodePin": "26.0",
            "xcodeVersion": "26.0",
            "macosSdkVersion": "26.0",
            "gitVersion": "git version 2.50.1",
        }
        reversed_payload = dict(reversed(list(payload.items())))
        self.assertEqual(
            f.sha256(f.canonical(payload)),
            f.sha256(f.canonical(reversed_payload)),
        )

    def test_zig_version_compatibility_matches_setup_policy(self):
        self.assertTrue(f.zig_version_compatible("0.16.0", "0.16.0"))
        self.assertTrue(f.zig_version_compatible("0.16.4", "0.16.0"))
        self.assertFalse(f.zig_version_compatible("0.15.9", "0.16.0"))
        self.assertFalse(f.zig_version_compatible("0.17.0", "0.16.0"))
        self.assertFalse(f.zig_version_compatible("nightly", "0.16.0"))

    def test_settlement_observes_finished_group(self):
        ok, settled, _ = f.run_group(
            ["/bin/sh", "-c", "exit 0"],
            Path.cwd(),
            5,
        )
        self.assertTrue(ok)
        self.assertTrue(settled)

    def test_settlement_catches_background_child(self):
        ok, settled, _ = f.run_group(
            ["/bin/sh", "-c", "sleep 3600 & exit 0"],
            Path.cwd(),
            5,
        )
        self.assertTrue(ok)
        self.assertFalse(settled)


    def test_linux_accept_materializes_exact_source_and_independent_checks(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)

            def run_group(argv, cwd, timeout, extra_env=None):
                del cwd, timeout, extra_env
                executable = Path(argv[0]).name
                if executable == "git":
                    return True, True, b"archive ok"
                if executable == "tar":
                    work = Path(argv[argv.index("-C") + 1])
                    (work / ".github/workflows").mkdir(parents=True)
                    (work / "tests").mkdir(parents=True)
                    (work / ".github/workflows/ci.yml").write_text("name: CI\n")
                    (work / "tests/test_ci_self_hosted_guard.sh").write_text("#!/bin/bash\n")
                    return True, True, b"extract ok"
                if executable == "bash":
                    return True, True, b"PASS: runner labels\nPASS: routing\n"
                if executable == "python3":
                    return True, True, b"OK\n"
                raise AssertionError(argv)

            with (
                mock.patch.object(f.platform, "system", return_value="Linux"),
                mock.patch.object(f, "git_identity") as identity,
                mock.patch.object(f, "command", side_effect=lambda name: f"/usr/bin/{name}"),
                mock.patch.object(f, "run_group", side_effect=run_group),
            ):
                checks = f.linux_accept(root, "1" * 40)

        self.assertEqual(identity.call_count, 2)
        self.assertEqual(checks, {
            "workload": "pass",
            "semanticVerifier": "pass",
            "artifact": "pass",
            "processSettlement": "pass",
        })

    def test_linux_accept_failed_unsettled_workload_stays_red(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)

            def run_group(argv, cwd, timeout, extra_env=None):
                del cwd, timeout, extra_env
                executable = Path(argv[0]).name
                if executable == "git":
                    return True, True, b"archive ok"
                if executable == "tar":
                    work = Path(argv[argv.index("-C") + 1])
                    (work / ".github/workflows").mkdir(parents=True)
                    (work / "tests").mkdir(parents=True)
                    (work / ".github/workflows/ci.yml").write_text("name: CI\n")
                    (work / "tests/test_ci_self_hosted_guard.sh").write_text("#!/bin/bash\n")
                    return True, True, b"extract ok"
                if executable == "bash":
                    return False, False, b"timed out"
                raise AssertionError(argv)

            with (
                mock.patch.object(f.platform, "system", return_value="Linux"),
                mock.patch.object(f, "git_identity"),
                mock.patch.object(f, "command", side_effect=lambda name: f"/usr/bin/{name}"),
                mock.patch.object(f, "run_group", side_effect=run_group),
                mock.patch.object(f, "print_failure_tail"),
            ):
                checks = f.linux_accept(root, "1" * 40)

        self.assertEqual(checks["workload"], "fail")
        self.assertEqual(checks["semanticVerifier"], "fail")
        self.assertEqual(checks["artifact"], "pass")
        self.assertEqual(checks["processSettlement"], "fail")


    def test_linux_acceptance_checks_distinct_evidence(self):
        commit = "1" * 40
        root = Path.cwd()

        def run_group(argv, cwd, timeout, extra_env=None):
            del timeout, extra_env
            if "tar" in Path(argv[0]).name and "-xf" in argv:
                work = Path(argv[argv.index("-C") + 1])
                (work / ".github/workflows").mkdir(parents=True)
                (work / ".github/workflows/ci.yml").write_text("name: fixture\n")
                (work / "tests").mkdir()
                (work / "tests/test_ci_self_hosted_guard.sh").write_text("# fixture\n")
                return True, True, b""
            if argv[-1] == "tests/test_ci_self_hosted_guard.sh":
                return True, True, b"PASS: guarded fleet routing\n"
            if "test_ci_linux_guard_routing.py" in argv:
                return True, True, b"OK\n"
            return True, True, b""

        with (
            mock.patch.object(f.platform, "system", return_value="Linux"),
            mock.patch.object(f, "git_identity"),
            mock.patch.object(f, "command", side_effect=lambda name: f"/usr/bin/{name}"),
            mock.patch.object(f, "run_group", side_effect=run_group),
        ):
            checks = f.linux_accept(root, commit)

        self.assertEqual(
            checks,
            {
                "workload": "pass",
                "semanticVerifier": "pass",
                "artifact": "pass",
                "processSettlement": "pass",
            },
        )

    def test_linux_semantic_verifier_can_fail_independently(self):
        commit = "1" * 40
        root = Path.cwd()

        def run_group(argv, cwd, timeout, extra_env=None):
            del timeout, extra_env
            if "tar" in Path(argv[0]).name and "-xf" in argv:
                work = Path(argv[argv.index("-C") + 1])
                (work / ".github/workflows").mkdir(parents=True)
                (work / ".github/workflows/ci.yml").write_text("name: fixture\n")
                (work / "tests").mkdir()
                (work / "tests/test_ci_self_hosted_guard.sh").write_text("# fixture\n")
                return True, True, b""
            if argv[-1] == "tests/test_ci_self_hosted_guard.sh":
                return True, True, b"guard exited zero without semantic marker\n"
            return True, True, b"OK\n"

        with (
            mock.patch.object(f.platform, "system", return_value="Linux"),
            mock.patch.object(f, "git_identity"),
            mock.patch.object(f, "command", side_effect=lambda name: f"/usr/bin/{name}"),
            mock.patch.object(f, "run_group", side_effect=run_group),
        ):
            checks = f.linux_accept(root, commit)

        self.assertEqual(checks["workload"], "pass")
        self.assertEqual(checks["artifact"], "pass")
        self.assertEqual(checks["processSettlement"], "pass")
        self.assertEqual(checks["semanticVerifier"], "fail")

    def test_evidence_dispatches_linux_role_and_binds_receipt(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            expected_toolchain = "sha256:" + "a" * 64
            expected_checks = {
                "workload": "pass",
                "semanticVerifier": "pass",
                "artifact": "pass",
                "processSettlement": "pass",
            }
            args = argparse.Namespace(
                role="cmux_linux_ci",
                repo_root=root,
                commit="1" * 40,
                node_id="cmux-fixture-001",
                enrollment_generation=7,
                glaeda_generation="sha256:" + "b" * 64,
                toolchain_generation=expected_toolchain,
                output=None,
            )
            with (
                mock.patch.object(f, "linux_toolchain", return_value=expected_toolchain) as toolchain,
                mock.patch.object(f, "linux_accept", return_value=expected_checks) as accept,
                mock.patch.object(
                    f,
                    "mac_accept",
                    side_effect=AssertionError("Linux role must not dispatch to macOS acceptance"),
                ),
            ):
                document = f.evidence(args)

        toolchain.assert_called_once_with(root)
        accept.assert_called_once_with(root, "1" * 40)
        self.assertEqual(document["role"], "cmux_linux_ci")
        self.assertEqual(document["nodeId"], "cmux-fixture-001")
        self.assertEqual(document["enrollmentGeneration"], 7)
        self.assertEqual(document["checks"], expected_checks)
        self.assertEqual(document["toolchainGeneration"], expected_toolchain)
        self.assertRegex(document["workloadGeneration"], r"^sha256:[0-9a-f]{64}$")

    def test_parser_rejects_abbreviated_protected_option_overrides(self):
        for option in ("--rol=cmux_macos_native_build", "--repo-r=/tmp"):
            with self.subTest(option=option), self.assertRaises(SystemExit):
                f.parser().parse_args([
                    "--role", "cmux_linux_ci",
                    "--repo-root", ".",
                    "--commit", "1" * 40,
                    "--node-id", "cmux-fixture-001",
                    "--enrollment-generation", "1",
                    "--glaeda-generation", "sha256:" + "a" * 64,
                    "--toolchain-generation", "sha256:" + "b" * 64,
                    option,
                ])

    def test_parser_rejects_abbreviated_protected_options(self):
        for option in ("--rol=cmux_linux_ci", "--repo-r=/tmp/other"):
            with self.subTest(option=option), self.assertRaises(SystemExit):
                f.parser().parse_args([
                    option,
                    "--commit", "1" * 40,
                    "--node-id", "cmux-fixture-001",
                    "--enrollment-generation", "1",
                    "--glaeda-generation", "sha256:" + "a" * 64,
                    "--toolchain-generation", "sha256:" + "b" * 64,
                ])

    def test_named_launchers_reject_role_and_repo_root_overrides(self):
        root = Path(__file__).resolve().parents[1]
        for name in (
            "fleet-accept-linux-ci",
            "fleet-accept-macos-native-build",
        ):
            wrapper = root / "scripts" / name
            for arguments in (
                ["--role", "cmux_linux_ci"],
                ["--role=cmux_linux_ci"],
                ["--repo-root", "/tmp"],
                ["--repo-root=/tmp"],
            ):
                with self.subTest(wrapper=name, arguments=arguments):
                    result = subprocess.run(
                        ["bash", str(wrapper), *arguments],
                        cwd=root,
                        stdin=subprocess.DEVNULL,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        check=False,
                    )
                    self.assertEqual(result.returncode, 2)
                    self.assertIn(
                        b"fixes --role and --repo-root",
                        result.stderr,
                    )

    def test_exact_commit_rejects_abbreviation(self):
        with self.assertRaisesRegex(f.AcceptanceError, "40-hex"):
            f.git_identity(Path.cwd(), "abc")


if __name__ == "__main__":
    unittest.main()
