#!/usr/bin/env python3
"""Tests for the shared model stub (model_stub.py): both wire formats, streamed and not, scripted tool calls and
templates. Standard library only: python3 tests/fixtures/model-stub/test_model_stub.py"""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import model_stub  # noqa: E402

SCRIPT = {
    "version": 1,
    "steps": [
        {"shell": "printenv NONCE_VAR"},
        {"tool": {"name": "Fetch", "input": {"url": "https://example.test/{{result.0}}"}}},
        {"text": "env={{result.0}}\nheader={{result.1~\"x-echo\"\\s*:\\s*\"([^\"]*)\"}}\nmissing=[{{result.5}}]\nnonce={{nonce}}"},
    ],
}


def post(url: str, body: dict, headers: dict | None = None) -> tuple[str, str]:
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers={"content-type": "application/json", **(headers or {})})
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.headers.get("content-type", ""), r.read().decode()


def sse(text: str) -> list[tuple[str, dict]]:
    out = []
    for block in text.strip().split("\n\n"):
        lines = dict(line.split(": ", 1) for line in block.splitlines())
        out.append((lines["event"], json.loads(lines["data"])))
    return out


class StubTest(unittest.TestCase):
    def setUp(self) -> None:
        self.log = tempfile.NamedTemporaryFile(delete=False, suffix=".jsonl").name
        self.server, self.stub = model_stub.serve(SCRIPT, "N0NCE", log_path=self.log)
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        os.unlink(self.log)

    def rows(self) -> list[dict]:
        with open(self.log) as f:
            return [json.loads(line) for line in f if line.strip()]

    # Anthropic Messages

    def anthropic(self, messages: list, stream: bool, tools=("Bash", "Fetch")) -> tuple[str, str]:
        body = {"model": "claude-x", "stream": stream, "messages": messages, "tools": [{"name": t, "input_schema": {}} for t in tools]}
        return post(self.base + "/v1/messages", body, {"authorization": "Bearer sk-ant-oat01-fake"})

    def test_anthropic_first_step_is_a_streamed_bash_call(self) -> None:
        ctype, text = self.anthropic([{"role": "user", "content": "go"}], stream=True)
        self.assertIn("text/event-stream", ctype)
        events = sse(text)
        self.assertEqual([e for e, _ in events][0], "message_start")
        self.assertEqual(events[-1][0], "message_stop")
        start = next(d for e, d in events if e == "content_block_start")
        self.assertEqual(start["content_block"]["type"], "tool_use")
        self.assertEqual(start["content_block"]["name"], "Bash")
        delta = next(d for e, d in events if e == "content_block_delta")
        self.assertEqual(json.loads(delta["delta"]["partial_json"])["command"], "printenv NONCE_VAR")
        stop = next(d for e, d in events if e == "message_delta")
        self.assertEqual(stop["delta"]["stop_reason"], "tool_use")
        row = self.rows()[-1]
        self.assertEqual((row["protocol"], row["step"], row["stream"]), ("anthropic", 0, True))
        self.assertEqual(row["cred_sha256"], hashlib.sha256(b"sk-ant-oat01-fake").hexdigest())
        self.assertNotIn("sk-ant-oat01-fake", open(self.log).read())

    def test_anthropic_templates_read_earlier_tool_results(self) -> None:
        messages = [
            {"role": "user", "content": "go"},
            {"role": "assistant", "content": [{"type": "tool_use", "id": "a", "name": "Bash", "input": {}}]},
            {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "a", "content": "abc123\n"}]},
            {"role": "assistant", "content": [{"type": "tool_use", "id": "b", "name": "Fetch", "input": {}}]},
            {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "b", "content": [{"type": "text", "text": '{"headers": {"X-Echo": "abc123"}}'}]}]},
        ]
        _, text = self.anthropic(messages, stream=False)
        reply = json.loads(text)
        self.assertEqual(reply["stop_reason"], "end_turn")
        self.assertEqual(reply["content"][0]["text"], "env=abc123\nheader=abc123\nmissing=[]\nnonce=N0NCE")

    def test_anthropic_named_tool_step_renders_its_input(self) -> None:
        messages = [
            {"role": "user", "content": "go"},
            {"role": "assistant", "content": [{"type": "tool_use", "id": "a", "name": "Bash", "input": {}}]},
            {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "a", "content": "abc"}]},
        ]
        _, text = self.anthropic(messages, stream=False)
        call = json.loads(text)["content"][0]
        self.assertEqual((call["type"], call["name"], call["input"]), ("tool_use", "Fetch", {"url": "https://example.test/abc"}))

    def test_count_tokens_and_models(self) -> None:
        _, text = post(self.base + "/v1/messages/count_tokens", {"messages": []})
        self.assertEqual(json.loads(text), {"input_tokens": 10})
        with urllib.request.urlopen(self.base + "/v1/models", timeout=10) as r:
            models = json.loads(r.read())
        self.assertEqual(models["data"][0]["id"], "stub-model")
        # Codex decodes {"models": [ModelInfo]}; an empty list leaves it on its fallback model metadata.
        self.assertEqual(models["models"], [])
        with urllib.request.urlopen(self.base + "/__stub/info", timeout=10) as r:
            self.assertEqual(json.loads(r.read())["version"], model_stub.STUB_VERSION)

    # OpenAI Responses

    def responses(self, items: list, stream: bool, tools: list) -> tuple[str, str]:
        body = {"model": "gpt-x", "stream": stream, "input": items, "tools": tools}
        return post(self.base + "/v1/responses", body, {"authorization": "Bearer sk-fake"})

    def test_responses_shell_step_uses_the_offered_shell_tool(self) -> None:
        for tools, name, args in (
            ([{"type": "function", "name": "exec_command"}], "exec_command", {"cmd": "printenv NONCE_VAR"}),
            ([{"type": "function", "name": "shell"}], "shell", {"command": ["bash", "-lc", "printenv NONCE_VAR"]}),
        ):
            _, text = self.responses([{"type": "message", "role": "user", "content": [{"type": "input_text", "text": "go"}]}], True, tools)
            events = sse(text)
            kinds = [e for e, _ in events]
            self.assertEqual(kinds[0], "response.created")
            self.assertEqual(kinds[-1], "response.completed")
            self.assertEqual([d["sequence_number"] for _, d in events], list(range(len(events))))
            done = next(d for e, d in events if e == "response.output_item.done")["item"]
            self.assertEqual((done["type"], done["name"], json.loads(done["arguments"])), ("function_call", name, args))
        _, text = self.responses([], True, [{"type": "local_shell"}])
        done = next(d for e, d in sse(text) if e == "response.output_item.done")["item"]
        self.assertEqual((done["type"], done["action"]["command"]), ("local_shell_call", ["bash", "-lc", "printenv NONCE_VAR"]))

    def test_responses_text_after_tool_outputs(self) -> None:
        items = [
            {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "go"}]},
            {"type": "function_call", "call_id": "c1", "name": "shell", "arguments": "{}"},
            {"type": "function_call_output", "call_id": "c1", "output": "Chunk ID: 7ae406\nWall time: 0.0000 seconds\nProcess exited with code 0\nOriginal token count: 3\nOutput:\nabc123\n"},
            {"type": "function_call", "call_id": "c2", "name": "Fetch", "arguments": "{}"},
            {"type": "function_call_output", "call_id": "c2", "output": '{"headers": {"x-echo": "abc123"}}'},
        ]
        _, text = self.responses(items, True, [{"type": "function", "name": "shell"}])
        events = sse(text)
        deltas = "".join(d["delta"] for e, d in events if e == "response.output_text.delta")
        self.assertEqual(deltas, "env=abc123\nheader=abc123\nmissing=[]\nnonce=N0NCE")
        final = events[-1][1]["response"]
        self.assertEqual(final["status"], "completed")
        self.assertEqual(final["output"][0]["content"][0]["text"], deltas)
        _, plain = self.responses(items, False, [{"type": "function", "name": "shell"}])
        self.assertEqual(json.loads(plain)["output"][0]["content"][0]["text"], deltas)
        self.assertEqual(self.rows()[-1]["protocol"], "openai")

    def test_tool_inputs_keep_quotes_newlines_and_regex_escapes(self) -> None:
        script = {"version": 1, "steps": [{"shell": "x"}, {"tool": {"name": "Fetch", "input": {"a": "{{result.0}}", "b": ["{{result.0~ (\\d+)}}"], "n": 3}}}]}
        server, _ = model_stub.serve(script, "n")
        try:
            msgs = [{"role": "user", "content": [{"type": "tool_result", "tool_use_id": "a", "content": 'say "hi"\nline2 42\\'}]}]
            _, text = post(f"http://127.0.0.1:{server.server_address[1]}/v1/messages", {"messages": msgs, "tools": [{"name": "Fetch"}]})
            self.assertEqual(json.loads(text)["content"][0]["input"], {"a": 'say "hi"\nline2 42\\', "b": ["42"], "n": 3})
        finally:
            server.shutdown()
            server.server_close()

    def test_side_requests_with_no_tools_get_text_and_never_a_step(self) -> None:
        _, text = post(self.base + "/v1/messages", {"messages": [{"role": "user", "content": "title?"}]})
        self.assertEqual(json.loads(text)["content"][0]["type"], "text")
        self.assertEqual((self.rows()[-1]["step"], self.rows()[-1]["side"]), (-1, True))

    def test_a_step_that_does_not_fit_is_a_400_with_a_reason(self) -> None:
        with self.assertRaises(urllib.error.HTTPError) as e:
            self.responses([], False, [{"type": "function", "name": "apply_patch"}])
        self.assertEqual(e.exception.code, 400)
        self.assertIn("no shell tool", json.loads(e.exception.read())["error"]["message"])
        self.assertIn("error", self.rows()[-1])

    def test_responses_shell_command_tool(self) -> None:
        _, text = self.responses([], False, [{"type": "function", "name": "shell_command"}])
        item = json.loads(text)["output"][0]
        self.assertEqual((item["name"], json.loads(item["arguments"])), ("shell_command", {"command": "printenv NONCE_VAR"}))

    def test_unknown_path_is_404_and_logged(self) -> None:
        with self.assertRaises(urllib.error.HTTPError) as e:
            post(self.base + "/v1/chat/completions", {})
        self.assertEqual(e.exception.code, 404)


