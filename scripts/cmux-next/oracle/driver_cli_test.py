#!/usr/bin/env python3
"""Offline tests of driver_cli.py (p15-oracle-048): no daemon, no app, no build.

Run: python3 -I scripts/cmux-next/oracle/driver_cli_test.py
The live test is `driver_cli.py smoke --binary CMUX_TUI` on the VM (50 daemon CLI cases, each twice).
"""

from __future__ import annotations

import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from typing import List, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import case_checks  # noqa: E402
import driver_cli  # noqa: E402
import normalize  # noqa: E402

CASE_SCHEMA = REPO / "schemas" / "oracle" / "case-v1.schema.json"
WS = "ws_" + "a" * 32
WS2 = "ws_" + "b" * 32
PANE = "pane_" + "c" * 32


def schema() -> normalize.Schema:
    loaded, refusal = driver_cli.load_snapshot_schema(str(normalize.DEFAULT_SCHEMA))
    if loaded is None:
        raise unittest.SkipTest(f"normalize.py refuses the snapshot schema at this base: {refusal}")
    return loaded


def output(stdout: object, exit_code: int = 0, stderr: bytes = b"") -> driver_cli.CliOutput:
    text = stdout if isinstance(stdout, str) else json.dumps(stdout)
    return driver_cli.CliOutput(exit_code, text.encode(), stderr)


class FakeRunner(driver_cli.CliRunner):
    def __init__(self, outputs: Sequence[driver_cli.CliOutput]):
        self.outputs = list(outputs)
        self.calls: List[Tuple[List[str], Optional[str]]] = []

    def run(self, argv, stdin, timeout):
        self.calls.append((list(argv), stdin))
        return self.outputs.pop(0)

    def describe(self) -> str:
        return "fake"


def executable(directory: Path, name: str) -> Path:
    path = directory / name
    path.write_text("#!/bin/sh\nexit 0\n")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return path


