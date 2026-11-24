#!/usr/bin/env python3
"""RFD 0065's serve/link/mount and clone matrix, on one harness (RFD 0065 piece 14).

    measure.py projection TREE [--mode folder|plain] [--steps ls,rg,gitstatus] [--profile NAME | --rtt-ms N --mbps M]
                               [--bin SLICE_BENCH] [--build] [--out DIR] [--label NAME]
    measure.py git REPO [--branch B] [--options depth1,blobnone,sparse,gitzst,overlay] [--cone DIR,DIR]
                        [--out DIR] [--label NAME]
    measure.py table DIR|ROWS.jsonl [--profiles a,b] [--markdown]
    measure.py profiles

projection: `slice_bench serve TREE`, `slice_bench link --rtt-ms N [--mbps M] --stats FILE` (byte and ask
counter), `slice_bench mount` (the real FUSE overlay over the real wire), then per step a cold run (a fresh
mount and state dir, page cache dropped when `sudo -n` works) and a warm repeat. plain: the same steps on TREE
itself, the baseline. git: clone options against a local `git daemon` serving REPO, with a clean HOME;
bytes are the growth of `.git/objects/pack`, so they are what any link must carry.

Every row goes to DIR/rows.jsonl (one JSON object a line) and the run prints the table: TSV, or Markdown with
--markdown. A row measured on an uncapped local link gets a projected-seconds column per link profile (RFD
0067): local seconds + bytes down / rate + asks x RTT. Commands are RFD 0065's projection-measure.md and
git-measure.md. Stdlib only; Linux.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]

# Link profiles from RFD 0067 (Freestyle VM, 2026-11-23). rate in MB/s (1e6 bytes), rtt in ms.
PROFILES: dict[str, dict] = {
    "github-v4-bad": {"rate": 0.14, "rtt": 67, "what": "GitHub, one IPv4 stream, the path's bad hour"},
    "github-v4-good": {"rate": 0.47, "rtt": 67, "what": "GitHub, one IPv4 stream, an hour later"},
    "store-v6-1-low": {"rate": 22.0, "rtt": 5, "what": "our store, one IPv6 stream, low end"},
    "store-v6-1-high": {"rate": 43.0, "rtt": 5, "what": "our store, one IPv6 stream, high end"},
    "store-v6-8": {"rate": 131.0, "rtt": 5, "what": "our store, 8 IPv6 streams (131-139 MB/s)"},
}
DEFAULT_TABLE_PROFILES = ("github-v4-bad", "store-v6-1-low", "store-v6-8")

STEPS = {
    "ls": "find . | wc -l",
    "rg": "rg -c the . >/dev/null; true",
    "gitstatus": "git status --porcelain | wc -l",
}

COLUMNS = ("kind", "label", "mode", "profile", "phase", "wall_s", "down_bytes", "up_bytes", "asks", "git_bytes",
           "tree_bytes", "st1_s", "st2_s", "rss_mb", "rc", "note")


def now_utc() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


class Rows:
    def __init__(self, out: Path, base: dict):
        out.mkdir(parents=True, exist_ok=True)
        self.path = out / "rows.jsonl"
        self.base = base

    def add(self, **row) -> dict:
        row = {**self.base, "utc": now_utc(), **row}
        with self.path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(row) + "\n")
        print(f"[measure] {row.get('mode')} {row.get('phase')}: {row.get('wall_s')} s "
              f"down={row.get('down_bytes', 0)} asks={row.get('asks', 0)} rc={row.get('rc', 0)}", file=sys.stderr)
        return row


def can_drop_caches() -> bool:
    return subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode == 0


def drop_caches(enabled: bool) -> None:
    if enabled:
        subprocess.run("sync; echo 3 | sudo -n tee /proc/sys/vm/drop_caches >/dev/null", shell=True, check=False)


def timed(cmd: str, cwd: Path, env: dict | None = None, timeout: float = 3600) -> tuple[float, int, str]:
    started = time.monotonic()
    got = subprocess.run(cmd, shell=True, cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout)
    wall = time.monotonic() - started
    out = (got.stdout.strip().splitlines() or [""])[-1][:80]
    if got.returncode:
        out = (got.stderr.strip().splitlines() or [out])[-1][:160]
    return round(wall, 3), got.returncode, out


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def du_bytes(path: Path, exclude_git: bool = False) -> int:
    total = 0
    for root, dirs, files in os.walk(path):
        if exclude_git and ".git" in dirs:
            dirs.remove(".git")
        for name in files:
            try:
                total += os.lstat(os.path.join(root, name)).st_size
            except OSError:
                pass
    return total


def rss_mb(pid: int) -> float:
    try:
        for line in Path(f"/proc/{pid}/status").read_text().splitlines():
            if line.startswith("VmRSS:"):
                return round(int(line.split()[1]) / 1024, 1)
    except OSError:
        pass
    return 0.0


# --- projection ---------------------------------------------------------------------------------

def slice_bench(args) -> Path:
    if args.bin:
        return Path(args.bin)
    target = Path(os.environ.get("CARGO_TARGET_DIR", REPO_ROOT / "cmux-tui" / "target"))
    binary = target / "release" / "examples" / "slice_bench"
    if args.build or not binary.exists():
        # Only this crate's bench example, never the workspace.
        subprocess.run(["cargo", "build", "-q", "--release", "-p", "cmux-projection", "--example", "slice_bench"],
                       cwd=REPO_ROOT / "cmux-tui", check=True)
    return binary


class Link:
    """serve + link, up for the whole run; mounts come and go behind it."""

    def __init__(self, binary: Path, tree: Path, work: Path, rtt_ms: float, mbps: float | None):
        self.binary, self.work = binary, work
        serve_port, self.port = free_port(), free_port()
        self.stats = work / "link-stats.json"
        self.serve = subprocess.Popen([str(binary), "serve", str(tree), f"127.0.0.1:{serve_port}"],
                                      stdout=subprocess.PIPE, stderr=(work / "serve.log").open("w"), text=True)
        line = self.serve.stdout.readline()
        if not line:
            raise SystemExit(f"slice_bench serve printed nothing; see {work / 'serve.log'}")
        self.serve_info = json.loads(line)
        cmd = [str(binary), "link", f"127.0.0.1:{self.port}", f"127.0.0.1:{serve_port}", "--rtt-ms", str(rtt_ms),
               "--stats", str(self.stats)]
        if mbps:
            cmd += ["--mbps", str(mbps)]
        self.link = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=(work / "link.log").open("w"))
        time.sleep(0.3)

    def counts(self) -> tuple[int, int, int]:
        time.sleep(0.3)  # the stats file lags by up to 100 ms
        try:
            d = json.loads(self.stats.read_text())
            return d["bytes_down"], d["bytes_up"], d.get("writes_up", 0)
        except (OSError, ValueError, KeyError):
            return 0, 0, 0

    def close(self) -> None:
        for proc in (self.link, self.serve):
            proc.terminate()
        for proc in (self.link, self.serve):
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()


class Mount:
    def __init__(self, link: Link, at: Path, state: Path):
        for path in (at, state):
            shutil.rmtree(path, ignore_errors=True)
            path.mkdir(parents=True)
        self.at = at
        started = time.monotonic()
        self.proc = subprocess.Popen([str(link.binary), "mount", f"127.0.0.1:{link.port}", str(at), str(state)],
                                     stdout=subprocess.PIPE, stderr=(link.work / "mount.log").open("a"), text=True)
        self.info = json.loads(self.proc.stdout.readline() or "{}")
        if self.proc.stdout.readline().strip() != "mounted":
            raise SystemExit(f"slice_bench mount did not mount; see {link.work / 'mount.log'}")
        self.wall = round(time.monotonic() - started, 3)

    def close(self) -> dict:
        self.proc.send_signal(signal.SIGTERM)
        try:
            out, _ = self.proc.communicate(timeout=30)
        except subprocess.TimeoutExpired:
            subprocess.run(["fusermount3", "-u", str(self.at)], check=False)
            self.proc.kill()
            out = ""
        last = (out or "").strip().splitlines()
        try:
            return json.loads(last[-1]) if last else {}
        except ValueError:
            return {}


def cmd_projection(args) -> None:
    tree = Path(args.tree).resolve()
    out = Path(args.out).resolve()
    rtt, mbps = args.rtt_ms, args.mbps
    if args.profile:
        profile = PROFILES[args.profile]
        rtt, mbps = profile["rtt"], profile["rate"] * 8
    label = args.label or tree.name
    rows = Rows(out, {"kind": "projection", "label": label, "mode": args.mode, "tree": str(tree),
                      "profile": args.profile or ("local" if not mbps and not rtt else f"rtt{rtt}-mbps{mbps}"),
                      "rtt_ms": rtt, "mbps": mbps})
    cold_drop = can_drop_caches()
    cold_note = "" if cold_drop else "page cache not dropped (no sudo -n)"
    steps = [s for s in args.steps.split(",") if s]
    if args.mode == "plain":
        for step in steps:
            drop_caches(cold_drop)
            for phase in ("cold", "warm"):
                wall, rc, got = timed(STEPS[step], tree)
                rows.add(phase=f"{step}_{phase}", wall_s=wall, rc=rc, note=f"out={got} {cold_note}".strip())
        return
    binary = slice_bench(args)
    work = Path(tempfile.mkdtemp(prefix="measure-proj-", dir=args.scratch))
    link = Link(binary, tree, work, rtt, mbps)
    try:
        info = link.serve_info
        rows.add(phase="serve_start", wall_s=round(info.get("walk_ms", 0) / 1000, 3), tree_bytes=info.get("bytes"),
                 note=json.dumps(info))
        for i, step in enumerate(steps):
            before = link.counts()
            mount = Mount(link, work / "mnt", work / f"state{i}")
            after = link.counts()
            rows.add(phase=f"mount_{step}", wall_s=mount.wall, down_bytes=after[0] - before[0],
                     up_bytes=after[1] - before[1], asks=after[2] - before[2], rss_mb=rss_mb(mount.proc.pid),
                     note=json.dumps(mount.info))
            try:
                drop_caches(cold_drop)
                for phase in ("cold", "warm"):
                    before = link.counts()
                    wall, rc, got = timed(STEPS[step], mount.at)
                    after = link.counts()
                    rows.add(phase=f"{step}_{phase}", wall_s=wall, down_bytes=after[0] - before[0],
                             up_bytes=after[1] - before[1], asks=after[2] - before[2], rss_mb=rss_mb(mount.proc.pid),
                             rc=rc, note=f"out={got} {cold_note}".strip())
            finally:
                stats = mount.close()
                if stats:
                    rows.add(phase=f"{step}_overlay_stats", note=json.dumps(stats))
    finally:
        link.close()
        if not args.keep:
            shutil.rmtree(work, ignore_errors=True)
    print_table(rows.path, args)


# --- git ----------------------------------------------------------------------------------------

def git_env(home: Path) -> dict:
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(HOME=str(home), GIT_CONFIG_NOSYSTEM="1", GIT_TERMINAL_PROMPT="0", XDG_CONFIG_HOME=str(home / ".config"))
    return env


def pack_bytes(repo: Path) -> int:
    packs = repo / ".git" / "objects" / "pack"
    return sum(p.stat().st_size for p in packs.glob("*.pack")) if packs.is_dir() else 0


def status_pair(repo: Path, env: dict) -> tuple[float | None, float | None]:
    if not (repo / ".git").exists():
        return None, None
    first = timed("git status --porcelain >/dev/null", repo, env)[0]
    second = timed("git status --porcelain >/dev/null", repo, env)[0]
    return first, second


def cmd_git(args) -> None:
    source = Path(args.repo).resolve()
    out = Path(args.out).resolve()
    work = Path(tempfile.mkdtemp(prefix="measure-git-", dir=args.scratch))
    home = work / "home"
    home.mkdir()
    env = git_env(home)
    branch = args.branch or subprocess.run(["git", "-C", str(source), "rev-parse", "--abbrev-ref", "HEAD"],
                                           capture_output=True, text=True, check=True).stdout.strip()
    rows = Rows(out, {"kind": "git", "label": args.label or source.name, "repo": str(source), "branch": branch,
                      "profile": "local"})
    srv = work / "srv"
    srv.mkdir()
    served = srv / "repo.git"
    subprocess.run(["git", "clone", "-q", "--bare", "--single-branch", "-b", branch, str(source), str(served)],
                   env=env, check=True)
    for key in ("uploadpack.allowFilter", "uploadpack.allowAnySHA1InWant", "daemon.uploadpack"):
        subprocess.run(["git", "-C", str(served), "config", key, "true"], env=env, check=True)
    port = free_port()
    daemon = subprocess.Popen(["git", "daemon", "--export-all", f"--base-path={srv}", "--listen=127.0.0.1",
                               f"--port={port}", "--reuseaddr", str(srv)], env=env,
                              stdout=subprocess.DEVNULL, stderr=(work / "daemon.log").open("w"))
    url = f"git://127.0.0.1:{port}/repo.git"

    def short(text: str) -> str:  # the work dir and port change every run; keep notes comparable
        return text.replace(f"127.0.0.1:{port}", "HOST").replace(str(work), "$W").strip()
    for _ in range(50):
        if subprocess.run(["git", "ls-remote", url], env=env, capture_output=True).returncode == 0:
            break
        time.sleep(0.1)
    clone = f"git -c transfer.unpackLimit=1 clone -q -b {branch}"
    cone = " ".join(c for c in args.cone.split(",") if c)
    drop = can_drop_caches()
    ready = None  # a depth-1 checkout the archive and overlay rows reuse

    def row(option: str, cmd: str, dest: Path, extra_bytes: int = 0, note: str = "") -> dict:
        drop_caches(drop)
        wall, rc, got = timed(cmd, work, env)
        st1, st2 = status_pair(dest, env)
        return rows.add(mode=option, phase="clone", wall_s=wall, rc=rc, down_bytes=pack_bytes(dest) + extra_bytes,
                        git_bytes=du_bytes(dest / ".git") if dest.exists() else 0,
                        tree_bytes=du_bytes(dest, exclude_git=True) if dest.exists() else 0,
                        st1_s=st1, st2_s=st2, note=short(f"{note or (got if rc else '')} cmd: {cmd}"))

    try:
        for option in [o for o in args.options.split(",") if o]:
            dest = work / option
            if option == "depth1":
                row(option, f"{clone} --depth 1 {url} {dest}", dest)
                ready = dest
            elif option == "blobnone":
                row(option, f"{clone} --filter=blob:none {url} {dest}", dest)
            elif option == "treeless":
                row(option, f"{clone} --filter=tree:0 {url} {dest}", dest)
            elif option == "sparse":
                row(option, f"{clone} --depth 1 --filter=blob:none --sparse {url} {dest}", dest)
                if cone:
                    before = pack_bytes(dest)
                    drop_caches(drop)
                    cmd = f"git -C {dest} -c transfer.unpackLimit=1 sparse-checkout set {cone}"
                    wall, rc, got = timed(cmd, work, env)
                    st1, st2 = status_pair(dest, env)
                    rows.add(mode=option, phase="widen", wall_s=wall, rc=rc, down_bytes=pack_bytes(dest) - before,
                             git_bytes=du_bytes(dest / ".git"), tree_bytes=du_bytes(dest, exclude_git=True),
                             st1_s=st1, st2_s=st2, note=short(f"{got if rc else ''} cmd: {cmd}"))
            elif option == "gitzst":
                if ready is None:
                    ready = work / "ready"
                    subprocess.run(f"{clone} --depth 1 {url} {ready}", shell=True, env=env, check=True)
                archive = work / "git.tar.zst"
                wall, rc, got = timed(f"tar -C {ready} -cf - .git | zstd -q -3 -T16 -o {archive}", work, env)
                size = archive.stat().st_size if archive.exists() else 0
                rows.add(mode=option, phase="pack", wall_s=wall, rc=rc, down_bytes=size,
                         note="tar .git | zstd -3 -T16 (server side, not on the clone's path)")
                dest.mkdir()
                row(option, f"zstd -dc {archive} | tar -C {dest} -xf - && git -C {dest} -c checkout.workers=16 "
                    f"checkout -f -q {branch}", dest, extra_bytes=size - pack_bytes(ready),
                    note="bytes = archive size")
            elif option == "overlay":
                if ready is None:
                    ready = work / "ready"
                    subprocess.run(f"{clone} --depth 1 {url} {ready}", shell=True, env=env, check=True)
                if not drop:
                    rows.add(mode=option, phase="clone", rc=-1, note="not measured: needs sudo -n for mount -t overlay")
                    continue
                upper, wdir = work / "ov-upper", work / "ov-work"
                for d in (dest, upper, wdir):
                    d.mkdir()
                cmd = f"sudo -n mount -t overlay overlay -o lowerdir={ready},upperdir={upper},workdir={wdir} {dest}"
                wall, rc, got = timed(cmd, work, env)
                st1, st2 = status_pair(dest, env) if rc == 0 else (None, None)
                rows.add(mode=option, phase="clone", wall_s=wall, rc=rc, down_bytes=0, git_bytes=0,
                         tree_bytes=du_bytes(upper) if rc == 0 else 0, st1_s=st1, st2_s=st2,
                         note=short(f"{got if rc else 'tree_bytes = upper dir after status'} cmd: {cmd}"))
                if rc == 0:
                    subprocess.run(["sudo", "-n", "umount", str(dest)], check=False)
            else:
                raise SystemExit(f"unknown option {option}")
    finally:
        daemon.terminate()
        daemon.wait(timeout=10)
        if not args.keep:
            subprocess.run(["chmod", "-R", "u+w", str(work)], check=False)
            shutil.rmtree(work, ignore_errors=True)
    print_table(rows.path, args)


# --- table --------------------------------------------------------------------------------------

def projected(row: dict, name: str) -> float | None:
    """Seconds on a profile's link: local seconds + bytes down / rate + asks x RTT (asks are a floor)."""
    if row.get("profile") != "local" or row.get("wall_s") is None or row.get("rc", 0) \
            or row.get("phase") in ("serve_start", "pack"):  # origin-side work, not on the link
        return None
    p = PROFILES[name]
    return round(row["wall_s"] + (row.get("down_bytes") or 0) / (p["rate"] * 1e6)
                 + (row.get("asks") or 0) * p["rtt"] / 1000, 2)


