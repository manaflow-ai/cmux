#!/usr/bin/env python3
"""sync-bench: `cmux link sync push` of one large, pinned, real-ish tree to a real machine daemon, by cmux commit.

Every change to the folder copy path (`cmux-tui/crates/cmux-tui/src/link/sync_cli*`) carries before/after numbers
from this one harness, on one host, so they compare (Leo, 2026-11-17: "also, on folders and the big ones, doing
better than just rsync -- what did we figure out? what solulus did we have?").

    sync-bench gen [--layout projects|flat|all]          make the pinned tree once (idempotent, resumable)
    sync-bench run --commit SHA [--scenario a,b,c,d,e]   push it with that commit's cmux, print JSON + a table
                   [--layout projects|flat] [--rtt-ms 0,50] [--binary PATH] [--build] [--drop-caches]
    sync-bench compare BASE HEAD [--layout L] [--rtt-ms N]   the before/after table of two recorded runs
    sync-bench show SHA                                     the recorded table of one run
    sync-bench info                                         the tree's spec, sizes and what is recorded
    sync-bench build --commit SHA [--build]                 fetch or build that commit's binary now, under the lock

The tree (`--layout projects`) is shaped like a person's ~/Projects: a parent folder of several real git
repositories (public ones, pinned by commit, some shallow and some with full history), plus folders that are not
repositories: many small notes, a web app with node_modules and a .env, a Rust scratch crate with target/ (those
three stay on the Mac by the sync's own rules), and a few multi-GB media files. What goes is over 20 GiB and several
hundred thousand files. `--layout flat` is one huge folder that is not a repository (its large files are hard links
of the projects tree's, so it costs little disk). Everything generated is seeded, and repositories are fetched at
pinned commits, so two hosts make the same tree (git's pack files may differ byte for byte; their objects do not).

The machine is a real headless `cmux server` daemon with a Cloud machine's identity, so it serves `fs-v1` as a
Cloud VM's daemon does. A release binary trusts only a root-owned `/etc/cmux/image-stamp`; the daemon runs in a
private mount namespace whose `/etc` is an overlay with that stamp in its upper layer, so the host's own `/etc` is
never touched. `--rtt-ms N` puts a link between the push and the daemon: a veth pair into a network namespace with
`tc netem` delaying each way N/2 ms, the push's socket relayed over TCP across it (socat), as a Mac's link to a
Cloud machine is a TCP connection.

Scenarios, each a separate `cmux link sync push` with `CMUX_SYNC_PUSH_TIMINGS=1`:
    a  cold: the whole tree into an empty machine folder, `--allow-large`
    b  again, nothing changed
    c  again after touching 10 files (mtime only) and editing 10 (content), restored afterwards
    d  the default path: no `--allow-large`, a fresh Mac record and machine folder (the first pass)
    e  through `--store` (needs SYNC_BENCH_STORE=PLATFORM and SYNC_BENCH_STORE_CREDENTIAL=FILE; else not run)

Runs hold an flock on ROOT/lock, so concurrent callers queue instead of skewing each other. Results go to
ROOT/results/<commit>/<layout>-rtt<N>.json (ROOT: $SYNC_BENCH_ROOT, default /var/tmp/sync-bench).

The binary for a commit is CI's published cmux-tui build (leo-workspace tools/cmux-cli --commit SHA --path; a
same-repository PR head publishes its own when its push changes cmux-tui), else, with --build or when nothing is
published, it is built here from that commit (`cargo build --release`), fetched from GitHub by sha (a PR head is
fetchable once pushed). Linux only.
"""
from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import random
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(os.environ.get("SYNC_BENCH_ROOT", "/var/tmp/sync-bench"))
CMUX_CLI = Path(os.environ.get("SYNC_BENCH_CMUX_CLI", os.path.expanduser("~/Projects/leo-workspace/tools/cmux-cli")))
CMUX_REPO = "https://github.com/manaflow-ai/cmux"
HEX40 = re.compile(r"[0-9a-f]{40}")
GIB = 1 << 30
MIB = 1 << 20
# Every generated file's mtime, so two generations stat the same.
EPOCH = 1_760_000_000

