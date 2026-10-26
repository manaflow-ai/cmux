"""Tests for scripts/perf-lab/corpus/agent_replay.py and corpus/harnesses/replay.toml (task 114).

Run: python3 -m unittest scripts/perf-lab/tests/test_agent_replay.py
With ACPMUX_BIN set to an acpmux binary, one more test plays a transcript through a real acpmux daemon.
"""

import contextlib
import hashlib
import importlib.util
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import tomllib
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "corpus" / "agent_replay.py"
spec = importlib.util.spec_from_file_location("agent_replay_under_test", SCRIPT)
ar = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ar)

RECORDS = [
    {"t_ms": 0, "kind": "thought", "bytes": 40},
    {"t_ms": 20, "kind": "plan", "entries": 3, "done": 1},
    {"t_ms": 30, "kind": "tool_call", "tool": "t1", "tool_kind": "read", "status": "in_progress"},
    {"t_ms": 60, "kind": "tool_update", "tool": "t1", "status": "completed", "bytes": 100},
    {"t_ms": 80, "kind": "message", "bytes": 200, "shape": "prose"},
    {"t_ms": 100, "kind": "message", "bytes": 120, "shape": "code"},
    {"t_ms": 110, "kind": "message", "bytes": 90, "shape": "table"},
    {"t_ms": 150, "kind": "end", "stop": "end_turn"},
]


def transcript_bytes(records=RECORDS):
    rows = [{"schema": ar.TRANSCRIPT_SCHEMA}, *records]
    return "".join(json.dumps(row) + "\n" for row in rows).encode()


def store(directory, data):
    digest = hashlib.sha256(data).hexdigest()
    (Path(directory) / digest).write_bytes(data)
    return digest


def rpc(rid, method, params):
    return json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}) + "\n"


class Agent:
    """agent_replay.py serve as acpmux starts it: a child process on stdio."""

    def __init__(self, transcripts, log=None, speed="1"):
        env = dict(os.environ, **{ar.TRANSCRIPTS_ENV: str(transcripts), ar.SPEED_ENV: speed})
        if log:
            env[ar.LOG_ENV] = str(log)
        self.process = subprocess.Popen([sys.executable, "-I", str(SCRIPT), "serve"], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, env=env, text=True, bufsize=1)

    def send(self, line):
        self.process.stdin.write(line)
        self.process.stdin.flush()

    def read(self):
        line = self.process.stdout.readline()
        if not line:
            raise AssertionError("the agent closed stdout")
        return line

    def until(self, rid):
        """Every line up to and including the answer to `rid`, with each line's arrival time."""
        lines = []
        while True:
            line = self.read()
            lines.append((time.monotonic(), line))
            if json.loads(line).get("id") == rid:
                return lines

    def close(self):
        self.process.stdin.close()
        self.process.wait(10)
        self.process.stdout.close()


def run_once(transcripts, digest, log=None):
    """The raw ACP lines one agent writes for initialize, session/new and one replay prompt, and the
    prompt's send time."""
    agent = Agent(transcripts, log)
    try:
        agent.send(rpc(1, "initialize", {"protocolVersion": 1, "clientCapabilities": {}}))
        lines = [line for _, line in agent.until(1)]
        agent.send(rpc(2, "session/new", {"cwd": "/", "mcpServers": []}))
        lines += [line for _, line in agent.until(2)]
        sent = time.monotonic()
        agent.send(rpc(3, "session/prompt", {"sessionId": "replay-1",
                                             "prompt": [{"type": "text", "text": f"replay {digest}"}]}))
        timed = agent.until(3)
        return lines + [line for _, line in timed], sent, timed
    finally:
        agent.close()


