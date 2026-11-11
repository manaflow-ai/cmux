#!/usr/bin/env python3
"""scripts/ci/stable_next_slack.py: cmux NEXT Stable's Slack message, its thread and its final edit."""
from __future__ import annotations

import http.server
import importlib.util
import io
import json
import os
import tempfile
import threading
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("stable_next_slack", ROOT / "scripts/ci/stable_next_slack.py")
slack = importlib.util.module_from_spec(spec)
spec.loader.exec_module(slack)

ENV = {"BUILD": "4291415492601", "SHORT_VERSION": "1.0.0-nightly.4291415492601",
       "COMMIT": "9bef956af4a0c4d938c53db3220272bd38bfebb4", "RUN_URL": "https://github.com/o/r/actions/runs/1"}
ALL_PASS = {"plan": "success", "crash-class": "success", "perf-budgets": "success", "sign": "success",
            "smoke-27": "success", "smoke-26": "success", "soak": "success", "publish": "success"}


def text(body: dict) -> str:
    return "\n".join(block["text"]["text"] for block in body["blocks"])


class Messages(unittest.TestCase):
    def test_start_lists_every_gate_as_pending(self):
        body = slack.start_message(ENV)
        self.assertIn("`4291415492601`", text(body))
        self.assertIn("`9bef956af4`", text(body))
        self.assertEqual(text(body).count(":hourglass_flowing_sand:"), len(slack.LANES))

    def test_shipped(self):
        body = slack.final_message(ALL_PASS, {}, ENV)
        self.assertIn("shipped", text(body))
        self.assertIn(slack.FEED, text(body))
        self.assertNotIn(":x:", text(body))

    def test_blocked_names_the_failed_gates_and_mentions(self):
        results = {**ALL_PASS, "perf-budgets": "failure", "smoke-26": "cancelled", "publish": "skipped"}
        body = slack.final_message(results, {}, {**ENV, "MENTION": "<@U123>"})
        first = body["blocks"][0]["text"]["text"]
        self.assertIn("blocked", first)
        self.assertIn("Speed check (perf budgets)", first)
        self.assertIn("First-session UI test, macOS 26", first)
        self.assertNotIn("Crash-risk scan", first)
        self.assertIn("<@U123>", text(body))

    def test_blocked_at_plan_gives_plans_reason(self):
        body = slack.final_message({"plan": "failure"}, {"plan": "refused: build 7 was pulled"}, {"RUN_URL": "u"})
        self.assertIn("no build was tested", text(body))
        self.assertIn("build 7 was pulled", text(body))

    def test_a_failed_lane_quotes_why(self):
        body = slack.lane_message("crash-class", "failure", "rust acpmux: exit: 4 -> 6", ENV)
        self.assertIn(":x: *Crash-risk scan* failed", text(body))
        self.assertIn("```rust acpmux: exit: 4 -&gt; 6```", text(body))  # Slack shows &gt; as >

    def test_a_pass_with_a_warning_is_not_a_clean_pass(self):
        body = slack.lane_message("perf-budgets", "success", "step k-1 still queued after 3 h; no perf verdict", ENV)
        self.assertIn(":warning: *Speed check (perf budgets)* passed, with a warning", text(body))

    def test_details_cannot_break_the_code_block_or_ping_anyone(self):
        fence = "`" * 3
        body = slack.lane_message("soak", "failure", f"title {fence}x{fence} <@U1> <!channel> a & b", ENV)
        self.assertEqual(text(body).count(fence), 2)
        self.assertNotIn("<@U1>", text(body))
        self.assertNotIn("<!channel>", text(body))
        self.assertIn("&amp;", text(body))

    def test_long_details_are_clipped_under_slacks_block_limit(self):
        body = slack.lane_message("perf-budgets", "failure", "row\n" * 5000, ENV)
        self.assertLess(len(text(body)), 3000)


class Reasons(unittest.TestCase):
    def test_keeps_each_gates_own_errors_and_drops_runner_noise(self):
        notes = [
            {"annotation_level": "failure", "title": "", "message": "Process completed with exit code 1."},
            {"annotation_level": "warning", "title": "x", "message": "a warning"},
            {"annotation_level": "failure", "title": "cmux NEXT Stable: slower than the baseline",
             "message": "REGRESSION workspace_switch p95 35.8 vs baseline 6.4 (+463.2 %)"},
            {"annotation_level": "failure", "title": "cmux NEXT Stable: slower than the baseline",
             "message": "REGRESSION workspace_switch p95 35.8 vs baseline 6.4 (+463.2 %)"},
        ]
        self.assertEqual(slack.reasons(notes),
                         "slower than the baseline: REGRESSION workspace_switch p95 35.8 vs baseline 6.4 (+463.2 %)")