# The tree's spec. Changing anything here changes TREE_ID, and results of different trees never compare.
TREE_VERSION = 1
# (folder, url, commit, depth): depth 1 is a shallow fetch of that commit, None its full history.
REPOS = [
    ("linux", "https://github.com/torvalds/linux", "666539eecdf4db623f5e3c3e55cf9f2dfad24aa4", 1),
    ("llvm-project", "https://github.com/llvm/llvm-project", "2c77a8e818440a3696a0bf7d166ca10f15a9a02e", 1),
    ("rust", "https://github.com/rust-lang/rust", "7873354ea3ad96068868ba5f6dc8bdbaf843a09a", 1),
    ("kubernetes", "https://github.com/kubernetes/kubernetes", "dcd224ac7917b36275dc23d710de22902f49df82", None),
    ("git", "https://github.com/git/git", "e1ec09b23c8e0deb21a0b95ac5996422277395d4", None),
]
# Incompressible media (name, bytes), under projects/design-assets.
MEDIA = (
    [(f"footage/take-{i:02d}.mov", 4 * GIB) for i in range(3)]
    + [(f"exports/archive-{i:02d}.zip", 1 * GIB) for i in range(4)]
    + [(f"renders/frame-{i:04d}.png", 2 * MIB) for i in range(200)]
)
NOTES = 40_000  # projects/notes: small text files
WEB_SRC = 3_000  # projects/web-app/src
WEB_DEPS = 20_000  # projects/web-app/node_modules: stays on the Mac
RUST_TARGET = 3_000  # projects/scratch-rust/target: stays on the Mac
FLAT_SMALL = 250_000  # flat/huge-folder: small files
FLAT_MID = [(f"datasets/shard-{i:03d}.bin", 64 * MIB) for i in range(50)]
SCENARIOS = "abcde"
CHANGED = 10  # scenario c: files touched, and files edited


def tree_id():
    spec = json.dumps([TREE_VERSION, REPOS, MEDIA, NOTES, WEB_SRC, WEB_DEPS, RUST_TARGET, FLAT_SMALL, FLAT_MID])
    return hashlib.sha256(spec.encode()).hexdigest()[:12]


def log(*parts):
    print("sync-bench:", *parts, file=sys.stderr, flush=True)


def run(cmd, **kw):
    kw.setdefault("check", True)
    return subprocess.run(cmd, **kw)


# ---------------------------------------------------------------- generation


WORDS = (
    "value index buffer request answer socket parent entry machine folder revision listing budget progress "
    "manifest summary chunk store cache link daemon push pull merge branch commit stage tree blob hash file"
).split()


def text_bytes(rng: random.Random, size: int) -> bytes:
    """About `size` bytes of prose-and-code-like text, compressing like real notes (about 3-4x)."""
    out, n = [], 0
    while n < size:
        line = " ".join(rng.choice(WORDS) for _ in range(rng.randint(4, 14)))
        if rng.random() < 0.3:
            line = f"fn {rng.choice(WORDS)}_{rng.randint(0, 9999)}(x: u64) -> u64 {{ x + {rng.randint(0, 999)} }}"
        out.append(line)
        n += len(line) + 1
    return ("\n".join(out) + "\n").encode()[:max(size, 1)]


def small_size(rng: random.Random) -> int:
    """A small file's size: mostly a few KB, a long tail to ~200 KB."""
    return min(int(rng.lognormvariate(8.0, 1.1)), 200_000) + 16


def write_small_files(top: Path, count: int, seed: int, dirs: int, exts=(".md", ".txt", ".rs", ".py", ".json")):
    rng = random.Random(seed)
    for i in range(count):
        d = top / f"d{(i % dirs):04d}" / f"s{(i // dirs) % 7}"
        d.mkdir(parents=True, exist_ok=True)
        path = d / f"f{i:06d}{exts[i % len(exts)]}"
        path.write_bytes(text_bytes(rng, small_size(rng)))
        os.utime(path, (EPOCH, EPOCH))


def write_noise(path: Path, size: int):
    """`size` incompressible bytes, the same for the same path: AES-CTR of zeros keyed by the path."""
    path.parent.mkdir(parents=True, exist_ok=True)
    key = hashlib.sha256(f"sync-bench/{TREE_VERSION}/{path.name}".encode()).hexdigest()[:32]
    tmp = path.with_name(path.name + ".part")
    with open(tmp, "wb") as out:
        enc = subprocess.Popen(
            ["openssl", "enc", "-aes-128-ctr", "-nosalt", "-K", key, "-iv", "0" * 32, "-in", "/dev/zero"],
            stdout=subprocess.PIPE,
        )
        left = size
        while left:
            chunk = enc.stdout.read(min(left, 8 * MIB))
            if not chunk:
                raise SystemExit(f"sync-bench: openssl ended early writing {path}")
            out.write(chunk)
            left -= len(chunk)
        enc.kill()
        enc.wait()
    os.utime(tmp, (EPOCH, EPOCH))
    os.replace(tmp, path)


def fetch_repo(dest: Path, url: str, commit: str, depth):
    git = ["git", "-C", str(dest), "-c", "advice.detachedHead=false"]
    dest.mkdir(parents=True, exist_ok=True)
    run(["git", "init", "-q", "-b", "main", str(dest)])
    run(git + ["remote", "remove", "origin"], check=False, stderr=subprocess.DEVNULL)
    run(git + ["remote", "add", "origin", url])
    run(git + ["fetch", "-q", "--no-tags"] + (["--depth", str(depth)] if depth else []) + ["origin", commit])
    run(git + ["checkout", "-q", "-B", "main", commit])
    run(git + ["config", "user.name", "sync-bench"])
    run(git + ["config", "user.email", "sync-bench@example.com"])