class DigestTest(unittest.TestCase):
    """Acceptance: the same ACP frames in the same order on two runs."""

    def test_two_runs_write_the_same_frames_in_the_same_order(self):
        with tempfile.TemporaryDirectory() as folder:
            digest = store(folder, transcript_bytes())
            log = Path(folder) / "turns.ndjson"
            first, _, _ = run_once(folder, digest, log)
            second, _, _ = run_once(folder, digest, log)
            self.assertEqual(first, second)
            updates = [json.loads(line)["params"]["update"] for line in first
                       if json.loads(line).get("method") == "session/update"]
            expected, stop = ar.transcript_frames(ar.parse_transcript(transcript_bytes()))
            self.assertEqual(updates, [update for _, update in expected])
            self.assertEqual(json.loads(first[-1])["result"], {"stopReason": "end_turn"})
            turns = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertEqual(len(turns), 2)
            self.assertEqual(turns[0], turns[1])
            self.assertEqual(turns[0], {"transcript": digest, "frames": len(expected), "stop": stop,
                                        "digest": ar.frames_digest(updates, stop)})

    def test_the_turn_is_logged_before_its_stop_reason_goes_out(self):
        """A reader that opens the log when the prompt's answer arrives finds the turn's line."""

        class Out:
            def __init__(self, log):
                self.log, self.at_answer = log, None

            def write(self, text):
                if '"stopReason"' in text:
                    self.at_answer = self.log.read_text() if self.log.exists() else ""

            def flush(self):
                pass

        with tempfile.TemporaryDirectory() as folder:
            digest = store(folder, transcript_bytes())
            log = Path(folder) / "turns.ndjson"
            out = Out(log)
            agent = ar.ReplayAgent(out, {ar.TRANSCRIPTS_ENV: folder, ar.LOG_ENV: str(log), ar.SPEED_ENV: "1000"})
            agent.serve([rpc(1, "session/new", {"cwd": "/", "mcpServers": []}),
                         rpc(2, "session/prompt", {"sessionId": "replay-1",
                                                   "prompt": [{"type": "text", "text": f"replay {digest}"}]})])
            self.assertIsNotNone(out.at_answer)
            self.assertEqual([json.loads(line)["transcript"] for line in out.at_answer.splitlines()], [digest])

    def test_the_log_is_complete_when_the_answer_arrives(self):
        with tempfile.TemporaryDirectory() as folder:
            digest = store(folder, transcript_bytes())
            log = Path(folder) / "turns.ndjson"
            agent = Agent(folder, log)
            try:
                agent.send(rpc(1, "session/new", {"cwd": "/", "mcpServers": []}))
                agent.until(1)
                agent.send(rpc(2, "session/prompt", {"sessionId": "replay-1",
                                                     "prompt": [{"type": "text", "text": f"replay {digest}"}]}))
                agent.until(2)
                turns = [json.loads(line) for line in log.read_text().splitlines()]
                self.assertEqual([turn["transcript"] for turn in turns], [digest])
            finally:
                agent.close()

    def test_the_digest_leaves_out_session_and_request_ids(self):
        frames, stop = ar.transcript_frames(ar.parse_transcript(transcript_bytes()))
        updates = [update for _, update in frames]
        self.assertEqual(ar.frames_digest(updates, stop), ar.frames_digest(json.loads(json.dumps(updates)), stop))
        self.assertNotEqual(ar.frames_digest(updates, stop), ar.frames_digest(updates[1:], stop))
        self.assertNotEqual(ar.frames_digest(updates, stop), ar.frames_digest(updates, "cancelled"))
        self.assertNotEqual(ar.frames_digest(updates, stop), ar.frames_digest(list(reversed(updates)), stop))


