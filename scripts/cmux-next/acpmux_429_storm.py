#!/usr/bin/env python3
"""A 429 storm on a real coordinator chat, driven through a built acpmux.

Leo, 2026-11-19: "I hope we aren't getting the fucking 429s anymore in our fucking app ... the GUI ones
kept like getting busted". cmuxterm-hq docs/handbook/rate-limit-spiral-resends-the-context.md names the
class; cmux-tui/crates/acpmux/tests/hub_integration/auto_resume_429_storm.rs is its in-process test with a
fake ACP agent. This harness runs the same storm end to end, on a published or built acpmux binary (a
NIGHTLY's own acpmux: `--acpmux`), with a real Claude Code chat:

- a local fake Anthropic Messages endpoint is the chat's ANTHROPIC_BASE_URL. It answers every request
  429 ("This request would exceed your account's rate limit") for `--storm` seconds, with or without a
  Retry-After header (`--retry-after`), then answers like a coordinator: an inbox notice gets a Bash
  call that reads every thread it names (`acpmux session inbox ... --mark-read`), anything else one
  short text reply that names the report markers it was given;
- an isolated acpmux daemon (its own HOME, ACPMUX_HOME and socket; nothing touches this host's daemon)
  runs the coordinator chat `coord` on the `claude` harness. Its first turn starts into the storm;
- `--agents` senders (other agents: `acpmux send --from lane-K --no-wait --class question`) each send it
  one report every `--interval` seconds for the whole storm;
- one attached client follows the chat the way the app does (`acpmux session tail -f`): it must stay
  attached and keep receiving events.

It then waits for the chat to settle and counts, from the endpoint's own request log and the daemon's
event journal: messages sent, messages that reached the model (given to it, in a prompt or an inbox
read, by a request it answered), lost, duplicated (given to the model as new input by two answered
requests, or twice in the conversation it last saw), model requests (and bytes, each a full-context resend)
during the storm, the time from the lift to the first completed turn, and whether the attached client
stayed attached. One JSON result and one markdown table row per run go to `--out`.

Run two builds with the same parameters and put the rows side by side:

    scripts/cmux-next/acpmux_429_storm.py --acpmux /path/to/nightly/acpmux --label nightly --out /tmp/storm/nightly
    scripts/cmux-next/acpmux_429_storm.py --acpmux /path/to/pr/acpmux --label pr --out /tmp/storm/pr
    scripts/cmux-next/acpmux_429_storm.py --table /tmp/storm/nightly /tmp/storm/pr

The storm injection alone, for another test's chats (a relay drop loop, a GUI driver): it prints the
ANTHROPIC_BASE_URL and key to start them with, answers 429 while the storm file exists, and logs each
request (time, model, bytes, status, the STORM-K-I markers it carried) to LOG:

    scripts/cmux-next/acpmux_429_storm.py --endpoint-only /tmp/storm/endpoint.ndjson \\
        --storm-file /tmp/storm/on --retry-after none     # touch /tmp/storm/on: storm; rm it: lifted

Needs: python3, a `claude` CLI on PATH (Claude Code; no login: the fake endpoint takes any key).
"""

from __future__ import annotations

import argparse
import http.server
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

MARK = re.compile(r"\bSTORM-(\d+)-(\d+)\b")
RATE_LIMIT_MESSAGE = (
    "This request would exceed your account's rate limit. Please try again later."
)


class Endpoint:
    """The fake model. Every request is one log line: time, path, model, bytes, status, markers."""

    def __init__(self, log: Path, retry_after: int | None):
        self.log = log
        self.retry_after = retry_after
        self.storm_until = float("inf")
        self.lock = threading.Lock()
        self.requests: list[dict] = []

        # With a storm file, the storm is on exactly while the file exists (`--endpoint-only`).
        self.storm_file: Path | None = None

    def lift_at(self, when: float) -> None:
        self.storm_until = when

    def storming(self, now: float) -> bool:
        if self.storm_file is not None:
            return self.storm_file.exists()
        return now < self.storm_until

    def record(self, row: dict) -> None:
        with self.lock:
            self.requests.append(row)
            with self.log.open("a", encoding="utf-8") as f:
                f.write(json.dumps(row) + "\n")


