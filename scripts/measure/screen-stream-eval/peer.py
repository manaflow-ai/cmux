#!/usr/bin/env python3
"""The screen stream eval across two Macs on one LAN: the host Mac runs the harness as always (scene,
marker, host, OCR, results) and hands each viewer verb to a viewer Mac, which runs it there.

  peer.py serve BIND PORT TOKEN_FILE DIR      host Mac: the control server, in the background
  peer.py call DIR TARGET VERB ARG...         host Mac: run one viewer verb on the viewer Mac
  peer.py done DIR                            host Mac: tell the viewer Mac the run is over
  peer.py agent HOST PORT TOKEN_FILE ROOT     viewer Mac: run what the host Mac hands over

Two fleet steps, one per Mac, started together (README.md, "Two Macs"), share a run token: every
request carries it, and the agent runs only the fixed viewer verbs (latency-view INPUT SAMPLES,
window-view SECONDS) of a target script in its own checkout, against the host address it was given
itself. The token, the rd stream token and the WebRTC pairing link cross the LAN in plain HTTP; a
measure Mac's LAN is the trust boundary, as its console is (README.md, "Trust").

Clocks: the two Macs' clocks share no epoch (CLOCK_MONOTONIC) and only roughly agree (wall). Before
and after each verb the agent takes the offset (host minus viewer) of both clocks from the round
trip with the least delay of 16, and returns their mean with the change between the two as a bound.
The host Mac's report verbs read them as EVAL_PEER_MONO_OFFSET_MS and EVAL_PEER_WALL_OFFSET_MS.
"""

from __future__ import annotations

import base64
import hmac
import http.server
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

POLL_S = 20  # how long one /next request waits for a command
CALL_WAIT_S = 900  # how long a call waits for its result (a window verb runs about 90 s)
AGENT_WAIT_S = 1800  # how long the agent waits for the host Mac to come up or say something
VERBS = {"latency-view": re.compile(r"^(key|pointer) [0-9]{1,5}$"), "window-view": re.compile(r"^[0-9]{1,4}$")}
TARGET = re.compile(r"^[a-z0-9_-]{1,32}$")


def read_token(path: str) -> str:
    token = Path(path).read_text().strip()
    if not re.fullmatch(r"[0-9a-f]{64}", token):
        sys.exit("peer.py: the run token is 64 hex characters")
    return token


def clocks() -> dict:
    return {"mono_ns": time.clock_gettime_ns(time.CLOCK_MONOTONIC), "wall_ns": time.time_ns()}


# ---- host Mac ----


def serve(bind: str, port: int, token: str, folder: Path) -> None:
    folder.mkdir(parents=True, exist_ok=True)

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):  # the step log stays the harness's
            pass

        def reply(self, code: int, body: dict | None = None) -> None:
            data = json.dumps(body or {}).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def authorized(self) -> bool:
            if hmac.compare_digest(self.headers.get("X-Eval-Token", ""), token):
                return True
            self.reply(403)
            return False

        def do_GET(self):
            if not self.authorized():
                return
            if self.path == "/clock":
                return self.reply(200, clocks())
            if self.path == "/next":
                deadline = time.monotonic() + POLL_S
                while time.monotonic() < deadline:
                    for cmd in sorted(folder.glob("cmd-*.json"), key=lambda p: int(p.stem[4:])):
                        handed = cmd.with_suffix(".handed")
                        if not handed.exists():
                            handed.touch()
                            return self.reply(200, json.loads(cmd.read_text()))
                    time.sleep(0.1)  # bounded by POLL_S: the agent asks again
                return self.reply(204)
            self.reply(404)

        def do_POST(self):
            if not self.authorized():
                return
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
            m = re.fullmatch(r"/(go|result|hello)/([0-9]+)", self.path)
            if not m:
                return self.reply(404)
            kind, n = m.group(1), m.group(2)
            if kind == "hello":
                (folder / "agent.json").write_text(json.dumps(body))
            elif kind == "go":
                cmd = json.loads((folder / f"cmd-{n}.json").read_text())
                if cmd.get("go_file"):
                    Path(cmd["go_file"]).touch()
            else:
                tmp = folder / f"result-{n}.json.tmp"
                tmp.write_text(json.dumps(body))
                tmp.rename(folder / f"result-{n}.json")
            self.reply(200)

    http.server.ThreadingHTTPServer((bind, port), Handler).serve_forever()


