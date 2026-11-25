#!/usr/bin/env python3
"""acpmux/cmux n/n-1 skew: one real prompt through each mixed pair of builds.

Leo (ask-7c2b010159): "of course acpmux/cmux protocols need to be able to work in lockstep with
these and improve ever further".

acpmux and cmux deploy apart: `cmux live start --rust` (scripts/cmux-next/rust-live.py) swaps only
the daemon a saved crate reaches, so a new acpmux daemon serves an app whose cmux (and the acpmux
client inside it: the app's bin/acpmux is bin/cmux) is still the old build, and the other way
round. A remote machine or a day-old NEXT nightly is the same pair. The protocol checks
(api-compat-check --acpmux, protocol_skew_check.py) read the spec; this runs the real binaries.

  acpmux-skew-matrix.py --old-acpmux A --old-cmux C --new-acpmux A2 --new-cmux C2 [--out FILE]
  acpmux-skew-matrix.py --old shipped --new-acpmux A2 --new-cmux C2 [--out FILE]

`--old shipped` downloads the acpmux and cmux of the build the cmux NEXT nightly feed ships
(its sourceCommit's commit-addressed objects on files.cmux.com, Linux x86_64 or arm64 musl, or
macOS arm64): the n-1 every user runs. acpmux has no release tag of its own; v* and cmux-tui-v*
predate it.

For (acpmux=old, cmux=new) and (acpmux=new, cmux=old), each in its own temporary HOME:
  1. the pair's cmux starts an isolated cmux-tui daemon (`server ensure`);
  2. the pair's acpmux starts its daemon (`daemon run --memory`) with a stand-in agent
     (cmux-tui/crates/acpmux/tests/fake_agent.py) and CMUX_TUI_SOCKET at that cmux daemon;
  3. the pair's cmux, run as `acpmux` (the multicall name the app uses), sends one prompt
     (`run`) to that acpmux daemon and must get the agent's echo back.

It writes one JSON report (--out, and stdout's last line):
  {"schema": 1, "pass": P, "total": T, "ok": 0|1, "pairs": [...], "builds": {...}}
`ok` is 1 only when every pair passed: the number a live swap of one daemon reads before it swaps
(rust-live.py `skew_verdict`, from the report CMUX_ACPMUX_SKEW_REPORT names). Exits 0 when ok, 1 when a pair failed, 2 on bad input.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FAKE_AGENT = ROOT / "cmux-tui/crates/acpmux/tests/fake_agent.py"
NIGHTLY_FEED = "https://files-next.cmux.com/nightly-next/appcast-arm64.xml"  # scripts/ci/protocol_skew_check.py
OBJECTS = "https://files.cmux.com/cmux-tui"  # .github/workflows/cmux-tui-artifacts.yml layout
SOURCE_COMMIT = re.compile(r"<cmux:sourceCommit[^>]*>\s*([0-9a-f]{40})\s*</cmux:sourceCommit>")
PROMPT = "acpmux skew probe"
AGENT = "skm-agent"
SCHEMA = 1


def target() -> str:
    machine = platform.machine().lower()
    arch = "aarch64" if machine in ("arm64", "aarch64") else "x86_64"
    if sys.platform == "darwin":
        return f"{arch}-apple-darwin"
    return f"{arch}-unknown-linux-musl"


def fetch(url: str, dest: Path | None = None, timeout: float = 600) -> bytes:
    # The CDN refuses Python's default User-Agent with a 403.
    request = urllib.request.Request(url, headers={"User-Agent": "acpmux-skew-matrix/1"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        if dest is None:
            return response.read()
        with open(dest, "wb") as out:
            shutil.copyfileobj(response, out, 1 << 20)
    return b""


def shipped(into: Path) -> tuple[Path, Path, str]:
    """The acpmux and cmux of the build the NEXT nightly feed ships, downloaded into INTO."""
    feed = fetch(NIGHTLY_FEED, timeout=60).decode("utf-8", "replace")
    match = SOURCE_COMMIT.search(feed)
    if not match:
        raise RuntimeError(f"{NIGHTLY_FEED} names no sourceCommit")
    commit = match.group(1)
    into.mkdir(parents=True, exist_ok=True)
    paths = []
    for name in ("cmux-tui-acpmux", "cmux-tui"):
        dest = into / name
        fetch(f"{OBJECTS}/{commit}/{name}-{target()}", dest)
        dest.chmod(0o755)
        paths.append(dest)
    return paths[0], paths[1], commit


def version(binary: Path) -> str:
    try:
        done = subprocess.run([str(binary), "--version"], capture_output=True, text=True, timeout=30,
                              stdin=subprocess.DEVNULL)
        return (done.stdout or done.stderr).strip().splitlines()[0] if (done.stdout or done.stderr) else "?"
    except (OSError, subprocess.TimeoutExpired, IndexError):
        return "?"


class Pair:
    """One acpmux daemon and one cmux daemon of the given builds, in a private root; close() ends
    only what this started."""

    def __init__(self, acpmux: Path, cmux: Path, label: str, timeout: float):
        self.acpmux = acpmux
        self.cmux = cmux
        self.timeout = timeout
        # Short: the socket paths must fit sun_path (104 bytes on macOS).
        self.root = Path(os.path.realpath(tempfile.mkdtemp(prefix=f"askm.{label}.", dir="/tmp")))
        for sub in ("home", "state", "amx", "work", "bin"):
            (self.root / sub).mkdir(mode=0o700)
        # The app's acpmux client is cmux under the name acpmux (multicall).
        self.client = self.root / "bin" / "acpmux"
        self.client.symlink_to(cmux)
        self.cmux_socket: str | None = None
        self.cmux_pid: int | None = None
        self.daemon: subprocess.Popen | None = None
        self.log = self.root / "acpmux.log"

    def env(self) -> dict[str, str]:
        python = shutil.which("python3") or "/usr/bin/python3"
        path = f"{Path(python).parent}:/usr/bin:/bin:/usr/sbin:/sbin"
        env = {
            "PATH": path,
            "HOME": str(self.root / "home"),
            "TMPDIR": str(self.root),
            "CMUX_TUI_STATE_DIR": str(self.root / "state"),
            "CMUX_TUI_CONFIG": str(self.root / "home" / "no-config.toml"),
            "ACPMUX_HOME": str(self.root / "amx"),
            "ACPMUX_SOCKET": str(self.root / "a.sock"),
            "ACPMUX_LOGIN_ENV": "0",
            "ACPMUX_REGISTRY_FETCH": "0",
            "ACPMUX_HEALTH_FETCH": "0",
            "ACPMUX_PROBE_HARNESSES": AGENT,
            "ACPMUX_SPARE_HARNESS": "0",
            "ACPMUX_SESSION_CPU_CLASS": "normal",
        }
        if self.cmux_socket:
            env["CMUX_TUI_SOCKET"] = self.cmux_socket
        return env

    def run(self, argv: list, timeout: float | None = None) -> subprocess.CompletedProcess:
        return subprocess.run([str(a) for a in argv], env=self.env(), cwd=self.root / "work",
                              stdin=subprocess.DEVNULL, capture_output=True, text=True,
                              timeout=timeout or self.timeout)

    def start_cmux(self) -> None:
        done = self.run([self.cmux, "--session", f"askm{os.getpid()}", "--json", "server", "ensure"])
        lines = [line for line in done.stdout.splitlines() if line.strip().startswith("{")]
        if done.returncode != 0 or not lines:
            raise RuntimeError(f"cmux server ensure exit {done.returncode}: {tail(done.stderr or done.stdout)}")
        endpoint = json.loads(lines[-1])
        self.cmux_socket = endpoint.get("socket")
        self.cmux_pid = endpoint.get("pid") if isinstance(endpoint.get("pid"), int) else None
        if not self.cmux_socket:
            raise RuntimeError(f"cmux server ensure printed no socket: {lines[-1]}")

    def start_acpmux(self) -> None:
        config = {"harnesses": {AGENT: {"argv": ["python3", str(FAKE_AGENT)]}},
                  "defaultHarness": AGENT, "permissionPolicy": "approve-all"}
        path = self.root / "amx" / "config.json"
        path.write_text(json.dumps(config))
        path.chmod(0o600)  # acpmux refuses a config another user can write
        log = open(self.log, "w")
        self.daemon = subprocess.Popen(
            [str(self.acpmux), "daemon", "run", "--memory", "--ready-fd", "1", "--log", "warn"],
            env=self.env(), cwd=self.root / "work", stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=log, text=True)
        log.close()
        assert self.daemon.stdout is not None
        # A log line can come before the ready line on stdout (a systemd slice warning on Linux).
        seen = []
        while True:
            line = self.daemon.stdout.readline()
            if not line:
                raise RuntimeError(f"acpmux daemon exited before ready ({tail(''.join(seen))}): "
                                   f"{tail(self.log.read_text())}")
            if '"ready":true' in line.replace(" ", ""):
                return
            seen.append(line)

    def prompt(self) -> str:
        done = self.run([self.client, "--json", "run", "--timeout", str(int(self.timeout)), PROMPT])
        text = done.stdout + done.stderr
        if done.returncode != 0:
            raise RuntimeError(f"`acpmux run` exit {done.returncode}: {tail(text)}")
        if f"echo: {PROMPT}" not in text:
            raise RuntimeError(f"`acpmux run` answered without the agent's echo: {tail(text)}")
        return f"echo: {PROMPT}"

    def close(self) -> None:
        if self.daemon is not None:
            try:
                self.run([self.client, "daemon", "shutdown", "--end-agents"], timeout=30)
            except (OSError, subprocess.TimeoutExpired):
                pass
            if self.daemon.poll() is None:
                self.daemon.terminate()
                try:
                    self.daemon.wait(10)
                except subprocess.TimeoutExpired:
                    self.daemon.kill()
                    self.daemon.wait(10)
        if self.cmux_socket:
            for flags in (["--end-terminals"], ["--force"]):
                if not self.cmux_alive():
                    break
                try:
                    self.run([self.cmux, "--socket", self.cmux_socket, "--json", "server", "stop", *flags],
                             timeout=150)
                except (OSError, subprocess.TimeoutExpired):
                    pass
            if self.cmux_alive():
                os.kill(self.cmux_pid, 15)
        shutil.rmtree(self.root, ignore_errors=True)

    def cmux_alive(self) -> bool:
        if not self.cmux_pid or self.cmux_pid <= 1:
            return False
        try:
            os.kill(self.cmux_pid, 0)
        except OSError:
            return False
        exe = Path(f"/proc/{self.cmux_pid}/exe")
        if exe.exists():
            try:
                return os.path.realpath(exe) == os.path.realpath(self.cmux)
            except OSError:
                return False
        return True


def tail(text: str, lines: int = 6) -> str:
    return " | ".join(line.strip() for line in (text or "").strip().splitlines()[-lines:] if line.strip())


def run_pair(acpmux: Path, cmux: Path, label: str, timeout: float) -> dict:
    t0 = time.monotonic()
    row = {"pair": label, "acpmux": str(acpmux), "cmux": str(cmux)}
    pair = Pair(acpmux, cmux, label.replace("acpmux=", "a").replace(" cmux=", "-c"), timeout)
    try:
        pair.start_cmux()
        pair.start_acpmux()
        row["reply"] = pair.prompt()
        row["verdict"] = "pass"
    except (RuntimeError, OSError, subprocess.TimeoutExpired, ValueError) as error:
        row["verdict"] = "FAIL"
        row["detail"] = str(error)
    finally:
        pair.close()
    row["secs"] = round(time.monotonic() - t0, 3)
    return row


def report(rows: list[dict], builds: dict) -> dict:
    passed = sum(row["verdict"] == "pass" for row in rows)
    return {"schema": SCHEMA, "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "pass": passed, "total": len(rows), "ok": int(bool(rows) and passed == len(rows)),
            "pairs": rows, "builds": builds}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--old", choices=["shipped"], help="download the NEXT nightly's acpmux and cmux as n-1")
    parser.add_argument("--old-acpmux", type=Path)
    parser.add_argument("--old-cmux", type=Path)
    parser.add_argument("--new-acpmux", type=Path, required=True)
    parser.add_argument("--new-cmux", type=Path, required=True)
    parser.add_argument("--out", type=Path, help="write the JSON report here too")
    parser.add_argument("--timeout", type=float, default=90, help="seconds per step")
    args = parser.parse_args(argv)
    if not FAKE_AGENT.is_file():
        print(f"acpmux-skew-matrix: no stand-in agent at {FAKE_AGENT}", file=sys.stderr)
        return 2
    scratch = None
    builds: dict = {}
    if args.old == "shipped":
        scratch = Path(tempfile.mkdtemp(prefix="askm-old."))
        try:
            args.old_acpmux, args.old_cmux, commit = shipped(scratch)
        except (OSError, RuntimeError) as error:
            print(f"acpmux-skew-matrix: could not download the shipped build: {error}", file=sys.stderr)
            return 2
        builds["old_commit"] = commit
    if not args.old_acpmux or not args.old_cmux:
        print("acpmux-skew-matrix: pass --old shipped, or --old-acpmux and --old-cmux", file=sys.stderr)
        return 2
    binaries = {"old_acpmux": args.old_acpmux, "old_cmux": args.old_cmux,
                "new_acpmux": args.new_acpmux, "new_cmux": args.new_cmux}
    for name, path in binaries.items():
        if not os.access(path, os.X_OK):
            print(f"acpmux-skew-matrix: --{name.replace('_', '-')} {path} is not executable", file=sys.stderr)
            return 2
        binaries[name] = Path(os.path.realpath(path))
        builds[name] = version(binaries[name])
    try:
        rows = [
            run_pair(binaries["old_acpmux"], binaries["new_cmux"], "acpmux=old cmux=new", args.timeout),
            run_pair(binaries["new_acpmux"], binaries["old_cmux"], "acpmux=new cmux=old", args.timeout),
        ]
    finally:
        if scratch:
            shutil.rmtree(scratch, ignore_errors=True)
    result = report(rows, builds)
    for row in rows:
        print(f"acpmux-skew-matrix: {row['pair']}: {row['verdict']} ({row['secs']}s)"
              + (f": {row['detail']}" if row.get("detail") else ""), file=sys.stderr)
    text = json.dumps(result, sort_keys=True)
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(text + "\n")
    print(text)
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