class TimingTest(unittest.TestCase):
    def test_each_update_leaves_at_its_recorded_time(self):
        with tempfile.TemporaryDirectory() as folder:
            digest = store(folder, transcript_bytes())
            _, sent, timed = run_once(folder, digest)
            times = [record["t_ms"] for record in RECORDS if record["kind"] != "end"]
            arrivals = [(at - sent) * 1000 for at, line in timed if json.loads(line).get("method") == "session/update"]
            self.assertEqual(len(arrivals), len(times))
            for recorded, arrived in zip(times, arrivals):
                self.assertGreaterEqual(arrived, recorded - 1)  # never early (1 ms for the two clocks' reads)

    def test_speed_scales_the_waits(self):
        records = [{"t_ms": 2000, "kind": "message", "bytes": 10, "shape": "prose"},
                   {"t_ms": 2000, "kind": "end", "stop": "end_turn"}]
        with tempfile.TemporaryDirectory() as folder:
            digest = store(folder, transcript_bytes(records))
            agent = Agent(folder, speed="100")
            try:
                agent.send(rpc(1, "session/new", {"cwd": "/", "mcpServers": []}))
                agent.until(1)
                started = time.monotonic()
                agent.send(rpc(2, "session/prompt", {"sessionId": "replay-1",
                                                     "prompt": [{"type": "text", "text": f"replay {digest}"}]}))
                agent.until(2)
                self.assertLess(time.monotonic() - started, 1.5)
            finally:
                agent.close()


class CancelTest(unittest.TestCase):
    def test_a_cancel_ends_the_stream_at_once(self):
        records = [{"t_ms": 0, "kind": "message", "bytes": 10, "shape": "prose"},
                   {"t_ms": 30000, "kind": "message", "bytes": 10, "shape": "prose"},
                   {"t_ms": 30000, "kind": "end", "stop": "end_turn"}]
        with tempfile.TemporaryDirectory() as folder:
            digest = store(folder, transcript_bytes(records))
            agent = Agent(folder)
            try:
                agent.send(rpc(1, "session/new", {"cwd": "/", "mcpServers": []}))
                agent.until(1)
                agent.send(rpc(2, "session/prompt", {"sessionId": "replay-1",
                                                     "prompt": [{"type": "text", "text": f"replay {digest}"}]}))
                self.assertEqual(json.loads(agent.read())["method"], "session/update")
                started = time.monotonic()
                agent.send(json.dumps({"jsonrpc": "2.0", "method": "session/cancel",
                                       "params": {"sessionId": "replay-1"}}) + "\n")
                answer = json.loads(agent.until(2)[-1][1])
                self.assertEqual(answer["result"], {"stopReason": "cancelled"})
                self.assertLess(time.monotonic() - started, 5)
            finally:
                agent.close()

    def test_a_prompt_that_names_no_transcript_is_refused(self):
        with tempfile.TemporaryDirectory() as folder:
            missing = "ab" * 32
            store(folder, transcript_bytes())
            agent = Agent(folder)
            try:
                agent.send(rpc(1, "session/new", {"cwd": "/", "mcpServers": []}))
                agent.until(1)
                for rid, text in ((2, "hello"), (3, f"replay {missing}")):
                    agent.send(rpc(rid, "session/prompt", {"sessionId": "replay-1",
                                                           "prompt": [{"type": "text", "text": text}]}))
                    self.assertEqual(json.loads(agent.until(rid)[-1][1])["error"]["code"], -32602)
            finally:
                agent.close()

    def test_a_blob_that_does_not_match_its_name_is_refused(self):
        with tempfile.TemporaryDirectory() as folder:
            wrong = "cd" * 32
            (Path(folder) / wrong).write_bytes(transcript_bytes())
            with self.assertRaises(ar.TranscriptError):
                ar.read_transcript(Path(folder), wrong)