def step(marker: Path, what: str, make):
    """Runs `make` once: `marker` records it done, so an interrupted generation resumes at the next step."""
    if marker.exists():
        return
    log("making", what)
    started = time.time()
    make()
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.write_text(f"{time.time() - started:.0f}s\n")
    log(f"made {what} in {time.time() - started:.0f}s")


def gen_projects(trees: Path, marks: Path):
    top = trees / "projects"
    for name, url, commit, depth in REPOS:
        step(marks / f"repo-{name}", f"repo {name} at {commit[:12]}", lambda: fetch_repo(top / name, url, commit, depth))
    step(marks / "notes", f"{NOTES} notes", lambda: write_small_files(top / "notes", NOTES, 1, 400))

    def web():
        write_small_files(top / "web-app/src", WEB_SRC, 2, 60, (".ts", ".tsx", ".css", ".json"))
        write_small_files(top / "web-app/node_modules", WEB_DEPS, 3, 800, (".js", ".d.ts", ".json"))
        (top / "web-app/package.json").write_text('{"name": "web-app", "private": true}\n')
        (top / "web-app/.env").write_text("API_TOKEN=not-a-real-token\n")

    step(marks / "web-app", "web-app", web)

    def scratch():
        (top / "scratch-rust/src").mkdir(parents=True, exist_ok=True)
        (top / "scratch-rust/Cargo.toml").write_text('[package]\nname = "scratch"\nversion = "0.1.0"\n')
        (top / "scratch-rust/src/main.rs").write_text('fn main() { println!("hi"); }\n')
        write_small_files(top / "scratch-rust/target", RUST_TARGET, 4, 100, (".rlib", ".d", ".o"))

    step(marks / "scratch-rust", "scratch-rust", scratch)
    for name, size in MEDIA:
        step(marks / f"media-{name.replace('/', '_')}", f"media {name}", lambda n=name, s=size: write_noise(top / "design-assets" / n, s))


def gen_flat(trees: Path, marks: Path):
    top = trees / "flat/huge-folder"
    step(marks / "flat-small", f"{FLAT_SMALL} flat files", lambda: write_small_files(top / "files", FLAT_SMALL, 5, 2500))
    for name, size in FLAT_MID:
        step(marks / f"flat-{name.replace('/', '_')}", f"flat {name}", lambda n=name, s=size: write_noise(top / n, s))

    def links():
        for name, _ in MEDIA:
            if name.startswith("renders/"):
                continue
            src, dst = trees / "projects/design-assets" / name, top / "media" / name
            dst.parent.mkdir(parents=True, exist_ok=True)
            if not dst.exists():
                os.link(src, dst)

    step(marks / "flat-media-links", "flat media (hard links of projects/design-assets)", links)


def edit_set(layout: str):
    """The files scenario c touches and edits: fixed paths, half in repositories when the layout has them."""
    if layout == "projects":
        touch = [f"notes/d{i:04d}/s0/f{i:06d}{('.md', '.txt', '.rs', '.py', '.json')[i % 5]}" for i in (1, 2, 3, 4, 5)]
        touch += ["linux/Makefile", "linux/README", "kubernetes/README.md", "rust/README.md", "git/README.md"]
        edit = [f"notes/d{i:04d}/s0/f{i:06d}{('.md', '.txt', '.rs', '.py', '.json')[i % 5]}" for i in (11, 12, 13, 14, 15)]
        edit += ["linux/MAINTAINERS", "llvm-project/README.md", "kubernetes/go.mod", "rust/Cargo.toml", "git/Makefile"]
    else:
        names = [f"files/d{i:04d}/s0/f{i:06d}{('.md', '.txt', '.rs', '.py', '.json')[i % 5]}" for i in range(1, 21)]
        touch, edit = names[:CHANGED], names[CHANGED:]
    return touch, edit


def layout_dir(layout: str) -> Path:
    return ROOT / "trees" / ("projects" if layout == "projects" else "flat/huge-folder")


def cmd_gen(args):
    trees, marks = ROOT / "trees", ROOT / "marks" / tree_id()
    with bench_lock("gen"):
        if args.layout in ("projects", "all", "flat"):  # flat links projects' media
            gen_projects(trees, marks)
        if args.layout in ("flat", "all"):
            gen_flat(trees, marks)
    (ROOT / "tree-id").write_text(tree_id() + "\n")
    log("tree", tree_id(), "ready")


# ---------------------------------------------------------------- the lock


