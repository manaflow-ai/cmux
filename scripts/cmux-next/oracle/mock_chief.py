#!/usr/bin/env python3
"""The mock agent of the daemon-op chief family: a mock Chief brain and its Chief conversation (stdlib only).

Spec: plans/cmux-next/chrome-parity/p15-oracle.md section 9 (069 and 240). A real Chief brain (optchat-chief) runs a
model with agent credentials, which no oracle case may hold. The daemon talks to the default Chief's brain through one
Unix socket, CMUX_TUI_CHIEF_TOOLS_SOCKET (server/chief_control.rs, chief_inspect.rs): one JSON line in, one JSON line
out. MockChief serves that socket with fixed answers, so chief.engine.set and chief.stop run their whole daemon path
(owner check, forward, result mapping, the engine record write) with no model and no credential.

The mock agent's conversation is the Chief conversation `cmux chief` makes on first launch (cli/chief/launch.rs
ensure_conversation): the person and the default Chief (agent_mux), plus one more agent participant (agent_oracle)
that chief.profile.adopt can make a Chief. CHIEF_CONVERSATION is that `conversation-create` request.

Chromium reference: components/sync/test/fake_server/fake_server.h. The sync tests replace the remote service with a
fake at its protocol boundary and keep the whole client path real; this mock replaces the brain at its tools socket.

Usage:
    mock_chief.py live --cmux BINARY [--daemon-blocking record]   the mock agent on a real debug cmux-tui (VM)
    mock_chief.py --selftest
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import socket
import socketserver
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from typing import Any, Callable, Dict, List, Mapping, Optional

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
SDK = REPO / "cmux-tui" / "bindings" / "python"

TOOLS_SOCKET_ENV = "CMUX_TUI_CHIEF_TOOLS_SOCKET"
MAX_LINE_BYTES = 1024 * 1024

# What the mock brain reports as its engine: optchat-chief's `engine` tool answer shape (chief_control_tests.rs).
ENGINE = {"harness": "mock", "model": "mock", "effort": "low"}
# The `engine set` fields chief_control.rs tool_line forwards.
ENGINE_FIELDS = frozenset({
    "harness", "model", "effort", "speed", "compactor_speed", "compactor_harness", "compactor_model",
    "classifier_harness", "classifier_model", "classifier_prompt", "reactions_can_wake",
})
STOP_FIELDS = frozenset({"name", "all", "restart"})

ADOPTABLE = "agent_oracle"
CHIEF_CONVERSATION: Dict[str, Any] = {
    "idempotency_key": "oracle-mock-agent",
    "actor": "user_local",
    "title": "Chief",
    "participants": [
        {"id": "user_local", "kind": "human", "display_name": "oracle"},
        {"id": "agent_mux", "kind": "agent", "display_name": "Chief", "agent_class": "mux", "acp_session": "mux"},
        {"id": ADOPTABLE, "kind": "agent", "display_name": "oracle agent", "agent_class": "mux",
         "acp_session": "oracle"},
    ],
}


class MockChiefError(Exception):
    """A mock brain that cannot serve, or a live check that failed."""


def answer(line: Any) -> Dict[str, Any]:
    """The mock brain's answer to one tools-socket line. A line it does not know gets the brain's error shape,
    which chief_control.rs `result` maps to operation.failed with the code as the reason."""
    if not isinstance(line, dict):
        return {"error": {"code": "bad_request", "message": "a tools line is a JSON object"}}
    tool = line.get("tool")
    if tool == "engine" and line.get("action") == "show":
        return {"engine": dict(ENGINE), "choice": {}, "last_turn": None, "recent": []}
    if tool == "engine" and line.get("action") == "set":
        unknown = sorted(set(line) - ENGINE_FIELDS - {"tool", "action"})
        if unknown:
            return {"error": {"code": "bad_request", "message": f"engine set takes no {unknown}"}}
        choice = {key: value for key, value in line.items() if key in ENGINE_FIELDS}
        engine = {**ENGINE, **{key: choice[key] for key in ("harness", "model", "effort") if key in choice}}
        return {"engine": engine, "choice": choice}
    if tool == "stop":
        unknown = sorted(set(line) - STOP_FIELDS - {"tool"})
        if unknown:
            return {"error": {"code": "bad_request", "message": f"stop takes no {unknown}"}}
        # The mock runs no turn, so there is none to stop.
        return {"stopped": False, "note": "no turn is running"}
    return {"error": {"code": "unknown_tool", "message": f"the mock Chief has no tool {tool!r}"}}


class _Handler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        raw = self.rfile.readline(MAX_LINE_BYTES + 1)
        try:
            line: Any = json.loads(raw)
        except ValueError:
            line = None
        server: "_Server" = self.server  # type: ignore[assignment]
        server.mock.record(line)
        self.wfile.write(json.dumps(answer(line), sort_keys=True).encode() + b"\n")


class _Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True

    def __init__(self, path: str, mock: "MockChief"):
        self.mock = mock
        super().__init__(path, _Handler)


class MockChief:
    """The mock brain's tools socket at `path` (its directory must exist; the socket is the caller's user's, which
    chief_inspect.rs `checked` requires). Use as a context manager or start() / close()."""

    def __init__(self, path: Path):
        self.path = Path(path)
        self._lock = threading.Lock()
        self._lines: List[Any] = []
        self._server: Optional[_Server] = None
        self._thread: Optional[threading.Thread] = None

    def environment(self) -> Dict[str, str]:
        """The case daemon's environment entry for this mock."""
        return {TOOLS_SOCKET_ENV: str(self.path)}

    def record(self, line: Any) -> None:
        with self._lock:
            self._lines.append(line)

    @property
    def lines(self) -> List[Any]:
        """The tools lines the daemon sent, in order."""
        with self._lock:
            return list(self._lines)

    def start(self) -> "MockChief":
        if len(os.fsencode(self.path)) > 100:
            raise MockChiefError(f"{self.path}: a Unix socket path over 100 bytes does not fit sun_path")
        try:
            self._server = _Server(str(self.path), self)
        except OSError as error:
            raise MockChiefError(f"{self.path}: cannot serve the mock Chief: {error}") from None
        os.chmod(self.path, 0o600)
        self._thread = threading.Thread(target=self._server.serve_forever, name="mock-chief", daemon=True)
        self._thread.start()
        return self

    def close(self) -> None:
        if self._server is not None:
            self._server.shutdown()
            self._server.server_close()
            self._server = None
        if self._thread is not None:
            self._thread.join()
            self._thread = None
        try:
            self.path.unlink()
        except FileNotFoundError:
            pass

    def __enter__(self) -> "MockChief":
        return self.start()

    def __exit__(self, *_: object) -> None:
        self.close()