INBOX_NOTICE = "[inbox] New messages"
THREAD = re.compile(r"\(thread ([^)\s]+)\)")


def blocks(msg: dict) -> list[dict]:
    content = msg.get("content")
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    return [c for c in content or [] if isinstance(c, dict)]


def block_text(b: dict) -> str:
    if b.get("type") == "text":
        return b.get("text", "")
    if b.get("type") == "tool_result":
        c = b.get("content")
        if isinstance(c, str):
            return c
        return "\n".join(x.get("text", "") for x in c or [] if isinstance(x, dict))
    return ""


def given_markers(msg: dict) -> list[str]:
    """The markers a user message gives the model: its texts and tool results (an inbox read), not the
    inbox notice, which only previews each thread's newest message and points at the read."""
    out = []
    for b in blocks(msg):
        t = block_text(b)
        if b.get("type") == "text" and t.lstrip().startswith(INBOX_NOTICE):
            continue
        out += [m.group(0) for m in MARK.finditer(t)]
    return out


def last_user(body: dict) -> dict:
    for msg in reversed(body.get("messages") or []):
        if msg.get("role") == "user":
            return msg
    return {}


def last_user_markers(body: dict) -> list[str]:
    """The markers the request's last user message gives the model: this request's new input."""
    return given_markers(last_user(body))


def all_markers(body: dict) -> list[str]:
    """Every marker every user message of the request gave the model, with repeats: a repeat is a message
    the chat was given twice."""
    return [m for msg in body.get("messages") or [] if msg.get("role") == "user" for m in given_markers(msg)]


def inbox_threads(body: dict) -> list[str]:
    """The threads an inbox notice in the last user message names, when that message holds no tool result
    yet: the model then reads them, as a coordinator does."""
    msg = last_user(body)
    if any(b.get("type") == "tool_result" for b in blocks(msg)):
        return []
    threads = []
    for b in blocks(msg):
        t = block_text(b)
        if INBOX_NOTICE in t:
            threads += [x for x in THREAD.findall(t) if x not in threads]
    return threads