@contextlib.contextmanager
def bench_lock(what: str):
    ROOT.mkdir(parents=True, exist_ok=True)
    fd = os.open(ROOT / "lock", os.O_RDWR | os.O_CREAT, 0o666)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            holder = (ROOT / "lock.holder").read_text().strip() if (ROOT / "lock.holder").exists() else "?"
            log(f"waiting for the bench lock (held by: {holder})")
            fcntl.flock(fd, fcntl.LOCK_EX)
        (ROOT / "lock.holder").write_text(f"{what} pid {os.getpid()} since {time.strftime('%H:%M:%SZ', time.gmtime())}\n")
        yield
    finally:
        os.close(fd)


# ---------------------------------------------------------------- the binary


def binary_for(commit: str, build: bool) -> tuple[Path, str]:
    """The cmux binary of `commit` and where it came from."""
    if not build:
        env = dict(os.environ, CMUX_CLI_CACHE=str(ROOT / "bin"))
        got = subprocess.run([sys.executable, str(CMUX_CLI), "--commit", commit, "--path"], env=env,
                             capture_output=True, text=True)
        if got.returncode == 0 and got.stdout.strip():
            info = subprocess.run([sys.executable, str(CMUX_CLI), "--commit", commit, "--info"], env=env,
                                  capture_output=True, text=True)
            source = "ci"
            with contextlib.suppress(ValueError):
                built = json.loads(info.stdout)["commit"]
                source = f"ci (published for {built[:12]})" if built != commit else "ci"
            return Path(got.stdout.strip().splitlines()[-1]), source
        log(f"no published build for {commit[:12]} ({(got.stderr or got.stdout).strip()[-200:]}); building it here")
    return build_here(commit), "built on the bench host (cargo build --release, glibc)"


def build_here(commit: str) -> Path:
    out = ROOT / "bin" / f"{commit}-built" / "cmux"
    if out.exists():
        return out
    src = ROOT / "src"
    if not (src / ".git").exists():
        run(["git", "init", "-q", str(src)])
        run(["git", "-C", str(src), "remote", "add", "origin", CMUX_REPO])
    run(["git", "-C", str(src), "fetch", "-q", "--depth", "1", "origin", commit])
    run(["git", "-C", str(src), "checkout", "-q", "--force", commit])
    # ghostty-vt-sys builds libghostty-vt from the ghostty-next submodule with the repository's pinned zig.
    run(["git", "-C", str(src), "submodule", "update", "--init", "--depth", "1", "ghostty-next"])
    zig_env = ROOT / "bin" / f".zig-{commit}.env"
    zig_env.parent.mkdir(parents=True, exist_ok=True)
    zig_env.write_text("")
    run(["bash", str(src / "scripts/install-zig-ci.sh")], cwd=src,
        env=dict(os.environ, ZIG_FORCE_LOCAL_INSTALL="1", GITHUB_ENV=str(zig_env)))
    zig = dict(line.split("=", 1) for line in zig_env.read_text().splitlines() if "=" in line).get("CMUX_ZIG")
    zig_env.unlink()
    env = dict(os.environ, CARGO_TARGET_DIR=str(ROOT / "target"), **({"CMUX_ZIG": zig} if zig else {}))
    run(["cargo", "build", "--release", "-p", "cmux-tui", "--bin", "cmux-tui"], cwd=src / "cmux-tui", env=env)
    out.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / "target/release/cmux-tui", out)
    return out


# ---------------------------------------------------------------- the machine and the link


class Machine:
    """A headless cmux daemon with a Cloud machine's identity, in a private mount namespace (module docs)."""

    def __init__(self, binary: Path, work: Path):
        self.binary, self.work = binary, work
        self.home = work / "vm/home"
        self.sockets = Path(f"/tmp/sbm-{os.getpid()}")
        self.socket = self.sockets / "m.sock"
        self.session = f"sync-bench-{os.getpid()}"

    def start(self):
        for sub in ("vm/home/work", "vm/state"):
            (self.work / sub).mkdir(parents=True, exist_ok=True)
        self.sockets.mkdir(mode=0o700, exist_ok=True)
        etc_up, etc_work = ROOT / "etc/upper", ROOT / "etc/work"
        if not (etc_up / "cmux/image-stamp").exists():
            run(["sudo", "mkdir", "-p", str(etc_up / "cmux"), str(etc_work)])
            for name, text in (("image-stamp", "cmux-vm inputs=sync-bench\n"), ("vm-kind", "owner\n")):
                run(["sudo", "tee", str(etc_up / "cmux" / name)], input=text.encode(), stdout=subprocess.DEVNULL)
            run(["sudo", "chown", "-R", "root:root", str(ROOT / "etc")])
            run(["sudo", "chmod", "755", str(ROOT / "etc"), str(etc_up), str(etc_up / "cmux")])
            run(["sudo", "sh", "-c", f"chmod 644 {etc_up}/cmux/*"])
        inner = (
            f"mount -t overlay overlay -o lowerdir=/etc,upperdir={etc_up},workdir={etc_work} /etc && "
            f"exec setpriv --reuid={os.getuid()} --regid={os.getgid()} --init-groups env "
            f"HOME={self.home} CMUX_TUI_STATE_DIR={self.work}/vm/state CMUX_TUI_CONFIG={self.work}/vm/config.json "
            f"CMUX_VM_ID=vm-sync-bench CMUX_CODEROUTER_URL=http://127.0.0.1:9 "
            f"{self.binary} server ensure --json --session {self.session} --socket {self.socket}"
        )
        run(["sudo", "unshare", "--mount", "--propagation", "private", "--", "sh", "-c", inner],
            stdout=subprocess.DEVNULL)

    def stop(self):
        subprocess.run([str(self.binary), "server", "stop", "--json", "--session", self.session, "--socket",
                        str(self.socket)], capture_output=True)
        shutil.rmtree(self.sockets, ignore_errors=True)


