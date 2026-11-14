"""Optional completed-chat fixture for the startup benchmark, outside the measured interval.

The normal app actions create the session; the shipped test agent answers one
marker. Every measured reopen must preserve its exact session and transcript.
Runtime state is private temporary data, separate from the artifact volume and
the worker's config. Only readback receipts go into the output directory.
"""
import json
from pathlib import Path
import sys
import tempfile
import time


class RPCError(RuntimeError):
    def __init__(self, response):
        super().__init__(f"startup chat RPC failed: {response}")
        self.response = response


def unwrap(value):
    while isinstance(value, dict):
        if value.get("error") or value.get("ok") is False:
            raise RPCError(value)
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
        self.roots, self.receipts, self.expected = {}, {}, {}
        self.runtime_directories = []

    def environment(self, tag):
        if tag not in self.roots:
            # Fleet artifact volumes may have writable, non-sticky ancestors.
            # acpmux correctly refuses state there; /tmp permits a private child.
            runtime = tempfile.TemporaryDirectory(prefix="cmux-startup-chat-", dir="/tmp")
            self.runtime_directories.append(runtime)
            root = Path(runtime.name)
            receipts = Path(tempfile.mkdtemp(prefix="chat-", dir=self.output))
            (root / "project").mkdir()
            (root / "acpmux").mkdir(mode=0o700)
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
            self.receipts[tag] = receipts
            (receipts / "runtime.json").write_text(json.dumps({"root": str(root)}) + "\n")
        root = self.roots[tag]
        return {"ACPMUX_HOME": str(root / "acpmux"), "XDG_CONFIG_HOME": str(root / "config")}

    def close(self):
        """Remove only this fixture's runtime state after its apps have stopped."""
        for directory in self.runtime_directories:
            directory.cleanup()
        self.runtime_directories.clear()

    def seed(self, tag, client, timeout):
        marker = "STARTUP_FIXTURE_" + tag
        client.sock.settimeout(timeout)
        before = unwrap(client.call("debug.agent_pane", {"action": "chat_state"}))
        if before.get("sessionId") or transcript(before) or before.get("isWorking") or before.get("queued"):
            raise RuntimeError("startup fixture refuses to replace an existing conversation")
        reply = client.call("debug.agent_pane", {"action": "new_chat", "harness": "startup-fixture",
                                                "cwd": str(self.roots[tag] / "project")})
        (self.receipts[tag] / "create-reply.json").write_text(json.dumps(reply, indent=2) + "\n")
        try:
            unwrap(reply)
        except RPCError as error:
            if not str(error.response.get("error", "")).startswith('timedOut("DevTools Runtime.evaluate ('):
                raise
            # The page may have created the session before its evaluation reply
            # timed out. Read back that single request; never replay the mutation.
        # Folder trust is a user gesture surfaced by the agent page. The app CLI
        # deliberately does not expose a direct trust mutation method.
        trust = client.call("debug.agent_pane", {"action": "click", "selector": ".acpmux-trust-ask-action"})
        (self.receipts[tag] / "trust-click-reply.json").write_text(json.dumps(trust, indent=2) + "\n")
        unwrap(trust)
        try:
            self.until(client, lambda state: bool(state.get("sessionId")), timeout)
        except RuntimeError:
            # Preserve the owning page's reason before the isolated app exits.
            # These are reads only: an uncertain create must never be replayed.
            daemon_log = self.roots[tag] / "acpmux/daemon.log"
            if daemon_log.is_file():
                with daemon_log.open("rb") as log:
                    log.seek(0, 2)
                    log.seek(max(0, log.tell() - 16000))
                    print("startup fixture daemon log: " + log.read().decode(errors="replace"),
                          file=sys.stderr, flush=True)
            for action, params in (("chat_state", {}), ("acp_log", {"limit": 20}),
                                   ("query", {"selector": ".acpmux-trust-ask"})):
                try:
                    diagnostic = client.call("debug.agent_pane", {"action": action, **params})
                    (self.receipts[tag] / f"failed-{action}.json").write_text(json.dumps(diagnostic, indent=2) + "\n")
                    print(f"startup fixture {action}: {json.dumps(diagnostic)[:24000]}", file=sys.stderr, flush=True)
                except Exception as error:
                    print(f"startup fixture {action} diagnostic failed: {error}", file=sys.stderr, flush=True)
            raise
        unwrap(client.call("debug.agent_pane", {"action": "send_prompt", "text": marker}))
        state = self.until(client, lambda state: not state.get("isWorking") and
                           (state.get("lastAssistant") or {}).get("text") == "echo: " + marker, timeout)
        expected = [{"kind": "user", "text": marker}, {"kind": "assistant", "text": "echo: " + marker}]
        if transcript(state) != expected:
            raise RuntimeError("startup fixture did not create exactly one completed exchange")
        self.expected[tag] = {"sessionId": state["sessionId"], "transcript": expected}
        (self.receipts[tag] / "seed.json").write_text(json.dumps(state, indent=2) + "\n")

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
        path = self.receipts[tag] / f"restored-{time.monotonic_ns()}.json"
        path.write_text(json.dumps(state, indent=2) + "\n")
        return {**observed, "receipt": str(path)}
