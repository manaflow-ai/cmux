#!/usr/bin/env python3
"""Behavior-level tests for the target-scale benchmark contract.

These tests deliberately run on Linux/CI too.  macOS command parsing is fed
fixture text, while the four acceptance faults are injected through the pure
budget evaluator.  No test launches cmux or charges child RSS to app budgets.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import perf_target_scale as runner  # noqa: E402
import perf_target_scale_metrics as metrics  # noqa: E402


class TargetScaleMetricsTests(unittest.TestCase):
    def test_size_parser_accepts_macos_units(self) -> None:
        self.assertEqual(metrics.parse_size("1K"), 1024)
        self.assertEqual(metrics.parse_size("1.5 MB"), int(1.5 * metrics.BYTES_PER_MIB))
        self.assertEqual(metrics.parse_size("12,345"), 12345)

    def test_footprint_parser_keeps_gpu_categories_separate(self) -> None:
        parsed = metrics.parse_footprint_output(
            """
            Physical footprint: 500.0M
            Peak physical footprint: 512.0M
            Dirty Graphics: 120.0M
            IOSurface: 40.0M
            IOAccelerator: 12.0M
            """
        )
        self.assertEqual(parsed["phys_footprint_bytes"], 500 * metrics.BYTES_PER_MIB)
        self.assertEqual(parsed["phys_footprint_peak_bytes"], 512 * metrics.BYTES_PER_MIB)
        self.assertEqual(parsed["dirty_graphics_bytes"], 120 * metrics.BYTES_PER_MIB)
        self.assertEqual(parsed["iosurface_bytes"], 40 * metrics.BYTES_PER_MIB)
        self.assertEqual(parsed["ioaccelerator_bytes"], 12 * metrics.BYTES_PER_MIB)

    def test_footprint_parser_reads_dirty_before_table_category(self) -> None:
        parsed = metrics.parse_footprint_output(
            """
             53 MB        0 B        0 B         27    IOSurface
             39 MB        0 B      9152 KB      164    IOAccelerator (graphics)
             11 MB        0 B        0 B          4    Owned physical footprint (unmapped) (graphics)
            Auxiliary data:
                phys_footprint: 110 MB
                phys_footprint_peak: 120 MB
            """
        )
        self.assertEqual(parsed["phys_footprint_bytes"], 110 * metrics.BYTES_PER_MIB)
        self.assertEqual(parsed["phys_footprint_peak_bytes"], 120 * metrics.BYTES_PER_MIB)
        self.assertEqual(parsed["iosurface_bytes"], 53 * metrics.BYTES_PER_MIB)
        self.assertEqual(parsed["ioaccelerator_bytes"], 39 * metrics.BYTES_PER_MIB)
        self.assertEqual(parsed["dirty_graphics_bytes"], 50 * metrics.BYTES_PER_MIB)

    def test_footprint_parser_reads_camel_case_peak_key(self) -> None:
        parsed = metrics.parse_footprint_output(
            "physicalFootprintPeak: 512M\nphysicalFootprint: 500M\n"
        )
        self.assertEqual(parsed["phys_footprint_bytes"], 500 * metrics.BYTES_PER_MIB)
        self.assertEqual(parsed["phys_footprint_peak_bytes"], 512 * metrics.BYTES_PER_MIB)

    def test_thread_roles_are_stable(self) -> None:
        listing = """\
