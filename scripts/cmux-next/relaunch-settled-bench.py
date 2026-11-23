#!/usr/bin/env python3
"""What redoes itself on screen when cmux relaunches into an update: one JSON of counters per relaunch, all 0 is good.

    relaunch-settled-bench.py --ref <SHA|PR> [--rounds 3] [--out DIR] [--side NAME] [--seconds 15]
                              [--fixtures DIR] [--web-tree DIR] [--keep]

Leo, 2026-11-22: "just restarted to update again. lots of bullshit. composer dips down then goes back up. then the
crazy fucking stupid folding animations somehow replay even though these messages had already been seen by me and
shit... and then the top half of the chat blanked out for like 10 seconds. and then the sidebar re-rendered/re-ordered
with some animations. and then the scroll rail re-rednered. and then more shit re-rendered. all of these need fucking
help"

No app build. The ref's code runs in a DEV side copy (side-instance.sh) of the nearest published DEV build at or
behind the ref (the tip feed's Debug builds or a fleet build, hot-verify.py `golden_candidates`; a NIGHTLY has no
debug hooks): the ref's web bundles go into the copy's overlay (published for the ref's source key, else built here
from --web-tree or a checkout of the ref; never a dev server, so timing is the shipped page's) and the ref's
daemon replaces the copy's (hot-apply.py --parts rust) when it is published. The copy's Swift stays the build's;
the report names the build and how far behind the ref it is.

It seeds one long busy chat from Leo's real coordinator transcripts, the chat simulator's private fixtures
(cmuxterm-hq fixtures/chat-sim: never copied into this repo; read from --fixtures, a cmuxterm-hq checkout or its
`tools/chat-sim-fixtures/fetch` at run time): coord-god-chat, then coord-notices-background, then coord-subagents
(9 subagents, 3 whose end never reached the log), as one acpmux chat (`_acpmux/import`), shown in its own
workspace, plus 5 more workspaces for sidebar rows. Then per round it quits the copy through the updater's relaunch
path (`debug.updater relaunch`), opens it again with `--record-launch` (every window frame from the first,
DebugWindowRecord) and a launch marks FIFO (so the page's relaunch record runs, webviews relaunchWatch.ts), starts
the sidebar's motion probe the moment the socket answers, and after --seconds reads:

  composer_height_changes  composer box height changes after the page's first content
  replayed_animations      CSS animations/transitions and Web Animations started on rows that were there at first
                           content (the fold's and growth's `rows.animate` on the row stack count)
  chat_blank_frames        page frames after first content whose transcript top half shows no row; blank_ms their time
  sidebar_reorders         sidebar frames whose row order (by y) differs from the frame before
  sidebar_row_animations   sidebar frames where a row's presented frame moved or its opacity was neither 0 nor 1
  scroll_rail_renders      the scroll rail drawn again (a new node, a new box, or its subtree changed)
  rerenders                DOM mutation batches inside rows that were there at first content
  layout_shifts            the page's launch settle shifts (web.layout.shifts) + window geometry frames (launch_shift)
  false_disconnected_rows  "Subagent disconnected" rows after the relaunch that were not there before the quit

and prints `RELAUNCH-SETTLED {json}` per round, then a summary; report.json, frames and contact sheets in --out.
The sidebar probe starts when the socket answers, so a sidebar change before that is not seen (frame-0 filming
of the sidebar is cmux#50447). A ref whose web lacks relaunchWatch.ts reports its page counters as null.

GUI: run it on a Mac where agents may open app windows (Leo's rules: air-blue or cmux16, `host-presence` idle and
`mac-budget` admitted; never his NIGHTLY: the copy has its own bundle id, socket and data).
"""
from __future__ import annotations

import argparse
import contextlib
import importlib.util
import json
import os
import re
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))
import launch_shift  # noqa: E402


def load(name: str, file: str):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


hv = load("hot_verify", "hot-verify.py")

FIXTURES = ("coord-god-chat", "coord-notices-background", "coord-subagents")
SIDEBAR_ROWS = 5
DEV_KINDS = ("fleet",)  # a tip feed DEV build is a Release compile: no debug.* methods (#if DEBUG || CMUX_BENCH_HOOKS)
FAKE_AGENT = ROOT / "cmux-tui/crates/acpmux/tests/fake_agent.py"
COUNTERS = ("composer_height_changes", "replayed_animations", "chat_blank_frames", "blank_ms", "sidebar_reorders",
            "sidebar_row_animations", "scroll_rail_renders", "rerenders", "layout_shifts", "false_disconnected_rows",
            "chat_not_restored_in_front")


def say(*parts) -> None:
    print(time.strftime("%H:%M:%S"), *parts, file=sys.stderr, flush=True)


def git(*args: str, check: bool = True) -> str:
    done = subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True)
    if check and done.returncode != 0:
        raise SystemExit(f"git {' '.join(args)}: {done.stderr.strip()[:300]}")
    return done.stdout.strip()


