#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "scripts/ci/cmux_workload_profile.py"
SPEC = importlib.util.spec_from_file_location("cmux_workload_profile", RUNNER)
assert SPEC and SPEC.loader
profile = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(profile)


def valid_result() -> dict[str, object]:
    value: dict[str, object] = {
        "document_type": "cmux-workload-result",
        "schema_version": 1,
        "source": {
            "repository": "manaflow-ai/cmux",
            "commit": "1" * 40,
            "tree": "2" * 40,
        },
        "profile": {"id": "cmux.ci.guard", "generation": 1},
        "semantic_validator": "cmux.ci-guard/v1",
        "expected_result_class": "cmux.ci-guard-result/v1",
        "result": "passed",
        "parameters": {},
        "runtime_input_identities": [],
        "artifact_identities": [],
        "validation": {"missing_required_artifact_classes": []},
        "stage_timings": [],
        "resource_summary": {
            "resource_class": "cmux-linux-ci-small",
            "cpu_count": 4,
            "memory_bytes": 1024,
            "architecture": "x86_64",
        },
        "toolchain": {
            "identity": profile.sha256_bytes(
                profile.canonical_bytes({"python": "3"})
            ),
            "observations": {"python": "3"},
        },
        "benchmark": {
            "state_class": "cold",
            "semantic_comparison_key": "sha256:" + "a" * 64,
            "comparison_context_key": "sha256:" + "b" * 64,
        },
        "network_class": "none",
        "timeout_class": "portable-short",
        "cleanup": {"state": "complete", "process_group_settled": True},
        "exit_code": 0,
        "started_at_unix_millis": 1,
        "ended_at_unix_millis": 2,
    }
    value["toolchain"]["identity"] = profile.sha256_bytes(
        profile.canonical_bytes(value["toolchain"]["observations"])
    )
    semantic = profile.semantic_key(
        value["source"],
        {
            "id": value["profile"]["id"],
            "generation": value["profile"]["generation"],
            "semantic_validator": value["semantic_validator"],
        },
        value["parameters"],
        value["runtime_input_identities"],
    )
    value["benchmark"]["semantic_comparison_key"] = semantic
    value["benchmark"]["comparison_context_key"] = profile.context_key(
        semantic,
        value["benchmark"]["state_class"],
        value["toolchain"]["identity"],
    )
    return value


