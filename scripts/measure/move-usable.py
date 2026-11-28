#!/usr/bin/env python3
"""move-usable: time-to-usable vs time-to-complete of `acpmux transfer SESSION --to SOCKET`.

README
------
Measures a chat move at three link rates (lan = unthrottled, 1MBps, 96KBps) in two modes:
  before: ACPMUX_MOVE_HISTORY_LATER unset: the whole history is pre-copied before the chat runs.
  after:  ACPMUX_MOVE_HISTORY_LATER=4: the chat runs on the target at once, history follows.

Two acpmux daemons start in their own homes (tmp dirs) with the fake harness
(crates/acpmux/tests/fake_agent.py), as tests/transfer_cli.rs does. The source chat is filled with
turns whose text is distinct slices of this repo's Rust source (--text code, the default: it
packs like a real chat log; --text hex is random hex, which does not) until the log
holds about --size-mb. A unix-socket proxy with a token bucket per direction sits in front of the
target's socket; its path is passed as --to. The CLI's own stderr is timestamped line by line.

  usable_ms   move start -> a probe prompt sent to the TARGET daemon's own socket (a client on the
              target machine, not through the throttled link) is answered with end_turn. The probe
              is sent the moment stderr prints "frozen ... carried": that line is printed right after
              the target's finish and the source's commit, so it is the earliest moment the chat
              is live on the target. Polling the listing instead would add poll latency and cannot
              tell "listed" from "answers"; a real prompt is what a user does.
  complete_ms move start -> the CLI exits (after it printed "history arrived" in after-mode).
  carried     bytes in the freeze (frozen line); history_sent / raw: the "history arrived" line.

Usage: move-usable.py --bin PATH/acpmux [--size-mb 20] [--reps 3] [--rates lan,1MBps,96KBps]
       [--modes before,after] [--out /tmp/move-usable-results.jsonl]
Results are appended as JSON lines; a markdown table of medians is printed at the end.
"""
import argparse, asyncio, json, os, re, secrets, shutil, socket, statistics, subprocess
import sys, tempfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
FAKE = os.path.join(HERE, "..", "..", "cmux-tui", "crates", "acpmux", "tests", "fake_agent.py")
RATES = {"lan": None, "1MBps": 1_000_000, "96KBps": 96_000}


os.umask(0o077)  # the daemon refuses group-writable state ancestors


def rpc_session(path):
    s = socket.socket(socket.AF_UNIX)
    s.connect(path)
    f = s.makefile("rw", buffering=1)
    n = [0]

    def call(method, params, timeout=600):
        n[0] += 1
        s.settimeout(timeout)
        f.write(json.dumps({"jsonrpc": "2.0", "id": n[0], "method": method, "params": params}) + "\n")
        while True:
            line = f.readline()
            if not line:
                raise RuntimeError("socket closed")
            v = json.loads(line)
            if v.get("id") == n[0]:
                if "error" in v:
                    raise RuntimeError(f"{method}: {v['error']}")
                return v["result"]

    call("initialize", {"protocolVersion": 1, "clientInfo": {"name": "move-usable"}})
    return call, s


def env_for(home, sock, extra=None):
    e = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": os.path.join(home, "home"),
         "TMPDIR": home, "ACPMUX_HOME": home, "ACPMUX_SOCKET": sock, "ACPMUX_AGENT_HOSTS": "0",
         "ACPMUX_LOGIN_ENV": "0", "ACPMUX_SESSION_CPU_CLASS": "normal"}
    e.update(extra or {})
    return e


