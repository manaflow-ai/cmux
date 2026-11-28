#!/usr/bin/env python3
"""CI skew matrix: CLI N against daemon N-1 and N+1 for every capability-gated
command (plans/cmux-next/version-skew.md step 5).

Usage: skew-matrix.py --old <cmux-tui> --new <cmux-tui> [--cases <json>] [--timeout <s>]

For (cli=new, daemon=old) and (cli=old, daemon=new), and for each case in
skew-matrix-cases.json, it starts an isolated daemon with the daemon binary
(temporary HOME, TMPDIR and CMUX_TUI_STATE_DIR, its own socket, as
check-daemon-capabilities.sh does), runs the case with the other binary as the
CLI (`--socket <that daemon> --json <argv>`), classifies the result, and stops
the daemon it started (`server stop --end-terminals`, then only the pid that
`server ensure` printed). It prints one table and exits 1 on any FAIL row.

A row passes when the command
  works     exit 0, or a domain answer the case lists in works_if;
  re-exec   the one stderr line of cli/skew.rs, naming the daemon's binary;
  fix       exactly one fix command of cli/fix_command.rs, for this CLI and
            this daemon socket.
Anything else is FAIL: a raw capability error, a timeout, or another error.

On Linux and for unbundled binaries (a cargo build, a copied binary) the CLI
never re-execs (plan "Known limits"): there a pass is works or fix. The re-exec
half runs only from a cmux .app bundle (step 6, live proof).

A CLI older than the skew code (version-skew steps 2-4) cannot print a fix
command or re-exec, so its rows show what that older CLI does today.
"""

import argparse
import json
import os
import pathlib
import re
import shutil
import socket as socketlib
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
DEFAULT_CASES = HERE / "skew-matrix-cases.json"

_QUOTED = r"'((?:[^']|'\\'')*)'"
FIX_RE = re.compile(
    _QUOTED + r" daemon stop --socket " + _QUOTED
    + r"(?: && " + _QUOTED + r" daemon ensure --socket " + _QUOTED + r")?"
)
REEXEC_RE = re.compile(
    r"^cmux: this CLI \(build [^)]*\) does not match the daemon \(build [^)]*\);"
    r" running the daemon's CLI (.+?)\s*$",
    re.MULTILINE,
)
RAW_CAPABILITY_RE = re.compile(
    r"capabilit|does not support|not supported|unsupported|method_not_found"
    r"|unknown (?:command|method)|update (?:the )?(?:cmux )?(?:app|daemon)|upgrade|を更新",
    re.IGNORECASE,
)


def _unquote(text):
    return text.replace("'\\''", "'")


def _strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from _strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from _strings(item)


def _texts(outcome):
    """The output as one text: raw stdout and stderr plus every string of
    each JSON line (a JSON error escapes its message)."""
    parts = [outcome.get("stdout") or "", outcome.get("stderr") or ""]
    for line in (outcome.get("stdout") or "").splitlines():
        line = line.strip()
        if line.startswith("{") or line.startswith("["):
            try:
                parts.extend(_strings(json.loads(line)))
            except ValueError:
                pass
    return "\n".join(parts)


def _same_path(a, b):
    if a is None or b is None:
        return False
    return a == b or os.path.realpath(a) == os.path.realpath(b)


def _first_line(text):
    for line in text.splitlines():
        if line.strip():
            return line.strip()[:160]
    return ""