class Warnings(unittest.TestCase):
    def test_only_this_pipelines_warnings_count(self):
        notes = [
            {"annotation_level": "warning", "title": "", "message": "Node.js 20 actions are deprecated."},
            {"annotation_level": "warning", "title": "stable perf", "message": "step k-1 still queued after 3 h (kept)"},
        ]
        self.assertEqual(slack.reasons(notes, "warning"), "stable perf: step k-1 still queued after 3 h (kept)")


class FakeSlack(http.server.BaseHTTPRequestHandler):
    calls: list = []

    def do_POST(self):  # noqa: N802
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        FakeSlack.calls.append((self.path, self.headers.get("Authorization"), body))
        answer = {"ok": True, "ts": "1700000000.000100", "channel": "C0STABLE"}
        if body.get("channel") == "C0BROKEN":
            answer = {"ok": False, "error": "not_in_channel"}
        data = json.dumps(answer).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass


class EndToEnd(unittest.TestCase):
    def setUp(self):
        FakeSlack.calls = []
        self.server = http.server.HTTPServer(("127.0.0.1", 0), FakeSlack)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.tmp = tempfile.TemporaryDirectory()
        self.output = Path(self.tmp.name) / "out"
        self.env = {**ENV, "SLACK_API_URL": f"http://127.0.0.1:{self.server.server_port}",
                    "SLACK_BOT_TOKEN": "xoxb-test", "SLACK_CHANNEL": "C0STABLE", "GITHUB_OUTPUT": str(self.output)}

    def tearDown(self):
        self.server.shutdown()
        self.tmp.cleanup()

    def run_cli(self, *argv, **extra):
        out = io.StringIO()
        with mock.patch.dict(os.environ, {**self.env, **extra}, clear=True), redirect_stdout(out):
            code = slack.main(list(argv))
        return code, out.getvalue()

    def test_start_thread_and_final_edit(self):
        self.assertEqual(self.run_cli("start")[0], 0)
        self.assertIn("ts=1700000000.000100", self.output.read_text())
        self.assertIn("channel=C0STABLE", self.output.read_text())
        self.run_cli("lane", "--lane", "smoke-27", "--result", "failure", "--detail", "UI step palette failed",
                     TS="1700000000.000100", CHANNEL_ID="C0STABLE")
        self.run_cli("final", "--results", "plan=success,smoke-27=failure,publish=skipped",
                     TS="1700000000.000100", CHANNEL_ID="C0STABLE")
        paths = [path for path, _, _ in FakeSlack.calls]
        self.assertEqual(paths, ["/chat.postMessage", "/chat.postMessage", "/chat.update"])
        self.assertTrue(all(auth == "Bearer xoxb-test" for _, auth, _ in FakeSlack.calls))
        self.assertEqual(FakeSlack.calls[1][2]["thread_ts"], "1700000000.000100")
        self.assertEqual(FakeSlack.calls[2][2]["ts"], "1700000000.000100")
        self.assertIn("UI step palette failed", text(FakeSlack.calls[1][2]))

    def test_final_without_a_message_posts_one(self):
        self.run_cli("final", "--results", "plan=failure", "--detail", "plan=refused: pulled")
        self.assertEqual([path for path, _, _ in FakeSlack.calls], ["/chat.postMessage"])

    def test_not_configured_or_a_slack_error_never_fails_the_run(self):
        code, out = self.run_cli("start", SLACK_BOT_TOKEN="")
        self.assertEqual(code, 0)
        self.assertIn("::warning", out)
        self.assertEqual(FakeSlack.calls, [])
        code, out = self.run_cli("start", SLACK_CHANNEL="C0BROKEN")
        self.assertEqual(code, 0)
        self.assertIn("not_in_channel", out)
        code, out = self.run_cli("start", SLACK_API_URL="http://127.0.0.1:9")  # nothing listens there
        self.assertEqual(code, 0)
        self.assertIn("::warning", out)

    def test_a_lane_without_the_runs_message_posts_nothing(self):
        self.assertEqual(self.run_cli("lane", "--lane", "soak", "--result", "success")[0], 0)
        self.assertEqual(FakeSlack.calls, [])


if __name__ == "__main__":
    unittest.main()