class TranscriptRulesTest(unittest.TestCase):
    def errors(self, records):
        return ar.transcript_errors([{"schema": ar.TRANSCRIPT_SCHEMA}, *records])

    def test_the_fixture_is_valid(self):
        self.assertEqual(self.errors(RECORDS), [])

    def test_text_fields_are_refused(self):
        bad = [{"t_ms": 0, "kind": "message", "bytes": 5, "shape": "prose", "text": "hello"}, RECORDS[-1]]
        self.assertTrue(any("no field text" in e for e in self.errors(bad)))
        bad = [{"t_ms": 0, "kind": "tool_call", "tool": "t1", "tool_kind": "execute", "status": "pending",
                "title": "rm -rf"}, RECORDS[-1]]
        self.assertTrue(any("no field title" in e for e in self.errors(bad)))

    def test_rules(self):
        end = {"t_ms": 10, "kind": "end", "stop": "end_turn"}
        cases = {
            "unknown kind": [{"t_ms": 0, "kind": "permission"}, end],
            "before the previous": [{"t_ms": 20, "kind": "thought", "bytes": 1},
                                    {"t_ms": 10, "kind": "thought", "bytes": 1}, {**end, "t_ms": 20}],
            "before its tool_call": [{"t_ms": 0, "kind": "tool_update", "tool": "t9", "status": "completed",
                                      "bytes": 0}, end],
            "announced twice": [{"t_ms": 0, "kind": "tool_call", "tool": "a", "tool_kind": "read", "status": "pending"},
                                {"t_ms": 0, "kind": "tool_call", "tool": "a", "tool_kind": "read", "status": "pending"},
                                end],
            "more than plan.entries": [{"t_ms": 0, "kind": "plan", "entries": 2, "done": 3}, end],
            "the last record is an end": [{"t_ms": 0, "kind": "thought", "bytes": 1}],
            "end is the last record": [end, {"t_ms": 10, "kind": "thought", "bytes": 1}],
            "message.bytes": [{"t_ms": 0, "kind": "message", "bytes": 0, "shape": "prose"}, end],
            "message.shape": [{"t_ms": 0, "kind": "message", "bytes": 3, "shape": "html"}, end],
            "t_ms is a non-negative integer": [{"t_ms": 1.5, "kind": "thought", "bytes": 1}, end],
        }
        for expected, records in cases.items():
            with self.subTest(expected):
                self.assertTrue(any(expected in e for e in self.errors(records)), self.errors(records))
        self.assertTrue(ar.transcript_errors([{"schema": "other"}, end]))
        with self.assertRaises(ar.TranscriptError):
            ar.parse_transcript(b"not json\n")

    def test_synthetic_text_has_the_recorded_size(self):
        for shape in ar.SHAPES:
            for size in (1, 7, 8, 9, 100, 4097):
                with self.subTest(shape=shape, size=size):
                    text = ar.synthetic_text(size, shape, 3)
                    self.assertEqual(len(text.encode()), size)
        self.assertNotEqual(ar.synthetic_text(50, "prose", 0), ar.synthetic_text(50, "prose", 1))
        self.assertTrue(ar.synthetic_text(40, "code", 0).startswith("```\n"))


