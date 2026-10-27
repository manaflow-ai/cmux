#!/usr/bin/env python3
"""Offline tests of driver_cli.py (p15-oracle-048): no daemon, no app, no build.

Run: python3 -I scripts/cmux-next/oracle/driver_cli_test.py
The live test is `driver_cli.py smoke --binary CMUX_TUI` on the VM (50 daemon CLI cases, each twice).

The receipt tests canonicalize through normalize.py with a stub of the snapshot schema (its `schema`, `meta`,
`facets.cli`, a not-comparable `facets.daemon` and its id patterns), so they run on a normalize.py that still
refuses keywords elsewhere in the full schema. Only the path and time rules of open objects need
normalize.py's x-oracle-open-keys (p15-oracle-006); that one test says so when it skips.
"""

from __future__ import annotations

import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import case_checks  # noqa: E402
import driver_cli  # noqa: E402
import normalize  # noqa: E402

CASE_SCHEMA = REPO / "schemas" / "oracle" / "case-v1.schema.json"
SNAPSHOT_SCHEMA = REPO / "schemas" / "oracle" / "snapshot-v1.schema.json"
WS = "ws_" + "a" * 32
WS2 = "ws_" + "b" * 32
PANE = "pane_" + "c" * 32
OPEN_KEYS = "x-oracle-open-keys" in normalize.ROOT_KEYWORDS


def stub_schema_doc() -> Dict[str, Any]:
    """The parts of the snapshot schema a cli receipt needs, as the loaded normalize.py accepts them."""
    real = json.loads(SNAPSHOT_SCHEMA.read_text(encoding="utf-8"))
    props = real["properties"]
    facets = props["facets"]
    daemon = facets["properties"]["daemon"]
    doc = {key: real[key] for key in ("type", "additionalProperties", "required", "x-oracle-precision-default",
                                      "x-oracle-id-patterns")}
    if OPEN_KEYS:
        doc["x-oracle-open-keys"] = real["x-oracle-open-keys"]
    doc["properties"] = {
        "schema": props["schema"],
        "meta": props["meta"],
        "facets": {**{k: v for k, v in facets.items() if k != "properties"},
                   "properties": {"daemon": {"x-oracle-source": daemon["x-oracle-source"],
                                             "oneOf": [{"$ref": "#/definitions/notComparable"}]},
                                  "cli": facets["properties"]["cli"]}},
    }
    doc["definitions"] = {"notComparable": real["definitions"]["notComparable"]}
    return doc


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


def cli_step(step_id: str, argv: Sequence[str], **extra: Any) -> Dict[str, Any]:
    return {"id": step_id, "op": "cli", "args": {"argv": list(argv)}, **extra}


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


