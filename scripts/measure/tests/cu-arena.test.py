#!/usr/bin/env python3
"""scripts/measure/cu-driver-eval/arena: the harness trace parsers, the checkers, the sampler's
grouping, the summary, and the two MCP shims (chief-desktop, the cu-rewrite host) against fakes.
No Mac, no model: synthetic traces and fake binaries in a temp folder.
Run: python3 -I scripts/measure/tests/cu-arena.test.py"""
import importlib.util, json, os, socket, subprocess, sys, tempfile, time, unittest
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
DIR = os.path.normpath(os.path.join(HERE, "..", "cu-driver-eval", "arena"))


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(DIR, f"{name}.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


arena = load("arena")
TASKS = json.load(open(os.path.join(DIR, "tasks.json")))
TASK = {t["id"]: t for t in TASKS["tasks"]}


def lines(*events):
    return [json.dumps(e) for e in events]


class Parsers(unittest.TestCase):
    def test_claude_counts_tools_images_turns_and_tokens(self):
        r = arena.parse_claude(lines(
            {"type": "system", "subtype": "init"},
            {"type": "assistant", "message": {"id": "m1", "content": [
                {"type": "tool_use", "name": "mcp__computer__get_window_state", "input": {}}]}},
            {"type": "user", "message": {"content": [{"type": "tool_result", "content": [
                {"type": "image", "source": {}}, {"type": "text", "text": "tree"}]}]}},
            {"type": "assistant", "message": {"id": "m2", "content": [
                {"type": "text", "text": "clicking"}, {"type": "tool_use", "name": "mcp__computer__click", "input": {}}]}},
            {"type": "assistant", "message": {"id": "m2", "content": [
                {"type": "tool_use", "name": "mcp__computer__type_text", "input": {}}]}},
            {"type": "user", "message": {"content": [{"type": "tool_result", "is_error": True, "content": "refused"}]}},
            {"type": "result", "result": "ABC123", "num_turns": 3, "duration_api_ms": 4200,
             "usage": {"input_tokens": 50, "cache_read_input_tokens": 9000, "cache_creation_input_tokens": 1200, "output_tokens": 310}},
        ))
        self.assertEqual((r["tool_calls"], r["actions"], r["observations"]), (3, 2, 1))
        self.assertEqual((r["screenshots"], r["tool_errors"], r["model_calls"]), (1, 1, 2))
        self.assertEqual((r["input_tokens"], r["cached_input_tokens"], r["cache_write_tokens"], r["output_tokens"]), (50, 9000, 1200, 310))
        self.assertEqual(r["answer"], "ABC123")
        self.assertEqual(r["tools"], {"get_window_state": 1, "click": 1, "type_text": 1})

    def test_claude_without_a_result_leaves_tokens_unknown(self):
        r = arena.parse_claude(lines({"type": "assistant", "message": {"id": "m1", "content": []}}))
        self.assertIsNone(r["input_tokens"])
        self.assertIsNone(r["output_tokens"])

    def test_codex_counts_mcp_calls_shell_and_usage(self):
        r = arena.parse_codex(lines(
            {"type": "thread.started"},
            {"type": "item.completed", "item": {"type": "reasoning", "text": "look"}},
            {"type": "item.completed", "item": {"type": "mcp_tool_call", "server": "computer", "tool": "screenshot", "status": "completed",
                                                "result": {"content": [{"type": "image", "data": "x"}]}}},
            {"type": "item.completed", "item": {"type": "mcp_tool_call", "server": "computer", "tool": "click", "status": "failed"}},
            {"type": "item.completed", "item": {"type": "reasoning", "text": "again"}},
            {"type": "item.completed", "item": {"type": "mcp_tool_call", "server": "computer", "tool": "type_text", "status": "completed"}},
            {"type": "item.completed", "item": {"type": "command_execution", "command": "osascript"}},
            {"type": "item.completed", "item": {"type": "agent_message", "text": "done"}},
            {"type": "turn.completed", "usage": {"input_tokens": 12000, "cached_input_tokens": 8000, "output_tokens": 400}},
        ))
        self.assertEqual((r["tool_calls"], r["actions"], r["observations"], r["screenshots"]), (3, 2, 1, 1))
        self.assertEqual((r["tool_errors"], r["shell_calls"], r["model_calls"]), (1, 1, 3))
        self.assertEqual((r["input_tokens"], r["cached_input_tokens"], r["output_tokens"]), (12000, 8000, 400))
        self.assertEqual(r["answer"], "done")


class Argv(unittest.TestCase):
    def test_claude_runs_with_no_builtin_tools_and_medium_effort(self):
        with tempfile.TemporaryDirectory() as folder:
            argv = arena.claude_argv("claude-opus-5-5", "do it", Path(folder) / "m.json", "guide", 60)
        self.assertEqual(argv[argv.index("--tools") + 1], "")
        self.assertEqual(argv[argv.index("--effort") + 1], "medium")
        self.assertIn("--strict-mcp-config", argv)
        self.assertEqual(argv[argv.index("--append-system-prompt") + 1], "guide")

    def test_codex_has_no_shell_and_its_own_computer_use_off(self):
        argv = arena.codex_argv("gpt-6-astra", "do it", {"command": "/x/mcp", "args": ["a b"], "env": {"K": "v\"q"}}, None, "http://127.0.0.1:4016")
        disabled = {argv[i + 1] for i, a in enumerate(argv) if a == "--disable"}
        self.assertTrue({"shell_tool", "unified_exec", "computer_use", "browser_use"} <= disabled)
        self.assertIn('mcp_servers.computer.command="/x/mcp"', argv)
        self.assertIn('mcp_servers.computer.args=["a b"]', argv)
        self.assertIn('mcp_servers.computer.env={K = "v\\"q"}', argv)
        self.assertIn('model_providers.arena.base_url="http://127.0.0.1:4016/v1"', argv)
        self.assertEqual(argv[-1], "do it")


class Checks(unittest.TestCase):
    def task(self, task_id, states=None):
        work = Path(tempfile.mkdtemp())
        t = arena.Task(TASK[task_id], Path("/nonexistent"), Path("/nonexistent"), work, 0)
        for mode, state in (states or {}).items():
            path = work / f"state-{mode}.json"
            path.write_text(json.dumps(state))
            t.states[mode] = path
        return t

    def test_form_passes_only_with_every_field(self):
        good = {"name": "Ada Lovelace ", "email": "ada@example.com", "plan": "Team", "agree": True, "submitted": True}
        self.assertEqual(self.task("form-fill", {"form": good}).check(""), (True, ""))
        ok, why = self.task("form-fill", {"form": {**good, "plan": "Pro"}}).check("")
        self.assertFalse(ok)
        self.assertIn("plan", why)

    def test_settings_must_not_touch_other_panes(self):
        st = {"scrollback": "5000", "telemetry": False, "restore": False, "theme": "System"}
        self.assertTrue(self.task("settings-pane", {"settings": st}).check("")[0])
        self.assertFalse(self.task("settings-pane", {"settings": {**st, "theme": "Dark"}}).check("")[0])

    def test_read_needs_the_exact_code_token(self):
        t = self.task("read-canvas", {"canvas": {"code": "MX7KAD"}})
        self.assertTrue(t.check("The code is MX7KAD.")[0])
        self.assertFalse(t.check("MX7KA")[0])

    def test_list_needs_only_the_target(self):
        self.assertTrue(self.task("list-scroll", {"list": {"target": "0042", "paid": ["0042"]}}).check("")[0])
        self.assertFalse(self.task("list-scroll", {"list": {"target": "0042", "paid": ["0041", "0042"]}}).check("")[0])

    def test_two_windows_compares_against_the_other_app(self):
        t = self.task("two-windows", {"readout": {"code": "HJK469"}, "form": {"name": "hjk469", "submitted": True}})
        self.assertTrue(t.check("")[0])

    def test_prompt_fills_the_target(self):
        self.assertIn("Invoice 0042", self.task("list-scroll", {"list": {"target": "0042"}}).prompt())

    def test_every_task_has_a_known_check(self):
        known = {"state", "equals", "equals_state_key", "answer_state", "key", "answer", "ax_value", "file_text", "contains", "exists", "missing"}
        for t in TASKS["tasks"]:
            self.assertTrue(set(t["check"]) <= known, t["id"])
            self.assertTrue(set(t["setup"]) <= {"arena", "textedit", "calculator", "files", "remove"}, t["id"])


class Sampling(unittest.TestCase):
    def test_groups_by_mcp_root_daemon_name_and_app(self):
        s = arena.Sampler(10, ["Python"], ["cmux-cua"], ["Arena"])
        table = {
            1: {"ppid": 0, "rss_kb": 1, "cpu_s": 0, "comm": "launchd"},
            9: {"ppid": 1, "rss_kb": 1, "cpu_s": 0, "comm": "/usr/bin/Python"},  # the runner itself
            10: {"ppid": 9, "rss_kb": 1, "cpu_s": 0, "comm": "/opt/homebrew/bin/claude"},
            11: {"ppid": 10, "rss_kb": 1, "cpu_s": 0, "comm": "/x/Python"},  # the MCP server
            12: {"ppid": 11, "rss_kb": 1, "cpu_s": 0, "comm": "/x/arena-desktop"},
            13: {"ppid": 1, "rss_kb": 1, "cpu_s": 0, "comm": "/a/cmux-cua"},
            14: {"ppid": 1, "rss_kb": 1, "cpu_s": 0, "comm": "/a/Arena"},
            15: {"ppid": 1, "rss_kb": 1, "cpu_s": 0, "comm": "/System/WindowServer"},
        }
        g = s.classify(table)
        self.assertEqual(set(g["harness"]), {10})
        self.assertEqual(set(g["engine"]), {11, 12, 13})
        self.assertEqual(set(g["apps"]), {14})
        self.assertEqual(set(g["windowserver"]), {15})

    def test_cpu_from_cputime_deltas(self):
        s = arena.Sampler(10, [], [], [])
        row = lambda cpu, rss: {"harness": {10: {"ppid": 1, "rss_kb": rss, "cpu_s": cpu, "comm": "claude"}}, "engine": {}, "apps": {}, "windowserver": {}}
        s.samples = [(0.0, row(1.0, 1024)), (1.0, row(1.5, 2048)), (2.0, row(1.6, 1024))]
        r = s.stop()["harness"]
        self.assertEqual((r["cpu_avg_pct"], r["cpu_peak_pct"], r["rss_peak_mb"]), (30.0, 50.0, 2.0))
        self.assertIsNone(s.stop()["engine"]["cpu_avg_pct"])

    def test_cputime_formats(self):
        self.assertEqual(arena.parse_cputime("0:01.50"), 1.5)
        self.assertEqual(arena.parse_cputime("1:02:03.00"), 3723.0)
        self.assertEqual(arena.parse_cputime("2-00:00:01"), 172801.0)


class Daemon(unittest.TestCase):
    def test_a_daemon_that_never_listens_is_an_error_not_a_ready_arm(self):
        d = Path(tempfile.mkdtemp())
        spec = {"daemon": {"argv": [sys.executable, "-c", "import time; time.sleep(60)"], "ready_socket": str(d / "never.sock"), "env": {}}}
        start = time.monotonic()
        with self.assertRaises(RuntimeError) as caught:
            arena.start_daemon("slow", spec, d)
        self.assertIn("made no", str(caught.exception))
        self.assertLess(time.monotonic() - start, 40)

    def test_owner_pid_becomes_the_runners(self):
        d = Path(tempfile.mkdtemp())
        seen = d / "argv.txt"
        spec = {"daemon": {"argv": [sys.executable, "-c", f"import sys; open({str(seen)!r}, 'w').write(' '.join(sys.argv[1:])); open({str(d / 'ready')!r}, 'w')",
                                    "--owner-pid", "1"], "ready_socket": str(d / "ready"), "env": {}}}
        proc = arena.start_daemon("ok", spec, d)
        proc.wait(timeout=10)
        self.assertEqual(seen.read_text(), f"--owner-pid {os.getpid()}")


class Summary(unittest.TestCase):
    def test_tables_per_config_and_task_and_unavailable(self):
        out = Path(tempfile.mkdtemp())
        rows = []
        for rep in range(5):
            rows.append({"config": "cu-fast|claude:claude-opus-5-5", "arm": "cu-fast", "task": "form-fill", "rep": rep,
                         "passed": rep != 2, "wall_s": 20.0 + rep, "tool_calls": 6, "model_calls": 5, "screenshots": 3,
                         "input_tokens": 10, "cached_input_tokens": 1000, "cache_write_tokens": 0, "output_tokens": 200,
                         "resources": {"engine": {"cpu_avg_pct": 12.0, "cpu_peak_pct": 80.0, "rss_peak_mb": 60.0}},
                         "reason": "plan='Pro'" if rep == 2 else ""})
        rows.append({"config": "cu-rewrite|claude:claude-opus-5-5", "arm": "cu-rewrite", "task": None, "unavailable": "did not build"})
        (out / "trials.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
        data = arena.write_summary(out, out / "summary.md")
        md = (out / "summary.md").read_text()
        self.assertIn("| cu-fast | claude:claude-opus-5-5 | 4/5 (80%) | 22.0 / 23.6 |", md)
        self.assertIn("not run: did not build", md)
        self.assertIn("form-fill", md)
        self.assertNotIn("$", md)  # tokens and time, never money
        self.assertEqual(data["by_config"]["cu-fast|claude:claude-opus-5-5"]["in_tokens_p50"], 1010)


class ChiefDesktop(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.fake = self.dir / "arena-desktop"
        self.calls = self.dir / "calls.txt"
        self.fake.write_text(f"""#!/bin/sh
echo "$@" >> {self.calls}
if [ "$1" = screenshot ]; then printf 'JPEG' > "$2"; echo '{{"width":1280,"height":720,"scale":0.6666666667}}'; fi
""")
        self.fake.chmod(0o755)
        self.proc = subprocess.Popen([sys.executable, "-I", os.path.join(DIR, "chief_computer_mcp.py"), "--desktop", str(self.fake)],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)

    def tearDown(self):
        self.proc.stdin.close()
        self.proc.wait(timeout=10)
        self.proc.stdout.close()

    def ask(self, mid, method, params=None):
        self.proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": mid, "method": method, "params": params or {}}) + "\n")
        self.proc.stdin.flush()
        return json.loads(self.proc.stdout.readline())

    def test_screenshot_is_an_image_and_input_answers_a_note_at_points(self):
        self.ask(1, "initialize")
        tools = self.ask(2, "tools/list")["result"]["tools"]
        self.assertEqual([t["name"] for t in tools], ["computer"])
        self.assertIn("1280x720", tools[0]["description"])
        shot = self.ask(3, "tools/call", {"name": "computer", "arguments": {"op": "screenshot"}})["result"]["content"]
        self.assertEqual(shot[0]["type"], "image")
        click = self.ask(4, "tools/call", {"name": "computer", "arguments": {"op": "click", "x": 640, "y": 360}})["result"]
        self.assertIn("take a screenshot", click["content"][0]["text"])
        self.assertIn("click 960.0 540.0 1 left", self.calls.read_text())
        bad = self.ask(5, "tools/call", {"name": "computer", "arguments": {"op": "type", "x": 1, "text": "a"}})["result"]
        self.assertTrue(bad["isError"])


class CuRewriteHost(unittest.TestCase):
    def test_configures_the_worker_and_answers_the_endpoint(self):
        d = Path(tempfile.mkdtemp())
        exe = d / "Remote.app" / "Contents" / "MacOS" / "cmux-remote"
        exe.parent.mkdir(parents=True)
        seen = d / "configure.json"
        exe.write_text(f"""#!{sys.executable}
import json, sys
line = sys.stdin.readline()
open({str(seen)!r}, "w").write(line)
c = json.loads(line)
print(json.dumps({{"type": "ready", "pid": 4242, "socket": c["socket"]}}), flush=True)
sys.stdin.read()
""")
        exe.chmod(0o755)
        sock = str(d / "daemon.sock")
        host = subprocess.Popen([sys.executable, "-I", os.path.join(DIR, "cu_rewrite_host.py"), "--remote", str(d / "Remote.app"),
                                 "--socket", sock, "--state", str(d / "state")], stderr=subprocess.DEVNULL)
        try:
            for _ in range(100):
                if os.path.exists(sock):
                    break
                time.sleep(0.05)
            c = socket.socket(socket.AF_UNIX)
            c.connect(sock)
            c.sendall(b'{"id":"cu-1","cmd":"computer-use-endpoint"}\n')
            reply = json.loads(c.makefile().readline())
            c.close()
            self.assertEqual(reply["id"], "cu-1")
            self.assertTrue(reply["ok"])
            self.assertEqual(reply["data"]["state"], "ready")
            self.assertEqual(reply["data"]["pid"], 4242)
            configure = json.loads(seen.read_text())
            self.assertEqual(configure["type"], "configure")
            self.assertEqual(configure["config"], {"mode": "fullAccess"})
            self.assertEqual(configure["secret"], reply["data"]["secret"])
            self.assertGreaterEqual(len(configure["secret"]), 32)
        finally:
            host.terminate()
            host.wait(timeout=10)


if __name__ == "__main__":
    unittest.main()