NETNS, VETH_HOST, VETH_NS = "sync-bench", "sbench0", "sbench1"
HOST_IP, NS_IP, PORT = "10.213.77.1", "10.213.77.2", 7713


class Link:
    """`rtt_ms` of round trip between the push and the daemon (module docs); 0 is the bare socket."""

    def __init__(self, rtt_ms: int, target: Path, rate_mbit: int = 0):
        self.rtt_ms, self.target, self.rate_mbit = rtt_ms, target, rate_mbit
        self.socket = target.parent / "link.sock"
        self.procs: list[subprocess.Popen] = []

    def __enter__(self):
        if not self.rtt_ms:
            return self.target
        self.down()
        ns = ["sudo", "ip", "netns", "exec", NETNS]
        run(["sudo", "ip", "netns", "add", NETNS])
        run(["sudo", "ip", "link", "add", VETH_HOST, "type", "veth", "peer", "name", VETH_NS])
        run(["sudo", "ip", "link", "set", VETH_NS, "netns", NETNS])
        run(["sudo", "ip", "addr", "add", f"{HOST_IP}/30", "dev", VETH_HOST])
        run(["sudo", "ip", "link", "set", VETH_HOST, "up"])
        run(ns + ["ip", "addr", "add", f"{NS_IP}/30", "dev", VETH_NS])
        run(ns + ["ip", "link", "set", VETH_NS, "up"])
        run(ns + ["ip", "link", "set", "lo", "up"])
        half = f"{self.rtt_ms / 2:g}ms"
        shape = ["netem", "delay", half, "limit", "200000"] + (["rate", f"{self.rate_mbit}mbit"] if self.rate_mbit else [])
        run(["sudo", "tc", "qdisc", "add", "dev", VETH_HOST, "root"] + shape)
        run(ns + ["tc", "qdisc", "add", "dev", VETH_NS, "root"] + shape)
        self.procs.append(subprocess.Popen(
            ["socat", f"TCP-LISTEN:{PORT},bind={HOST_IP},reuseaddr,fork", f"UNIX-CONNECT:{self.target}"],
            stderr=subprocess.DEVNULL))
        self.procs.append(subprocess.Popen(
            ns + ["setpriv", f"--reuid={os.getuid()}", f"--regid={os.getgid()}", "--init-groups", "socat",
                  f"UNIX-LISTEN:{self.socket},fork,mode=600", f"TCP:{HOST_IP}:{PORT}"],
            stderr=subprocess.DEVNULL, start_new_session=True))
        for _ in range(100):
            if self.socket.exists():
                break
            time.sleep(0.05)
        return self.socket

    def __exit__(self, *exc):
        for proc in self.procs:
            # The netns side runs under sudo: signal its process group, which this harness started.
            with contextlib.suppress(ProcessLookupError, PermissionError):
                if proc.args[0] == "sudo":
                    subprocess.run(["sudo", "kill", "--", f"-{proc.pid}"], capture_output=True)
                else:
                    proc.terminate()
            with contextlib.suppress(subprocess.TimeoutExpired):
                proc.wait(timeout=5)
        self.procs.clear()
        if self.rtt_ms:
            self.down()
        with contextlib.suppress(FileNotFoundError):
            self.socket.unlink()

    @staticmethod
    def down():
        subprocess.run(["sudo", "ip", "link", "del", VETH_HOST], capture_output=True)
        subprocess.run(["sudo", "ip", "netns", "del", NETNS], capture_output=True)


# ---------------------------------------------------------------- one push