class InstallTest(unittest.TestCase):
    def test_install_writes_a_schema_1_profile_and_makes_it_the_default(self):
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder) / "acpmux" / "builds" / "com.cmuxterm.app.debug.bench"
            home.mkdir(parents=True)
            (home / "config.json").write_text(json.dumps({"pool": {"idleMinutes": 5}}))
            log = Path(folder) / "log.ndjson"
            xdg = Path(folder) / "xdg"
            path = ar.install(home, xdg, Path(folder) / "tx", python="/usr/bin/python3", log=log)
            self.assertEqual(path, xdg / "cmux" / "harnesses" / "replay.toml")
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            profile = tomllib.loads(path.read_text())
            self.assertEqual(profile["schema"], 1)
            self.assertEqual(profile["id"], path.stem)
            self.assertEqual(profile["protocol"], "acp")
            self.assertEqual(profile["command"], "/usr/bin/python3")
            self.assertEqual(profile["args"], ["-I", str(SCRIPT), "serve"])
            self.assertEqual(profile["env"], {ar.TRANSCRIPTS_ENV: str(Path(folder) / "tx"), ar.LOG_ENV: str(log),
                                              ar.SPEED_ENV: "1.0"})
            self.assertNotIn("@", path.read_text().split("schema = 1", 1)[1])
            self.assertEqual(json.loads((home / "config.json").read_text()),
                             {"pool": {"idleMinutes": 5}, "defaultHarness": "replay"})

    def test_paths_with_quotes_stay_one_toml_string(self):
        with tempfile.TemporaryDirectory() as folder:
            odd = Path(folder) / 'a "quoted" \\ dir'
            path = ar.install(Path(folder) / "home", Path(folder) / "xdg", odd, python=sys.executable)
            self.assertEqual(tomllib.loads(path.read_text())["env"][ar.TRANSCRIPTS_ENV], str(odd))

    def test_the_bench_home_is_the_build_key_under_the_root(self):
        root = Path("/scratch/acpmux")
        self.assertEqual(ar.bench_acpmux_home(root, "com.cmuxterm.app.debug.bench-1"),
                         root / "builds" / "com.cmuxterm.app.debug.bench-1")
        self.assertEqual(ar.bench_acpmux_home(root, "com.cmuxterm.app.nightly"), root)
        for hashed in ("com.cmuxterm.app.debug.", "a b", "x--y", "-lead"):
            with self.subTest(hashed), self.assertRaises(ValueError):
                ar.bench_acpmux_home(root, hashed)

    def test_launch_env_narrows_the_launch_denial_to_the_replay_harness(self):
        env = ar.launch_env(Path("/scratch/acpmux"), Path("/scratch/xdg"))
        self.assertEqual(env["CMUX_NEXT_ACPMUX_ROOT"], "/scratch/acpmux")
        self.assertEqual(env["XDG_CONFIG_HOME"], "/scratch/xdg")
        self.assertEqual(env["ACPMUX_PROBE_HARNESSES"], "replay")
        self.assertEqual(env["ACPMUX_AGENT_LAUNCH"], "only:replay")
        self.assertIsNone(env["CMUX_NEXT_AGENT_PANE_MOCK"])


