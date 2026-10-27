#!/usr/bin/env python3
"""Offline tests of driver_mcp.py (p15-oracle-209): no daemon, no app, no build.

Run: python3 -I scripts/cmux-next/oracle/driver_mcp_test.py
The live test is `oracle.py run --product mcp --suite mcp,daemon-ops --binary CMUX_TUI` on the VM, then
`driver_mcp.py parity RUN_DIR` (MCP vs resource API settled snapshots), and one fleet shard against a tagged app.
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path
from typing import Any, Dict, List, Optional

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import driver_cli  # noqa: E402
import driver_mcp  # noqa: E402
from driver_daemon import CaseError  # noqa: E402

WS = "ws_" + "a" * 32


def answer(result: Any = None, *, error: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    if error is not None:
        return {"jsonrpc": "2.0", "id": driver_mcp.CALL_ID, "error": error}
    return {"jsonrpc": "2.0", "id": driver_mcp.CALL_ID, "result": result}


def tool_result(value: Any, failed: bool = False) -> Dict[str, Any]:
    return {"content": [{"type": "text", "text": json.dumps(value)}], "structuredContent": value, "isError": failed}


def lines(*messages: Dict[str, Any]) -> bytes:
    return "".join(json.dumps(m) + "\n" for m in messages).encode()


def mcp_step(step_id: str = "call", tool: str = "workspace_rename", **extra: Any) -> Dict[str, Any]:
    return {"id": step_id, "op": "mcp", "args": {"tool": tool, "arguments": {"workspace": WS, "name": "x"}}, **extra}


class FakeServe:
    def __init__(self, outputs: List[driver_cli.CliOutput]):
        self.outputs = outputs
        self.inputs: List[str] = []

    def __call__(self, stdin: str, timeout: float) -> driver_cli.CliOutput:
        self.inputs.append(stdin)
        return self.outputs.pop(0)


class SessionLines(unittest.TestCase):
    def test_one_client_session_initializes_then_calls_once(self) -> None:
        messages = [json.loads(line) for line in driver_mcp.session_input("workspace_list", {"limit": 1}).splitlines()]
        self.assertEqual([m.get("method") for m in messages],
                         ["initialize", "notifications/initialized", "tools/call"])
        self.assertNotIn("id", messages[1])
        self.assertEqual(messages[2]["params"], {"name": "workspace_list", "arguments": {"limit": 1}})
        self.assertEqual(messages[0]["params"]["protocolVersion"], driver_mcp.PROTOCOL_VERSION)

    def test_the_answer_is_the_call_ids_reply_not_a_notification(self) -> None:
        text = "\n".join([json.dumps({"jsonrpc": "2.0", "id": 1, "result": {}}),
                          json.dumps({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"}),
                          "not json",
                          json.dumps(answer(tool_result({"ok": 1})))])
        self.assertEqual(driver_mcp.call_answer(text)["result"]["structuredContent"], {"ok": 1})
        self.assertIsNone(driver_mcp.call_answer(json.dumps({"jsonrpc": "2.0", "id": 1, "result": {}})))


class Receipts(unittest.TestCase):
    def test_a_result_is_the_facet_and_the_reply(self) -> None:
        receipt = driver_mcp.receipt_of(answer(tool_result({"value": {"id": WS}})), {})
        self.assertEqual(receipt.facet, {"isError": False, "result": {"value": {"id": WS}}})
        self.assertEqual(receipt.outcome, ("ok", {"value": {"id": WS}}))

    def test_a_tool_error_is_its_envelope_code(self) -> None:
        envelope = {"error": {"code": "selector.not_found", "details": {"scope": "workspace"}}, "state": "rejected"}
        receipt = driver_mcp.receipt_of(answer(tool_result(envelope, failed=True)), {})
        self.assertEqual(receipt.outcome, ("error", "selector.not_found"))
        self.assertEqual(receipt.facet["error"], "selector.not_found")
        self.assertTrue(receipt.facet["isError"])

    def test_a_bare_app_code_is_a_control_code_and_no_code_is_tool_failed(self) -> None:
        self.assertEqual(driver_mcp.typed_code({"code": "busy"}), "control.busy")
        self.assertEqual(driver_mcp.typed_code({"code": 7}), driver_mcp.TOOL_FAILED)
        self.assertEqual(driver_mcp.typed_code(None), driver_mcp.TOOL_FAILED)

    def test_an_rpc_error_is_mcp_rpc_error(self) -> None:
        receipt = driver_mcp.receipt_of(answer(error={"code": -32602, "message": "unknown tool: x"}), {})
        self.assertEqual(receipt.outcome, ("error", driver_mcp.RPC_ERROR))
        self.assertEqual(receipt.facet, {"isError": True, "result": {"rpcCode": -32602}, "error": driver_mcp.RPC_ERROR})

    def test_content_stands_in_when_there_is_no_structured_content(self) -> None:
        receipt = driver_mcp.receipt_of(answer({"content": [{"type": "text", "text": "hi"}], "isError": False}), {})
        self.assertEqual(receipt.facet["result"], [{"type": "text", "text": "hi"}])

    def test_the_case_session_name_is_the_fixtures(self) -> None:
        receipt = driver_mcp.receipt_of(answer(tool_result({"session": "oracle-abc123"})), {"oracle-abc123": "oracle"})
        self.assertEqual(receipt.facet["result"], {"session": "oracle"})
        self.assertEqual(receipt.reply, {"session": "oracle-abc123"})


class Expect(unittest.TestCase):
    def check(self, step: Dict[str, Any], value: Any, failed: bool = False) -> None:
        receipt = driver_mcp.receipt_of(answer(tool_result(value, failed)), {})
        driver_mcp.check_outcome(step, receipt, {})

    def test_a_mutation_result_receipt_needs_its_keys(self) -> None:
        step = mcp_step(expect={"outcome": "ok", "receipt": "mutation_result"})
        self.check(step, {"value": {}, "generation": "g", "revision": "1", "replayed": False})
        with self.assertRaises(CaseError) as caught:
            self.check(step, {"items": []})
        self.assertEqual(caught.exception.status, "Failure")

    def test_another_receipt_kind_is_a_crash(self) -> None:
        with self.assertRaises(CaseError) as caught:
            self.check(mcp_step(expect={"outcome": "ok", "receipt": "action.done"}), {})
        self.assertEqual(caught.exception.status, "Crash")

    def test_the_wrong_outcome_or_code_fails(self) -> None:
        with self.assertRaises(CaseError):
            self.check(mcp_step(expect={"outcome": "ok", "noReceiptReason": "a read of the session"}),
                       {"error": {"code": "validation.invalid"}}, failed=True)
        with self.assertRaises(CaseError):
            self.check(mcp_step(expect={"outcome": "error", "error": "selector.not_found"}),
                       {"error": {"code": "validation.invalid"}}, failed=True)

    def test_error_details_are_a_subset(self) -> None:
        step = mcp_step(expect={"outcome": "error", "error": "revision.conflict", "errorDetails": {"expected": "9"}})
        self.check(step, {"error": {"code": "revision.conflict", "details": {"expected": "9", "actual": "2"}}}, True)
        with self.assertRaises(CaseError):
            self.check(step, {"error": {"code": "revision.conflict", "details": {"expected": "8"}}}, True)
        self.assertIsNone(driver_mcp.details_problem({"a": {"b": 1}}, {"a": {"b": 1, "c": 2}}))
        self.assertIn("/a/b", driver_mcp.details_problem({"a": {"b": 1}}, {"a": {"b": 2}}))

    def test_expect_result_compares_the_canonical_result(self) -> None:
        case = {"steps": [mcp_step(expect={"outcome": "ok", "result": {"name": "x"}})]}
        checkpoints = [{"step": "call", "checkpoint": "settled",
                        "snapshot": {"facets": {"mcp": {"isError": False, "result": {"name": "x"}}}}}]
        self.assertIsNone(driver_mcp.check_results(case, checkpoints))
        checkpoints[0]["snapshot"]["facets"]["mcp"]["result"] = {"name": "y"}
        self.assertEqual(driver_mcp.check_results(case, checkpoints).status, "Failure")

    def test_an_mcp_step_keeps_its_settled_checkpoint(self) -> None:
        driver_mcp.check_mcp_step(mcp_step())
        with self.assertRaises(CaseError):
            driver_mcp.check_mcp_step(mcp_step(checkpoint=["before"]))


class Steps(unittest.TestCase):
    def test_a_step_resolves_references_and_keeps_its_receipt(self) -> None:
        serve = FakeServe([driver_cli.CliOutput(0, lines(answer(tool_result({"value": {"id": WS}}))), b"")])
        steps = driver_mcp.McpSteps(serve, "fake")
        replies = {"fx": {"value": {"workspace_id": WS}}}
        step = {"id": "call", "op": "mcp",
                "args": {"tool": "workspace_get", "arguments": {"workspace": "$step:fx#/value/workspace_id"}}}
        self.assertEqual(steps.run(step, replies)[0], "ok")
        sent = json.loads(serve.inputs[0].splitlines()[2])
        self.assertEqual(sent["params"]["arguments"], {"workspace": WS})
        self.assertEqual(steps.facet("call"), {"isError": False, "result": {"value": {"id": WS}}})
        self.assertEqual(replies["call"], {"value": {"id": WS}})
        self.assertEqual(steps.facet("other")["status"], "not-comparable")

    def test_no_answer_is_a_crash_and_a_slow_server_a_timeout(self) -> None:
        steps = driver_mcp.McpSteps(FakeServe([driver_cli.CliOutput(1, b"", b"cmux: mcp is off\n")]), "fake")
        with self.assertRaises(CaseError) as caught:
            steps.run(mcp_step(), {})
        self.assertEqual(caught.exception.status, "Crash")
        self.assertIn("mcp is off", caught.exception.message)

        def slow(stdin: str, timeout: float) -> driver_cli.CliOutput:
            raise driver_cli.CliTimeout("over")

        with self.assertRaises(CaseError) as caught:
            driver_mcp.McpSteps(slow, "fake").run(mcp_step(), {})
        self.assertEqual(caught.exception.status, "Timeout")

    def test_the_receipt_joins_only_its_settled_checkpoint(self) -> None:
        receipts = {"call": {"isError": False, "result": {}}}
        self.assertEqual(driver_mcp.with_receipt(("daemon",), "settled", "call", "mcp", receipts), ("daemon", "mcp"))
        self.assertEqual(driver_mcp.with_receipt(("daemon",), "before", "call", "mcp", receipts), ("daemon",))
        self.assertEqual(driver_mcp.with_receipt(("daemon",), "settled", "x", "mcp", receipts), ("daemon",))

    def test_the_server_config_turns_mcp_on_and_is_written_once(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = driver_mcp.write_mcp_config(Path(tmp) / driver_mcp.MCP_CONFIG)
            self.assertEqual(json.loads(path.read_text()), {"mcp": {"enabled": True}})
            path.write_text("{}")
            driver_mcp.write_mcp_config(path)
            self.assertEqual(path.read_text(), "{}")


class Sessions(unittest.TestCase):
    def test_a_bundle_is_fleet_mode_and_a_binary_vm_mode(self) -> None:
        self.assertTrue(driver_mcp.is_app_bundle("/x/cmux DEV tag.app"))
        self.assertTrue(driver_mcp.is_app_bundle("/x/cmux DEV tag.app/"))
        self.assertFalse(driver_mcp.is_app_bundle("/x/cmux-tui"))
        with self.assertRaisesRegex(ValueError, "--binary"):
            driver_mcp.open_session({})

    def test_the_vm_worker_is_this_file(self) -> None:
        self.assertEqual(driver_mcp.McpSession.worker_script, Path(driver_mcp.__file__).resolve())
        self.assertTrue(issubclass(driver_mcp.McpCaseRun, driver_cli.CliCaseRun))

    def test_the_fleet_case_extends_driver_app(self) -> None:
        import driver_app

        session_class, case_class = driver_mcp.fleet_classes()
        self.assertTrue(issubclass(session_class, driver_app.AppSession))
        self.assertIs(session_class.case_class, case_class)
        self.assertTrue(issubclass(case_class, driver_app.CaseRun))

    def test_the_fleet_cli_error_names_a_control_code(self) -> None:
        self.assertEqual(driver_mcp.fleet_cli_error(b'{"code":"socket.no_app","message":"m"}\n'), "socket.no_app")
        self.assertEqual(driver_mcp.fleet_cli_error(b'{"error":{"code":"busy"}}\n'), "control.busy")
        self.assertEqual(driver_mcp.fleet_cli_error(b"plain\n"), driver_cli.FALLBACK_ERROR)


class ToolList(unittest.TestCase):
    def test_the_list_keeps_names_hints_and_arguments(self) -> None:
        listing = {"count": 2, "app_actions": False, "excluded": [{"kind": "operation", "name": "b", "reason": "r"}],
                   "tools": [{"name": "z_tool", "inputSchema": {"properties": {"b": {}, "a": {}}, "required": ["b"]},
                              "annotations": {"readOnlyHint": True}},
                             {"name": "a_tool", "inputSchema": {}, "annotations": {"destructiveHint": True}}]}
        doc = driver_mcp.tools_document(listing)
        self.assertEqual([t["name"] for t in doc["tools"]], ["a_tool", "z_tool"])
        self.assertEqual(doc["tools"][1], {"name": "z_tool", "readOnly": True, "destructive": False,
                                           "arguments": ["a", "b"], "required": ["b"]})
        self.assertEqual(doc["excluded"], [{"kind": "operation", "name": "b"}])

    def test_the_checked_in_list_matches_its_own_format(self) -> None:
        doc = json.loads(driver_mcp.TOOLS_FILE.read_text())
        self.assertEqual(doc["count"], len(doc["tools"]))
        self.assertEqual([t["name"] for t in doc["tools"]], sorted(t["name"] for t in doc["tools"]))


def snapshot(**daemon: Any) -> Dict[str, Any]:
    return {"facets": {"daemon": daemon, "mcp": {"isError": False, "result": {"r": 1}}}}


def runs(rows: Dict[str, List[Any]]) -> Dict[Any, driver_mcp.Checkpoint]:
    """case -> [(step, checkpoint, index, daemon facet)] as driver_mcp.load_run gives them."""
    out = {}
    for case, items in rows.items():
        for step, checkpoint, index, daemon in items:
            out[(case, step, checkpoint)] = driver_mcp.Checkpoint(index, snapshot(**daemon))
    return out


class Parity(unittest.TestCase):
    PAIR = {"mcp": "mcp/x-ok", "twin": "daemon-ops/x-ok", "tool": "x", "step": "call"}

    def test_equal_snapshots_are_parity_and_receipts_are_never_compared(self) -> None:
        data = runs({"mcp/x-ok": [("call", "settled", 1, {"name": "a"})],
                     "daemon-ops/x-ok": [("call", "settled", 1, {"name": "a"})]})
        data[("daemon-ops/x-ok", "call", "settled")].snapshot["facets"]["mcp"] = {"isError": True, "result": {}}
        verdict = driver_mcp.compare_pair(self.PAIR, data, [])
        self.assertEqual((verdict["checkpoints"], verdict["differences"]), (1, []))

    def test_a_difference_from_the_entry_step_on_is_a_divergence_unless_reasoned(self) -> None:
        data = runs({"mcp/x-ok": [("fx", "settled", 0, {"id": "a"}), ("call", "settled", 1, {"name": "a", "c": [1]})],
                     "daemon-ops/x-ok": [("fx", "settled", 0, {"id": "b"}), ("call", "settled", 1, {"name": "b", "c": [2]})]})
        verdict = driver_mcp.compare_pair(self.PAIR, data, [])
        self.assertEqual([d["pointer"] for d in verdict["differences"]], ["/daemon/c/0", "/daemon/name"])
        self.assertEqual(verdict["before_entry"], 1)
        reasons = [driver_mcp.Reason("/daemon/c", "the reason is long enough here"),
                   driver_mcp.Reason("/daemon/name", "only for another tool, long enough", ("y",))]
        verdict = driver_mcp.compare_pair(self.PAIR, data, reasons)
        self.assertEqual([d["pointer"] for d in verdict["differences"]], ["/daemon/name"])
        self.assertEqual(len(verdict["reasoned"]), 1)

    def test_reason_patterns_match_segments_prefixes_and_checkpoints(self) -> None:
        reason = driver_mcp.Reason("/daemon/session/clients/*/id", "r" * 30)
        self.assertTrue(reason.covers("/daemon/session/clients/3/id", "t"))
        self.assertTrue(reason.covers("/daemon/session/clients/3/id/x", "t"))
        self.assertFalse(reason.covers("/daemon/session/clients", "t"))
        self.assertFalse(reason.covers("/daemon/session/tabs/3/id", "t"))
        scoped = driver_mcp.Reason("/daemon", "r" * 30, ("t",), ("call/settled",))
        self.assertTrue(scoped.covers("/daemon/x", "t", "call/settled"))
        self.assertFalse(scoped.covers("/daemon/x", "t", "retry/settled"))
        self.assertFalse(scoped.covers("/daemon/x", "u", "call/settled"))

    def write_run(self, tmp: str, results: Dict[str, str]) -> Path:
        """A run dir where every case in `results` has one equal settled checkpoint at the call step."""
        run = Path(tmp)
        rows = [{"case": c, "suite": c.split("/")[0], "step": "call", "checkpoint": "settled", "index": 0,
                 "snapshot": snapshot(name="a")} for c in results]
        (run / "checkpoints.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
        (run / "receipt.json").write_text(json.dumps({"cases": {c: {"result": r} for c, r in results.items()}}))
        return run

    def pair(self, name: str) -> Dict[str, str]:
        return {**self.PAIR, "mcp": f"mcp/{name}", "twin": f"daemon-ops/{name}"}

    def test_a_pair_that_failed_the_same_way_on_both_sides_is_not_compared(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            run = self.write_run(tmp, {"mcp/x-ok": "Pass", "daemon-ops/x-ok": "Pass",
                                       "mcp/y-ok": "Timeout", "daemon-ops/y-ok": "Timeout"})
            report = driver_mcp.parity([run], {"parity": [self.PAIR, self.pair("y-ok")]}, [])
            self.assertEqual((report["compared"], report["divergent"]), (1, 0))
            self.assertEqual(report["not_compared"][0]["mcp"], "mcp/y-ok")
            self.assertEqual(report["not_compared"][0]["why"], "both results Timeout")

    def test_a_pair_whose_results_differ_is_divergent(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            run = self.write_run(tmp, {"mcp/x-ok": "Pass", "daemon-ops/x-ok": "Pass",
                                       "mcp/y-ok": "Failure", "daemon-ops/y-ok": "Pass",
                                       "mcp/z-ok": "Crash", "daemon-ops/z-ok": "Timeout",
                                       "mcp/w-ok": "Pass"})
            coverage = {"parity": [self.PAIR, self.pair("y-ok"), self.pair("z-ok"), self.pair("w-ok")]}
            report = driver_mcp.parity([run], coverage, [])
            self.assertEqual((report["compared"], report["divergent"], report["not_compared"]), (4, 3, []))
            self.assertEqual([p["result"] for p in report["pairs"]], [
                {"mcp": "Failure", "twin": "Pass"}, {"mcp": "Crash", "twin": "Timeout"}, {"mcp": "Pass", "twin": None}])
            with mock.patch("builtins.print"):
                args = ["parity", str(run), "--coverage", str(run / "coverage.json"), "--reasons", str(run / "r.json")]
                (run / "coverage.json").write_text(json.dumps({"parity": [self.PAIR, self.pair("y-ok")]}))
                (run / "r.json").write_text(json.dumps({"differences": []}))
                self.assertEqual(driver_mcp.main(args), 1)
                (run / "coverage.json").write_text(json.dumps({"parity": [self.PAIR]}))
                self.assertEqual(driver_mcp.main(args), 0)

    def test_a_pair_masked_whole_from_the_entry_step_on_is_not_compared(self) -> None:
        data = runs({"mcp/x-ok": [("fx", "settled", 0, {"id": "a"}), ("call", "settled", 1, {"name": "a"}),
                                  ("retry", "settled", 2, {"name": "a"})],
                     "daemon-ops/x-ok": [("fx", "settled", 0, {"id": "a"}), ("call", "settled", 1, {"name": "b"}),
                                         ("retry", "settled", 2, {"name": "b"})]})
        whole = driver_mcp.Reason("/daemon", "r" * 30, ("x",), ("call/settled", "retry/*"))
        verdict = driver_mcp.compare_pair(self.PAIR, data, [whole])
        self.assertEqual((verdict["checkpoints"], verdict["masked"], verdict["reasoned"]), (0, 2, []))
        # A narrower reason still compares the checkpoint, and a whole mask on one checkpoint leaves the others.
        verdict = driver_mcp.compare_pair(self.PAIR, data, [driver_mcp.Reason("/daemon/name", "r" * 30)])
        self.assertEqual((verdict["checkpoints"], verdict["masked"], len(verdict["reasoned"])), (2, 0, 2))
        verdict = driver_mcp.compare_pair(self.PAIR, data, [driver_mcp.Reason("/daemon", "r" * 30, (), ("call/*",))])
        self.assertEqual((verdict["checkpoints"], verdict["masked"], len(verdict["differences"])), (1, 1, 1))
        with tempfile.TemporaryDirectory() as tmp:
            run = self.write_run(tmp, {"mcp/x-ok": "Pass", "daemon-ops/x-ok": "Pass"})
            whole_call = driver_mcp.Reason("/daemon", "r" * 30, (), ("call/settled",))
            report = driver_mcp.parity([run], {"parity": [self.PAIR]}, [whole_call])
            self.assertEqual(report["compared"], 0)
            self.assertIn("masked whole", report["not_compared"][0]["why"])

    def test_no_checked_in_reason_masks_a_pair_whole(self) -> None:
        """Every pair's checkpoints from the entry step on keep something compared under the checked-in reasons."""
        reasons = driver_mcp.load_reasons()
        coverage = json.loads(driver_mcp.COVERAGE_FILE.read_text())
        for pair in coverage["parity"]:
            if pair["entry"] != "resource.call":
                continue
            case = json.loads((driver_mcp.CORPUS / f"{pair['mcp'].split('/', 1)[1]}.json").read_text())
            ids = [step["id"] for step in case["steps"]]
            after = case["steps"][ids.index(pair["step"]):]
            ats = [f"{s['id']}/{cp}" for s in after for cp in (s.get("checkpoint") or ["settled"])]
            masked = [at for at in ats if any(r.masks_facet("daemon", pair["tool"], at) for r in reasons)]
            self.assertLess(len(masked), len(ats), pair)

    def test_the_checked_in_reasons_load(self) -> None:
        reasons = driver_mcp.load_reasons()
        self.assertTrue(reasons)
        self.assertTrue(all(len(r.reason) >= 20 for r in reasons))


if __name__ == "__main__":
    unittest.main()