class NeverTmpCmuxCli(unittest.TestCase):
    def test_the_tmp_cli_is_refused_by_path_symlink_and_name(self) -> None:
        with self.assertRaisesRegex(ValueError, "/tmp/cmux-cli"):
            driver_cli.CliBinary(Path("/tmp/cmux-cli"))
        with tempfile.TemporaryDirectory() as tmp:
            link = Path(tmp) / "cmux"
            link.symlink_to("/tmp/cmux-cli")
            self.assertTrue(driver_cli.forbidden_cli(link))
            self.assertTrue(driver_cli.forbidden_cli(Path(tmp) / "cmux-cli"))
            self.assertFalse(driver_cli.forbidden_cli(executable(Path(tmp), "cmux-tui")))

    @unittest.skipUnless(Path("/proc/self/cmdline").exists(), "reads argv[0] from /proc")
    def test_vm_runs_the_binary_as_cmux_with_the_case_env_only(self) -> None:
        # /bin/sh stands in for cmux-tui: `-c` prints its own argv[0] (a script's shebang would hide it).
        script = ('printf \'{"argv0":"%s","socket":"%s","home":"%s","tag":"%s"}\' '
                  '"$(tr "\\0" "\\n" < /proc/$$/cmdline | head -n 1)" "$CMUX_TUI_SOCKET" "$HOME" "$CMUX_TAG"')
        with tempfile.TemporaryDirectory() as tmp:
            env = {"PATH": "/usr/bin:/bin", "CMUX_TUI_SOCKET": "/tmp/o/a/b/s.sock", "HOME": tmp}
            os.environ["CMUX_TAG"] = "leaks-if-inherited"
            try:
                vm = driver_cli.VmCli(driver_cli.CliBinary(Path("/bin/sh")), env, tmp)
                got = vm.run(["-c", script], None, 10)
            finally:
                del os.environ["CMUX_TAG"]
            value = json.loads(got.stdout)
            self.assertEqual(value, {"argv0": "cmux", "socket": "/tmp/o/a/b/s.sock", "home": tmp, "tag": ""})

    def test_fleet_runs_cmux_debug_cli_with_the_tag(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            script = Path(tmp) / "cmux-debug-cli.sh"
            script.write_text('printf \'{"tag":"%s","args":"%s"}\' "$CMUX_TAG" "$*"\n')
            fleet = driver_cli.FleetCli("my-tag", env={"PATH": "/usr/bin:/bin", "CMUX_TAG": "other"}, script=script)
            got = fleet.run(["--json", "workspace", "list"], None, 10)
            self.assertEqual(json.loads(got.stdout), {"tag": "my-tag", "args": "--json workspace list"})
        self.assertEqual(driver_cli.DEBUG_CLI, REPO / "scripts" / "cmux-debug-cli.sh")
        with self.assertRaisesRegex(ValueError, "not a cmux tag"):
            driver_cli.FleetCli("bad tag")

    def test_open_session_picks_one_mode(self) -> None:
        with self.assertRaisesRegex(ValueError, "two modes"):
            driver_cli.open_session({"binary": "/bin/true", "tag": "t"})
        with self.assertRaisesRegex(ValueError, "--binary .* or --tag"):
            driver_cli.open_session({})
        with self.assertRaisesRegex(ValueError, "/tmp/cmux-cli"):
            driver_cli.open_session({"binary": "/tmp/cmux-cli"})

    def test_a_binary_built_at_another_sha_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            binary = executable(Path(tmp), "cmux-tui")
            (Path(tmp) / "build.json").write_text(json.dumps({"sha": "1" * 40}))
            self.assertEqual(driver_cli.build_sha(binary), "1" * 40)
            with self.assertRaisesRegex(ValueError, "not at the run SHA"):
                driver_cli.CliSession({"binary": str(binary), "ref": "2" * 40})


class Receipts(unittest.TestCase):
    def setUp(self) -> None:
        self.schema = schema()
        ctx = normalize.Context(root=("/tmp/o/abc/def",), home=("/tmp/o/abc/def/home",))
        self.normalizer = driver_cli.StdoutNormalizer(driver_cli.IdLabels(self.schema), ctx,
                                                      {"oracle-zmr7ii": "oracle"})

    def test_stdout_forms(self) -> None:
        self.assertEqual(driver_cli.parse_stdout(b'{"a": 1}\n'), {"a": 1})
        self.assertEqual(driver_cli.parse_stdout(b'{"a": 1}\n{"a": 2}\n'), [{"a": 1}, {"a": 2}])
        self.assertEqual(driver_cli.parse_stdout(b"plain text\n"), "plain text\n")
        self.assertEqual(driver_cli.parse_stdout(b""), "")

    def test_paths_names_clock_and_ids_are_normalized_in_sorted_key_order(self) -> None:
        raw = {"z": WS, "a": [WS2, WS], "cwd": "/tmp/o/abc/def/home/x", "session": "oracle-zmr7ii",
               "created_at_ms": "1793014165795", "extra": {"at_ms": 17}, "count": 3}
        receipt, reply = driver_cli.receipt_of(output(raw), self.normalizer)
        self.assertEqual(receipt["exit"], 0)
        self.assertEqual(receipt["stdout"], {
            "a": ["workspace#1", "workspace#2"], "z": "workspace#2", "cwd": "$HOME/x", "session": "oracle",
            "created_at_ms": "$WALL_TIME", "extra": {"at_ms": "$WALL_TIME"}, "count": 3,
        })
        self.assertEqual(reply["stdout"], raw, "$step: references read the raw stdout")

    def test_labels_are_shared_by_the_steps_of_a_case(self) -> None:
        first, _ = driver_cli.receipt_of(output({"value": {"workspace_id": WS}}), self.normalizer)
        second, _ = driver_cli.receipt_of(output([{"id": WS2}, {"id": WS}]), self.normalizer)
        self.assertEqual(first["stdout"]["value"]["workspace_id"], "workspace#1")
        self.assertEqual([item["id"] for item in second["stdout"]], ["workspace#2", "workspace#1"])

    def test_a_virtual_clock_keeps_times(self) -> None:
        normalizer = driver_cli.StdoutNormalizer(driver_cli.IdLabels(self.schema), normalize.Context(),
                                                 wall_clock=lambda: False)
        receipt, _ = driver_cli.receipt_of(output({"at_ms": "5"}), normalizer)
        self.assertEqual(receipt["stdout"], {"at_ms": "5"})

    def test_errors_take_the_typed_code_from_stderr(self) -> None:
        err = json.dumps({"code": "selector.not_found", "message": "no workspace", "retryable": False}).encode()
        receipt, _ = driver_cli.receipt_of(output("", 1, b"warning: x\n" + err + b"\n"), self.normalizer)
        self.assertEqual((receipt["exit"], receipt["error"]), (1, "selector.not_found"))
        receipt, _ = driver_cli.receipt_of(output("", 3, b"transport error: refused\n"), self.normalizer)
        self.assertEqual(receipt["error"], driver_cli.FALLBACK_ERROR)
        self.assertEqual(driver_cli.outcome_of(receipt), ("error", driver_cli.FALLBACK_ERROR))


class Steps(unittest.TestCase):
    def setUp(self) -> None:
        self.schema = schema()

    def steps(self, outputs: Sequence[driver_cli.CliOutput]) -> Tuple[driver_cli.CliSteps, FakeRunner]:
        runner = FakeRunner(outputs)
        normalizer = driver_cli.StdoutNormalizer(driver_cli.IdLabels(self.schema), normalize.Context())
        return driver_cli.CliSteps(runner, normalizer), runner

    def test_step_refs_resolve_from_the_raw_stdout_and_receipts_are_hashed(self) -> None:
        steps, runner = self.steps([output({"value": {"workspace_id": WS}}), output({"id": WS, "name": "a"})])
        replies: dict = {}
        steps.run({"id": "s0", "op": "cli", "args": {"argv": ["--json", "workspace", "create"]},
                   "expect": {"outcome": "ok", "receipt": "cli.exit"}}, replies)
        steps.run({"id": "s1", "op": "cli",
                   "args": {"argv": ["--json", "workspace", "$step:s0#/stdout/value/workspace_id", "show"]},
                   "expect": {"outcome": "ok", "result": {"exit": 0, "stdout": {"id": "workspace#1", "name": "a"}}}},
                  replies)
        self.assertEqual(runner.calls[1][0], ["--json", "workspace", WS, "show"])
        self.assertEqual([r["step"] for r in steps.receipts], ["s0", "s1"])
        for receipt in steps.receipts:
            body = {k: receipt[k] for k in ("exit", "stdout")}
            self.assertEqual(receipt["sha256"], driver_cli.hashlib.sha256(
                normalize.canonical_json(body).encode()).hexdigest())

    def test_expectations_fail_the_step(self) -> None:
        cases = [
            (output({}, 1, b'{"code":"usage.invalid","message":"x"}'), {"outcome": "ok"}, "expected ok, got error"),
            (output({}), {"outcome": "error", "error": "selector.not_found"}, "got ok"),
            (output({}, 1, b'{"code":"usage.invalid","message":"x"}'),
             {"outcome": "error", "error": "selector.not_found"}, "got error usage.invalid"),
            (output({"a": 1}), {"outcome": "ok", "result": {"exit": 0, "stdout": {"a": 2}}}, "result differs"),
        ]
        for out, expect, message in cases:
            steps, _ = self.steps([out])
            with self.assertRaisesRegex(driver_cli.CaseError, message):
                steps.run({"id": "s", "op": "cli", "args": {"argv": ["x"]}, "expect": expect}, {})
        steps, _ = self.steps([output({})])
        with self.assertRaisesRegex(driver_cli.CaseError, "receipt kind mutation_result"):
            steps.run({"id": "s", "op": "cli", "args": {"argv": ["x"]},
                       "expect": {"outcome": "ok", "receipt": "mutation_result"}}, {})

    def test_a_missing_reference_fails_at_its_step(self) -> None:
        steps, runner = self.steps([])
        with self.assertRaises(driver_cli.CaseError) as caught:
            steps.run({"id": "s1", "op": "cli", "args": {"argv": ["$step:s0#/stdout/id"]}}, {})
        self.assertEqual(caught.exception.step, "s1")
        self.assertEqual(runner.calls, [])

    def test_a_timeout_is_a_timeout(self) -> None:
        class Slow(FakeRunner):
            def run(self, argv, stdin, timeout):
                raise driver_cli.CliTimeout("over")

        normalizer = driver_cli.StdoutNormalizer(driver_cli.IdLabels(self.schema), normalize.Context())
        with self.assertRaises(driver_cli.CaseError) as caught:
            driver_cli.CliSteps(Slow([]), normalizer).run({"id": "s", "op": "cli", "args": {"argv": ["x"]}}, {})
        self.assertEqual(caught.exception.status, "Timeout")


class Fleet(unittest.TestCase):
    def test_a_fleet_case_gives_receipts_and_not_comparable_facets(self) -> None:
        schema()
        runner = FakeRunner([output({"value": {"workspace_id": WS}}), output([{"id": WS}])])
        session = driver_cli.FleetSession({"tag": "t", "ref": "a" * 40}, runner=runner)
        case = driver_cli.smoke_case("x", (driver_cli.MAKE_EMPTY, ("read", ("workspace", "list"))))
        result = session.run_case(case, {"case_id": "cli/x"})
        self.assertEqual(result["status"], "Pass", result["message"])
        self.assertEqual([r["stdout"] for r in result["receipts"]][1], [{"id": "workspace#1"}])
        self.assertEqual(len(result["checkpoints"]), 2)
        facet = result["checkpoints"][0]["snapshot"]["facets"]["daemon"]
        self.assertEqual(facet["status"], "not-comparable")
        self.assertEqual(result["checkpoints"][0]["snapshot"]["meta"]["product"], "cli")

    def test_app_steps_are_not_fleet_cli_steps(self) -> None:
        schema()
        session = driver_cli.FleetSession({"tag": "t"}, runner=FakeRunner([]))
        case = driver_cli.smoke_case("x", ())
        case["steps"] = [{"id": "a", "op": "action.run", "target": {"workspace": "w"}, "args": {"action": "x"},
                          "expect": {"outcome": "ok", "receipt": "action.done"}}]
        result = session.run_case(case, {"case_id": "cli/x"})
        self.assertEqual((result["status"], result["step"]), ("Crash", "a"))
        self.assertIn("driver_app.py", result["message"])


class SmokeCorpus(unittest.TestCase):
    def test_fifty_cases_that_case_v1_and_case_checks_accept(self) -> None:
        cases = driver_cli.smoke_cases()
        self.assertEqual(len(cases), 50)
        self.assertEqual(len({c["id"] for c in cases}), 50)
        doc = json.loads(CASE_SCHEMA.read_text(encoding="utf-8"))
        validator = normalize.Schema(doc, str(CASE_SCHEMA))
        rules = case_checks.Rules(doc)
        for case in cases:
            errors, _ = validator.validate(case)
            self.assertEqual(errors, [], case["id"])
            self.assertEqual(case_checks.check_case(case, rules), [], case["id"])

    def test_references_point_at_the_first_step(self) -> None:
        for case in driver_cli.smoke_cases():
            for step in case["steps"][1:]:
                for arg in step["args"]["argv"]:
                    if arg.startswith("$step:"):
                        self.assertTrue(arg.startswith("$step:s0#/stdout/value/"), (case["id"], arg))


if __name__ == "__main__":
    unittest.main(verbosity=2)