def resolve_ref(ref: str) -> tuple[str, int | None]:
    """A full sha and the pull request number, if REF named one (`123`, `#123`, a PR URL)."""
    number = re.fullmatch(r"#?(\d{3,6})|.*/pull/(\d+).*", ref)
    if number:
        pr = int(number.group(1) or number.group(2))
        git("fetch", "-q", "--no-tags", "origin", f"+refs/pull/{pr}/head:refs/remotes/origin/pr/{pr}")
        return git("rev-parse", f"refs/remotes/origin/pr/{pr}"), pr
    git("fetch", "-q", "--no-tags", "origin", "+refs/heads/feat-cmux-next:refs/remotes/origin/feat-cmux-next", check=False)
    sha = git("rev-parse", "--verify", f"{ref}^{{commit}}", check=False)
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        git("fetch", "-q", "--no-tags", "origin", ref, check=False)
        sha = git("rev-parse", "--verify", f"{ref}^{{commit}}")
    return sha, None


def merged_onto(sha: str, onto: str) -> str:
    """SHA merged into ONTO (a local merge commit, never pushed): the web a PR ships once it lands on today's base,
    so a PR branched before a base fix (#51194: the shipped pane.js never connected) measures with that fix."""
    git("fetch", "-q", "--no-tags", "origin", "+refs/heads/feat-cmux-next:refs/remotes/origin/feat-cmux-next", check=False)
    base = git("rev-parse", "--verify", f"{onto}^{{commit}}")
    if subprocess.run(["git", "-C", str(ROOT), "merge-base", "--is-ancestor", base, sha]).returncode == 0:
        return sha
    tree = subprocess.run(["git", "-C", str(ROOT), "merge-tree", "--write-tree", base, sha], capture_output=True,
                          text=True)
    if tree.returncode != 0:
        raise SystemExit(f"{sha[:12]} does not merge cleanly onto {onto}: {tree.stdout.strip()[-300:]}")
    return git("commit-tree", tree.stdout.split()[0], "-p", base, "-p", sha, "-m", f"relaunch-settled: {sha[:12]} onto {onto}")


def cached_dev_goldens(anchor: str) -> list[dict]:
    """DEV apps already in hot-verify's golden cache whose commit is ANCHOR or behind it, nearest first."""
    found = []
    root = hv.golden_root()
    for ready in root.glob(f"*/{hv.GOLDEN_READY}") if root.is_dir() else []:
        try:
            build = json.loads(ready.read_text())
        except ValueError:
            continue
        commit = build.get("commit") or ""
        if build.get("kind") not in DEV_KINDS or not commit:
            continue
        if subprocess.run(["git", "-C", str(ROOT), "merge-base", "--is-ancestor", commit, anchor]).returncode:
            continue
        found.append((int(git("rev-list", "--count", f"{commit}..{anchor}") or 0), build))
    return [build for _, build in sorted(found, key=lambda pair: pair[0])]


def fleet_job_build(job: str) -> dict:
    """The finished fleet app build JOB (`cmux-ci build cmux`) as a golden: a DEV compile with the debug methods."""
    found = subprocess.run([hv.cmux_ci() or "cmux-ci", "status", job], capture_output=True, text=True, timeout=60)
    try:
        info = json.loads(found.stdout or "{}")
    except ValueError:
        info = {}
    info = info[0] if isinstance(info, list) and info else info
    if not isinstance(info, dict) or info.get("state") != "done" or not info.get("ref"):
        raise SystemExit(f"fleet build {job} is not a finished app build: {(found.stdout or found.stderr)[:300]}")
    return {"kind": "fleet", "commit": git("rev-parse", info["ref"]), "job": str(info.get("id") or job),
            "label": str(info.get("tag") or job)}


def pick_dev_golden(sha: str, job: str | None = None) -> dict:
    """The nearest published DEV build at or behind SHA's merge base with feat-cmux-next."""
    if job:
        build = fleet_job_build(job)
        build["swift_behind_ref"] = int(git("rev-list", "--count", f"{build['commit']}..{sha}") or 0)
        return build
    anchor = hv.golden_anchor(ROOT, sha)
    for attempt in range(5):  # a feed that did not answer once (a slow CDN edge) answers the next try
        notes: list[str] = []
        builds = [b for b in hv.golden_candidates(ROOT, anchor, None, notes) if b["kind"] in DEV_KINDS]
        if builds or not notes:  # notes say which feed did not answer; none means it answered with no build here
            break
        time.sleep(20 * (attempt + 1))
    if not builds:  # the feed moved past the ref: a DEV app already downloaded here at or behind it still serves
        builds = cached_dev_goldens(anchor)
        if builds:
            say(f"golden copy: the feed has no DEV build at or behind {anchor[:12]}; using the cached {builds[0]['commit'][:12]}")
    if not builds:
        raise SystemExit(f"no fleet DEV build at or behind {anchor[:12]} ({notes}): build one with `cmux-ci build "
                         "cmux --ref SHA` and pass its job with --build-job")
    build = builds[0]
    build["swift_behind_ref"] = int(git("rev-list", "--count", f"{build['commit']}..{sha}") or 0)
    return build