def ask(path: Path, line: Mapping[str, Any], timeout: float = 5.0) -> Dict[str, Any]:
    """One tools-socket exchange, as the daemon's chief_control.rs `ask` does it."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.settimeout(timeout)
        conn.connect(str(path))
        conn.sendall(json.dumps(line).encode() + b"\n")
        reply = conn.makefile("rb").readline(MAX_LINE_BYTES + 1)
    return json.loads(reply)


# ---------------------------------------------------------------------------------------------- the mock agent


class MockAgent:
    """What a driver runs for a case with `fixture.agent: mock` (case-v1): the mock brain on `<run_dir>/chief.sock`
    before the case daemon starts (its environment() goes into the daemon's), then the mock agent's Chief
    conversation once the daemon answers (ready()). `command(cmd, params)` is the driver's v1 command call; the
    conversation is a v1 command because no protocol/2 operation makes one (`cmux chief` sends the same).
    A case reads the conversation's id with a readOnly `conversation.list` step: it is the only conversation."""

    SOCKET_NAME = "chief.sock"

    def __init__(self, run_dir: Path):
        self.brain = MockChief(Path(run_dir) / self.SOCKET_NAME)

    def start(self) -> Dict[str, str]:
        self.brain.start()
        return self.brain.environment()

    def ready(self, command: Callable[[str, Mapping[str, Any]], Any]) -> None:
        command("conversation-create", CHIEF_CONVERSATION)

    def close(self) -> None:
        self.brain.close()


# ---------------------------------------------------------------------------------------------- live check


def live_check(binary: Path, blocking: Optional[str] = None) -> int:
    """The mock agent against a real cmux-tui, as a `fixture.agent: mock` case uses it: chief.engine.set and
    chief.stop succeed through the mock brain (and fail with no mock); the mock conversation is the only one
    conversation.list gives, and conversation.send, conversation.typing and chief.profile.adopt succeed on it.
    Linux or macOS; a debug or --features oracle build. `blocking` sets CMUX_DAEMON_BLOCKING (see main)."""
    wire = _sibling("capture_wire_fixtures")
    if str(SDK) not in sys.path:
        sys.path.insert(0, str(SDK))
    from cmux._protocol import ProtocolConnection
    from cmux.errors import ResourceError

    scope = {"machine": "current", "session": "current"}
    problems: List[str] = []

    def call(conn: Any, operation: str, params: Mapping[str, Any], key: Optional[str]) -> Any:
        try:
            return conn.request(operation, {**scope, **params}, idempotency_key=key)
        except ResourceError as error:
            return {"error": {"code": error.code, "details": error.details}}

    def expect_ok(label: str, reply: Any) -> Any:
        if not (isinstance(reply, dict) and {"value", "generation", "revision", "replayed"} <= set(reply)):
            problems.append(f"{label}: expected a mutation result, got {json.dumps(reply)[:300]}")
            return {}
        return reply["value"]

    for with_mock in (True, False):
        root = Path(tempfile.mkdtemp(prefix="o-mc-", dir="/tmp"))
        agent = MockAgent(root)
        daemon = wire.Daemon(binary.resolve(), root)
        if blocking:
            daemon.env["CMUX_DAEMON_BLOCKING"] = blocking
        conn = None
        try:
            if with_mock:
                daemon.env.update(agent.start())
            daemon.start()
            conn = ProtocolConnection(daemon.socket, 15.0)
            engine = call(conn, "chief.engine.set", {"model": "mock-2"}, "live.engine")
            stopped = call(conn, "chief.stop", {}, "live.stop")
            if not with_mock:
                for label, reply in (("engine.set", engine), ("stop", stopped)):
                    if (reply.get("error") or {}).get("code") != "operation.failed":
                        problems.append(f"no mock: {label} should be operation.failed, got {reply}")
                continue
            value = expect_ok("chief.engine.set", engine)
            if value.get("choice") != {"model": "mock-2"}:
                problems.append(f"chief.engine.set: the brain's choice is not the request's: {value}")
            if expect_ok("chief.stop", stopped).get("stopped") is not False:
                problems.append(f"chief.stop: the mock runs no turn, got {stopped}")
            want = [{"tool": "engine", "action": "set", "model": "mock-2"}, {"tool": "stop"}]
            if agent.brain.lines != want:
                problems.append(f"the mock got {agent.brain.lines}, not {want}")
            agent.ready(lambda cmd, params: daemon.run(
                "raw", "command", "--request-json", json.dumps({"cmd": cmd, **params})))
            listed = conn.request("conversation.list", scope)
            if not (isinstance(listed, list) and len(listed) == 1 and isinstance(listed[0].get("id"), str)):
                problems.append(f"conversation.list: expected the mock conversation only, got {json.dumps(listed)[:300]}")
                continue
            conversation = listed[0]["id"]
            expect_ok("conversation.send",
                      call(conn, "conversation.send", {"conversation": conversation, "text": "oracle"}, "live.send"))
            expect_ok("conversation.typing",
                      call(conn, "conversation.typing", {"conversation": conversation, "on": True}, "live.typing"))
            expect_ok("chief.profile.adopt", call(conn, "chief.profile.adopt", {"participant_id": ADOPTABLE}, "live.adopt"))
        finally:
            if conn is not None:
                conn.close()
            daemon.stop()
            agent.close()
            shutil.rmtree(root, ignore_errors=True)
    for problem in problems:
        print(f"live: {problem}", file=sys.stderr)
    print("live: ok" if not problems else f"live: {len(problems)} problem(s)")
    return 0 if not problems else 1


def _sibling(module: str) -> Any:
    if str(HERE) not in sys.path:
        sys.path.insert(0, str(HERE))
    return __import__(module)


# ---------------------------------------------------------------------------------------------- self test


class MockChiefSelfTest(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = Path(tempfile.mkdtemp(prefix="o-mc-", dir="/tmp"))
        self.addCleanup(shutil.rmtree, self.dir, True)

    def test_each_tool_line_gets_the_brains_answer_shape(self) -> None:
        self.assertEqual(answer({"tool": "engine", "action": "show"})["engine"], ENGINE)
        set_line = {"tool": "engine", "action": "set", "model": "m2", "reactions_can_wake": False}
        self.assertEqual(answer(set_line)["choice"], {"model": "m2", "reactions_can_wake": False})
        self.assertEqual(answer(set_line)["engine"]["model"], "m2")
        self.assertEqual(answer({"tool": "stop"}), {"stopped": False, "note": "no turn is running"})
        self.assertEqual(answer({"tool": "stop", "all": True})["stopped"], False)

    def test_an_unknown_line_gets_a_typed_brain_error(self) -> None:
        for line, code in (({"tool": "inspect"}, "unknown_tool"), ("stop", "bad_request"),
                           ({"tool": "engine", "action": "set", "x": 1}, "bad_request"),
                           ({"tool": "stop", "argv": ["sh"]}, "bad_request")):
            with self.subTest(line=line):
                self.assertEqual(answer(line)["error"]["code"], code)

    def test_the_socket_answers_one_line_and_records_it(self) -> None:
        with MockChief(self.dir / "tools.sock") as mock:
            self.assertEqual(mock.environment(), {TOOLS_SOCKET_ENV: str(self.dir / "tools.sock")})
            self.assertEqual(os.stat(mock.path).st_mode & 0o777, 0o600)
            self.assertEqual(ask(mock.path, {"tool": "stop"})["stopped"], False)
            self.assertEqual(ask(mock.path, {"tool": "engine", "action": "set", "effort": "high"})["choice"],
                             {"effort": "high"})
            self.assertEqual(mock.lines, [{"tool": "stop"}, {"tool": "engine", "action": "set", "effort": "high"}])
        self.assertFalse((self.dir / "tools.sock").exists(), "close removes the socket")

    def test_the_mock_agent_serves_the_brain_then_makes_its_conversation(self) -> None:
        sent: List[Any] = []
        agent = MockAgent(self.dir)
        try:
            env = agent.start()
            self.assertEqual(env, {TOOLS_SOCKET_ENV: str(self.dir / MockAgent.SOCKET_NAME)})
            self.assertEqual(ask(Path(env[TOOLS_SOCKET_ENV]), {"tool": "stop"})["stopped"], False)
            agent.ready(lambda cmd, params: sent.append((cmd, params)))
            self.assertEqual(sent, [("conversation-create", CHIEF_CONVERSATION)])
        finally:
            agent.close()
        self.assertFalse((self.dir / MockAgent.SOCKET_NAME).exists())

    def test_a_socket_path_over_sun_path_is_refused(self) -> None:
        with self.assertRaisesRegex(MockChiefError, "sun_path"):
            MockChief(self.dir / ("x" * 120)).start()

    def test_the_conversation_holds_no_credential_and_an_adoptable_agent(self) -> None:
        # server/conversations.rs CreateParams: no token or credential field.
        self.assertEqual(set(CHIEF_CONVERSATION), {"idempotency_key", "actor", "title", "participants"})
        for participant in CHIEF_CONVERSATION["participants"]:
            self.assertLessEqual(set(participant), {"id", "kind", "display_name", "agent_class", "acp_session"})
        kinds = {p["id"]: p["kind"] for p in CHIEF_CONVERSATION["participants"]}
        self.assertEqual(kinds, {"user_local": "human", "agent_mux": "agent", ADOPTABLE: "agent"})


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--selftest", action="store_true", help="run the offline self tests")
    sub = parser.add_subparsers(dest="command")
    live = sub.add_parser("live", help="the mock against a real debug cmux-tui")
    live.add_argument("--cmux", type=Path, required=True, help="a debug or --features oracle cmux-tui binary")
    # A debug daemon panics on two blocking calls every connection makes;
    # `--daemon-blocking record` records them instead until those land.
    live.add_argument("--daemon-blocking", choices=("record", "panic"), help="CMUX_DAEMON_BLOCKING for the daemon")
    args = parser.parse_args(argv)
    if args.selftest:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(MockChiefSelfTest)
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    try:
        if args.command == "live":
            return live_check(args.cmux, args.daemon_blocking)
    except MockChiefError as error:
        print(f"mock_chief.py: {error}", file=sys.stderr)
        return 1
    parser.print_usage(sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
