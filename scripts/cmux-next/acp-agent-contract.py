#!/usr/bin/env python3
"""ACP contract cells for the agents a Cloud chat runs: the agent's own CLI, no account needed.

The Cloud chat matrix (cloud-chat-matrix.ts) proves a cell on a real Cloud machine. This proves the
part under it with no Cloud and no login: the agent's CLI in ACP mode on this host, started the way
acpmux starts it on a Cloud machine (cmux-tui/crates/acpmux/src/config/discover.rs): initialize,
session/new, a first prompt and a follow-up, then a NEW process that resumes with session/load and
prompts again, each leg timed. A cell with no login checks the protocol up to the documented
sign-in refusal (`auth_required`, -32000), which is what a signed-out Cloud machine answers before
its sign-in card. A cell whose program or credential is missing here is `skipped` with the reason.

  python3 scripts/cmux-next/acp-agent-contract.py --list
  python3 scripts/cmux-next/acp-agent-contract.py --cells opencode-zen,gemini-signed-out --out /tmp/c

Exit 0 when no selected cell failed, 1 when one did, 2 on bad arguments. --out DIR gets
matrix.json and summary.md.
"""

from __future__ import annotations

import argparse
import json
import os
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Optional

PROMPT_FIRST = "Reply with exactly the word: pong"
PROMPT_FOLLOW = "Reply with exactly the word you replied with last time, and nothing else."
PROMPT_RESUME = "Reply with exactly the word: resumed"


@dataclass(frozen=True)
class Cell:
    id: str
    lane: str
    agent: str  # the `cmux chat --agent` name (acpmux harness id)
    login: str  # how it signs in: "none", "api-key:ENV", "oauth", "subscription"
    # contract mode: the ACP argv acpmux runs (discover.rs), and what the cell expects
    argv: tuple[str, ...] = ()
    expect: str = "reply"  # "reply" (a model answers) or "auth_required" (signed out, by design)
    model: Optional[str] = None  # session/set_model or the CLI's model flag, when the cell pins one
    env_needed: tuple[str, ...] = ()  # env keys the cell needs; missing ones skip it
    env: tuple[tuple[str, str], ...] = ()
    note: str = ""


CELLS: list[Cell] = [
    # cloud-grok-gemini-opencode
    Cell(
        "opencode-zen", "cloud-grok-gemini-opencode", "opencode", "none",
        argv=("opencode", "acp"), expect="reply",
        note="OpenCode with no login: its free OpenCode Zen models",
    ),
    Cell(
        "gemini-signed-out", "cloud-grok-gemini-opencode", "gemini", "none",
        argv=("gemini", "--experimental-acp"), expect="auth_required",
        note="Gemini CLI with no Google login and no key: the ACP sign-in refusal the card answers",
    ),
    Cell(
        "gemini-api-key", "cloud-grok-gemini-opencode", "gemini", "api-key:GEMINI_API_KEY",
        argv=("gemini", "--experimental-acp"), expect="reply", env_needed=("GEMINI_API_KEY",),
        note="Gemini CLI with a Gemini API key (AI Studio free tier works)",
    ),
    Cell(
        "gemini-google-login", "cloud-grok-gemini-opencode", "gemini", "oauth",
        argv=("gemini", "--experimental-acp"), expect="reply", env_needed=("CMUX_MATRIX_GEMINI_HOME",),
        env=(("GEMINI_CLI_HOME", "${CMUX_MATRIX_GEMINI_HOME}"),),
        note="Gemini CLI signed in with a Google account (free or AI Pro): a home holding .gemini/oauth_creds.json",
    ),
    # No Grok (SuperGrok, xAI key) or third-party provider-key cells: Leo has none of those accounts (Leo,
    # 2026-11-10: "I only have ChatGPT and Google ... Or else I ask the company to get me basic accounts later").
]


# ---------------------------------------------------------------- ACP client


class AcpError(Exception):
    def __init__(self, code: Any, message: str, data: Any = None):
        super().__init__(f"{code}: {message}")
        self.code, self.message, self.data = code, message, data

    def auth_required(self) -> bool:
        text = f"{self.message} {json.dumps(self.data) if self.data is not None else ''}".lower()
        return self.code == -32000 or "auth" in text or "login" in text or "sign in" in text or "api key" in text