def classify(case, outcome, *, cli, daemon_cli, socket):
    """(verdict, detail) for one run: verdict is works, re-exec, fix or FAIL.

    outcome: {exit, stdout, stderr, timed_out}. cli: the CLI under test;
    daemon_cli: the daemon's own binary (the only valid re-exec target);
    socket: the daemon socket the case used."""
    if outcome.get("timed_out"):
        return "FAIL", "timed out"
    stderr = outcome.get("stderr") or ""
    reexecs = REEXEC_RE.findall(stderr)
    if len(reexecs) > 1:
        return "FAIL", f"{len(reexecs)} re-exec lines (the loop guard must allow one)"
    if reexecs:
        target = reexecs[0]
        if daemon_cli is None or not _same_path(target, daemon_cli):
            return "FAIL", f"re-exec to {target}, not the daemon's CLI {daemon_cli}"
        return "re-exec", f"ran {target} (exit {outcome.get('exit')})"
    if outcome.get("exit") == 0:
        return "works", "exit 0"
    text = _texts(outcome)
    fixes = {match.group(0): match for match in FIX_RE.finditer(text)}
    if len(fixes) > 1:
        return "FAIL", f"{len(fixes)} fix commands (expected one): " + " | ".join(fixes)
    if fixes:
        command, match = next(iter(fixes.items()))
        clis = [_unquote(g) for g in (match.group(1), match.group(3)) if g is not None]
        sockets = [_unquote(g) for g in (match.group(2), match.group(4)) if g is not None]
        if all(_same_path(c, cli) for c in clis) and all(_same_path(s, socket) for s in sockets):
            return "fix", command
        return "FAIL", f"capability error with a fix command for another CLI or socket: {command}"
    if RAW_CAPABILITY_RE.search(text):
        return "FAIL", "raw capability error: " + _first_line(stderr or text)
    for pattern in case.get("works_if") or []:
        if re.search(pattern, text):
            return "works", f"exit {outcome.get('exit')}: " + _first_line(stderr or text)
    return "FAIL", f"other error (exit {outcome.get('exit')}): " + _first_line(stderr or text)


def load_cases(path):
    data = json.loads(pathlib.Path(path).read_text())
    cases = data.get("cases") or []
    seen = set()
    for case in cases:
        for key in ("id", "argv", "capability", "pass"):
            if not case.get(key):
                raise ValueError(f"{path}: case {case.get('id')!r} has no {key}")
        if case["id"] in seen:
            raise ValueError(f"{path}: case {case['id']!r} twice")
        seen.add(case["id"])
    skipped = data.get("skipped") or []
    for entry in skipped:
        if not entry.get("reason"):
            raise ValueError(f"{path}: skipped {entry.get('id')!r} has no reason")
    return cases, skipped


def render_table(rows):
    headers = ("direction", "case", "verdict", "detail")
    widths = [max(len(h), *(len(str(r[h])) for r in rows)) if rows else len(h) for h in headers[:3]]
    lines = ["  ".join(h.ljust(w) for h, w in zip(headers[:3], widths)) + "  detail"]
    for row in rows:
        lines.append(
            "  ".join(str(row[h]).ljust(w) for h, w in zip(headers[:3], widths)) + "  " + row["detail"]
        )
    return "\n".join(lines)


def exit_status(rows):
    return 1 if any(row["verdict"] == "FAIL" for row in rows) else 0


# --- daemons (not used by the classifier tests) ---


class Daemon:
    """One isolated daemon of `binary`; stop() ends only what start() made."""

    def __init__(self, binary, label):
        self.binary = binary
        # A short private root: the socket path must fit sun_path (104 bytes).
        self.root = os.path.realpath(tempfile.mkdtemp(prefix="skm.", dir="/tmp"))
        self.session = f"skm{os.getpid()}{label}"
        for sub in ("home", "state"):
            os.makedirs(os.path.join(self.root, sub), mode=0o700)
        self.socket = None
        self.pid = None
        self.identity = {}

    def env(self):
        return {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": os.path.join(self.root, "home"),
            "TMPDIR": self.root,
            "CMUX_TUI_STATE_DIR": os.path.join(self.root, "state"),
            "CMUX_TUI_CONFIG": os.path.join(self.root, "home", "no-config.toml"),
        }

    def start(self, timeout):
        done = subprocess.run(
            [self.binary, "--session", self.session, "--json", "server", "ensure"],
            env=self.env(), stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout,
        )
        lines = [l for l in done.stdout.splitlines() if l.strip().startswith("{")]
        if done.returncode != 0 or not lines:
            raise RuntimeError(f"{self.binary} server ensure failed ({done.returncode}): {done.stderr.strip()}")
        endpoint = json.loads(lines[-1])
        self.socket = endpoint.get("socket")
        self.pid = endpoint.get("pid")
        if not self.socket:
            raise RuntimeError(f"server ensure printed no socket: {lines[-1]}")
        self.identity = identify(self.socket)

    def _alive(self):
        if not isinstance(self.pid, int) or self.pid <= 1:
            return False
        try:
            os.kill(self.pid, 0)
        except OSError:
            return False
        exe = f"/proc/{self.pid}/exe"
        if os.path.exists(exe):
            try:
                return os.path.realpath(exe) == os.path.realpath(self.binary)
            except OSError:
                return False
        return True

    def stop(self):
        if self.socket:
            for flags in (["--end-terminals"], ["--force"]):
                if not self._alive():
                    break
                subprocess.run(
                    [self.binary, "--socket", self.socket, "--json", "server", "stop", *flags],
                    env=self.env(), stdin=subprocess.DEVNULL, capture_output=True, timeout=150,
                )
        if self._alive():
            os.kill(self.pid, 15)
        shutil.rmtree(self.root, ignore_errors=True)