def push(binary: Path, socket: Path, local: Path, remote: Path, state: Path, extra=(), stdin=None) -> dict:
    env = dict(os.environ, CMUX_SYNC_PUSH_TIMINGS="1", CMUX_TUI_STATE_DIR=str(state))
    cmd = [str(binary), "link", "sync", "push", "--socket", str(socket), *extra, str(local), str(remote)]
    logs = state.parent / "push-logs"
    logs.mkdir(parents=True, exist_ok=True)
    out_path, err_path, in_path = logs / "stdout", logs / "stderr", logs / "stdin"
    in_path.write_bytes(stdin or b"")
    with open(out_path, "wb") as out, open(err_path, "wb") as err, open(in_path, "rb") as given:
        started = time.monotonic()
        child = subprocess.Popen(cmd, env=env, stdin=given, stdout=out, stderr=err)
        # wait4: this push's own CPU and peak RSS (with the git it waited for), not every child's so far.
        _, status, usage = os.wait4(child.pid, 0)
        wall = time.monotonic() - started
        child.returncode = os.waitstatus_to_exitcode(status)
    in_path.unlink()
    proc = subprocess.CompletedProcess(cmd, child.returncode, out_path.read_bytes(), err_path.read_bytes())
    summary, timings, progress = None, None, None
    with contextlib.suppress(ValueError, IndexError):
        summary = json.loads(proc.stdout.decode().strip().splitlines()[-1])
    for line in proc.stderr.decode(errors="replace").splitlines():
        with contextlib.suppress(ValueError):
            obj = json.loads(line)
            if isinstance(obj, dict) and "timings" in obj:
                timings = obj["timings"]
            elif isinstance(obj, dict) and "progress" in obj:
                progress = obj["progress"]
    row = {
        "exit": proc.returncode,
        "wall_ms": round(wall * 1000),
        "cpu_ms": round((usage.ru_utime + usage.ru_stime) * 1000),
        "max_rss_mb": round(usage.ru_maxrss / 1024),  # KB on Linux
        "summary": summary,
        "timings": timings,
        "progress": progress,
    }
    if proc.returncode:
        row["stderr_tail"] = proc.stderr.decode(errors="replace")[-2000:]
        row["stdout_tail"] = proc.stdout.decode(errors="replace")[-2000:]
    if summary:
        summary.pop("skipped_files", None)  # names only; counts stay in skipped_counts
    return row


@contextlib.contextmanager
def changed(top: Path, layout: str):
    """Scenario c's touches and edits, put back afterwards (bytes and mtimes), so the tree stays the spec's."""
    touch, edit = edit_set(layout)
    saved = {}
    for rel in touch + edit:
        path = top / rel
        st = path.stat()
        saved[rel] = (path.read_bytes() if rel in edit else None, st.st_atime_ns, st.st_mtime_ns)
    now = time.time()
    for rel in touch:
        os.utime(top / rel, (now, now))
    for rel in edit:
        with open(top / rel, "ab") as f:
            f.write(b"\n// sync-bench edit\n")
    try:
        yield len(touch), len(edit)
    finally:
        for rel, (data, atime, mtime) in saved.items():
            if data is not None:
                (top / rel).write_bytes(data)
            os.utime(top / rel, ns=(atime, mtime))


def store_args():
    platform, cred = os.environ.get("SYNC_BENCH_STORE"), os.environ.get("SYNC_BENCH_STORE_CREDENTIAL")
    if not platform or not cred or not Path(cred).is_file():
        return None, ("no dev store endpoint and credential: set SYNC_BENCH_STORE=PLATFORM_URL and "
                      "SYNC_BENCH_STORE_CREDENTIAL=FILE (a dev cmux credential); /v1/sync answers only where "
                      "the platform has its store bucket bound")
    return (["--store", platform], Path(cred).read_bytes()), None


def run_layout(binary: Path, layout: str, rtt_ms: int, scenarios: str, drop_caches: bool, rate_mbit: int) -> dict:
    top = layout_dir(layout)
    if not top.is_dir():
        raise SystemExit(f"sync-bench: no {layout} tree at {top}: run `sync-bench gen --layout {layout}` first")
    work = ROOT / "work"
    shutil.rmtree(work, ignore_errors=True)
    machine = Machine(binary, work)
    rows: dict = {}
    machine.start()
    try:
        with Link(rtt_ms, machine.socket, rate_mbit) as socket:
            remote = machine.home / "work" / layout
            state = work / "mac-state"
            if drop_caches:
                run(["sudo", "sh", "-c", "sync; echo 3 > /proc/sys/vm/drop_caches"])
            if "a" in scenarios:
                log(f"{layout} rtt {rtt_ms}: a (cold, --allow-large)")
                rows["a"] = push(binary, socket, top, remote, state, ["--allow-large"])
            if "b" in scenarios:
                log(f"{layout} rtt {rtt_ms}: b (nothing changed)")
                rows["b"] = push(binary, socket, top, remote, state, ["--allow-large"])
            if "c" in scenarios:
                with changed(top, layout) as (touched, edited):
                    log(f"{layout} rtt {rtt_ms}: c ({touched} touched, {edited} edited)")
                    rows["c"] = push(binary, socket, top, remote, state, ["--allow-large"])
            shutil.rmtree(remote, ignore_errors=True)
            if "d" in scenarios:
                log(f"{layout} rtt {rtt_ms}: d (default path, first pass)")
                rows["d"] = push(binary, socket, top, machine.home / "work" / f"{layout}-d", work / "mac-state-d")
            if "e" in scenarios:
                got, why = store_args()
                if got is None:
                    rows["e"] = {"not_run": why}
                else:
                    log(f"{layout} rtt {rtt_ms}: e (--store)")
                    rows["e"] = push(binary, socket, top, machine.home / "work" / f"{layout}-e", work / "mac-state-e",
                                     got[0] + ["--allow-large"], stdin=got[1])
    finally:
        machine.stop()
        shutil.rmtree(work, ignore_errors=True)
    return rows