def make_handler(ep: Endpoint):
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *a):  # quiet
            pass

        def _read(self) -> bytes:
            n = int(self.headers.get("content-length") or 0)
            return self.rfile.read(n) if n else b""

        def _json(self, status: int, obj: dict, headers: dict | None = None) -> None:
            data = json.dumps(obj).encode()
            self.send_response(status)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(data)))
            for k, v in (headers or {}).items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            self._read()
            self._json(200, {"data": [], "has_more": False})

        def do_HEAD(self):
            self.send_response(200)
            self.send_header("content-length", "0")
            self.end_headers()

        def do_POST(self):
            raw = self._read()
            try:
                body = json.loads(raw or b"{}")
            except ValueError:
                body = {}
            now = time.time()
            path = self.path.split("?")[0]
            row = {
                "at": now, "path": path, "model": body.get("model"), "bytes": len(raw),
                "messages": len(body.get("messages") or []), "stream": bool(body.get("stream")),
                "new": last_user_markers(body), "all": all_markers(body),
            }
            if not path.endswith("/v1/messages"):
                row["status"] = 200
                ep.record(row)
                self._json(200, {"input_tokens": max(1, len(raw) // 4)})
                return
            if ep.storming(now):
                row["status"] = 429
                ep.record(row)
                headers = {"x-should-retry": "true"}
                if ep.retry_after is not None:
                    headers["retry-after"] = str(ep.retry_after)
                self._json(429, {"type": "error", "error": {"type": "rate_limit_error", "message": RATE_LIMIT_MESSAGE}},
                           headers)
                return
            row["status"] = 200
            threads = inbox_threads(body) if any(
                t.get("name") == "Bash" for t in body.get("tools") or [] if isinstance(t, dict)) else []
            row["inbox_read"] = threads
            ep.record(row)
            model = body.get("model") or "claude-fake"
            msg_id = f"msg_{int(now * 1000)}"
            usage_in = max(1, len(raw) // 4)
            if threads:
                # Read every thread the notice names, as a coordinator does, marking them read.
                command = "; ".join(f'acpmux session inbox "$ACPMUX_SESSION_ID" --thread {shlex.quote(t)} --mark-read'
                                    for t in threads)
                block = {"type": "tool_use", "id": f"toolu_{msg_id}", "name": "Bash",
                         "input": {"command": command, "description": "Read the inbox threads"}}
                stop = "tool_use"
            else:
                block = {"type": "text", "text": "ack " + (" ".join(row["new"]) if row["new"] else "ok")}
                stop = "end_turn"
            if not body.get("stream"):
                self._json(200, {
                    "id": msg_id, "type": "message", "role": "assistant", "model": model, "content": [block],
                    "stop_reason": stop, "stop_sequence": None,
                    "usage": {"input_tokens": usage_in, "output_tokens": 5},
                })
                return
            if block["type"] == "tool_use":
                start = {**block, "input": {}}
                delta = {"type": "input_json_delta", "partial_json": json.dumps(block["input"])}
            else:
                start = {"type": "text", "text": ""}
                delta = {"type": "text_delta", "text": block["text"]}
            events = [
                ("message_start", {"type": "message_start", "message": {
                    "id": msg_id, "type": "message", "role": "assistant", "model": model,
                    "content": [], "stop_reason": None, "stop_sequence": None,
                    "usage": {"input_tokens": usage_in, "output_tokens": 1}}}),
                ("content_block_start", {"type": "content_block_start", "index": 0, "content_block": start}),
                ("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": delta}),
                ("content_block_stop", {"type": "content_block_stop", "index": 0}),
                ("message_delta", {"type": "message_delta", "delta": {"stop_reason": stop, "stop_sequence": None},
                                   "usage": {"output_tokens": 5}}),
                ("message_stop", {"type": "message_stop"}),
            ]
            data = b"".join(f"event: {k}\ndata: {json.dumps(v)}\n\n".encode() for k, v in events)
            self.send_response(200)
            self.send_header("content-type", "text/event-stream")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    return Handler


def clean_env(out: Path, base_url: str, acpmux: str) -> dict:
    """An environment with nothing of this host's acpmux, Claude Code or session in it. The build under
    test is first on PATH, so the chat's own `acpmux` (its inbox reads) is that build too."""
    env = {k: os.environ[k] for k in ("PATH", "LANG", "LC_ALL", "TERM", "USER", "LOGNAME", "SHELL", "TZ") if k in os.environ}
    home = out / "home"
    env.update({
        "PATH": f"{Path(acpmux).parent}:{env.get('PATH', '/usr/bin:/bin')}",
        "HOME": str(home), "XDG_CONFIG_HOME": str(home / ".config"), "XDG_DATA_HOME": str(home / ".local/share"),
        "XDG_STATE_HOME": str(home / ".local/state"), "XDG_CACHE_HOME": str(home / ".cache"),
        "XDG_RUNTIME_DIR": str(out / "run"), "TMPDIR": str(out / "tmp"),
        "ACPMUX_HOME": str(out / "acpmux-home"), "ACPMUX_SOCKET": str(out / "run" / "acpmux.sock"),
        "ANTHROPIC_BASE_URL": base_url, "ANTHROPIC_API_KEY": "sk-ant-api03-storm-harness-fake",
        "DISABLE_AUTOUPDATER": "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_TELEMETRY": "1",
    })
    for d in ("home", "run", "tmp", "acpmux-home", "work"):
        (out / d).mkdir(parents=True, exist_ok=True)
    os.chmod(out / "run", 0o700)
    os.chmod(out / "acpmux-home", 0o700)
    # Claude Code would otherwise ask about the API key and the folder on its first start.
    (home / ".claude.json").write_text(json.dumps({
        "hasCompletedOnboarding": True, "bypassPermissionsModeAccepted": True,
        "customApiKeyResponses": {"approved": ["storm-harness-fake"[-20:]], "rejected": []},
        "projects": {str(out / "work"): {"hasTrustDialogAccepted": True}},
    }))
    return env


def run(cmd: list[str], env: dict, timeout: float = 60) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)


def journal(acpmux_home: Path) -> list[dict]:
    rows = []
    for f in sorted(acpmux_home.glob("sessions/*/events/*.ndjson")):
        sid = f.parent.parent.name
        for line in f.read_text(encoding="utf-8", errors="replace").splitlines():
            try:
                e = json.loads(line)
            except ValueError:
                continue
            e["_session"] = sid
            rows.append(e)
    return rows


def ev_kind(e: dict) -> str:
    return e.get("kind") or e.get("type") or ""


def ev_msg(e: dict) -> dict:
    m = e.get("msg")
    return m if isinstance(m, dict) else e


def ev_at(e: dict) -> float:
    at = e.get("at") or e.get("ts") or 0
    return at / 1000 if at > 1e11 else at


def turn_markers(events: list[dict], sid: str) -> tuple[dict, dict, list]:
    """(turnId -> markers given as user input in it, turnId -> status, [(at, turnId, status)])."""
    given: dict[str, list[str]] = {}
    status: dict[str, str] = {}
    results = []
    for e in events:
        if e["_session"] != sid:
            continue
        k, m = ev_kind(e), ev_msg(e)
        tid = str(m.get("turnId") or e.get("turnId") or "")
        if k == "user_message":
            given.setdefault(tid, []).extend(x.group(0) for x in MARK.finditer(json.dumps(m)))
        elif k == "turn_result":
            status[tid] = str(m.get("status"))
            results.append((ev_at(e), tid, str(m.get("status"))))
    return given, status, results


def main_run(a: argparse.Namespace) -> int:
    # The daemon refuses a state directory under a group- or world-writable folder.
    os.umask(0o022)
    out = Path(a.out).resolve()
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    log = lambda *x: print(f"[{time.strftime('%H:%M:%S')}] [{a.label}]", *x, flush=True)

    ep = Endpoint(out / "endpoint.ndjson", None if a.retry_after in (None, "none") else int(a.retry_after))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), make_handler(ep))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base_url = f"http://127.0.0.1:{server.server_address[1]}"
    acpmux = str(Path(a.acpmux).resolve())
    env = clean_env(out, base_url, acpmux)
    version = run([acpmux, "--version"], env).stdout.strip()
    log("acpmux", version, "endpoint", base_url)

    # The daemon, with a scaled hold when the build reads one (an older build ignores the key).
    r, w = os.pipe()
    daemon_log = (out / "daemon.log").open("w")
    daemon = subprocess.Popen([acpmux, "daemon", "run", "--ready-fd", str(w), "--log", a.log],
                              env=env, stdout=daemon_log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                              pass_fds=(w,), start_new_session=True)
    os.close(w)
    ready = os.fdopen(r).readline()
    log("daemon", ready.strip())
    procs: list[subprocess.Popen] = [daemon]
    if not ready.strip():
        log("the daemon did not start; see", out / "daemon.log")
        server.shutdown()
        return 2
    try:
        return storm(a, out, ep, env, acpmux, version, procs, log)
    finally:
        for p in reversed(procs):
            if p.poll() is None:
                try:
                    os.killpg(p.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
        for p in procs:
            try:
                p.wait(timeout=20)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid, signal.SIGKILL)
        server.shutdown()