# ---- the copy's sockets --------------------------------------------------------------------------------------


def rpc(sock: str, method: str, params: dict | None = None, timeout: float = 60):
    """One request on the copy's control socket: the result, or {"error": ...}."""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(timeout)
            conn.connect(sock)
            conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = conn.recv(1 << 22)
                if not chunk:
                    break
                buf += chunk
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def processes() -> list[tuple[int, str]]:
    out = subprocess.run(["ps", "-axww", "-o", "pid=,command="], capture_output=True, text=True).stdout
    found = []
    for line in out.splitlines():
        pid, _, command = line.strip().partition(" ")
        if pid.isdigit():
            found.append((int(pid), command))
    return found


def environment_of(pid: int, keys: tuple[str, ...]) -> dict:
    out = subprocess.run(["ps", "eww", "-o", "command=", "-p", str(pid)], capture_output=True, text=True).stdout
    return {k: m.group(1) for k in keys if (m := re.search(rf"(?:^| ){k}=(\S+)", out))}


class Acpmux:
    """JSON-RPC lines to the copy's acpmux daemon; notifications are dropped."""

    def __init__(self, path: str):
        self.conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.conn.settimeout(120)
        self.conn.connect(path)
        self.next, self.buf = 0, b""
        self.request("initialize", {"protocolVersion": 1, "clientInfo": {"name": "relaunch-settled-bench"}})

    def request(self, method: str, params: dict) -> dict:
        self.next += 1
        rid = self.next
        self.conn.sendall((json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}) + "\n").encode())
        while True:
            while b"\n" in self.buf:
                line, self.buf = self.buf.split(b"\n", 1)
                with contextlib.suppress(ValueError):
                    message = json.loads(line)
                    if message.get("id") == rid and ("result" in message or "error" in message):
                        return message
            chunk = self.conn.recv(1 << 20)
            if not chunk:
                return {"error": {"message": "closed"}}
            self.buf += chunk