class Acp:
    """One ACP agent over stdio: JSON-RPC 2.0, one JSON object per line."""

    def __init__(self, argv: list[str], cwd: str, env: dict[str, str]):
        self.proc = subprocess.Popen(
            argv, cwd=cwd, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, bufsize=1,
        )
        self.next_id = 0
        self.replies: "queue.Queue[dict]" = queue.Queue()
        self.text: list[str] = []
        self.stderr: list[str] = []
        threading.Thread(target=self._read, daemon=True).start()
        threading.Thread(target=self._read_err, daemon=True).start()

    def _read_err(self) -> None:
        assert self.proc.stderr
        for line in self.proc.stderr:
            if len(self.stderr) < 400:
                self.stderr.append(line.rstrip())

    def _send(self, msg: dict) -> None:
        assert self.proc.stdin
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()

    def _read(self) -> None:
        assert self.proc.stdout
        for line in self.proc.stdout:
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if "method" in msg and "id" in msg:
                self._answer(msg)
            elif "method" in msg:
                self._notify(msg)
            else:
                self.replies.put(msg)
        self.replies.put({"eof": True})

    def _notify(self, msg: dict) -> None:
        if msg.get("method") != "session/update":
            return
        update = (msg.get("params") or {}).get("update") or {}
        if update.get("sessionUpdate") == "agent_message_chunk":
            content = update.get("content") or {}
            if content.get("type") == "text":
                self.text.append(content.get("text", ""))

    def _answer(self, msg: dict) -> None:
        method = msg.get("method")
        if method == "session/request_permission":
            options = (msg.get("params") or {}).get("options") or []
            allow = next((o for o in options if str(o.get("kind", "")).startswith("allow")), None)
            outcome = {"outcome": "selected", "optionId": allow["optionId"]} if allow else {"outcome": "cancelled"}
            self._send({"jsonrpc": "2.0", "id": msg["id"], "result": {"outcome": outcome}})
        else:
            self._send({"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32601, "message": f"{method} not offered"}})

    def call(self, method: str, params: dict, timeout: float) -> dict:
        self.next_id += 1
        want = self.next_id
        self._send({"jsonrpc": "2.0", "id": want, "method": method, "params": params})
        deadline = time.monotonic() + timeout
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                raise TimeoutError(f"{method}: no answer in {timeout:.0f}s")
            try:
                msg = self.replies.get(timeout=left)
            except queue.Empty:
                continue
            if msg.get("eof"):
                tail = " | ".join(self.stderr[-5:])
                raise AcpError("eof", f"{method}: the agent exited ({self.proc.poll()}): {tail}")
            if msg.get("id") != want:
                continue
            if "error" in msg:
                err = msg["error"] or {}
                raise AcpError(err.get("code"), str(err.get("message", "")), err.get("data"))
            return msg.get("result") or {}

    def close(self) -> None:
        try:
            if self.proc.stdin:
                self.proc.stdin.close()
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()
            self.proc.wait()


def expand(value: str) -> str:
    return os.path.expandvars(value)


# What a cell inherits from this shell: the program path and locale only. Every login, key and config
# home stays out, so a signed-out cell is signed out and a no-login cell cannot pass on a host login.
INHERITED = ("PATH", "LANG", "LC_ALL", "TERM", "TMPDIR", "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS")


def cell_env(cell: Cell, home: str) -> dict[str, str]:
    env = {k: os.environ[k] for k in INHERITED if k in os.environ}
    env.update({
        "HOME": home,
        "XDG_CONFIG_HOME": os.path.join(home, ".config"),
        "XDG_DATA_HOME": os.path.join(home, ".local/share"),
        "XDG_CACHE_HOME": os.path.join(home, ".cache"),
        "XDG_STATE_HOME": os.path.join(home, ".local/state"),
        "NO_BROWSER": "true",
        "BROWSER": "true",
    })
    # Only the login this cell asks for: its env_needed keys, and its own env (a login home).
    env.update({k: os.environ[k] for k in cell.env_needed if k in os.environ and not k.startswith("CMUX_MATRIX_")})
    env.update({k: expand(v) for k, v in cell.env})
    return env


def contract_cell(cell: Cell, turn_timeout: float) -> list[dict]:
    rows: list[dict] = []
    program = shutil.which(cell.argv[0])
    if not program:
        return [row(cell, "first", "skipped", 0, reason=f"{cell.argv[0]} is not on PATH")]
    missing = [k for k in cell.env_needed if not os.environ.get(k)]
    if missing:
        return [row(cell, "first", "skipped", 0, reason=f"needs {', '.join(missing)}")]
    work = tempfile.mkdtemp(prefix=f"matrix-{cell.id}-")
    env = cell_env(cell, work)
    argv = [program, *cell.argv[1:]]
    started = time.monotonic()
    acp = Acp(argv, work, env)
    session = None
    try:
        init = acp.call("initialize", {
            "protocolVersion": 1,
            "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False}, "terminal": False},
        }, 60)
        caps = init.get("agentCapabilities") or {}
        auth_methods = [m.get("id") for m in init.get("authMethods") or []]
        rows.append(row(cell, "initialize", "pass", ms(started), protocol=init.get("protocolVersion"),
                        load_session=bool(caps.get("loadSession")), auth_methods=auth_methods))
        t = time.monotonic()
        try:
            new = acp.call("session/new", {"cwd": work, "mcpServers": []}, 60)
            session = new.get("sessionId")
        except AcpError as e:
            if cell.expect == "auth_required" and e.auth_required():
                rows.append(row(cell, "first", "pass", ms(t), reply=f"auth_required ({e.code})", auth_methods=auth_methods))
                return rows
            raise
        if not session:
            raise AcpError("shape", "session/new answered no sessionId")
        for leg, prompt in (("first", PROMPT_FIRST), ("follow-up", PROMPT_FOLLOW)):
            t = time.monotonic()
            try:
                reply = prompt_turn(acp, session, prompt, turn_timeout)
            except AcpError as e:
                if cell.expect == "auth_required" and e.auth_required():
                    rows.append(row(cell, leg, "pass", ms(t), reply=f"auth_required ({e.code})", auth_methods=auth_methods))
                    return rows
                raise
            ok = cell.expect == "reply" and bool(reply.strip())
            rows.append(row(cell, leg, "pass" if ok else "fail", ms(t), reply=reply[:200]))
            if not ok:
                return rows
        acp.close()
        # Resume: a new process loads the chat, as acpmux does after a restart or a machine resume.
        t = time.monotonic()
        if not caps.get("loadSession"):
            rows.append(row(cell, "resume", "fail", 0, reason="the agent does not offer session/load"))
            return rows
        acp = Acp(argv, work, env)
        acp.call("initialize", {"protocolVersion": 1, "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False}, "terminal": False}}, 60)
        acp.call("session/load", {"sessionId": session, "cwd": work, "mcpServers": []}, 120)
        acp.text.clear()
        reply = prompt_turn(acp, session, PROMPT_RESUME, turn_timeout)
        rows.append(row(cell, "resume", "pass" if reply.strip() else "fail", ms(t), reply=reply[:200]))
        return rows
    except (AcpError, TimeoutError) as e:
        leg = "first" if len(rows) <= 1 else ("follow-up" if len(rows) == 2 else "resume")
        rows.append(row(cell, leg, "fail", ms(started), reason=str(e)[:400]))
        return rows
    finally:
        acp.close()
        shutil.rmtree(work, ignore_errors=True)


def prompt_turn(acp: Acp, session: str, text: str, timeout: float) -> str:
    acp.text.clear()
    result = acp.call("session/prompt", {"sessionId": session, "prompt": [{"type": "text", "text": text}]}, timeout)
    if result.get("stopReason") not in (None, "end_turn", "max_tokens", "max_turn_requests"):
        raise AcpError("stop", f"stopReason {result.get('stopReason')}")
    return "".join(acp.text)


# ---------------------------------------------------------------- output


def ms(start: float) -> float:
    return round((time.monotonic() - start) * 1000)


def row(cell: Cell, leg: str, status: str, took_ms: float, **extra: Any) -> dict:
    return {"cell": cell.id, "lane": cell.lane, "agent": cell.agent, "login": cell.login, "leg": leg,
            "status": status, "ms": took_ms, **{k: v for k, v in extra.items() if v is not None}}


def summary(rows: list[dict], mode: str) -> str:
    lines = [f"# ACP agent contract ({mode})", "", "| Cell | Agent | Login | Leg | Status | ms | Reply or reason |",
             "| --- | --- | --- | --- | --- | --- | --- |"]
    for r in rows:
        said = r.get("reply") or r.get("reason") or ""
        said = str(said).replace("|", "/").replace("\n", " ")[:120]
        lines.append(f"| {r['cell']} | {r['agent']} | {r['login']} | {r['leg']} | {r['status']} | {r['ms']} | {said} |")
    return "\n".join(lines) + "\n"


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--cells", help="comma-separated cell ids (default: all)")
    ap.add_argument("--lane", help="only this lane's cells")
    ap.add_argument("--turn-timeout", type=float, default=300)
    ap.add_argument("--out", help="write matrix.json and summary.md here")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args(argv)
    cells = CELLS
    if args.cells:
        want = set(args.cells.split(","))
        unknown = want - {c.id for c in CELLS}
        if unknown:
            print(f"unknown cells: {', '.join(sorted(unknown))}", file=sys.stderr)
            return 2
        cells = [c for c in CELLS if c.id in want]
    if args.lane:
        cells = [c for c in cells if c.lane == args.lane]
    if args.list:
        for c in cells:
            print(f"{c.id:24} {c.lane:28} {c.agent:9} {c.login:28} {c.note}")
        return 0
    rows: list[dict] = []
    for cell in cells:
        got = contract_cell(cell, args.turn_timeout)
        for r in got:
            r["mode"] = "contract"
            print(json.dumps(r), flush=True)
        rows.extend(got)
    text = summary(rows, "contract")
    if args.out:
        out = Path(args.out)
        out.mkdir(parents=True, exist_ok=True)
        (out / "matrix.json").write_text(json.dumps(rows, indent=2) + "\n")
        (out / "summary.md").write_text(text)
    print(text)
    return 1 if any(r["status"] == "fail" for r in rows) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