tid thcomm
1 Main Thread
2 CVDisplayLink
3 Ghostty renderer
4 pty-io
5 dispatch-worker
"""
        parsed = metrics.parse_thread_listing(listing)
        self.assertEqual(parsed["total"], 5)
        self.assertEqual(parsed["roles"]["main"], 1)
        self.assertEqual(parsed["roles"]["display_link"], 1)
        self.assertEqual(parsed["roles"]["renderer"], 1)
        self.assertEqual(parsed["roles"]["pty_io"], 1)
        self.assertEqual(parsed["roles"]["dispatch"], 1)

    def test_balanced_layout_has_exact_visible_panes(self) -> None:
        def leaves(node: dict) -> list[dict]:
            if "pane" in node:
                return [node]
            result: list[dict] = []
            for child in node["children"]:
                result.extend(leaves(child))
            return result

        self.assertEqual(len(leaves(metrics.balanced_layout(5))), 5)
        self.assertEqual(len(leaves(metrics.balanced_layout(1))), 1)

    def test_healthy_series_passes_and_child_workload_is_excluded(self) -> None:
        runs = [metrics.synthetic_run(size) for size in metrics.FIXTURE_SIZES]
        result = metrics.evaluate_series(runs)
        self.assertTrue(result["passed"], result)
        # synthetic_run intentionally carries a huge child RSS value.  It must
        # not become an app-footprint failure.
        self.assertFalse(any(failure["code"] == "child_workload" for failure in result["failures"]))

    def test_each_acceptance_fault_fails_the_expected_budget(self) -> None:
        expected = {
            "hidden-renderer": "gpu_hidden_slope",
            "hidden-wakeup": "cpu_hidden_slope",
            "retained-allocation": "soak_footprint",
            "display-link": "display_link_model",
        }
        for fault, code in expected.items():
            with self.subTest(fault=fault):
                result = metrics.evaluate_series([metrics.synthetic_run(size, fault) for size in metrics.FIXTURE_SIZES])
                self.assertIn(code, {failure["code"] for failure in result["failures"]})

    def test_artifact_is_machine_readable_and_declares_contract(self) -> None:
        artifact = metrics.make_artifact(
            [metrics.synthetic_run(size) for size in metrics.FIXTURE_SIZES],
            metadata={"app_version": "synthetic", "hardware": {"model": "test"}},
        )
        encoded = json.dumps(artifact)
        decoded = json.loads(encoded)
        self.assertEqual(decoded["schema_version"], metrics.SCHEMA_VERSION)
        self.assertEqual(decoded["fixture_contract"]["sizes"], list(metrics.FIXTURE_SIZES))
        self.assertFalse(decoded["fixture_contract"]["child_workload_charged_to_app"])
        self.assertEqual(len(decoded["runs"]), len(metrics.FIXTURE_SIZES))

    def test_short_cpu_sample_is_rejected(self) -> None:
        run = metrics.synthetic_run(200)
        run["cpu"]["duration_seconds"] = metrics.MIN_CPU_SECONDS - 1
        codes = {failure["code"] for failure in metrics.evaluate_run(run)}
        self.assertIn("cpu_duration", codes)

    def test_sparse_cpu_sample_is_unavailable(self) -> None:
        run = metrics.synthetic_run(200)
        run["cpu"]["sample_count"] = 1
        failures = metrics.evaluate_run(run)
        codes = {failure["code"] for failure in failures}
        self.assertIn("cpu_samples", codes)
        self.assertNotIn("idle_cpu", codes)

    def test_missing_app_footprint_is_rejected(self) -> None:
        run = metrics.synthetic_run(10)
        run["first_settled"]["phys_footprint_bytes"] = None
        run["first_settled"]["phys_footprint_peak_bytes"] = None
        codes = {failure["code"] for failure in metrics.evaluate_run(run)}
        self.assertIn("app_footprint_unavailable", codes)

    def test_artifact_preserves_requested_cycle_count(self) -> None:
        artifact = metrics.make_artifact(
            [metrics.synthetic_run(1)],
            metadata={"app_version": "synthetic"},
            reveal_hide_cycles=7,
        )
        self.assertEqual(artifact["fixture_contract"]["reveal_hide_cycles"], 7)


class TargetScaleCliTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.output_dir = Path(self._tmp.name)

    def test_self_test_cli_passes(self) -> None:
        output = self.output_dir / "self-test.json"
        self.assertEqual(runner.main(["--self-test", "--output", str(output)]), 0)
        self.assertFalse(output.exists(), "self-test must not replace the benchmark artifact")
        self.assertTrue((self.output_dir / "self-test.self-test.json").is_file())

    def test_real_run_requires_tag(self) -> None:
        self.assertEqual(
            runner.main(
                [
                    "--sizes",
                    "1",
                    "--cpu-seconds",
                    "30",
                    "--output",
                    str(self.output_dir / "missing-tag.json"),
                ]
            ),
            2,
        )


class TargetScaleFixtureTests(unittest.TestCase):
    class _Runner(runner.TargetScaleRunner):
        def __init__(self, create_payload: dict[str, object]) -> None:
            args = runner._build_parser().parse_args(["--tag", "fixture-test"])
            super().__init__(args)
            self.create_payload = create_payload
            self.calls: list[tuple[str, dict[str, object]]] = []
            self.fail_topology = False
            self.runtime_ready_count = 1
            self.capture_called = False

        def _workspace_ids(self) -> list[str]:
            return ["old-workspace"]

        def _pane_topology(self, workspace_id: str) -> list[dict[str, object]]:
            del workspace_id
            if self.fail_topology:
                raise runner.BenchmarkError("synthetic topology failure")
            return [{"id": "pane", "surface_ids": ["surface"], "selected": "surface"}]

        def _runtime_terminal_stats(self, workspace_id: str) -> dict[str, object]:
            del workspace_id
            return {"reported_count": 1, "runtime_ready_count": self.runtime_ready_count}

        def _seed_scrollback(
            self,
            workspace_id: str,
            panes: list[dict[str, object]],
            scrollback_bytes: int,
        ) -> int:
            del workspace_id, panes
            return scrollback_bytes

        def _assert_visibility(self, workspace_id: str, expected_live: int) -> None:
            del workspace_id, expected_live

        def _settle(self) -> None:
            return None

        def _capture_snapshot(self) -> dict[str, object]:
            self.capture_called = True
            return metrics.synthetic_run(1)["first_settled"]

        def _cycle_visibility(self, workspace_id: str, panes: list[dict[str, object]]) -> None:
            del workspace_id, panes

        def _sample_cpu(self, duration_seconds: float) -> dict[str, object]:
            del duration_seconds
            return metrics.synthetic_run(1)["cpu"]

        def rpc(
            self,
            method: str,
            params: dict[str, object] | None = None,
            *,
            timeout: float = 120.0,
        ) -> dict[str, object]:
            del timeout
            self.calls.append((method, dict(params or {})))
            if method == "workspace.create":
                return self.create_payload
            return {}

    def test_fixture_uses_created_workspace_id_response(self) -> None:
        fixture = self._Runner(
            {"created_workspace_id": "created-workspace", "workspace_id": "stale-workspace"}
        )

        workspace_id, panes = fixture._create_fixture(1)

        self.assertEqual(workspace_id, "created-workspace")
        self.assertEqual(panes[0]["id"], "pane")
        self.assertIn(("workspace.select", {"workspace_id": "created-workspace"}), fixture.calls)
        self.assertIn(("workspace.close", {"workspace_id": "old-workspace"}), fixture.calls)

    def test_fixture_accepts_workspace_id_compatibility_response(self) -> None:
        fixture = self._Runner({"workspace_id": "created-workspace"})

        workspace_id, _panes = fixture._create_fixture(1)

        self.assertEqual(workspace_id, "created-workspace")

    def test_run_size_closes_workspace_when_fixture_setup_raises(self) -> None:
        fixture = self._Runner({"workspace_id": "created-workspace"})
        fixture.fail_topology = True

        with self.assertRaises(runner.BenchmarkError):
            fixture.run_size(1)

        self.assertIn(("workspace.close", {"workspace_id": "created-workspace"}), fixture.calls)

    def test_run_size_rejects_unready_runtime_before_measurement(self) -> None:
        fixture = self._Runner({"workspace_id": "created-workspace"})
        fixture.runtime_ready_count = 0

        with self.assertRaises(runner.BenchmarkError):
            fixture.run_size(1)

        self.assertFalse(fixture.capture_called)

    def test_socket_owner_uses_the_launched_app_only(self) -> None:
        fixture = self._Runner({})
        fixture.proc = SimpleNamespace(pid=42, poll=lambda: None)
        self.assertEqual(fixture.socket_owner_pid(), 42)

    def test_socket_owner_fails_without_live_launched_app(self) -> None:
        fixture = self._Runner({})
        fixture.proc = SimpleNamespace(pid=42, poll=lambda: 0)
        with self.assertRaises(runner.BenchmarkError):
            fixture.socket_owner_pid()

    def test_default_app_path_is_shared_with_metadata(self) -> None:
        args = runner._build_parser().parse_args(["--tag", "Perf.123"])
        expected = runner.default_app_path_for_tag(args.tag)
        self.assertEqual(runner.TargetScaleRunner(args).default_app_path(), expected)
        self.assertEqual(runner._metadata(args)["app_path"], str(expected))

    def test_child_cleanup_escalates_after_term_grace(self) -> None:
        with mock.patch.object(runner, "_wait_for_pids", side_effect=[{123}, set()]) as wait_for_pids:
            with mock.patch.object(runner.os, "kill") as kill:
                self.assertEqual(runner._terminate_pids([123]), set())

        self.assertEqual(wait_for_pids.call_count, 2)
        self.assertEqual(
            kill.call_args_list,
            [mock.call(123, runner.signal.SIGTERM), mock.call(123, runner.signal.SIGKILL)],
        )

    def test_target_scale_workflow_uses_safe_console_home_and_tagged_cleanup(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "perf-target-scale.yml").read_text(encoding="utf-8")
        self.assertNotIn("awk '{print $2}'", workflow)
        self.assertIn("scripts/ci/cleanup-target-scale.sh", workflow)
        cleanup = (ROOT / "scripts" / "ci" / "cleanup-target-scale.sh").read_text(encoding="utf-8")
        self.assertIn("cmuxd-dev-${tag}.sock", cleanup)
        self.assertNotIn("pgrep", cleanup)
        self.assertNotIn("sleep", cleanup)
        self.assertIn("wait-for-pids.py", cleanup)

    def test_activation_workflow_uses_shared_tagged_cleanup(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "perf-activation.yml").read_text(encoding="utf-8")
        cleanup_start = workflow.index("      - name: Cleanup tagged app")
        cleanup = workflow[cleanup_start : cleanup_start + 260]
        self.assertIn("./scripts/ci/cleanup-target-scale.sh \"$PERF_TAG\"", cleanup)
        self.assertNotIn('pkill -f "cmux DEV ${PERF_TAG}', cleanup)

    def test_console_home_helper_preserves_spaces(self) -> None:
        helper = ROOT / "scripts" / "ci" / "console-home.sh"
        self.assertTrue(helper.is_file())
        with tempfile.TemporaryDirectory() as directory:
            fake_bin = Path(directory) / "bin"
            fake_bin.mkdir()
            (fake_bin / "dscl").write_text(
                "#!/bin/sh\nprintf 'NFSHomeDirectory: /Users/Console User\\n'\n",
                encoding="utf-8",
            )
            (fake_bin / "dscl").chmod(0o755)
            result = subprocess.run(
                ["/bin/bash", "-c", f"source '{helper}'; cmux_console_home alice"],
                env={**os.environ, "PATH": f"{fake_bin}:{os.environ['PATH']}"},
                text=True,
                capture_output=True,
                check=False,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "/Users/Console User")


class TargetScaleCleanupTests(unittest.TestCase):
    def test_wait_helper_uses_process_exit_events(self) -> None:
        helper = ROOT / "scripts" / "ci" / "wait-for-pids.py"
        self.assertTrue(helper.is_file())
        source = helper.read_text(encoding="utf-8")
        self.assertIn("KQ_FILTER_PROC", source)
        self.assertIn("KQ_NOTE_EXIT", source)
        if not hasattr(__import__("select"), "kqueue"):
            self.skipTest("process exit kqueue is macOS-only")
        process = subprocess.Popen(["/bin/sleep", "0.05"])
        try:
            result = subprocess.run(
                [sys.executable, str(helper), "--timeout", "2", str(process.pid)],
                text=True,
                capture_output=True,
                check=False,
            )
        finally:
            process.wait()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "")

    def test_cleanup_script_reaps_tagged_processes_and_both_sockets(self) -> None:
        script = ROOT / "scripts" / "ci" / "cleanup-target-scale.sh"
        self.assertTrue(script.is_file())
        tag = f"test-cleanup-{os.getpid()}"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            log = root / "signals.log"
            bash_env = root / "bash-env"
            home = root / "home"
            cmuxd_socket = home / "Library" / "Application Support" / "cmux" / f"cmuxd-dev-{tag}.sock"
            cmuxd_socket.parent.mkdir(parents=True)
            cmuxd_socket.touch()

            (fake_bin / "ps").write_text(
                "#!/bin/sh\n"
                "case \" $* \" in\n"
                "  *' -o user= -p '* ) printf 'console\\n' ;;\n"
                "  * ) printf '123 cmux DEV %s.app/Contents/MacOS/cmux DEV\\n' \"$CMUX_TEST_TAG\"; printf '456 cmuxd-dev-%s.sock\\n' \"$CMUX_TEST_TAG\"; printf '789 cmux DEV perfX123.app/Contents/MacOS/cmux DEV\\n' ;;\n"
                "esac\n",
                encoding="utf-8",
            )
            (fake_bin / "lsof").write_text("#!/bin/sh\nprintf '456\\n'\n", encoding="utf-8")
            (fake_bin / "date").write_text(
                "#!/bin/sh\n"
                "printf '100\\n'\n",
                encoding="utf-8",
            )
            bash_env.write_text(
                "kill() {\n"
                "  printf '%s %s\\n' \"$1\" \"$2\" >> \"$CMUX_TEST_SIGNAL_LOG\"\n"
                "  return 0\n"
                "}\n",
                encoding="utf-8",
            )
            for command in fake_bin.iterdir():
                command.chmod(0o755)

            result = subprocess.run(
                ["bash", str(script), tag],
                cwd=ROOT,
                env={
                    **os.environ,
                    "HOME": str(home),
                    "PATH": f"{fake_bin}:{os.environ['PATH']}",
                    "CMUX_TEST_SIGNAL_LOG": str(log),
                    "CMUX_TEST_TAG": tag,
                    "CMUX_CLEANUP_TERM_GRACE_SECONDS": "0",
                    "BASH_ENV": str(bash_env),
                },
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(cmuxd_socket.exists())
            signals = log.read_text(encoding="utf-8")
            self.assertIn("-TERM 123", signals)
            self.assertIn("-TERM 456", signals)
            self.assertIn("-KILL 123", signals, result.stderr)

    def test_cleanup_executes_wait_helper_with_nonzero_grace(self) -> None:
        script = ROOT / "scripts" / "ci" / "cleanup-target-scale.sh"
        helper = ROOT / "scripts" / "ci" / "wait-for-pids.py"
        self.assertTrue(os.access(helper, os.X_OK), "wait helper must remain executable")
        tag = "test-cleanup-wait-helper"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            signal_log = root / "signals.log"
            helper_log = root / "wait-helper.log"
            bash_env = root / "bash-env"
            (fake_bin / "ps").write_text(
                "#!/bin/sh\n"
                "case \" $* \" in\n"
                "  *' -o user= -p '* ) printf 'runner\\n' ;;\n"
                "  * ) printf '123 cmux DEV %s.app/Contents/MacOS/cmux DEV\\n' \"$CMUX_TEST_TAG\" ;;\n"
                "esac\n",
                encoding="utf-8",
            )
            (fake_bin / "lsof").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            # The helper is launched through its executable shebang.  This
            # shim records the argv and returns the tagged PID as still
            # pending, so the test covers TERM -> wait -> KILL escalation.
            (fake_bin / "python3").write_text(
                "#!/bin/sh\n"
                "printf '%s|%s\\n' \"$*\" \"$CMUX_WAIT_PIDS\" >> \"$CMUX_WAIT_HELPER_LOG\"\n"
                "printf '123\\n'\n",
                encoding="utf-8",
            )
            bash_env.write_text(
                "kill() { printf '%s %s\\n' \"$1\" \"$2\" >> \"$CMUX_TEST_SIGNAL_LOG\"; return 0; }\n",
                encoding="utf-8",
            )
            for command in fake_bin.iterdir():
                command.chmod(0o755)

            result = subprocess.run(
                ["bash", str(script), tag],
                cwd=ROOT,
                env={
                    **os.environ,
                    "HOME": str(root / "home"),
                    "PATH": f"{fake_bin}:{os.environ['PATH']}",
                    "CMUX_TEST_TAG": tag,
                    "CMUX_TEST_SIGNAL_LOG": str(signal_log),
                    "CMUX_WAIT_HELPER_LOG": str(helper_log),
                    "CMUX_CLEANUP_TERM_GRACE_SECONDS": "1",
                    "BASH_ENV": str(bash_env),
                },
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            helper_call = helper_log.read_text(encoding="utf-8")
            self.assertIn("wait-for-pids.py", helper_call)
            self.assertIn("--timeout 1", helper_call)
            self.assertIn("123", helper_call)
            signals = signal_log.read_text(encoding="utf-8")
            self.assertIn("-TERM 123", signals)
            self.assertIn("-KILL 123", signals)

    def test_cleanup_revalidates_tag_before_kill_and_uses_literal_matching(self) -> None:
        script = ROOT / "scripts" / "ci" / "cleanup-target-scale.sh"
        tag = "test.cleanup"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            log = root / "signals.log"
            state = root / "ps-state"
            bash_env = root / "bash-env"
            (fake_bin / "ps").write_text(
                "#!/bin/sh\n"
                "if [ \"$1\" = '-o' ] && [ \"$2\" = 'user=' ]; then printf 'runner\\n'; exit 0; fi\n"
                "if [ ! -e \"$CMUX_TEST_PS_STATE\" ]; then\n"
                "  printf '123 cmux DEV %s.app/Contents/MacOS/cmux DEV\\n' \"$CMUX_TEST_TAG\"\n"
                "  : > \"$CMUX_TEST_PS_STATE\"\n"
                "else\n"
                "  printf '123 unrelated-reused-process\\n'\n"
                "fi\n",
                encoding="utf-8",
            )
            (fake_bin / "lsof").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            (fake_bin / "date").write_text("#!/bin/sh\nprintf '100\\n'\n", encoding="utf-8")
            bash_env.write_text(
                "kill() { printf '%s %s\\n' \"$1\" \"$2\" >> \"$CMUX_TEST_SIGNAL_LOG\"; return 0; }\n",
                encoding="utf-8",
            )
            for command in fake_bin.iterdir():
                command.chmod(0o755)
            result = subprocess.run(
                ["bash", str(script), tag],
                cwd=ROOT,
                env={
                    **os.environ,
                    "HOME": str(root / "home"),
                    "PATH": f"{fake_bin}:{os.environ['PATH']}",
                    "CMUX_TEST_TAG": tag,
                    "CMUX_TEST_PS_STATE": str(state),
                    "CMUX_TEST_SIGNAL_LOG": str(log),
                    "CMUX_CLEANUP_TERM_GRACE_SECONDS": "0",
                    "BASH_ENV": str(bash_env),
                },
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            signals = log.read_text(encoding="utf-8")
            self.assertIn("-TERM 123", signals)
            self.assertNotIn("-KILL 123", signals, result.stderr)
            self.assertNotIn("789", signals)

    def test_cleanup_elevates_when_console_user_owns_processes(self) -> None:
        script = ROOT / "scripts" / "ci" / "cleanup-target-scale.sh"
        tag = "test-cleanup-permissions"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            log = root / "signals.log"
            sudo_log = root / "sudo.log"
            bash_env = root / "bash-env"
            (fake_bin / "ps").write_text(
                "#!/bin/sh\n"
                "case \" $* \" in\n"
                "  *' -o user= -p '* ) printf 'console\\n' ;;\n"
                "  * ) printf '123 cmux DEV %s.app/Contents/MacOS/cmux DEV\\n' \"$CMUX_TEST_TAG\" ;;\n"
                "esac\n",
                encoding="utf-8",
            )
            (fake_bin / "lsof").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            (fake_bin / "sudo").write_text(
                "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$CMUX_TEST_SUDO_LOG\"\nexit 0\n",
                encoding="utf-8",
            )
            (fake_bin / "stat").write_text("#!/bin/sh\nprintf 'console\\n'\n", encoding="utf-8")
            (fake_bin / "dscl").write_text(
                "#!/bin/sh\nprintf 'NFSHomeDirectory: %s\\n' \"$CMUX_TEST_CONSOLE_HOME\"\n",
                encoding="utf-8",
            )
            bash_env.write_text(
                "kill() { printf '%s %s\\n' \"$1\" \"$2\" >> \"$CMUX_TEST_SIGNAL_LOG\"; return 1; }\n",
                encoding="utf-8",
            )
            for command in fake_bin.iterdir():
                command.chmod(0o755)
            result = subprocess.run(
                ["bash", str(script), tag],
                cwd=ROOT,
                env={
                    **os.environ,
                    "HOME": str(root / "runner-home"),
                    "PATH": f"{fake_bin}:{os.environ['PATH']}",
                    "CMUX_TEST_TAG": tag,
                    "CMUX_TEST_SIGNAL_LOG": str(log),
                    "CMUX_TEST_SUDO_LOG": str(sudo_log),
                    "CMUX_TEST_CONSOLE_HOME": str(root / "console home"),
                    "CMUX_CLEANUP_TERM_GRACE_SECONDS": "0",
                    "BASH_ENV": str(bash_env),
                },
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            sudo_calls = sudo_log.read_text(encoding="utf-8")
            self.assertIn("-u console", sudo_calls)
            self.assertIn("/bin/kill -TERM 123", sudo_calls)

    def test_cleanup_fails_when_signal_permission_cannot_be_elevated(self) -> None:
        script = ROOT / "scripts" / "ci" / "cleanup-target-scale.sh"
        tag = "test-cleanup-denied"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            bash_env = root / "bash-env"
            (fake_bin / "ps").write_text(
                "#!/bin/sh\n"
                "if [ \"$1\" = '-o' ]; then printf 'console\\n'; else printf '123 cmux DEV %s.app/Contents/MacOS/cmux DEV\\n' \"$CMUX_TEST_TAG\"; fi\n",
                encoding="utf-8",
            )
            (fake_bin / "lsof").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            (fake_bin / "sudo").write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
            bash_env.write_text(
                "kill() { return 1; }\n",
                encoding="utf-8",
            )
            for command in fake_bin.iterdir():
                command.chmod(0o755)
            result = subprocess.run(
                ["bash", str(script), tag],
                cwd=ROOT,
                env={
                    **os.environ,
                    "HOME": str(root / "home"),
                    "PATH": f"{fake_bin}:{os.environ['PATH']}",
                    "CMUX_TEST_TAG": tag,
                    "CMUX_CLEANUP_TERM_GRACE_SECONDS": "0",
                    "BASH_ENV": str(bash_env),
                },
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unable to signal tagged PID 123", result.stderr)

    def test_cleanup_elevates_socket_removal_for_console_home(self) -> None:
        script = ROOT / "scripts" / "ci" / "cleanup-target-scale.sh"
        tag = "test-cleanup-socket-permissions"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            runner_home = root / "runner-home"
            console_home = root / "console home"
            sockets = [
                runner_home / "Library" / "Application Support" / "cmux" / f"cmuxd-dev-{tag}.sock",
                console_home / "Library" / "Application Support" / "cmux" / f"cmuxd-dev-{tag}.sock",
            ]
            for socket in sockets:
                socket.parent.mkdir(parents=True, exist_ok=True)
                socket.touch()
            sudo_log = root / "sudo.log"
            (fake_bin / "ps").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            (fake_bin / "lsof").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            (fake_bin / "stat").write_text("#!/bin/sh\nprintf 'console\\n'\n", encoding="utf-8")
            (fake_bin / "dscl").write_text(
                "#!/bin/sh\nprintf 'NFSHomeDirectory: %s\\n' \"$CMUX_TEST_CONSOLE_HOME\"\n",
                encoding="utf-8",
            )
            (fake_bin / "rm").write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
            (fake_bin / "sudo").write_text(
                "#!/bin/sh\n"
                "printf '%s\\n' \"$*\" >> \"$CMUX_TEST_SUDO_LOG\"\n"
                "last=\"\"; for arg in \"$@\"; do last=\"$arg\"; done\n"
                "case \"$*\" in */bin/rm*) /bin/rm -f \"$last\" ;; esac\n"
                "exit 0\n",
                encoding="utf-8",
            )
            for command in fake_bin.iterdir():
                command.chmod(0o755)
            result = subprocess.run(
                ["bash", str(script), tag],
                cwd=ROOT,
                env={
                    **os.environ,
                    "HOME": str(runner_home),
                    "PATH": f"{fake_bin}:{os.environ['PATH']}",
                    "CMUX_TEST_CONSOLE_HOME": str(console_home),
                    "CMUX_TEST_SUDO_LOG": str(sudo_log),
                    "CMUX_CLEANUP_TERM_GRACE_SECONDS": "0",
                },
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(all(not socket.exists() for socket in sockets))
            self.assertIn("/bin/rm", sudo_log.read_text(encoding="utf-8"))


class TargetScaleArtifactTests(unittest.TestCase):
    def test_junit_emits_one_case_per_budget_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "target-scale.junit.xml"
            runner._write_junit(
                output,
                {
                    "evaluation": {
                        "failures": [
                            {"code": "cpu_hidden_slope", "message": "CPU slope exceeded"},
                            {"code": "soak_footprint", "message": "footprint grew"},
                        ]
                    }
                },
            )
            suite = ET.parse(output).getroot()

        self.assertEqual(suite.attrib["tests"], "2")
        self.assertEqual(suite.attrib["failures"], "2")
        cases = suite.findall("testcase")
        self.assertEqual([case.attrib["name"] for case in cases], ["cpu_hidden_slope_0", "soak_footprint_1"])
        self.assertEqual(
            [case.find("failure").attrib["type"] for case in cases],
            ["cpu_hidden_slope", "soak_footprint"],
        )

    def test_junit_emits_a_passing_case_when_no_budget_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "target-scale.junit.xml"
            runner._write_junit(output, {"evaluation": {"failures": []}})
            suite = ET.parse(output).getroot()

        self.assertEqual(suite.attrib["tests"], "1")
        self.assertEqual(suite.attrib["failures"], "0")
        self.assertEqual(len(suite.findall("testcase")), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