class Copy:
    """The side copy: its app, pid, control socket, daemon socket and acpmux."""

    def __init__(self, side, out: Path):
        self.side, self.out = side, out
        self.app = side.app()
        self.socket = side.socket()
        self.pid: int | None = None
        self.budget = shutil.which("mac-budget")
        self.fifo = out / "launch-marks.fifo"
        self.marks: list[tuple[str, float]] = []

    def exe(self) -> str:
        import plistlib
        info = plistlib.loads((self.app / "Contents/Info.plist").read_bytes())
        return str(self.app / "Contents/MacOS" / info["CFBundleExecutable"])

    def admit(self) -> None:
        if not self.budget:
            return
        done = subprocess.run([self.budget, "admit", "--kind", "side", "--name", self.side.name, "--wait", "900",
                               "--holder-pid", str(os.getpid())])
        if done.returncode != 0:
            raise SystemExit(f"mac-budget refused {self.side.name} (exit {done.returncode}): see `mac-budget status`")

    def record(self) -> None:
        (self.side.dir() / "pid").write_text(f"{self.pid}\n")
        if self.budget:
            subprocess.run([self.budget, "record", "--name", self.side.name, "--kind", "side", "--app", str(self.app),
                            "--pid", str(self.pid), "--stop-argv",
                            json.dumps([str(HERE / "side-instance.sh"), "stop", self.side.name])],
                           capture_output=True)

    def read_marks(self) -> None:
        """Reads the launch marks FIFO (opened before the app opens it: its nonblocking writer needs a reader)."""
        with contextlib.suppress(FileNotFoundError):
            self.fifo.unlink()
        os.mkfifo(self.fifo)
        fd = os.open(self.fifo, os.O_RDONLY | os.O_NONBLOCK)
        self.marks = []

        def run():
            buf = b""
            # A writer that has not opened yet reads as EOF: keep reading until the round ends.
            while not getattr(self, "marks_done", False):
                try:
                    chunk = os.read(fd, 65536)
                except BlockingIOError:
                    chunk = b""
                if chunk:
                    buf += chunk
                    while b"\n" in buf:
                        line, buf = buf.split(b"\n", 1)
                        name, _, ms = line.decode(errors="replace").rpartition(" ")
                        with contextlib.suppress(ValueError):
                            self.marks.append((name, float(ms)))
                else:
                    time.sleep(0.02)
            os.close(fd)

        self.marks_done = False
        threading.Thread(target=run, daemon=True).start()

    def launch(self, film: Path | None, seconds: float) -> float:
        """Opens the copy (behind the front app) with the marks FIFO and, with FILM, a launch recording; the time."""
        running = [pid for pid, command in processes() if command == self.exe() or command.startswith(self.exe() + " ")]
        if running:
            raise SystemExit(f"the copy still runs (pid {running}): never a second copy of its bundle id")
        self.read_marks()
        args = ["/usr/bin/open", "-n", "-g", "-a", str(self.app), "--env", f"CMUX_NEXT_LAUNCH_MARKS_PATH={self.fifo}"]
        if film is not None:
            args += ["--args", "--record-launch", str(film), "--record-launch-seconds", str(int(seconds))]
        began = time.monotonic()
        subprocess.run(args, check=True)
        exe = self.exe()
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            mine = [pid for pid, command in processes() if command == exe or command.startswith(exe + " ")]
            if mine:
                self.pid = max(mine)
                break
            time.sleep(0.05)
        else:
            raise SystemExit("the copy did not start")
        self.record()
        return began

    def answers(self, seconds: float = 90) -> bool:
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            reply = rpc(self.socket, "system.identify", timeout=2)
            if isinstance(reply, dict) and reply.get("pid") == self.pid:
                return True
            time.sleep(0.05)
        return False

    def quit_for_update(self) -> bool:
        """The updater's relaunch path (as Sparkle runs it before an update), then the exact pid's exit."""
        rpc(self.socket, "debug.updater", {"action": "relaunch"}, timeout=10)
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            try:
                os.kill(self.pid, 0)
            except ProcessLookupError:
                self.marks_done = True
                return True
            time.sleep(0.1)
        return False

    def bin(self, name: str) -> str:
        return str(self.app / "Contents/Resources/bin" / name)

    def daemon_socket(self) -> str | None:
        prefix = self.bin("")
        for _, command in processes():
            if command.startswith(prefix) and "--headless" in command and (m := re.search(r"--socket (\S+)", command)):
                return m.group(1)
        return None

    def cli(self, *args: str):
        sock = hv.until("the copy's daemon", 60, self.daemon_socket)
        done = subprocess.run([self.bin("cmux"), "--socket", sock, "--json", *args], capture_output=True, text=True,
                              timeout=60, env={**os.environ, "CMUX_QUIET": "1"})
        try:
            return json.loads(done.stdout)
        except ValueError:
            return {"error": (done.stdout + done.stderr).strip()[:300]}

    def acpmux(self) -> tuple[Path, Acpmux]:
        binary = self.bin("acpmux")

        def running():
            for pid, command in processes():
                if command.startswith(binary + " daemon run") or command.startswith(self.bin("cmux") + " acp daemon run"):
                    env = environment_of(pid, ("ACPMUX_HOME", "ACPMUX_SOCKET"))
                    if env.get("ACPMUX_HOME"):
                        home = env["ACPMUX_HOME"]
                        sock = env.get("ACPMUX_SOCKET") or os.path.join(home, "acpmux.sock")
                        if os.path.exists(sock):
                            return home, sock
            return None

        home, sock = hv.until("the copy's acpmux daemon", 90, running)
        return Path(home), Acpmux(sock)


# ---- the ref's code into the copy -----------------------------------------------------------------------------


WATCH_FILE = "webviews/src/agent-session/acpmux/relaunchWatch.ts"
PROTOCOL_IR = "cmux-tui/crates/acpmux/spec/acpmux-protocol.json"


def add_watch(tree: Path) -> str:
    """The page's relaunch record (this harness's webviews change, as this checkout has it) applied onto TREE."""
    mine = git("log", "-1", "--format=%H", "--", WATCH_FILE)
    if not mine:
        raise SystemExit(f"this checkout has no {WATCH_FILE} to add to the ref")
    patch = subprocess.run(["git", "-C", str(ROOT), "diff", f"{mine}~1", mine, "--", "webviews/"],
                           capture_output=True, text=True, check=True).stdout
    done = subprocess.run(["git", "-C", str(tree), "apply", "--3way"], input=patch, capture_output=True, text=True)
    if done.returncode != 0:
        raise SystemExit(f"the relaunch record does not apply onto the ref: {(done.stderr or done.stdout).strip()[-300:]}")
    return f"relaunch record from {mine[:12]}"