class RunSha(unittest.TestCase):
    """The VM binary is the build of the run SHA, or the session refuses it."""

    def test_a_binary_without_a_build_receipt_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            binary = executable(Path(tmp), "cmux-tui")
            with self.assertRaisesRegex(driver_cli.BuildMismatch, "no build receipt"):
                driver_cli.run_sha(binary, None)
            with self.assertRaisesRegex(driver_cli.BuildMismatch, "no build receipt"):
                driver_cli.CliSession({"binary": str(binary), "ref": "1" * 40})

    def test_a_binary_built_at_another_sha_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            binary = executable(Path(tmp), "cmux-tui")
            (Path(tmp) / driver_cli.BUILD_RECEIPT).write_text(json.dumps({"sha": "1" * 40}))
            self.assertEqual(driver_cli.run_sha(binary, None), "1" * 40)
            self.assertEqual(driver_cli.run_sha(binary, "1" * 40), "1" * 40)
            with self.assertRaisesRegex(driver_cli.BuildMismatch, "not at the run SHA"):
                driver_cli.run_sha(binary, "2" * 40)
            with self.assertRaisesRegex(driver_cli.BuildMismatch, "not at the run SHA"):
                driver_cli.CliSession({"binary": str(binary), "ref": "2" * 40})

    def test_a_short_or_symbolic_ref_is_resolved_before_the_compare(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            binary = executable(Path(tmp), "cmux-tui")
            (Path(tmp) / driver_cli.BUILD_RECEIPT).write_text(json.dumps({"sha": "1" * 40}))
            self.assertEqual(driver_cli.run_sha(binary, "HEAD", lambda ref: "1" * 40), "1" * 40)
            with self.assertRaisesRegex(driver_cli.BuildMismatch, "not at the run SHA"):
                driver_cli.run_sha(binary, "abc123", lambda ref: "2" * 40)

    @unittest.skipUnless((REPO / ".git").exists(), "needs this checkout's git")
    def test_resolve_ref_asks_git(self) -> None:
        head = driver_cli.resolve_ref("HEAD")
        self.assertRegex(head, r"^[0-9a-f]{40}$")
        self.assertEqual(driver_cli.resolve_ref(head[:12]), head)
        with self.assertRaisesRegex(driver_cli.BuildMismatch, "names no commit"):
            driver_cli.resolve_ref("refs/heads/no-such-branch-p15-oracle-048")


class SwitchArms(unittest.TestCase):
    """Neither mode applies an arm (p15-oracle-049), so an arm run is refused, never two default runs."""

    def test_both_modes_refuse_switches_and_a_non_default_arm(self) -> None:
        for ctx in ({"switches": {"terminal-holder": "new"}}, {"arm": "new"}, {"arm": "launch-config"}):
            with self.subTest(ctx=ctx):
                with self.assertRaisesRegex(ValueError, "p15-oracle-049"):
                    driver_cli.FleetSession({"tag": "t", **ctx}, runner=FakeRunner([]))
                with self.assertRaisesRegex(ValueError, "p15-oracle-049"):
                    driver_cli.CliSession({"binary": "/bin/true", **ctx})
        for arm in driver_cli.DEFAULT_ARMS:
            driver_cli.refuse_switch_arms({"arm": arm, "switches": {}})


class Receipts(unittest.TestCase):
    def test_stdout_forms(self) -> None:
        self.assertEqual(driver_cli.parse_stdout(b'{"a": 1}\n'), {"a": 1})
        self.assertEqual(driver_cli.parse_stdout(b'{"a": 1}\n{"a": 2}\n'), [{"a": 1}, {"a": 2}])
        self.assertEqual(driver_cli.parse_stdout(b"plain text\n"), "plain text\n")
        self.assertEqual(driver_cli.parse_stdout(b""), "")

    def test_the_case_session_name_is_the_fixtures_and_refs_read_the_raw_stdout(self) -> None:
        raw = {"session": "oracle-zmr7ii", "path": "/x/oracle-zmr7ii/panic.log", "oracle-zmr7ii": 1, "id": WS}
        receipt, reply = driver_cli.receipt_of(output(raw), {"oracle-zmr7ii": "oracle"})
        self.assertEqual(receipt, {"exit": 0, "stdout": {"session": "oracle", "path": "/x/oracle/panic.log",
                                                         "oracle": 1, "id": WS}})
        self.assertEqual(reply["stdout"], raw)

    def test_errors_take_the_typed_code_from_stderr_and_stderr_stays_out(self) -> None:
        err = json.dumps({"code": "selector.not_found", "message": f"no workspace {WS}", "retryable": False})
        receipt, _ = driver_cli.receipt_of(output("", 1, b"warning: x\n" + err.encode() + b"\n"), {})
        self.assertEqual(receipt, {"exit": 1, "stdout": "", "error": "selector.not_found"})
        receipt, _ = driver_cli.receipt_of(output("", 3, b"transport error: refused\n"), {})
        self.assertEqual(receipt["error"], driver_cli.FALLBACK_ERROR)
        self.assertEqual(driver_cli.outcome_of(receipt), ("error", driver_cli.FALLBACK_ERROR))


class Steps(unittest.TestCase):
    def steps(self, outputs: Sequence[driver_cli.CliOutput]) -> Tuple[driver_cli.CliSteps, FakeRunner]:
        runner = FakeRunner(outputs)
        return driver_cli.CliSteps(runner), runner

    def test_step_refs_resolve_from_the_raw_stdout_and_receipts_are_kept_by_step(self) -> None:
        steps, runner = self.steps([output({"value": {"workspace_id": WS}}), output({"id": WS, "name": "a"})])
        replies: dict = {}
        steps.run(cli_step("s0", ["--json", "workspace", "create"], expect={"outcome": "ok", "receipt": "cli.exit"}),
                  replies)
        steps.run(cli_step("s1", ["--json", "workspace", "$step:s0#/stdout/value/workspace_id", "show"]), replies)
        self.assertEqual(runner.calls[1][0], ["--json", "workspace", WS, "show"])
        self.assertEqual(steps.facet("s1"), {"exit": 0, "stdout": {"id": WS, "name": "a"}})
        self.assertEqual(steps.facet("s9")["status"], "not-comparable")

    def test_expectations_fail_the_step_with_the_stderr_tail(self) -> None:
        usage = b'{"code":"usage.invalid","message":"unknown flag"}'
        cases = [
            (output({}, 1, usage), {"outcome": "ok"}, "expected ok, got error usage.invalid .*unknown flag"),
            (output({}), {"outcome": "error", "error": "selector.not_found"}, "got ok"),
            (output({}, 1, usage), {"outcome": "error", "error": "selector.not_found"}, "got error usage.invalid"),
        ]
        for out, expect, message in cases:
            steps, _ = self.steps([out])
            with self.assertRaisesRegex(driver_cli.CaseError, message):
                steps.run(cli_step("s", ["x"], expect=expect), {})
        steps, _ = self.steps([output({})])
        with self.assertRaisesRegex(driver_cli.CaseError, "receipt kind mutation_result"):
            steps.run(cli_step("s", ["x"], expect={"outcome": "ok", "receipt": "mutation_result"}), {})

    def test_a_missing_reference_fails_at_its_step(self) -> None:
        steps, runner = self.steps([])
        with self.assertRaises(driver_cli.CaseError) as caught:
            steps.run(cli_step("s1", ["$step:s0#/stdout/id"]), {})
        self.assertEqual(caught.exception.step, "s1")
        self.assertEqual(runner.calls, [])

    def test_a_timeout_is_a_timeout(self) -> None:
        class Slow(FakeRunner):
            def run(self, argv, stdin, timeout):
                raise driver_cli.CliTimeout("over")

        with self.assertRaises(driver_cli.CaseError) as caught:
            driver_cli.CliSteps(Slow([])).run(cli_step("s", ["x"]), {})
        self.assertEqual(caught.exception.status, "Timeout")

    def test_the_cli_facet_joins_only_the_settled_checkpoint_of_a_cli_step(self) -> None:
        steps, _ = self.steps([output({})])
        steps.run(cli_step("s0", ["x"]), {})
        self.assertEqual(driver_cli.with_cli_facet(("daemon",), "settled", "s0", steps), ("daemon", "cli"))
        self.assertEqual(driver_cli.with_cli_facet(("daemon",), "before", "s0", steps), ("daemon",))
        self.assertEqual(driver_cli.with_cli_facet(("daemon",), "settled", "s1", steps), ("daemon",))
        with self.assertRaisesRegex(driver_cli.CaseError, "needs settled"):
            driver_cli.check_cli_step(cli_step("s0", ["x"], checkpoint=["before"]))


class Fleet(unittest.TestCase):
    """The fleet session end to end on a FakeRunner: receipts canonicalized by normalize.py as the cli facet."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.tmp = tempfile.TemporaryDirectory()
        cls.schema_path = Path(cls.tmp.name) / "snapshot-stub.schema.json"
        cls.schema_path.write_text(json.dumps(stub_schema_doc()), encoding="utf-8")

    @classmethod
    def tearDownClass(cls) -> None:
        cls.tmp.cleanup()

    def session(self, outputs: Sequence[driver_cli.CliOutput], **ctx: Any) -> driver_cli.FleetSession:
        return driver_cli.FleetSession({"tag": "t", "ref": "a" * 40, "snapshot_schema": str(self.schema_path), **ctx},
                                       runner=FakeRunner(outputs))

    def run_case(self, outputs: Sequence[driver_cli.CliOutput], steps: Sequence[Dict[str, Any]],
                 home: str = "") -> Dict[str, Any]:
        session = self.session(outputs)
        session.home = home
        case = driver_cli.smoke_case("x", ())
        case["steps"] = list(steps)
        return session.run_case(case, {"case_id": "cli/x"})

    @staticmethod
    def cli(result: Mapping[str, Any], step: str) -> Any:
        return next(cp["snapshot"]["facets"]["cli"] for cp in result["checkpoints"]
                    if cp["step"] == step and cp["checkpoint"] == "settled")

    @staticmethod
    def hashes(result: Mapping[str, Any]) -> List[str]:
        return driver_cli.attempt_hashes(result)

    def test_a_fleet_case_hashes_its_receipts_in_the_checkpoints(self) -> None:
        case = driver_cli.smoke_case("x", (driver_cli.MAKE_EMPTY, ("read", ("workspace", "list"))))
        case["steps"][1].pop("readOnly")
        session = self.session([output({"value": {"workspace_id": WS}}), output([{"id": WS}])])
        result = session.run_case(case, {"case_id": "cli/x"})
        self.assertEqual(result["status"], "Pass", result["message"])
        self.assertNotIn("receipts", result, "the receipts are the cli facet, not a side list")
        snapshot = result["checkpoints"][1]["snapshot"]
        self.assertEqual(snapshot["meta"]["product"], "cli")
        self.assertEqual(sorted(snapshot["meta"]["facets"]), ["cli", "daemon"])
        self.assertEqual(snapshot["facets"]["daemon"]["status"], "not-comparable")
        self.assertEqual(snapshot["facets"]["cli"], {"exit": 0, "stdout": [{"id": "workspace#1"}]})
        changed = self.session([output({"value": {"workspace_id": WS}}), output([{"id": WS}, {"id": WS2}])])
        other = changed.run_case(case, {"case_id": "cli/x"})
        self.assertEqual(self.hashes(result)[0], self.hashes(other)[0])
        self.assertNotEqual(self.hashes(result)[1], self.hashes(other)[1], "a stdout change changes the hash")

    def test_ids_keep_one_label_across_the_steps_of_a_case(self) -> None:
        result = self.run_case([output({"value": {"workspace_id": WS}}), output([{"id": WS2}, {"id": WS}])],
                               [cli_step("s0", ["a"]), cli_step("s1", ["b"])])
        self.assertEqual(result["status"], "Pass", result["message"])
        first = self.cli(result, "s0")["stdout"]["value"]["workspace_id"]
        listed = [item["id"] for item in self.cli(result, "s1")["stdout"]]
        self.assertEqual(listed[1], first)
        self.assertNotEqual(listed[0], first)

    def test_an_id_keyed_map_hashes_by_its_contents_not_by_its_raw_ids(self) -> None:
        steps = [cli_step("s0", ["a"])]
        one = self.run_case([output({WS: {"name": "first"}, WS2: {"name": "second"}})], steps)
        swapped = self.run_case([output({WS2: {"name": "first"}, WS: {"name": "second"}})], steps)
        self.assertEqual(one["status"], "Pass", one["message"])
        self.assertEqual(self.hashes(one), self.hashes(swapped))
        renamed = self.run_case([output({WS: {"name": "first"}, WS2: {"name": "third"}})], steps)
        self.assertNotEqual(self.hashes(one), self.hashes(renamed))

    def test_an_error_message_does_not_move_later_labels(self) -> None:
        steps = [cli_step("s0", ["a"], expect={"outcome": "error", "error": "selector.not_found"}),
                 cli_step("s1", ["b"])]
        named = json.dumps({"code": "selector.not_found", "message": f"no workspace {WS2}"}).encode()
        plain = json.dumps({"code": "selector.not_found", "message": "no such workspace"}).encode()
        with_id = self.run_case([output("", 1, named), output({"id": WS})], steps)
        without = self.run_case([output("", 1, plain), output({"id": WS})], steps)
        self.assertEqual(with_id["status"], "Pass", with_id["message"])
        self.assertEqual(self.hashes(with_id), self.hashes(without))

    @unittest.skipUnless(OPEN_KEYS, "the path and time rules of open objects are normalize.py's x-oracle-open-keys "
                                    "(p15-oracle-006), which this normalize.py lacks")
    def test_home_paths_and_schema_times_in_stdout(self) -> None:
        raw = {"cwd": "/h/me/x", "updated_at_ms": "1793014165795", "idle_timeout_seconds": 30, "started_ms": 5}
        result = self.run_case([output(raw)], [cli_step("s0", ["a"])], home="/h/me")
        stdout = self.cli(result, "s0")["stdout"]
        self.assertEqual(stdout["cwd"], "$HOME/x")
        self.assertTrue(str(stdout["updated_at_ms"]).startswith("not-comparable: wall clock"), stdout)
        # Not marked x-oracle-time by the schema: kept, so a change of the value shows in the diff.
        self.assertEqual((stdout["idle_timeout_seconds"], stdout["started_ms"]), (30, 5))

    def test_expect_result_compares_the_canonical_facet_after_the_case(self) -> None:
        create = output({"value": {"workspace_id": WS}})
        good = {"exit": 0, "stdout": {"value": {"workspace_id": "workspace#1"}}}
        result = self.run_case([create], [cli_step("s0", ["a"], expect={"outcome": "ok", "result": good})])
        self.assertEqual(result["status"], "Pass", result["message"])
        bad = {"exit": 0, "stdout": {"value": {"workspace_id": "workspace#2"}}}
        result = self.run_case([create], [cli_step("s0", ["a"], expect={"outcome": "ok", "result": bad})])
        self.assertEqual((result["status"], result["step"]), ("Failure", "s0"))
        self.assertIn("result differs", result["message"])

    def test_what_the_fleet_session_cannot_honor_is_a_crash_naming_the_app_driver(self) -> None:
        refused = [
            {"id": "a", "op": "action.run", "target": {"workspace": "w"}, "args": {"action": "x"}},
            {"id": "a", "op": "settle"},
            cli_step("a", ["x"], waitFor={"pointer": "/topology", "predicate": "exists", "maxMs": 100}),
            cli_step("a", ["x"], readOnly=True),
        ]
        for step in refused:
            with self.subTest(step=step):
                result = self.run_case([output({})], [step])
                self.assertEqual((result["status"], result["step"]), ("Crash", "a"))
                self.assertIn("driver_app.py", result["message"])
        result = self.run_case([output({})], [cli_step("a", ["x"], checkpoint=["before"])])
        self.assertEqual((result["status"], result["step"]), ("Crash", "a"))


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

    def test_every_mutation_is_followed_by_a_checked_read(self) -> None:
        checks = driver_cli.smoke_checks()
        for name, spec in driver_cli.SMOKE:
            kinds = [entry[0] for entry in spec]
            if "mutate" not in kinds:
                continue
            last = len(spec) - 1
            with self.subTest(case=name):
                self.assertEqual(kinds[last], "read", "a mutation case ends on a read")
                self.assertIn(f"s{last}", checks[f"cli-smoke-{name}"], "that read checks what the mutation did")

    def test_checks_find_a_mutation_that_did_nothing(self) -> None:
        checks = driver_cli.smoke_checks()["cli-smoke-create-rename"]

        def checkpoints(name: str) -> List[Dict[str, Any]]:
            facet = {"exit": 0, "stdout": {"id": "workspace#1", "name": name}}
            return [{"step": "s2", "checkpoint": "settled", "snapshot": {"facets": {"cli": facet}}}]

        self.assertEqual(driver_cli.check_problems(checkpoints("b"), checks), [])
        self.assertEqual(len(driver_cli.check_problems(checkpoints("a"), checks)), 1)
        self.assertEqual(len(driver_cli.check_problems([], checks)), 1)
        lengths = driver_cli.smoke_checks()["cli-smoke-create-close"]
        empty = [{"step": "s2", "checkpoint": "settled", "snapshot": {"facets": {"cli": {"exit": 0, "stdout": []}}}}]
        listed = [{"step": "s2", "checkpoint": "settled",
                   "snapshot": {"facets": {"cli": {"exit": 0, "stdout": [{"id": "workspace#1"}]}}}}]
        self.assertEqual(driver_cli.check_problems(empty, lengths), [])
        self.assertEqual(len(driver_cli.check_problems(listed, lengths)), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
