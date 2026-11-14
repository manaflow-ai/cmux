"""Optional completed-chat fixture for the startup benchmark, outside the measured interval.

The normal app actions create the session; the shipped test agent answers one
marker. Every measured reopen must preserve its exact session and transcript.
Configuration is private to the receipt directory, never the worker's config.
"""
import json
from pathlib import Path
import sys
import tempfile
import time


def unwrap(value):
    while isinstance(value, dict):
        if value.get("error") or value.get("ok") is False:
            raise RuntimeError(f"startup chat RPC failed: {value}")
        if "result" not in value:
            return value
        value = value["result"]
    raise RuntimeError("startup chat RPC returned no object")


def transcript(state):
    return [{"kind": row.get("kind"), "text": row.get("text")} for row in state.get("transcript", [])]


class ChatFixture:
    def __init__(self, output):
        self.output = Path(output).resolve()
        self.output.mkdir(parents=True, exist_ok=False)
        self.roots, self.expected = {}, {}

    def environment(self, tag):
        if tag not in self.roots:
            root = Path(tempfile.mkdtemp(prefix="chat-", dir=self.output))
            (root / "project").mkdir()
            (root / "acpmux").mkdir()
            profiles = root / "config/cmux/harnesses"
            profiles.mkdir(parents=True)
            agent = Path(__file__).resolve().parents[2] / "cmux-tui/crates/acpmux/tests/fake_agent.py"
            if not agent.is_file():
                raise RuntimeError(f"missing startup fixture agent: {agent}")
            (profiles / "startup-fixture.toml").write_text(
                'id = "startup-fixture"\nname = "Startup fixture"\n'
                f"command = {json.dumps(sys.executable)}\nargs = [{json.dumps(str(agent))}]\n"
            )
            self.roots[tag] = root
        root = self.roots[tag]
        return {"ACPMUX_HOME": str(root / "acpmux"), "XDG_CONFIG_HOME": str(root / "config")}

    def seed(self, tag, client, timeout):
        marker = "STARTUP_FIXTURE_" + tag
        client.sock.settimeout(timeout)
        unwrap(client.call("debug.agent_pane", {"action": "new_chat", "harness": "startup-fixture",
                                               "cwd": str(self.roots[tag] / "project")}))
        self.until(client, lambda state: bool(state.get("sessionId")), timeout)
        unwrap(client.call("debug.agent_pane", {"action": "send_prompt", "text": marker}))
        state = self.until(client, lambda state: not state.get("isWorking") and
                           (state.get("lastAssistant") or {}).get("text") == "echo: " + marker, timeout)
        expected = [{"kind": "user", "text": marker}, {"kind": "assistant", "text": "echo: " + marker}]
        if transcript(state) != expected:
            raise RuntimeError("startup fixture did not create exactly one completed exchange")
        self.expected[tag] = {"sessionId": state["sessionId"], "transcript": expected}
        (self.roots[tag] / "seed.json").write_text(json.dumps(state, indent=2) + "\n")

    @staticmethod
    def until(client, predicate, timeout):
        # chat_state has no event subscription. Only setup uses bounded backoff;
        # measured launch readiness still comes from the benchmark's mark pipe.
        deadline, delay = time.monotonic() + timeout, 0.05
        while True:
            state = unwrap(client.call("debug.agent_pane", {"action": "chat_state"}))
            if predicate(state):
                return state
            left = deadline - time.monotonic()
            if left <= 0:
                raise RuntimeError("startup chat fixture did not become ready")
            time.sleep(min(delay, left))
            delay = min(delay * 1.5, 1)

    def verify(self, tag, client, marks):
        missing = {"first_terminal_frame", "agent_pane.painted", "agent_pane.settled_painted"} - marks.keys()
        if missing:
            raise RuntimeError(f"startup sample lacks required paint marks: {sorted(missing)}")
        state = unwrap(client.call("debug.agent_pane", {"action": "chat_state"}))
        observed = {"sessionId": state.get("sessionId"), "transcript": transcript(state)}
        expected = self.expected.get(tag)
        if not expected or observed != expected or state.get("isWorking") or state.get("queued"):
            raise RuntimeError("startup sample lost, changed or duplicated the seeded conversation")
        # A receipt is taken after the paint marks, so it cannot reduce measured time.
        path = self.roots[tag] / f"restored-{time.monotonic_ns()}.json"
        path.write_text(json.dumps(state, indent=2) + "\n")
        return {**observed, "receipt": str(path)}