@unittest.skipUnless(os.environ.get("ACPMUX_BIN"), "ACPMUX_BIN names no acpmux binary")
class AcpmuxTest(unittest.TestCase):
    """The installed profile through a real acpmux daemon: the same frames on two sessions."""

    def call_session(self, sock, digest):
        with socket.socket(socket.AF_UNIX) as conn:
            conn.settimeout(30)
            conn.connect(sock)
            reader = conn.makefile("r")
            conn.sendall(rpc(1, "initialize", {"protocolVersion": 1, "clientCapabilities": {}}).encode())
            conn.sendall(rpc(2, "session/new", {"cwd": "/tmp", "mcpServers": [],
                                                "_meta": {"acpmux": {"harness": "replay"}}}).encode())
            session, updates = None, []
            for line in reader:
                message = json.loads(line)
                if message.get("id") == 2:
                    self.assertNotIn("error", message, message)
                    session = message["result"]["sessionId"]
                    conn.sendall(rpc(3, "session/prompt", {"sessionId": session, "prompt": [
                        {"type": "text", "text": f"replay {digest}"}]}).encode())
                elif message.get("method") == "session/update" and message["params"].get("sessionId") == session:
                    update = message["params"]["update"]
                    if update.get("sessionUpdate") in ("agent_message_chunk", "agent_thought_chunk", "tool_call",
                                                       "tool_call_update", "plan"):
                        updates.append(update)
                elif message.get("id") == 3:
                    self.assertNotIn("error", message, message)
                    return updates, message["result"]["stopReason"]
        self.fail("acpmux closed the connection")

    def ask(self, sock, method, params):
        """One request on its own connection; the whole response."""
        with socket.socket(socket.AF_UNIX) as conn:
            conn.settimeout(60)
            conn.connect(sock)
            conn.sendall(rpc(1, method, params).encode())
            for line in conn.makefile("r"):
                message = json.loads(line)
                if message.get("id") == 1:
                    return message
        self.fail("acpmux closed the connection")

    @contextlib.contextmanager
    def bench_daemon(self):
        """acpmux with the bench's environment (bench_env's ACPMUX_AGENT_LAUNCH=deny, then launch_env), the replay
        profile installed, and a decoy harness beside it that leaves a marker file if it ever starts."""
        with tempfile.TemporaryDirectory(dir="/tmp") as folder:
            root = Path(folder)
            transcripts = root / "tx"
            transcripts.mkdir()
            home, xdg = root / "home", root / "xdg"
            profile = ar.install(home, xdg, transcripts, log=root / "turns.ndjson")
            marker = root / "decoy-started"
            script = 'echo started >>"$0"; exec "$1" -I "$2" serve'
            args = json.dumps(["-c", script, str(marker), sys.executable, str(SCRIPT)])  # JSON strings are TOML strings
            decoy = f'schema = 1\nid = "decoy"\nprotocol = "acp"\ncommand = "/bin/sh"\nargs = {args}\n'
            (profile.parent / "decoy.toml").write_text(decoy)
            (profile.parent / "decoy.toml").chmod(0o600)  # acpmux skips a profile another user may change
            sock = str(root / "a.sock")
            env = dict(os.environ, ACPMUX_HOME=str(home), ACPMUX_SOCKET=sock, HOME=str(root),
                       ACPMUX_AGENT_LAUNCH="deny")
            for key, value in ar.launch_env(root / "acpmux", xdg).items():
                if value is None:
                    env.pop(key, None)
                else:
                    env[key] = value
            log = open(root / "daemon.log", "wb")
            daemon = subprocess.Popen([os.environ["ACPMUX_BIN"], "daemon", "run"], env=env, stdout=log,
                                      stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 30
                while not os.path.exists(sock):  # test: waiting for the daemon to listen
                    self.assertIsNone(daemon.poll(), (root / "daemon.log").read_text())
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(0.05)
                yield root, transcripts, sock, marker
            finally:
                daemon.terminate()
                daemon.wait(10)
                log.close()

    def test_two_sessions_through_acpmux_stream_the_same_frames(self):
        with self.bench_daemon() as (root, transcripts, sock, marker):
            digest = store(transcripts, transcript_bytes())
            first = self.call_session(sock, digest)
            second = self.call_session(sock, digest)
            expected, stop = ar.transcript_frames(ar.parse_transcript(transcript_bytes()))
            self.assertEqual(first, second)
            self.assertEqual(first, ([update for _, update in expected], stop))
            turns = [json.loads(line) for line in (root / "turns.ndjson").read_text().splitlines()]
            self.assertEqual([t["digest"] for t in turns], [ar.frames_digest(first[0], stop)] * 2)
            self.assertFalse(marker.exists())

    def test_a_harness_other_than_replay_never_starts(self):
        with self.bench_daemon() as (root, _, sock, marker):
            self.assertEqual(self.ask(sock, "_acpmux/status", {})["result"]["agentLaunch"], "only")
            for harness in ("decoy", "claude", "codex"):
                with self.subTest(harness):
                    reply = self.ask(sock, "session/new", {"cwd": "/tmp", "mcpServers": [],
                                                           "_meta": {"acpmux": {"harness": harness}}})
                    self.assertIn("error", reply, reply)
            reply = self.ask(sock, "session/new", {"cwd": "/tmp", "mcpServers": [],
                                                   "_meta": {"acpmux": {"harness": "decoy"}}})
            self.assertEqual(reply["error"].get("data", {}).get("reason"), "agent_launch_disabled", reply)
            prewarm = self.ask(sock, "_acpmux/prewarm", {"harness": "decoy", "cwd": str(root), "wait": True})
            self.assertFalse(prewarm["result"]["accepted"], prewarm)
            self.ask(sock, "_acpmux/models", {"refresh": True})
            self.assertFalse(marker.exists(), "the decoy harness started")

if __name__ == "__main__":
    unittest.main()