def storm(a, out: Path, ep: Endpoint, env: dict, acpmux: str, version: str, procs: list, log) -> int:
    t0 = time.time()
    lift = t0 + a.storm
    ep.lift_at(lift)
    # The coordinator's own first turn starts into the storm.
    first = subprocess.Popen([acpmux, "new", "-n", "coord", "-m", a.harness, "--policy", "approve-all", "-d",
                              "--cwd", str(out / "work"), "plan the day"],
                             env=env, stdout=(out / "coord-new.log").open("w"), stderr=subprocess.STDOUT,
                             stdin=subprocess.DEVNULL, start_new_session=True)
    procs.append(first)
    sid = ""
    for _ in range(120):
        r = run([acpmux, "--json", "session", "info", "coord"], env, 20)
        if r.returncode == 0:
            try:
                info = json.loads(r.stdout)
                sid = info.get("id") or info.get("sessionId") or (info.get("session") or {}).get("id") or ""
            except ValueError:
                pass
            if sid:
                break
        time.sleep(0.5)
    log("coord session", sid or "(not found)")
    # The attached client: follows the chat's events the whole run, as the app's chat pane does.
    tail_out = (out / "attached-client.ndjson").open("w")
    tail = subprocess.Popen([acpmux, "session", "tail", "coord", "-f"], env=env, stdout=tail_out,
                            stderr=(out / "attached-client.err").open("w"), stdin=subprocess.DEVNULL,
                            start_new_session=True)
    procs.append(tail)

    sent: list[dict] = []
    sent_lock = threading.Lock()

    def sender(k: int) -> None:
        i = 0
        nxt = t0 + 1 + k * a.interval / a.agents
        while nxt < lift:
            time.sleep(max(0, nxt - time.time()))
            marker = f"STORM-{k}-{i}"
            text = f"{marker}: report {i} from lane-{k}"
            at = time.time()
            r = run([acpmux, "--json", "send", "coord", "--from", f"lane-{k}", "--no-wait", "--class", "question",
                     text], env, 60)
            with sent_lock:
                sent.append({"marker": marker, "at": at, "rc": r.returncode, "out": r.stdout.strip()[-300:],
                             "err": r.stderr.strip()[-300:]})
            i += 1
            nxt += a.interval

    threads = [threading.Thread(target=sender, args=(k,)) for k in range(a.agents)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    log(f"storm sends done: {len(sent)} sent, lift in {max(0, lift - time.time()):.0f} s")
    time.sleep(max(0, lift - time.time()))
    lifted = time.time()
    in_storm = [r for r in ep.requests if r["at"] < lifted and r["path"].endswith("/v1/messages")]
    log(f"limit lifted: {len(in_storm)} model requests in the storm")

    markers = [s["marker"] for s in sent]
    deadline = lifted + a.settle
    quiet_since = time.time()
    seen_n = -1
    while time.time() < deadline:
        if set(markers) <= received(list(ep.requests)):
            break
        n = len(ep.requests)
        if n != seen_n:
            seen_n, quiet_since = n, time.time()
        if time.time() - quiet_since > a.quiet and time.time() - lifted > a.quiet:
            log(f"no model request for {a.quiet} s; stopping the wait")
            break
        time.sleep(2)
    time.sleep(3)
    (out / "sent.json").write_text(json.dumps(sent, indent=1))
    meta = {"label": a.label, "acpmux": version, "harness": a.harness, "agents": a.agents, "interval_s": a.interval,
            "storm_s": a.storm, "retry_after": a.retry_after, "session": sid, "t0": t0, "lifted": lifted,
            "end": time.time(), "attached_client_alive": tail.poll() is None, "daemon_alive": procs[0].poll() is None}
    (out / "meta.json").write_text(json.dumps(meta, indent=1))
    res = tally(out)
    log(json.dumps({k: v for k, v in res.items() if not k.endswith("_gaps_s")}))
    return 0


def is_main(r: dict) -> bool:
    """A request on the chat's own model (a full-context turn), not one of Claude Code's small side
    requests (titles, summaries) on a haiku model."""
    return "haiku" not in str(r.get("model"))


def received(requests: list[dict]) -> set[str]:
    """The markers the chat's model was given and answered: new input of a request it answered 200."""
    return {m for r in requests if r["path"].endswith("/v1/messages") and r["status"] == 200 and is_main(r)
            for m in r["new"]}


def tally(out: Path) -> dict:
    """The counts, from the run's files alone: `--recount DIR` gives the same result again."""
    meta = json.loads((out / "meta.json").read_text())
    sid, lifted = meta["session"], meta["lifted"]
    sent = json.loads((out / "sent.json").read_text())
    requests = [json.loads(x) for x in (out / "endpoint.ndjson").read_text().splitlines() if x.strip()]
    model_requests = [r for r in requests if r["path"].endswith("/v1/messages")]
    in_storm = [r for r in model_requests if r["at"] < lifted]
    main_storm = [r for r in in_storm if is_main(r)]
    markers = [x["marker"] for x in sent]
    events = journal(out / "acpmux-home")
    given, status, results = turn_markers(events, sid)
    completed = [t for t, st in status.items() if st == "completed"]
    # Reached: the chat's model was given the message (in a prompt, or in the result of its inbox read)
    # and answered. A duplicate: given to the model as new input by two answered requests, or twice in
    # the conversation the model last saw. Given in two turns' prompts after a failed turn is the
    # retry doing its job; it is counted apart, from the journal.
    done = received(model_requests)
    in_any: dict[str, int] = {}
    for tid, ms in given.items():
        for m in set(ms):
            in_any[m] = in_any.get(m, 0) + 1
    ok = [r for r in model_requests if r["status"] == 200 and is_main(r)]
    ok_new: dict[str, int] = {}
    for r in ok:
        for m in set(r["new"]):
            ok_new[m] = ok_new.get(m, 0) + 1
    conv: dict[str, int] = {}
    for m in max(ok, key=lambda r: r["messages"], default={"all": []})["all"]:
        conv[m] = conv.get(m, 0) + 1
    dup = sorted({m for m in markers if ok_new.get(m, 0) > 1 or conv.get(m, 0) > 1})
    lost = sorted(m for m in markers if m not in done)
    refused = [x for x in sent if x["rc"] != 0]
    post = [at for at, _, st in results if st == "completed" and at >= lifted - 1]
    tail_lines = tail_after = 0
    for line in (out / "attached-client.ndjson").open(encoding="utf-8", errors="replace"):
        tail_lines += 1
        try:
            if ev_at(json.loads(line)) >= lifted:
                tail_after += 1
        except (ValueError, AttributeError, TypeError):
            pass
    gaps = lambda rs: [round(b["at"] - a_["at"], 1) for a_, b in zip(rs, rs[1:])][:60]
    res = {k: meta[k] for k in ("label", "acpmux", "harness", "agents", "interval_s", "storm_s", "retry_after",
                                "session")}
    res.update({
        "sent": len(sent), "send_refused": len(refused), "reached_model": len(done & set(markers)),
        "lost": len(lost), "duplicated": len(dup),
        "given_in_more_than_one_turn": sum(1 for m in markers if in_any.get(m, 0) > 1),
        "model_requests_in_storm": len(in_storm), "main_model_requests_in_storm": len(main_storm),
        "model_bytes_in_storm": sum(r["bytes"] for r in in_storm), "model_requests_total": len(model_requests),
        "turns_started": sum(1 for e in events if e["_session"] == sid and ev_kind(e) == "turn_started"),
        "turns_failed": sum(1 for st in status.values() if st != "completed"), "turns_completed": len(completed),
        "first_reply_after_lift_s": round(min(post) - lifted, 1) if post else None,
        "attached_client_alive": meta["attached_client_alive"], "attached_client_events": tail_lines,
        "attached_client_events_after_lift": tail_after, "daemon_alive": meta["daemon_alive"],
        "main_request_gaps_s": gaps(main_storm), "storm_request_gaps_s": gaps(in_storm),
        "lost_markers": lost[:20], "duplicated_markers": dup[:20], "refused_sends": refused[:5],
        "wall_s": round(meta["end"] - meta["t0"], 1),
    })
    (out / "result.json").write_text(json.dumps(res, indent=2))
    return res


COLUMNS = [
    ("acpmux", "build"), ("sent", "messages sent"), ("send_refused", "send refused"),
    ("reached_model", "reached the model (answered)"), ("lost", "lost"), ("duplicated", "duplicated"),
    ("model_requests_in_storm", "model requests in storm"), ("main_model_requests_in_storm", "of them full-context (main model)"),
    ("model_bytes_in_storm", "request bytes in storm"),
    ("turns_started", "turns started"), ("turns_failed", "turns failed"),
    ("given_in_more_than_one_turn", "messages given again after a failed turn"),
    ("first_reply_after_lift_s", "first reply after lift (s)"), ("attached_client_alive", "client stayed attached"),
    ("attached_client_events_after_lift", "client events after lift"), ("daemon_alive", "daemon alive"),
]


def main_table(dirs: list[str]) -> int:
    rows = [json.loads((Path(d) / "result.json").read_text()) for d in dirs]
    print("| | " + " | ".join(r["label"] for r in rows) + " |")
    print("| --- | " + " | ".join("---" for _ in rows) + " |")
    for key, name in COLUMNS:
        print(f"| {name} | " + " | ".join(str(r.get(key)) for r in rows) + " |")
    p = rows[0]
    print(f"\nParameters: {p['agents']} agents, one message each every {p['interval_s']} s, storm {p['storm_s']} s, "
          f"Retry-After {p['retry_after']}, harness {p['harness']}.")
    return 0


def main_endpoint(a: argparse.Namespace) -> int:
    """The storm injection alone: a fake Anthropic endpoint that another test points its chats at."""
    ep = Endpoint(Path(a.endpoint_only), None if a.retry_after in (None, "none") else int(a.retry_after))
    if a.storm_file:
        ep.storm_file = Path(a.storm_file)
    else:
        ep.lift_at(time.time() + a.storm)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", a.port), make_handler(ep))
    print(json.dumps({"ANTHROPIC_BASE_URL": f"http://127.0.0.1:{server.server_address[1]}",
                      "ANTHROPIC_API_KEY": "sk-ant-api03-storm-harness-fake", "log": a.endpoint_only}), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--acpmux", help="the acpmux binary to run")
    ap.add_argument("--label", default="run")
    ap.add_argument("--out", help="a new directory for this run's logs and result")
    ap.add_argument("--harness", default="claude")
    ap.add_argument("--agents", type=int, default=7)
    ap.add_argument("--interval", type=float, default=10, help="seconds between one agent's messages")
    ap.add_argument("--storm", type=float, default=240, help="seconds the endpoint answers 429")
    ap.add_argument("--retry-after", default="none", help="Retry-After seconds on each 429, or none")
    ap.add_argument("--settle", type=float, default=900, help="longest wait after the lift")
    ap.add_argument("--quiet", type=float, default=240, help="stop waiting after this long with no model request")
    ap.add_argument("--log", default="info", help="the daemon's log filter")
    ap.add_argument("--table", nargs="+", metavar="RUN_DIR", help="print the side-by-side table of finished runs")
    ap.add_argument("--recount", nargs="+", metavar="RUN_DIR", help="count finished runs again from their files")
    ap.add_argument("--endpoint-only", metavar="LOG", help="serve only the fake model endpoint, logging each request "
                    "to LOG, for another harness's chats (ANTHROPIC_BASE_URL); the storm follows --storm-file, else "
                    "--storm seconds from start")
    ap.add_argument("--storm-file", help="with --endpoint-only: answer 429 exactly while this file exists")
    ap.add_argument("--port", type=int, default=0, help="with --endpoint-only: the port (0 picks one)")
    a = ap.parse_args()
    if a.endpoint_only:
        return main_endpoint(a)
    if a.recount:
        for d in a.recount:
            print(json.dumps(tally(Path(d)), indent=2))
        return 0
    if a.table:
        return main_table(a.table)
    if not (a.acpmux and a.out):
        ap.error("--acpmux and --out are required for a run")
    return main_run(a)


if __name__ == "__main__":
    sys.exit(main())