class ScriptAndCliTest(unittest.TestCase):
    def test_load_script_refuses_bad_steps(self) -> None:
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump({"version": 1, "steps": [{"text": "a", "shell": "b"}]}, f)
        try:
            with self.assertRaises(ValueError):
                model_stub.load_script(f.name)
        finally:
            os.unlink(f.name)

    def test_load_script_refuses_a_bad_regex_and_a_nameless_tool(self) -> None:
        for steps in ([{"text": "{{result.0~(}}"}], [{"tool": {"input": {}}}], [{"text": 3}]):
            with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
                json.dump({"version": 1, "steps": steps}, f)
            try:
                with self.assertRaises(ValueError, msg=steps):
                    model_stub.load_script(f.name)
            finally:
                os.unlink(f.name)

    def test_shipped_scripts_load(self) -> None:
        for name in sorted(os.listdir(HERE)):
            if name.endswith(".json"):
                model_stub.load_script(os.path.join(HERE, name))

    def test_machine_vault_script_reads_both_echo_apis(self) -> None:
        script = model_stub.load_script(os.path.join(HERE, "machine-vault-e2e.json"))
        results = ["cmux-secret://MACHINE_VAULT_E2E\n",
                   '{"headers":{"host":"postman-echo.com","x-cmux-e2e":"n0nce42","accept":"*/*"}}',
                   '{\n  "headers": {\n    "Host": "httpbin.org", \n    "X-Cmux-E2e": "cmux-secret://MACHINE_VAULT_E2E"\n  }\n}\n']
        reply = model_stub.render(script["steps"][3]["text"], "", results)
        self.assertEqual(reply.splitlines()[:3], ["env=cmux-secret://MACHINE_VAULT_E2E", "allowed=n0nce42", "denied=cmux-secret://MACHINE_VAULT_E2E"])

    def test_prompt_templates_read_the_last_user_message(self) -> None:
        script = model_stub.load_script(os.path.join(HERE, "exact-reply.json"))
        server, _ = model_stub.serve(script, "n")
        base = f"http://127.0.0.1:{server.server_address[1]}"
        ask = "ping. Reply with exactly the text PONG-r1-2 and nothing else. No tools."
        try:
            # Claude Code: a reminder block beside the prompt, an earlier turn before it.
            msgs = [{"role": "user", "content": "Reply with exactly the text PONG-r1-1 and nothing else."},
                    {"role": "assistant", "content": [{"type": "text", "text": "PONG-r1-1"}]},
                    {"role": "user", "content": [{"type": "text", "text": "<system-reminder>x</system-reminder>"}, {"type": "text", "text": ask}]}]
            _, text = post(base + "/v1/messages", {"messages": msgs, "tools": [{"name": "Bash"}]})
            self.assertEqual(json.loads(text)["content"][0]["text"], "PONG-r1-2")
            items = [{"type": "message", "role": "user", "content": [{"type": "input_text", "text": ask}]}]
            _, plain = post(base + "/v1/responses", {"input": items, "tools": [{"type": "function", "name": "shell"}]})
            self.assertEqual(json.loads(plain)["output"][0]["content"][0]["text"], "PONG-r1-2")
            _, plain = post(base + "/v1/responses", {"input": ask, "tools": [{"type": "function", "name": "shell"}]})
            self.assertEqual(json.loads(plain)["output"][0]["content"][0]["text"], "PONG-r1-2")
        finally:
            server.shutdown()
            server.server_close()
        self.assertEqual(model_stub.render("[{{prompt}}]", "n", ["x"]), "[]")

    def test_cli_prints_ready_line_and_serves(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            ready = os.path.join(d, "ready.json")
            p = subprocess.Popen([sys.executable, os.path.join(HERE, "model_stub.py"), "--script", os.path.join(HERE, "echo-tool.json"),
                                  "--nonce", "abc", "--ready-file", ready], stdout=subprocess.PIPE, text=True)
            try:
                line = json.loads(p.stdout.readline())
                self.assertEqual(json.load(open(ready))["port"], line["port"])
                _, text = post(line["url"] + "/v1/messages", {"messages": [], "tools": [{"name": "Bash"}]})
                self.assertEqual(json.loads(text)["content"][0]["input"]["command"], "echo abc-tool")
            finally:
                p.terminate()
                p.wait(5)


if __name__ == "__main__":
    unittest.main()