def start_daemon(binary, tag, root):
    home = os.path.join(root, tag)
    os.makedirs(os.path.join(home, "home"))
    sock = os.path.join(home, "s.sock")
    cfg = {"harnesses": {"fake": {"argv": ["python3", os.path.realpath(FAKE)], "env": {}}},
           "defaultHarness": "fake", "permissionPolicy": "approve-all"}
    with open(os.path.join(home, "config.json"), "w") as f:
        json.dump(cfg, f)
    p = subprocess.Popen([binary, "daemon", "run", "--log", "warn"], env=env_for(home, sock),
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=open(os.path.join(home, "daemon.err"), "w"))
    deadline = time.time() + 30
    while time.time() < deadline:
        try:
            call, s = rpc_session(sock)
            s.close()
            return p, home, sock
        except Exception:
            time.sleep(0.1)
    raise RuntimeError(f"daemon {tag} did not start")


class Proxy(threading.Thread):
    """Unix-socket proxy, one token bucket per direction (shared by all connections)."""

    def __init__(self, listen, target, rate):
        super().__init__(daemon=True)
        self.listen, self.target, self.rate = listen, target, rate
        self.ready = threading.Event()
        self.loop = asyncio.new_event_loop()
        self.bytes = [0, 0]

    def run(self):
        asyncio.set_event_loop(self.loop)
        self.loop.run_until_complete(self.serve())

    async def serve(self):
        self.next_free = [0.0, 0.0]
        srv = await asyncio.start_unix_server(self.handle, self.listen)
        self.ready.set()
        async with srv:
            await srv.serve_forever()

    async def pump(self, r, w, d):
        try:
            while True:
                data = await r.read(16384)
                if not data:
                    break
                if self.rate:
                    now = self.loop.time()
                    start = max(now, self.next_free[d])
                    self.next_free[d] = start + len(data) / self.rate
                    if start > now:
                        await asyncio.sleep(start - now)
                self.bytes[d] += len(data)
                w.write(data)
                await w.drain()
        except (ConnectionError, OSError):
            pass
        finally:
            try:
                w.close()
            except Exception:
                pass

    async def handle(self, cr, cw):
        try:
            tr, tw = await asyncio.open_unix_connection(self.target)
        except OSError:
            cw.close()
            return
        await asyncio.gather(self.pump(cr, tw, 0), self.pump(tr, cw, 1))


def corpus_text(per):
    """Turn texts that compress like a real chat: distinct slices of this repo's own Rust source
    (code and tool output is what a chat log mostly holds). Random hex does not: it cannot pack
    below 50%, and its exact echo is caught by a 4 MB zstd page but not by the session pack, whose
    columns order remainders by kind; that made history-later look 2x heavier on the wire than it
    is (on real logs the pack is 1.3-1.8x smaller than the pages; see the PR)."""
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "cmux-tui", "crates")
    files = sorted(os.path.join(d, f) for d, _, fs in os.walk(root) for f in fs if f.endswith(".rs"))
    blob = b"".join(open(f, "rb").read() for f in files).decode("utf-8", "replace")
    at = 0
    while True:
        if at + per > len(blob):
            at = 0
        yield blob[at:at + per]
        at += per


def fill(sock, home, size_mb, text_kind):
    cwd = os.path.join(home, "project")
    os.makedirs(cwd)
    call, s = rpc_session(sock)
    sid = call("session/new", {"cwd": cwd, "mcpServers": []})["sessionId"]
    per = 128 * 1024  # chars per turn; the echo doubles it in the log
    turns = max(2, int(size_mb * 1e6 / (2 * per)))
    texts = corpus_text(per) if text_kind == "code" else None
    for i in range(turns):
        text = next(texts) if texts else secrets.token_hex(per // 2)
        call("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": text}],
                                "_meta": {"acpmux": {"promptId": f"p-{i}"}}})
    call("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": "last"}],
                            "_meta": {"acpmux": {"promptId": "p-last"}}})
    s.close()
    return sid, turns