def call(folder: Path, target: str, verb: str, args: list[str]) -> int:
    """Hands VERB to the viewer Mac and waits. The last argument of a view verb is the RAW path on this
    Mac; window-view's SNAPSHOT and GO are paths on this Mac too (GO is created when the viewer's
    first frame shows there). Files come back next to RAW: RAW, RAW.span, RAW.clock and SNAPSHOT."""
    env = {k: os.environ[k] for k in ("CMUX_VNC_STREAM_LINK",) if os.environ.get(k)}
    files = {}
    for name, var in (("marker.log", "EVAL_MARKER_LOG"), ("token", "EVAL_PEER_STREAM_TOKEN")):
        if os.environ.get(var) and Path(os.environ[var]).is_file():
            files[name] = base64.b64encode(Path(os.environ[var]).read_bytes()).decode()
    if verb == "latency-view":
        input_, samples, raw = args
        cmd_args, outputs, go = [input_, samples], {"raw": raw}, None
    elif verb == "window-view":
        seconds, snapshot, go, raw = args
        cmd_args, outputs = [seconds], {"raw": raw, "snapshot": snapshot}
    else:
        sys.exit(f"peer.py call: {verb} is not a viewer verb")
    n = len(list(folder.glob("cmd-*.json"))) + 1
    cmd = {"id": n, "target": target, "verb": verb, "args": cmd_args, "env": env, "files": files, "go_file": go}
    (folder / f"cmd-{n}.json").write_text(json.dumps(cmd))
    result = folder / f"result-{n}.json"
    deadline = time.monotonic() + CALL_WAIT_S
    while not result.exists():
        if time.monotonic() > deadline:
            print(f"peer.py: the viewer Mac did not answer {verb} within {CALL_WAIT_S} s", file=sys.stderr)
            return 1
        time.sleep(0.2)  # bounded by CALL_WAIT_S
    body = json.loads(result.read_text())
    for key, path in outputs.items():
        if key in body.get("files", {}):
            Path(path).write_bytes(base64.b64decode(body["files"][key]))
    if "clock" in body:
        Path(f"{outputs['raw']}.clock").write_text(json.dumps(body["clock"]))
    if "span" in body:  # on this Mac's wall clock, as the host's own logs are
        wall = (body.get("clock") or {}).get("wall_ms", 0)
        span = {k: round(v + wall) for k, v in body["span"].items()}
        Path(f"{outputs['raw']}.span").write_text(json.dumps(span))
    sys.stderr.write(body.get("stderr", ""))
    return int(body.get("exit", 1))


def done(folder: Path) -> None:
    n = len(list(folder.glob("cmd-*.json"))) + 1
    (folder / f"cmd-{n}.json").write_text(json.dumps({"id": n, "verb": "done"}))


# ---- viewer Mac ----