class WorkloadProfileTests(unittest.TestCase):
    def command(self, *args: str) -> subprocess.CompletedProcess[bytes]:
        return subprocess.run(
            [sys.executable, str(RUNNER), *args],
            cwd=ROOT,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_registry_validates_through_runner(self) -> None:
        completed = self.command("validate")
        self.assertEqual(completed.returncode, 0, completed.stderr.decode())

    def test_list_exposes_first_generation_semantic_identities(self) -> None:
        completed = self.command("list")
        self.assertEqual(completed.returncode, 0, completed.stderr.decode())
        rows = json.loads(completed.stdout)
        identities = {(row["id"], row["generation"]) for row in rows}
        self.assertEqual(
            identities,
            {
                ("cmux.macos.compile-admission", 1),
                ("cmux.macos.dev-check", 1),
                ("cmux.macos.app-host-test-shard", 1),
                ("cmux.ci.guard", 1),
            },
        )

    def test_describe_keeps_semantic_generation_explicit(self) -> None:
        completed = self.command("describe", "cmux.macos.compile-admission")
        self.assertEqual(completed.returncode, 0, completed.stderr.decode())
        value = json.loads(completed.stdout)
        self.assertEqual(value["semantic_identity"], "cmux.macos.compile-admission@1")
        self.assertEqual(
            value["entrypoint"],
            "scripts/ci/workloads/macos-compile-admission.sh",
        )

    def test_parameters_are_bounded_by_profile_contract(self) -> None:
        registry = profile.load_registry()
        shard = profile.profile_by_id(registry, "cmux.macos.app-host-test-shard")
        self.assertEqual(profile.parse_parameters(shard, ["shard=1"]), {"shard": 1})
        with self.assertRaisesRegex(profile.ProfileError, "between 1 and 6"):
            profile.parse_parameters(shard, ["shard=7"])
        with self.assertRaisesRegex(profile.ProfileError, "unknown profile parameter"):
            profile.parse_parameters(shard, ["command=1"])

    def test_comparison_rejects_state_or_toolchain_drift(self) -> None:
        base = valid_result()
        changed = json.loads(json.dumps(base))
        changed["toolchain"]["observations"]["python"] = "4"
        changed["toolchain"]["identity"] = profile.sha256_bytes(
            profile.canonical_bytes(changed["toolchain"]["observations"])
        )
        changed["benchmark"]["comparison_context_key"] = profile.context_key(
            changed["benchmark"]["semantic_comparison_key"],
            changed["benchmark"]["state_class"],
            changed["toolchain"]["identity"],
        )
        with tempfile.TemporaryDirectory() as directory:
            left = Path(directory) / "left.json"
            right = Path(directory) / "right.json"
            left.write_text(json.dumps(base), encoding="utf-8")
            right.write_text(json.dumps(changed), encoding="utf-8")
            completed = self.command("compare", str(left), str(right))
        self.assertEqual(completed.returncode, 2)
        result = json.loads(completed.stdout)
        self.assertFalse(result["comparable"])
        self.assertIn("benchmark context differs", result["reasons"])

    def test_comparison_accepts_same_semantics_and_context(self) -> None:
        value = valid_result()
        with tempfile.TemporaryDirectory() as directory:
            left = Path(directory) / "left.json"
            right = Path(directory) / "right.json"
            left.write_text(json.dumps(value), encoding="utf-8")
            right.write_text(json.dumps(value), encoding="utf-8")
            completed = self.command("compare", str(left), str(right))
        self.assertEqual(completed.returncode, 0, completed.stderr.decode())
        self.assertTrue(json.loads(completed.stdout)["comparable"])

    def test_comparison_rejects_truncated_results(self) -> None:
        value = valid_result()
        cases = []
        missing_benchmark = json.loads(json.dumps(value))
        missing_benchmark["benchmark"].pop("semantic_comparison_key")
        cases.append(missing_benchmark)
        missing_validation = json.loads(json.dumps(value))
        missing_validation["validation"].pop("missing_required_artifact_classes")
        cases.append(missing_validation)
        for index, truncated in enumerate(cases):
            with self.subTest(index=index), tempfile.TemporaryDirectory() as directory:
                left = Path(directory) / "left.json"
                right = Path(directory) / "right.json"
                left.write_text(json.dumps(truncated), encoding="utf-8")
                right.write_text(json.dumps(truncated), encoding="utf-8")
                completed = self.command("compare", str(left), str(right))
            self.assertEqual(completed.returncode, 64)
            self.assertIn(b"structure", completed.stderr)

    def test_comparison_rejects_toolchain_identity_observation_mismatch(self) -> None:
        value = valid_result()
        value["toolchain"]["observations"]["python"] = "different"
        with tempfile.TemporaryDirectory() as directory:
            left = Path(directory) / "left.json"
            right = Path(directory) / "right.json"
            left.write_text(json.dumps(value), encoding="utf-8")
            right.write_text(json.dumps(value), encoding="utf-8")
            completed = self.command("compare", str(left), str(right))
        self.assertEqual(completed.returncode, 64)
        self.assertIn(b"toolchain identity is inconsistent", completed.stderr)

    def test_comparison_rejects_self_inconsistent_semantic_receipt(self) -> None:
        value = valid_result()
        value["profile"]["generation"] = 2
        with tempfile.TemporaryDirectory() as directory:
            left = Path(directory) / "left.json"
            right = Path(directory) / "right.json"
            left.write_text(json.dumps(value), encoding="utf-8")
            right.write_text(json.dumps(value), encoding="utf-8")
            completed = self.command("compare", str(left), str(right))
        self.assertEqual(completed.returncode, 64)
        self.assertIn(b"comparison identity is inconsistent", completed.stderr)

    def test_source_identity_rejects_untracked_nonignored_files(self) -> None:
        def fake_git_text(*arguments: str) -> str:
            if arguments == ("rev-parse", "HEAD^{commit}"):
                return "1" * 40
            if arguments == ("rev-parse", "HEAD^{tree}"):
                return "2" * 40
            if arguments and arguments[0] == "status":
                return "?? stray-source.swift"
            if arguments == ("submodule", "status", "--recursive"):
                return ""
            raise AssertionError(arguments)

        clean_diff = mock.Mock(returncode=0)
        with (
            mock.patch.object(profile, "git_text", side_effect=fake_git_text),
            mock.patch.object(profile.subprocess, "run", return_value=clean_diff),
        ):
            with self.assertRaisesRegex(
                profile.ProfileError, "non-ignored source changes"
            ):
                profile.source_identity(None, None)

    def test_source_identity_rejects_dirty_materialized_submodule_bytes(self) -> None:
        calls = []

        def fake_git_text(*arguments: str) -> str:
            calls.append(arguments)
            if arguments == ("rev-parse", "HEAD^{commit}"):
                return "1" * 40
            if arguments == ("rev-parse", "HEAD^{tree}"):
                return "2" * 40
            if arguments and arguments[0] == "status":
                if "--ignore-submodules=none" not in arguments:
                    raise AssertionError(arguments)
                return " m ghostty"
            if arguments == ("submodule", "status", "--recursive"):
                return " " + "3" * 40 + " ghostty (heads/main)"
            raise AssertionError(arguments)

        clean_diff = mock.Mock(returncode=0)
        with (
            mock.patch.object(profile, "git_text", side_effect=fake_git_text),
            mock.patch.object(profile.subprocess, "run", return_value=clean_diff),
        ):
            with self.assertRaisesRegex(
                profile.ProfileError,
                "non-ignored source changes",
            ):
                profile.source_identity(None, None)

        status_call = next(arguments for arguments in calls if arguments[0] == "status")
        self.assertIn("--ignore-submodules=none", status_call)
        self.assertNotIn("--ignore-submodules=dirty", status_call)

    def test_source_identity_accepts_clean_materialized_gitlink(self) -> None:
        def fake_git_text(*arguments: str) -> str:
            if arguments == ("rev-parse", "HEAD^{commit}"):
                return "1" * 40
            if arguments == ("rev-parse", "HEAD^{tree}"):
                return "2" * 40
            if arguments and arguments[0] == "status":
                return ""
            if arguments == ("submodule", "status", "--recursive"):
                return " " + "3" * 40 + " ghostty (heads/main)"
            raise AssertionError(arguments)

        clean_diff = mock.Mock(returncode=0)
        with (
            mock.patch.object(profile, "git_text", side_effect=fake_git_text),
            mock.patch.object(profile.subprocess, "run", return_value=clean_diff),
        ):
            value = profile.source_identity(None, None)

        self.assertEqual(value["commit"], "1" * 40)

    def test_comparison_rejects_toolchain_identity_observation_mismatch(self) -> None:
        value = valid_result()
        value["toolchain"]["observations"]["python"] = "changed"
        with tempfile.TemporaryDirectory() as directory:
            left = Path(directory) / "left.json"
            right = Path(directory) / "right.json"
            left.write_text(json.dumps(value), encoding="utf-8")
            right.write_text(json.dumps(value), encoding="utf-8")
            completed = self.command("compare", str(left), str(right))
        self.assertEqual(completed.returncode, 64)
        self.assertIn(b"toolchain identity is inconsistent", completed.stderr)

    def test_runtime_product_identity_covers_neighboring_product_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            products = Path(directory) / "Build" / "Products"
            products.mkdir(parents=True)
            xctestrun = products / "cmuxTests.xctestrun"
            xctestrun.write_text("manifest", encoding="utf-8")
            app = products / "Debug" / "cmux DEV.app" / "Contents" / "MacOS"
            app.mkdir(parents=True)
            binary = app / "cmux DEV"
            binary.write_bytes(b"one")
            spec = {
                "runtime_inputs": [{
                    "name": "app_host_xctestrun",
                    "env": "CMUX_APP_HOST_XCTESTRUN",
                    "class": "cmux.app-host-product-tree/v1",
                    "identity": "parent-tree-sha256",
                    "required": True,
                }]
            }
            with mock.patch.dict(
                "os.environ",
                {"CMUX_APP_HOST_XCTESTRUN": str(xctestrun)},
                clear=False,
            ):
                first = profile.runtime_inputs(spec)[0]["sha256"]
                binary.write_bytes(b"two")
                second = profile.runtime_inputs(spec)[0]["sha256"]
        self.assertNotEqual(first, second)

    def test_forced_cleanup_receipt_reports_unsettled_process_group(self) -> None:
        registry = profile.load_registry()
        workload = profile.profile_by_id(registry, "cmux.ci.guard")
        commit = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        tree = subprocess.run(
            ["git", "rev-parse", "HEAD^{tree}"],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

        class Child:
            pid = 4242

            def wait(self, timeout=None):
                return 0

        with tempfile.TemporaryDirectory() as directory:
            result_path = Path(directory) / "result.json"
            args = mock.Mock(
                profile=workload["id"],
                generation=workload["generation"],
                commit=commit,
                tree=tree,
                param=[],
                state_class="cold",
                state_root=None,
                result=str(result_path),
            )
            with (
                mock.patch.object(
                    profile,
                    "source_identity",
                    return_value={
                        "repository": "manaflow-ai/cmux",
                        "commit": commit,
                        "tree": tree,
                    },
                ),
                mock.patch.object(profile.subprocess, "Popen", return_value=Child()),
                mock.patch.object(profile, "runtime_inputs", return_value=[]),
                mock.patch.object(profile, "settle_process_group", return_value=(False, "forced")),
                mock.patch.object(profile, "collect_artifacts", return_value=([], [])),
                mock.patch.object(
                    profile,
                    "toolchain_summary",
                    return_value={
                        "identity": "sha256:" + "a" * 64,
                        "observations": {"fixture": "forced"},
                    },
                ),
                mock.patch.object(profile, "read_stage_timings", return_value=[]),
                mock.patch.object(profile, "memory_bytes", return_value=1024),
                mock.patch.object(profile, "normalized_arch", return_value="x86_64"),
            ):
                status = profile.run_profile(args)
            result = json.loads(result_path.read_text())

        self.assertEqual(status, 1)
        self.assertEqual(result["result"], "ambiguous")
        self.assertEqual(result["cleanup"]["state"], "forced")
        self.assertFalse(result["cleanup"]["process_group_settled"])

    def test_app_host_workload_fails_closed_on_planner_errors_and_empty_filters(self) -> None:
        script = (
            ROOT / "scripts/ci/workloads/macos-app-host-test-shard.sh"
        ).read_text(encoding="utf-8")
        self.assertIn('|| plan_status=$?', script)
        self.assertIn('if [[ "$plan_status" -ne 0 ]]', script)
        self.assertIn('return "$plan_status"', script)
        self.assertIn('if [[ "${#only_testing_args[@]}" -eq 0 ]]', script)
        self.assertIn('shard planner produced no test arguments', script)
        syntax = subprocess.run(
            ["bash", "-n", "scripts/ci/workloads/macos-app-host-test-shard.sh"],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(syntax.returncode, 0, syntax.stderr.decode())

    def test_unused_legacy_result_validator_is_absent(self) -> None:
        self.assertFalse(hasattr(profile, "validate_result_document"))

    def test_runtime_product_tree_rejects_external_or_dangling_symlinks(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            products = root / "products"
            products.mkdir()
            inside = products / "inside"
            inside.write_text("inside", encoding="utf-8")
            (products / "internal-link").symlink_to("inside")
            profile.sha256_tree(products)

            outside = root / "outside"
            outside.write_text("outside", encoding="utf-8")
            escaping = products / "escape"
            escaping.symlink_to(outside)
            with self.assertRaisesRegex(
                profile.ProfileError, "symlink escapes or dangles"
            ):
                profile.sha256_tree(products)
            escaping.unlink()

            (products / "dangling").symlink_to("missing")
            with self.assertRaisesRegex(
                profile.ProfileError, "symlink escapes or dangles"
            ):
                profile.sha256_tree(products)

    def test_settlement_kills_leaked_group_without_polling(self) -> None:
        with (
            mock.patch.object(profile, "process_group_alive", return_value=True),
            mock.patch.object(profile.os, "killpg") as killpg,
        ):
            self.assertEqual(profile.settle_process_group(1234), (False, "forced"))
        killpg.assert_called_once_with(1234, profile.signal.SIGKILL)



if __name__ == "__main__":
    unittest.main()