def host_facts() -> dict:
    facts = {"host": os.uname().nodename, "cpus": os.cpu_count()}
    with contextlib.suppress(OSError):
        facts["cpu"] = next(l.split(":", 1)[1].strip() for l in open("/proc/cpuinfo") if l.startswith("model name"))
    with contextlib.suppress(OSError):
        facts["mem_gb"] = round(int(next(l.split()[1] for l in open("/proc/meminfo") if l.startswith("MemTotal"))) / 1e6)
    facts["load"] = os.getloadavg()
    return facts


def cmd_run(args):
    commit = args.commit
    if not HEX40.fullmatch(commit):
        raise SystemExit("sync-bench: --commit takes a full 40-character sha")
    scenarios = "".join(s for s in args.scenario.replace(",", "") if s in SCENARIOS) or SCENARIOS
    rtts = [int(x) for x in str(args.rtt_ms).split(",") if x != ""]
    layouts = ["projects", "flat"] if args.layout == "all" else [args.layout]
    with bench_lock(f"run {commit[:12]} {''.join(layouts)} rtt {rtts}"):
        binary, source = (Path(args.binary), "given") if args.binary else binary_for(commit, args.build)
        for layout in layouts:
            for rtt in rtts:
                started = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
                facts = host_facts()
                rows = run_layout(binary, layout, rtt, scenarios, args.drop_caches, args.rate_mbit)
                record = {
                    "commit": commit, "binary": str(binary), "binary_source": source, "layout": layout,
                    "rtt_ms": rtt, "rate_mbit": args.rate_mbit, "tree": tree_id(), "started": started,
                    "drop_caches": args.drop_caches, "host": facts, "scenarios": rows,
                }
                out = result_path(commit, layout, rtt)
                out.parent.mkdir(parents=True, exist_ok=True)
                old = load(out) if out.exists() else None
                if old and old.get("tree") == record["tree"]:
                    # A rerun of some scenarios keeps the others' rows.
                    record["scenarios"] = {**old.get("scenarios", {}), **rows}
                out.write_text(json.dumps(record, indent=1) + "\n")
                print(json.dumps(record))
                print(table(record), file=sys.stderr)


# ---------------------------------------------------------------- results


def result_path(commit: str, layout: str, rtt: int) -> Path:
    return ROOT / "results" / commit / f"{layout}-rtt{rtt}.json"


def load(path: Path) -> dict:
    return json.loads(path.read_text())


def resolve(commit: str) -> str:
    """A recorded commit by its full sha or a unique prefix."""
    if (ROOT / "results" / commit).is_dir():
        return commit
    found = [d.name for d in (ROOT / "results").glob(f"{commit}*") if d.is_dir()]
    if len(found) != 1:
        raise SystemExit(f"sync-bench: {len(found)} recorded runs match {commit!r}")
    return found[0]


NAMES = {"a": "a cold whole", "b": "b nothing changed", "c": "c 10 touched + 10 edited", "d": "d default (first pass)",
         "e": "e --store"}


def secs(ms) -> str:
    return "-" if ms is None else f"{ms / 1000:.1f}"


def gib(n) -> str:
    return "-" if n is None else f"{n / GIB:.2f}"


def row_cells(row: dict) -> list[str]:
    if "not_run" in row:
        return ["not run"] + ["-"] * 11
    s, t = row.get("summary") or {}, row.get("timings") or {}
    status = "ok" if row.get("exit") == 0 else f"exit {row.get('exit')}"
    left = (s.get("skipped_counts") or {}).get("left_on_mac")
    return [status, secs(row.get("wall_ms")), *(secs(t.get(k)) for k in ("list", "hash", "prepare", "small", "large", "finish")),
            str(s.get("written", "-")), str(s.get("unchanged", "-")), gib(s.get("bytes")),
            f"{secs(row.get('cpu_ms'))} / {row.get('max_rss_mb', '-')}" + (f" (left {left})" if left else "")]