def apply_ref(copy: Copy, sha: str, pr: int | None, web_tree: Path | None, scratch: Path,
              web_sha: str | None = None) -> dict:
    """SHA's daemon (hot-apply) and WEB_SHA's web bundles (default SHA's) into the copy."""
    applied: dict = {}
    merged = web_sha is not None and web_sha != sha
    web_sha = web_sha or sha
    env = {**os.environ, **copy.side.env()}
    rust = subprocess.run([sys.executable, str(HERE / "hot-apply.py"), "apply", sha, "--branch", "--parts", "rust",
                           "--app", str(copy.app), "--repo", str(ROOT), "--restart-acpmux"],
                          env={**os.environ, "CMUX_HOT_APPLY_STATE_DIR": str(copy.side.dir() / "hot-apply")},
                          capture_output=True, text=True, timeout=900)
    applied["rust"] = ("ref's published daemon" if rust.returncode == 0 else
                       f"build's own daemon (hot-apply exit {rust.returncode}: {(rust.stderr or rust.stdout).strip()[-200:]})")
    # A ref without the page's relaunch record (relaunchWatch.ts: a fix measured before this landed) gets it here.
    watched = subprocess.run(["git", "-C", str(ROOT), "cat-file", "-e", f"{web_sha}:{WATCH_FILE}"],
                             capture_output=True).returncode == 0
    key = None if web_tree or not watched or merged else hv.published_web_key(ROOT, {"head": sha, "pr": pr})
    bundles = scratch / "web-bundles"
    if key:
        done = subprocess.run([str(HERE / "fetch-web-bundles.sh"), "--key", key, "--out", str(bundles)],
                              capture_output=True, text=True, timeout=900)
        if done.returncode != 0:
            raise SystemExit(f"fetch-web-bundles {key[:12]}: {done.stderr.strip()[-300:]}")
        applied["web"] = f"published bundles {key[:12]}"
    else:
        tree = web_tree or hv.web_checkout(ROOT, web_sha, scratch)
        if not web_tree:  # the bundles' postinstall reads the acpmux protocol IR (#50853), which a ref's
            # web-bundle-key.py --inputs may not list yet: without it the sparse tree's build fails
            subprocess.run(["git", "-C", str(tree), "sparse-checkout", "add", "/" + PROTOCOL_IR], check=True,
                           capture_output=True)
        if not watched and not web_tree:
            applied["watch"] = add_watch(tree)
        say(f"building the web bundles of {tree} (none published for {sha[:12]}{'' if watched else ', with the relaunch record'}{f', merged as {web_sha[:12]}' if merged else ''})")
        done = subprocess.run([str(tree / "scripts/cmux-next/build-web-bundles.sh"), "--force", "--out-root",
                               str(bundles)], cwd=tree, capture_output=True, text=True, timeout=3600)
        if done.returncode != 0:
            raise SystemExit(f"build-web-bundles: {(done.stderr or done.stdout).strip()[-400:]}")
        applied["web"] = f"built here from {web_sha[:12]}" + (f" ({sha[:12]} merged onto the base)" if merged else "")
    done = subprocess.run([str(HERE / "web-overlay.sh"), "install", str(bundles), "--commit", web_sha], env=env,
                          capture_output=True, text=True, timeout=300)
    if done.returncode != 0:
        raise SystemExit(f"web-overlay.sh install: {done.stderr.strip()[-300:]}")
    return applied


# ---- the seeded chat --------------------------------------------------------------------------------------------


def fixture_files(given: Path | None, scratch: Path) -> list[Path]:
    """The fixtures as plain .ndjson: from GIVEN, else fetched with cmuxterm-hq's tool (never stored in this repo)."""
    found = []
    folder = given or scratch / "chat-sim"
    for name in FIXTURES:
        if not (folder / f"{name}.ndjson").is_file():
            fetch = next((p for p in (Path(os.environ.get("CMUX_HQ_DIR", "")) / "tools/chat-sim-fixtures/fetch",
                                      Path.home() / "Projects/cmuxterm-hq/tools/chat-sim-fixtures/fetch") if p.is_file()), None)
            argv = [sys.executable, str(fetch)] if fetch else None
            if argv is None:
                script = subprocess.run(["gh", "api", "-H", "Accept: application/vnd.github.raw",
                                         "repos/manaflow-ai/cmuxterm-hq/contents/tools/chat-sim-fixtures/fetch"],
                                        capture_output=True, text=True)
                if script.returncode != 0:
                    raise SystemExit("no chat-sim fixtures: pass --fixtures DIR or set CMUX_HQ_DIR")
                (scratch / "fetch").write_text(script.stdout)
                argv = [sys.executable, str(scratch / "fetch")]
            folder.mkdir(parents=True, exist_ok=True)
            subprocess.run([*argv, name, "--to", str(folder)], check=True, capture_output=True)
        found.append(folder / f"{name}.ndjson")
    return found


def chat_records(files: list[Path], new_id: str) -> list[str]:
    """The fixtures as one chat's records: renumbered from 1, every source session id replaced by NEW_ID."""
    lines, seq = [], 0
    for path in files:
        text = path.read_text()
        ids = set(re.findall(r'"sessionId":\s*"([0-9a-f-]{36})"', text))
        for line in text.splitlines():
            if not line.strip():
                continue
            for old in ids:
                line = line.replace(old, new_id)
            record = json.loads(line)
            seq += 1
            record["seq"] = seq
            lines.append(json.dumps(record, separators=(",", ":")))
    return lines