def agent(host: str, port: int, token: str, root: Path) -> int:
    base = f"http://{host}:{port}"

    def request(path: str, body: dict | None = None, timeout: float = POLL_S + 10):
        req = urllib.request.Request(base + path, data=None if body is None else json.dumps(body).encode(),
                                     headers={"X-Eval-Token": token, "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as response:
            text = response.read()
            return response.status, (json.loads(text) if text else None)

    def offsets() -> dict:
        best = None
        for _ in range(16):
            t0 = clocks()
            _, there = request("/clock", timeout=5)
            t1 = clocks()
            rtt = t1["mono_ns"] - t0["mono_ns"]
            if best is None or rtt < best[0]:
                best = (rtt, {k: there[k] - (t0[k] + t1[k]) / 2 for k in ("mono_ns", "wall_ns")})
        return {"rtt_ms": best[0] / 1e6, "mono_ms": best[1]["mono_ns"] / 1e6, "wall_ms": best[1]["wall_ns"] / 1e6}

    state = root / ".build" / "screen-stream-eval" / "peer"
    state.mkdir(parents=True, exist_ok=True)
    os.chmod(state, 0o700)
    deadline = time.monotonic() + AGENT_WAIT_S
    while True:  # the host Mac's step may start later than this one
        try:
            first = offsets()
            break
        except OSError:
            if time.monotonic() > deadline:
                print(f"peer.py agent: no host Mac at {base} within {AGENT_WAIT_S} s", file=sys.stderr)
                return 1
            time.sleep(5)  # bounded by AGENT_WAIT_S
    request("/hello/0", {"host": os.uname().nodename, **first})
    print(f"peer.py agent: connected to {base} (rtt {first['rtt_ms']:.2f} ms)", flush=True)
    idle_until = time.monotonic() + AGENT_WAIT_S
    while True:
        try:
            status, cmd = request("/next")
        except OSError:
            status, cmd = 0, None
            time.sleep(2)  # the host Mac is busy or gone; bounded by idle_until
        if status != 200:
            if time.monotonic() > idle_until:
                print("peer.py agent: the host Mac said nothing for too long", file=sys.stderr)
                return 1
            continue
        idle_until = time.monotonic() + AGENT_WAIT_S
        if cmd.get("verb") == "done":
            print("peer.py agent: done", flush=True)
            return 0
        target, verb, args = cmd.get("target", ""), cmd.get("verb", ""), cmd.get("args") or []
        if not TARGET.match(target) or verb not in VERBS or not VERBS[verb].match(" ".join(map(str, args))):
            request(f"/result/{cmd['id']}", {"exit": 2, "stderr": f"peer.py agent: refused {verb} {args}\n"})
            continue
        work = state / target
        work.mkdir(parents=True, exist_ok=True)
        for name, data in (cmd.get("files") or {}).items():
            if name in ("marker.log", "token"):
                (work / name).write_bytes(base64.b64decode(data))
        raw, snapshot, go = work / f"{verb}.raw", work / "snapshot", work / "go"
        for path in (raw, snapshot, go):
            path.unlink(missing_ok=True)
        argv = ["bash", str(root / "scripts/measure/screen-stream-eval/targets" / f"{target}.sh"), verb, *args]
        argv += [str(raw)] if verb == "latency-view" else [str(snapshot), str(go), str(raw)]
        env = {**os.environ, "EVAL_ROOT": str(root), "EVAL_BIN": str(root / ".build/screen-stream-eval/bin"),
               "EVAL_STATE": str(work), "EVAL_PEER": host, "EVAL_MARKER_LOG": str(work / "marker.log"),
               **{k: v for k, v in (cmd.get("env") or {}).items() if k == "CMUX_VNC_STREAM_LINK"}}
        before = offsets()
        start = time.time_ns()
        proc = subprocess.Popen(argv, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        relayed = False
        while proc.poll() is None:
            if not relayed and go.exists():  # the viewer's first frame: the host Mac's scene starts
                request(f"/go/{cmd['id']}", {})
                relayed = True
            time.sleep(0.05)  # follows the view verb, which ends on its own
        if not relayed and go.exists():
            request(f"/go/{cmd['id']}", {})
        after = offsets()
        files = {k: base64.b64encode(p.read_bytes()).decode() for k, p in (("raw", raw), ("snapshot", snapshot)) if p.is_file()}
        clock = {k: (before[k] + after[k]) / 2 for k in ("mono_ms", "wall_ms")}
        clock.update({"rtt_ms": min(before["rtt_ms"], after["rtt_ms"]),
                      "mono_drift_ms": after["mono_ms"] - before["mono_ms"], "wall_drift_ms": after["wall_ms"] - before["wall_ms"]})
        request(f"/result/{cmd['id']}", {"exit": proc.returncode, "stderr": proc.stderr.read()[-4000:], "files": files,
                                         "span": {"start_unix_ms": start // 1_000_000, "end_unix_ms": time.time_ns() // 1_000_000},
                                         "clock": clock}, timeout=60)


def main(argv: list[str]) -> int:
    if len(argv) == 5 and argv[0] == "serve":
        serve(argv[1], int(argv[2]), read_token(argv[3]), Path(argv[4]))
        return 0
    if len(argv) >= 4 and argv[0] == "call":
        return call(Path(argv[1]), argv[2], argv[3], argv[4:])
    if len(argv) == 2 and argv[0] == "done":
        done(Path(argv[1]))
        return 0
    if len(argv) == 5 and argv[0] == "agent":
        return agent(argv[1], int(argv[2]), read_token(argv[3]), Path(argv[4]))
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