def load(path: Path) -> list[dict]:
    path = path / "rows.jsonl" if path.is_dir() else path
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def render(rows: list[dict], profiles: list[str], markdown: bool) -> str:
    head = list(COLUMNS) + [f"s@{p}" for p in profiles]
    lines = []
    for row in rows:
        cells = [row.get(c) for c in COLUMNS] + [projected(row, p) for p in profiles]
        sep = "\\|" if markdown else "|"
        lines.append(["" if v is None else str(v).replace("|", sep).replace("\t", " ") for v in cells])
    if not markdown:
        return "\n".join("\t".join(r) for r in [head] + lines)
    out = ["| " + " | ".join(head) + " |", "|" + "---|" * len(head)]
    out += ["| " + " | ".join(r) + " |" for r in lines]
    return "\n".join(out)


def print_table(path: Path, args) -> None:
    profiles = [p for p in (getattr(args, "profiles", None) or ",".join(DEFAULT_TABLE_PROFILES)).split(",") if p]
    print(render(load(path), profiles, getattr(args, "markdown", False)))


def cmd_table(args) -> None:
    for p in args.profiles.split(","):
        if p and p not in PROFILES:
            raise SystemExit(f"unknown profile {p}; see `measure.py profiles`")
    print_table(Path(args.rows), args)