def seed(copy: Copy, files: list[Path], scratch: Path) -> dict:
    home, client = copy.acpmux()
    config_path = home / "config.json"
    config = json.loads(config_path.read_text()) if config_path.is_file() else {}
    config.setdefault("harnesses", {})["fake"] = {"argv": ["python3", str(FAKE_AGENT)]}
    config_path.write_text(json.dumps(config, indent=2))
    client.request("_acpmux/reload_config", {})
    cwd = scratch / "chat-cwd"
    cwd.mkdir(exist_ok=True)
    made = client.request("session/new", {"cwd": str(cwd), "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}})
    template = (made.get("result") or {}).get("sessionId")
    if not template:
        raise SystemExit(f"session/new: {json.dumps(made)[:300]}")
    exported = client.request("_acpmux/export", {"sessionId": template, "dest": str(scratch / "export")})
    bundle = Path((exported.get("result") or {}).get("path", ""))
    if not (bundle / "session.json").is_file():
        raise SystemExit(f"_acpmux/export: {json.dumps(exported)[:300]}")
    new_id = str(uuid.uuid4())
    meta = json.loads((bundle / "session.json").read_text())
    meta["id"] = new_id
    meta["name"] = "settled-long-chat"
    records = chat_records(files, new_id)
    for key in ("lastSeq", "last_seq", "transcriptSeq", "transcript_seq"):
        if key in meta:
            meta[key] = len(records)
    (bundle / "session.json").write_text(json.dumps(meta))
    events = bundle / "events"
    shutil.rmtree(events, ignore_errors=True)
    events.mkdir()
    (events / "000001.ndjson").write_text("\n".join(records) + "\n")
    imported = client.request("_acpmux/import", {"path": str(bundle)})
    if "error" in imported:
        raise SystemExit(f"_acpmux/import: {json.dumps(imported)[:300]}")
    for n in range(SIDEBAR_ROWS):
        copy.cli("workspace", "create", "--name", f"settled-{n + 1}")
    named = {"session": new_id, "name": "settled long chat"}
    opened = rpc(copy.socket, "action.run", {"action": "agent.openSessionWorkspace", "arguments": named, **named},
                 timeout=90)
    if not isinstance(opened, dict) or "error" in opened:
        opened = copy.cli("agent", "open", new_id)
    say(f"seeded {len(records)} records as {new_id}: {json.dumps(opened)[:200]}")
    return {"session": new_id, "records": len(records), "opened": opened}


def chat_tab(copy: Copy, session: str) -> tuple[str | None, str | None, dict]:
    """The seeded chat's tab and pane, and what the copy has in front (its topology's focus)."""
    topo = (rpc(copy.socket, "snapshot.get") or {}).get("topology") or {}
    for ws in topo.get("workspaces", []):
        for screen in ws.get("screens", []):
            for pane in screen.get("panes", []):
                for tab in pane.get("tabs", []):
                    if tab.get("agent_session") == session:
                        return tab["id"], pane["id"], topo.get("focus") or {}
    return None, None, topo.get("focus") or {}


def show_chat(copy: Copy, session: str) -> bool:
    """The seeded chat in front (the `tab.focus` action, which selects its workspace too), checked on the topology:
    the app restores what was in front at the quit, so every round relaunches onto the chat the person was reading."""
    tab, _, _ = chat_tab(copy, session)
    if tab is None:
        return False
    rpc(copy.socket, "action.run", {"action": "tab.focus", "target": f"tab:{tab}", "focus": True}, timeout=30)
    return bool(hv.until("the chat in front", 20, lambda: chat_tab(copy, session)[2].get("tab") == tab))


def page_state(copy: Copy) -> dict:
    """What the shown chat page holds now: its rows and its "Subagent disconnected" rows."""
    rows = rpc(copy.socket, "debug.agent_pane", {"action": "query", "selector": ".acpmux-row[data-row-id]"}) or {}
    gone = rpc(copy.socket, "debug.agent_pane",
               {"action": "query", "selector": '.cv-subagent-done-row[data-state="disconnected"]'}) or {}

    def items(reply):
        return reply.get("elements") or reply.get("matches") or [] if isinstance(reply, dict) else []

    return {"rows": len(items(rows)),
            "disconnected": sorted({(e.get("text") or "").strip()[:120] for e in items(gone)})}


# ---- one round ----------------------------------------------------------------------------------------------------


def sidebar_counts(motion: dict) -> dict:
    frames = (motion or {}).get("frames") or []
    reorders = animated = rebuilt = 0
    before = None
    for frame in frames:
        views = {k: v for k, v in (frame.get("views") or {}).items() if not k.startswith("item:")}
        if before is not None:
            common = [k for k in views if k in before["views"]]
            order = sorted(common, key=lambda k: views[k][1])
            if order != sorted(common, key=lambda k: before["views"][k][1]):
                reorders += 1
            moved = any(max(abs(a - b) for a, b in zip(views[k][:4], before["views"][k][:4])) > 0.5 for k in common)
            fading = any(0.01 < v[4] < 0.99 for v in views.values())
            animated += 1 if moved or fading else 0
            rebuilt += sum(1 for k in common if frame.get("ids", {}).get(k) != before["ids"].get(k))
        before = {"views": views, "ids": frame.get("ids") or {}}
    return {"sidebar_frames": len(frames), "sidebar_reorders": reorders, "sidebar_row_animations": animated,
            "sidebar_row_rebuilds": rebuilt}


def contact_sheet(film: Path, out: Path) -> str | None:
    frames = sorted(film.glob("window-*/frame-*.jpg"))
    if not frames or not shutil.which("ffmpeg"):
        return None
    picked = frames[:: max(1, len(frames) // 48)][:48]
    listing = out.with_suffix(".txt")
    listing.write_text("".join(f"file '{p}'\nduration 0.1\n" for p in picked))
    done = subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", str(listing),
                           "-vf", "scale=320:-1,tile=8x6", "-frames:v", "1", str(out)], capture_output=True)
    listing.unlink()
    return str(out) if done.returncode == 0 else None


def round_(copy: Copy, n: int, out: Path, seconds: float, before: dict, session: str) -> dict:
    folder = out / f"round-{n}"
    film = folder / "film"
    film.mkdir(parents=True, exist_ok=True)
    if not copy.quit_for_update():
        raise SystemExit(f"round {n}: the copy did not quit within 60 s")
    say(f"round {n}: quit through the updater; relaunching, filmed for {seconds:g} s")
    began = copy.launch(film, seconds)
    if not copy.answers():
        raise SystemExit(f"round {n}: the relaunched copy never answered")
    answered_ms = round((time.monotonic() - began) * 1000)
    rpc(copy.socket, "debug.sidebar_rows", {"motion": "start"}, timeout=10)
    tab, pane, front = chat_tab(copy, session)
    restored_in_front = front.get("tab") == tab
    if not restored_in_front:  # the relaunch put something else in front: the page is read anyway, from the chat's pane
        say(f"round {n}: the relaunch restored {front.get('tab')} in front, not the chat {tab}")
        show_chat(copy, session)
    time.sleep(max(0.0, seconds - (time.monotonic() - began)) + 1.5)
    motion = rpc(copy.socket, "debug.sidebar_rows", {"motion": "stop"}, timeout=30)
    watch = rpc(copy.socket, "debug.agent_pane", {"action": "layout_watch", "ms": 200, **({"pane": pane} if pane else {})},
                timeout=30)
    after = page_state(copy)
    page = (watch or {}).get("relaunch") if isinstance(watch, dict) else None
    marks = dict(copy.marks)
    window = launch_shift.summarize(str(film)) if any(film.glob("window-*/frames.json")) else {"total": {}}
    side = sidebar_counts(motion if isinstance(motion, dict) else {})
    web_shifts = marks.get("web.layout.shifts")
    geometry = window["total"].get("geometry_frames")
    false_gone = sorted(set(after["disconnected"]) - set(before["disconnected"]))
    counters = {
        "composer_height_changes": page and page["composer_height_changes"],
        "replayed_animations": page and page["replayed_animations"],
        "chat_blank_frames": page and page["chat_blank_frames"],
        "blank_ms": page and page["blank_ms"],
        "sidebar_reorders": side["sidebar_reorders"],
        "sidebar_row_animations": side["sidebar_row_animations"],
        "scroll_rail_renders": page and page["scroll_rail_renders"],
        "rerenders": page and page["rerenders"],
        "layout_shifts": (int(web_shifts or 0) + int(geometry or 0)) if web_shifts is not None or geometry is not None else None,
        "false_disconnected_rows": len(false_gone),
        "chat_not_restored_in_front": int(not restored_in_front),
    }
    detail = {"round": n, "answered_ms": answered_ms, "restored_in_front": restored_in_front, "web_layout_shifts": web_shifts, "window": window["total"],
              "sidebar": side, "false_disconnected": false_gone, "rows_before": before["rows"],
              "rows_after": after["rows"], "page": page, "marks": marks,
              "contact_sheet": contact_sheet(film, folder / "contact-sheet.jpg")}
    (folder / "round.json").write_text(json.dumps({"counters": counters, **detail}, indent=2))
    (folder / "sidebar-motion.json").write_text(json.dumps(motion))
    print("RELAUNCH-SETTLED " + json.dumps({"round": n, **counters}), flush=True)
    show_chat(copy, session)
    return {"counters": counters, **detail}


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--ref", required=True, help="a commit (sha, branch) or pull request (123, #123, its URL)")
    p.add_argument("--rounds", type=int, default=3)
    p.add_argument("--out", type=Path)
    p.add_argument("--side", default="relaunch-settled")
    p.add_argument("--seconds", type=float, default=15, help="how long each relaunch is filmed and watched")
    p.add_argument("--fixtures", type=Path, help="a folder with the chat-sim fixtures as .ndjson")
    p.add_argument("--web-tree", type=Path, help="build the web bundles from this checkout instead of the ref's")
    p.add_argument("--build-job", help="the fleet app build to copy (a `cmux-ci build cmux` job id); default: the "
                   "nearest finished one at or behind the ref")
    p.add_argument("--onto", default="origin/feat-cmux-next",
                   help="measure the ref's web merged onto this base (default origin/feat-cmux-next; '' for the ref alone)")
    p.add_argument("--keep", action="store_true", help="leave the copy running at the end")
    args = p.parse_args()
    if sys.platform != "darwin":
        raise SystemExit("this opens the app: macOS only")
    sha, pr = resolve_ref(args.ref)
    out = (args.out or Path(tempfile.gettempdir()) / f"relaunch-settled-{sha[:12]}-{time.strftime('%H%M%S')}").resolve()
    out.mkdir(parents=True, exist_ok=True)
    scratch = Path(tempfile.mkdtemp(prefix="relaunch-settled-"))
    build = pick_dev_golden(sha, args.build_job)
    say(f"ref {sha[:12]}{f' (#{pr})' if pr else ''}; golden {build['kind']} {build['commit'][:12]}, "
        f"{build['swift_behind_ref']} commits behind the ref")
    with contextlib.ExitStack() as hold:
        golden = hv.fetch_golden(build, hold)
        side = hv.Side(args.side)
        if side.exists():
            side.stop()
            side.run("remove", timeout=300)
        side.run("make", "--from", str(golden), "--label", "cmux settled", "--neutral-shell", timeout=600)
    copy = Copy(side, out)
    report = {"ref": sha, "pr": pr, "golden": {k: build.get(k) for k in ("kind", "commit", "label", "swift_behind_ref")},
              "host": os.uname().nodename, "rounds": []}
    try:
        copy.admit()
        copy.launch(None, 0)
        if not copy.answers():
            raise SystemExit("the copy never answered on its socket")
        methods = (rpc(copy.socket, "system.identify") or {}).get("methods") or []
        if "debug.agent_pane" not in methods or "debug.updater" not in methods:
            raise SystemExit(f"{hv.describe(build)} has no debug.agent_pane / debug.updater: not a DEV compile")
        web_sha = merged_onto(sha, args.onto) if args.onto else sha
        report["web_ref"] = web_sha
        report["applied"] = apply_ref(copy, sha, pr, args.web_tree, scratch, web_sha)
        say(f"applied: {report['applied']}")
        report["seed"] = seed(copy, fixture_files(args.fixtures, scratch), scratch)
        # Once with the ref's code before any measured round: the copy restarts onto its overlay and new daemon.
        if not copy.quit_for_update():
            raise SystemExit("the copy did not quit through debug.updater relaunch within 60 s")
        copy.launch(None, 0)
        copy.answers()
        if not show_chat(copy, report["seed"]["session"]):
            raise SystemExit("the seeded chat has no tab")
        say("relaunched onto the ref; the seeded chat is shown")
        asked: list = []

        def page_answers() -> bool:  # a page that is not shown yet answers with an error (or not in 20 s): ask again
            asked.append(rpc(copy.socket, "debug.agent_pane", {"action": "layout_watch", "ms": 300}, timeout=20))
            return isinstance(asked[-1], dict) and "frames" in asked[-1]
        try:
            hv.until("the chat page", 120, page_answers)
        except hv.LookError:
            raise SystemExit(f"the chat page never answered layout_watch: {json.dumps(asked[-1:], default=str)[:400]}")
        # The person read it: the transcript drawn (a page that never connects draws no row and would count all
        # zero), at the bottom, settled.
        try:
            hv.until("the transcript's rows", 90, lambda: page_state(copy)["rows"] > 0)
        except hv.LookError:
            state = rpc(copy.socket, "debug.agent_pane", {"action": "chat_state"}) or {}
            raise SystemExit(f"the seeded chat drew no row: connection {str(state.get('connection'))[:200]!r}")
        time.sleep(10)
        before = page_state(copy)
        report["before"] = before
        say(f"before the first quit: {before['rows']} rows, {len(before['disconnected'])} disconnected")
        for n in range(1, args.rounds + 1):
            report["rounds"].append(round_(copy, n, out, args.seconds, before, report["seed"]["session"]))
            time.sleep(5)
    finally:
        (out / "report.json").write_text(json.dumps(report, indent=2))
        if not args.keep:
            with contextlib.suppress(Exception):
                side.stop()
            if copy.budget:
                subprocess.run([copy.budget, "release", "--name", side.name], capture_output=True)
        shutil.rmtree(scratch, ignore_errors=True)
    rows = [r["counters"] for r in report["rounds"]]
    summary = {k: [r[k] for r in rows] for k in COUNTERS}
    print("RELAUNCH-SETTLED-SUMMARY " + json.dumps(summary), flush=True)
    print(f"report: {out / 'report.json'}", flush=True)
    return 0 if all(all(v == 0 for v in vs) for vs in summary.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