def table(record: dict) -> str:
    head = (f"{record['layout']} tree {record['tree']}, rtt {record['rtt_ms']} ms, cmux {record['commit'][:12]} "
            f"({record['binary_source']}), {record['host'].get('host')} {record['started']}")
    lines = [head, "",
             "| scenario | result | wall s | list | hash | prepare | small | large | finish | written | unchanged | GiB written | cpu s / max RSS MB |",
             "|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for key in SCENARIOS:
        if key in record["scenarios"]:
            lines.append("| " + " | ".join([NAMES[key], *row_cells(record["scenarios"][key])]) + " |")
    return "\n".join(lines)


def ratio(base, head) -> str:
    if not base or head is None:
        return "-"
    return f"{head / base:.2f}x"


def compare(base: dict, head: dict) -> str:
    if base.get("tree") != head.get("tree"):
        return f"different trees ({base.get('tree')} vs {head.get('tree')}): not comparable"
    lines = [f"{base['layout']} tree {base['tree']}, rtt {base['rtt_ms']} ms: base {base['commit'][:12]} vs head "
             f"{head['commit'][:12]}", "",
             "| scenario | base wall s | head wall s | head/base | base hash s | head hash s | base cpu s | head cpu s | written base/head |",
             "|---|---|---|---|---|---|---|---|---|"]
    for key in SCENARIOS:
        b, h = base["scenarios"].get(key), head["scenarios"].get(key)
        if not b or not h:
            continue
        if "not_run" in b or "not_run" in h:
            lines.append(f"| {NAMES[key]} | not run | not run | - | - | - | - | - | - |")
            continue
        bw, hw = b.get("wall_ms"), h.get("wall_ms")
        bt, ht = b.get("timings") or {}, h.get("timings") or {}
        bs, hs = b.get("summary") or {}, h.get("summary") or {}
        lines.append(f"| {NAMES[key]} | {secs(bw)} | {secs(hw)} | {ratio(bw, hw)} | {secs(bt.get('hash'))} | "
                     f"{secs(ht.get('hash'))} | {secs(b.get('cpu_ms'))} | {secs(h.get('cpu_ms'))} | "
                     f"{bs.get('written', '-')}/{hs.get('written', '-')} |")
    return "\n".join(lines)


def cmd_compare(args):
    base, head = resolve(args.base), resolve(args.head)
    outs = []
    for path in sorted((ROOT / "results" / base).glob("*.json")):
        if args.layout and not path.name.startswith(args.layout + "-"):
            continue
        if args.rtt_ms is not None and not path.name.endswith(f"-rtt{args.rtt_ms}.json"):
            continue
        other = ROOT / "results" / head / path.name
        if other.exists():
            outs.append(compare(load(path), load(other)))
    if not outs:
        raise SystemExit("sync-bench: no layout/rtt both commits recorded")
    print("\n\n".join(outs))


def cmd_show(args):
    commit = resolve(args.commit)
    for path in sorted((ROOT / "results" / commit).glob("*.json")):
        print(table(load(path)) + "\n")


def cmd_build(args):
    if not HEX40.fullmatch(args.commit):
        raise SystemExit("sync-bench: --commit takes a full 40-character sha")
    # Under the lock: a cargo build beside a run would skew its numbers.
    with bench_lock(f"build {args.commit[:12]}"):
        binary, source = binary_for(args.commit, args.build)
    print(json.dumps({"commit": args.commit, "binary": str(binary), "binary_source": source}))


def cmd_info(_args):
    print(json.dumps({"root": str(ROOT), "tree": tree_id(), "repos": REPOS,
                      "media_gib": round(sum(s for _, s in MEDIA) / GIB, 2),
                      "recorded": sorted(d.name for d in (ROOT / "results").glob("*") if d.is_dir())}, indent=1))


def main(argv=None):
    p = argparse.ArgumentParser(prog="sync-bench", description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("gen")
    g.add_argument("--layout", choices=["projects", "flat", "all"], default="all")
    r = sub.add_parser("run")
    r.add_argument("--commit", required=True)
    r.add_argument("--scenario", default=SCENARIOS)
    r.add_argument("--layout", choices=["projects", "flat", "all"], default="projects")
    r.add_argument("--rtt-ms", default="0")
    r.add_argument("--rate-mbit", type=int, default=0)
    r.add_argument("--binary")
    r.add_argument("--build", action="store_true")
    r.add_argument("--drop-caches", action="store_true")
    c = sub.add_parser("compare")
    c.add_argument("base")
    c.add_argument("head")
    c.add_argument("--layout")
    c.add_argument("--rtt-ms", type=int)
    s = sub.add_parser("show")
    s.add_argument("commit")
    sub.add_parser("info")
    b = sub.add_parser("build")
    b.add_argument("--commit", required=True)
    b.add_argument("--build", action="store_true")
    args = p.parse_args(argv)
    {"gen": cmd_gen, "run": cmd_run, "compare": cmd_compare, "show": cmd_show, "info": cmd_info,
     "build": cmd_build}[args.cmd](args)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    main()