def one_run(binary, rate_name, mode, size_mb, text_kind="code"):
    root = tempfile.mkdtemp(prefix="mu-", dir="/tmp")
    procs = []
    try:
        tp, thome, tsock = start_daemon(binary, "t", root)
        sp, shome, ssock = start_daemon(binary, "s", root)
        procs = [tp, sp]
        sid, turns = fill(ssock, shome, size_mb, text_kind)
        proxy_sock = os.path.join(root, "p.sock")
        proxy = Proxy(proxy_sock, tsock, RATES[rate_name])
        proxy.start()
        proxy.ready.wait()
        env = env_for(shome, ssock)
        if mode == "after":
            env["ACPMUX_MOVE_HISTORY_LATER"] = "4"
        os.makedirs(os.path.join(thome, "arrived"), exist_ok=True)
        t0 = time.monotonic()
        cli = subprocess.Popen([binary, "transfer", sid, "--to", proxy_sock, "--cwd",
                                os.path.join(thome, "arrived")],
                               env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        res = {"rate": rate_name, "mode": mode, "size_mb_asked": size_mb, "turns": turns, "text": text_kind}
        lines = []
        probe = {}

        def probe_run():
            try:
                call, s = rpc_session(tsock)
                call("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": "probe"}],
                                        "_meta": {"acpmux": {"promptId": "probe"}}}, timeout=900)
                probe["usable_ms"] = (time.monotonic() - t0) * 1000
            except Exception as e:
                probe["error"] = str(e)

        pt = None
        for line in cli.stderr:
            t = (time.monotonic() - t0) * 1000
            lines.append((round(t), line.rstrip()))
            m = re.search(r"frozen (\d+) ms, (\d+) bytes carried", line)
            if m and pt is None:
                res["frozen_ms"], res["carried_bytes"] = int(m[1]), int(m[2])
                res["frozen_line_ms"] = round(t)
                pt = threading.Thread(target=probe_run)
                pt.start()
            m = re.search(r"history arrived: (\d+) records.*?(\d+) bytes sent for (\d+) of log", line)
            if m:
                res["history_arrived_ms"] = round(t)
                res["history_sent_bytes"], res["history_raw_bytes"] = int(m[2]), int(m[3])
        cli.wait()
        res["complete_ms"] = round((time.monotonic() - t0) * 1000)
        res["exit"] = cli.returncode
        if pt:
            pt.join(timeout=900)
        res.update({k: round(v) if isinstance(v, float) else v for k, v in probe.items()})
        res["link_bytes_to_target"], res["link_bytes_from_target"] = proxy.bytes
        res["stderr"] = [l for _, l in lines][-12:]
        return res
    finally:
        for p in procs:
            p.kill()
            p.wait()
        shutil.rmtree(root, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", required=True)
    ap.add_argument("--size-mb", type=float, default=20)
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--rates", default="lan,1MBps,96KBps")
    ap.add_argument("--modes", default="before,after")
    ap.add_argument("--out", default="/tmp/move-usable-results.jsonl")
    ap.add_argument("--text", choices=["code", "hex"], default="code",
                    help="turn text: slices of this repo's Rust source (like a real chat) or random hex")
    a = ap.parse_args()
    rows = []
    for rep in range(a.reps):
        for rate in a.rates.split(","):
            for mode in a.modes.split(","):
                r = one_run(a.bin, rate, mode, a.size_mb, a.text)
                r["rep"] = rep
                rows.append(r)
                with open(a.out, "a") as f:
                    f.write(json.dumps(r) + "\n")
                print(rate, mode, rep, {k: r.get(k) for k in
                      ("usable_ms", "complete_ms", "carried_bytes", "history_sent_bytes", "exit", "error")},
                      flush=True)
    print("\n| rate | mode | usable_ms | complete_ms | carried B | history sent B | n |\n|---|---|---|---|---|---|---|")
    for rate in a.rates.split(","):
        for mode in a.modes.split(","):
            g = [r for r in rows if r["rate"] == rate and r["mode"] == mode]
            med = lambda k: (statistics.median([r[k] for r in g if k in r]) if any(k in r for r in g) else "-")
            print(f"| {rate} | {mode} | {med('usable_ms')} | {med('complete_ms')} | {med('carried_bytes')} | {med('history_sent_bytes')} | {len(g)} |")


if __name__ == "__main__":
    sys.exit(main())