def identify(path):
    sock = socketlib.socket(socketlib.AF_UNIX, socketlib.SOCK_STREAM)
    sock.settimeout(15)
    try:
        sock.connect(path)
        sock.sendall(b'{"id":"skm","cmd":"identify"}\n')
        buffer = b""
        while True:
            while b"\n" not in buffer:
                chunk = sock.recv(1 << 20)
                if not chunk:
                    return {}
                buffer += chunk
            line, buffer = buffer.split(b"\n", 1)
            message = json.loads(line)
            if message.get("id") == "skm":
                return message.get("data") or {}
    except (OSError, ValueError):
        return {}
    finally:
        sock.close()


def run_case(cli, daemon, case, timeout):
    argv = [cli, "--socket", daemon.socket, "--json", *case["argv"]]
    try:
        done = subprocess.run(
            argv, env=daemon.env(), stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout,
        )
        return {"exit": done.returncode, "stdout": done.stdout, "stderr": done.stderr, "timed_out": False}
    except subprocess.TimeoutExpired as expired:
        out = expired.stdout.decode() if isinstance(expired.stdout, bytes) else (expired.stdout or "")
        err = expired.stderr.decode() if isinstance(expired.stderr, bytes) else (expired.stderr or "")
        return {"exit": None, "stdout": out, "stderr": err, "timed_out": True}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--old", required=True, help="cmux-tui binary N-1")
    parser.add_argument("--new", required=True, help="cmux-tui binary N")
    parser.add_argument("--cases", default=str(DEFAULT_CASES))
    parser.add_argument("--timeout", type=int, default=30, help="seconds per command")
    args = parser.parse_args(argv)
    binaries = {"old": os.path.realpath(args.old), "new": os.path.realpath(args.new)}
    for name, path in binaries.items():
        if not os.access(path, os.X_OK):
            print(f"skew-matrix: --{name} {path} is not an executable cmux-tui", file=sys.stderr)
            return 2
    cases, skipped = load_cases(args.cases)
    gated = sorted({case["capability"] for case in cases})
    print(f"skew-matrix: {len(cases)} cases, {len(skipped)} skipped; platform {sys.platform}"
          " (an unbundled CLI never re-execs: pass = works or fix)")
    rows = []
    for cli_name, daemon_name in (("new", "old"), ("old", "new")):
        direction = f"cli={cli_name} daemon={daemon_name}"
        described = False
        for case in cases:
            daemon = Daemon(binaries[daemon_name], daemon_name)
            try:
                daemon.start(args.timeout)
                if not described:
                    served = set(daemon.identity.get("capabilities") or [])
                    build = daemon.identity.get("build_id") or daemon.identity.get("build_commit") or "?"
                    missing = [c for c in gated if c not in served]
                    print(f"skew-matrix: daemon={daemon_name} {binaries[daemon_name]} build {build}; "
                          f"gated capabilities missing: {', '.join(missing) or 'none'}")
                    described = True
                outcome = run_case(binaries[cli_name], daemon, case, args.timeout)
                verdict, detail = classify(
                    case, outcome, cli=binaries[cli_name], daemon_cli=binaries[daemon_name], socket=daemon.socket,
                )
            except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
                verdict, detail = "FAIL", f"daemon did not start: {error}"
            finally:
                daemon.stop()
            rows.append({"direction": direction, "case": case["id"], "verdict": verdict, "detail": detail})
    print(render_table(rows))
    for entry in skipped:
        print(f"skipped {entry['id']} ({entry.get('capability', '')}): {entry['reason']}")
    failed = sum(row["verdict"] == "FAIL" for row in rows)
    print(f"skew-matrix: {len(rows) - failed} pass, {failed} FAIL")
    return exit_status(rows)


if __name__ == "__main__":
    sys.exit(main())