def cmd_profiles(_args) -> None:
    print("name\tMB/s\trtt_ms\twhat")
    for name, p in PROFILES.items():
        print(f"{name}\t{p['rate']}\t{p['rtt']}\t{p['what']}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--out", default="measure-out", help="directory for rows.jsonl (appended)")
    common.add_argument("--label", help="row label (default: the tree's or repo's name)")
    common.add_argument("--scratch", default=None, help="parent of the temporary work dir (default: $TMPDIR)")
    common.add_argument("--keep", action="store_true", help="keep the work dir")
    common.add_argument("--profiles", default=",".join(DEFAULT_TABLE_PROFILES), help="projected-seconds columns")
    common.add_argument("--markdown", action="store_true")

    p = sub.add_parser("projection", parents=[common])
    p.add_argument("tree")
    p.add_argument("--mode", choices=("folder", "plain"), default="folder")
    p.add_argument("--steps", default="ls,rg,gitstatus")
    p.add_argument("--rtt-ms", type=float, default=0.0)
    p.add_argument("--mbps", type=float, default=None, help="cap each way, megabits/s (slice_bench link --mbps)")
    p.add_argument("--profile", choices=sorted(PROFILES), help="run the link at a profile's rate and RTT")
    p.add_argument("--bin", help="slice_bench binary (default: cmux-tui's release example, built if missing)")
    p.add_argument("--build", action="store_true", help="build slice_bench first (cmux-projection only)")
    p.set_defaults(func=cmd_projection)

    g = sub.add_parser("git", parents=[common])
    g.add_argument("repo")
    g.add_argument("--branch")
    g.add_argument("--options", default="depth1,blobnone,sparse,gitzst,overlay",
                   help="depth1, blobnone, treeless, sparse, gitzst, overlay")
    g.add_argument("--cone", default="", help="sparse: then `sparse-checkout set` these dirs (comma list)")
    g.set_defaults(func=cmd_git)

    t = sub.add_parser("table", parents=[common])
    t.add_argument("rows")
    t.set_defaults(func=cmd_table)
    sub.add_parser("profiles").set_defaults(func=cmd_profiles)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
