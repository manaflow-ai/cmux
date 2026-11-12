#!/usr/bin/env python3
"""cmux live --rust: save Rust in a cmux checkout, and the running daemon is
that build a few seconds later, with every terminal and agent session kept.

  rust-live.py start  [--worktree T] [--build-host H] [--target TRIPLE]
                      [--session S | --socket P] [--foreground]
  rust-live.py stop
  rust-live.py status [--json]
  rust-live.py measure --out DIR [--runs N] [--terminals N]

The loop (`start`; `cmux live start --rust` runs it):

1. Watch the checkout's cmux-tui/ for a saved .rs, Cargo.toml or Cargo.lock.
2. Build only the daemons the changed crates reach, incrementally: cmux-tui
   (cmux-tui) and acpmux (shipped as cmux-tui-acpmux). With --build-host the
   build runs there: the changed files go over rsync to a tree kept per
   checkout on that host, which keeps its own warm target/ and uses sccache
   when the host has it. Without it the build runs here, in the checkout's
   own target/. Leo's Macs never build: pass --build-host there.
3. Bring the binaries back (rsync, compressed, over the tailnet) into a new
   folder per build, so the running daemon's file is never overwritten.
4. Swap the running daemon for the new build the way
   scripts/cmux-next/daemon-swap-check.py measures it (1-1.3 s): the old
   owner stops and leaves its terminal hosts running, the new one adopts
   them. A daemon a cmux app runs (its executable is the app's
   Contents/Resources/bin/cmux) swaps the way the app hands off its own daemon:
   the new build is renamed over that file (the cmux-tui link to it stays), the
   owner gets SIGTERM, and the app's reconnect runs its own `server ensure`
   from the file, with its own install key, so the app's launch identity is
   kept. Measured on a side copy of a DEV app (cmux#36389): 1.38 s to the PR's
   daemon, 1.34 s back, 1.16 s forward again; same app pid and shells. `stop`
   puts the app's own file back and hands the daemon back to it. Any other
   daemon: `server restart` when the build has it (cmux#36313); otherwise
   `server stop` then `server ensure`. acpmux: `daemon restart`, which hands
   the agent hosts over the same way.

Every swap goes to the state folder's last.json and history.jsonl, which
`status` (and `cmux live status`) prints: when, from which save, and how long
each step took.

`measure` is the fleet measurement (scripts/measure/rust-live-swap.sh runs
it): a scratch daemon with N shells, then N one-line edits to cmux-tui-core,
each timed from the save to the swapped daemon answering with the edit, with
every shell checked to be the same process, with its screen, still echoing.
It prints one JSON report with p50/p95 and exits 0 only when every run
swapped and every terminal survived.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import shlex
import shutil
import signal
import socket
import stat
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

WATCHED_SUFFIXES = (".rs", ".toml")
WATCHED_NAMES = ("Cargo.lock",)
SKIPPED_DIRS = {"target", ".git", "node_modules", "dist", "vendor"}
POLL_SECS = 0.05
SETTLE_SECS = 0.08
KEEP_BUILDS = 3
START_TIMEOUT_SECS = 300  # the first sync of a whole tree to a build host
# A cmux app runs its daemon from here; the app's reconnect re-runs `server ensure` from this file.
APP_BIN = "/Contents/Resources/bin/"
# How long a new owner may take after the SIGTERM: the app's reconnect backs off up to 30 s.
APP_OWNER_SECS = 35
# package -> (binary cargo builds, the name the app bundles it under)
DAEMONS = {"cmux-tui": ("cmux-tui", "cmux-tui"), "acpmux": ("acpmux", "cmux-tui-acpmux")}
# The measurement's one-line edit: a field in the daemon's `identify` answer,
# in cmux-tui-core (a library crate, not the binary's own).
EDIT_FILE = "cmux-tui/crates/cmux-tui-core/src/server/cmd_server.rs"
EDIT_ANCHOR = '        "daemon_handoff": 1,\n'


def log(message: str) -> None:
    stamp = time.strftime("%H:%M:%SZ", time.gmtime())
    print(f"rust-live {stamp} {message}", file=sys.stderr, flush=True)


def state_dir() -> Path:
    if os.environ.get("CMUX_RUST_LIVE_STATE_DIR"):
        return Path(os.environ["CMUX_RUST_LIVE_STATE_DIR"])
    home = Path.home()
    if sys.platform == "darwin":
        return home / "Library/Caches/cmux-next/rust-live"
    return Path(os.environ.get("XDG_CACHE_HOME") or home / ".cache") / "cmux-next/rust-live"


def checkout(worktree: str | None) -> Path:
    if worktree:
        tree = Path(worktree).resolve()
    else:
        out = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True)
        tree = Path(out.stdout.strip() or ".").resolve()
    if not (tree / "cmux-tui/Cargo.toml").is_file():
        raise SystemExit(f"rust-live: {tree} is not a cmux checkout (no cmux-tui/Cargo.toml)")
    return tree


# ---------------------------------------------------------------- watching


def scan(root: Path) -> dict[str, int]:
    """Relative path -> mtime_ns of every watched file under root."""
    found: dict[str, int] = {}
    stack = [root]
    while stack:
        folder = stack.pop()
        try:
            entries = list(os.scandir(folder))
        except OSError:
            continue
        for entry in entries:
            if entry.is_dir(follow_symlinks=False):
                if entry.name not in SKIPPED_DIRS and not entry.name.startswith("."):
                    stack.append(Path(entry.path))
            elif entry.name.endswith(WATCHED_SUFFIXES) or entry.name in WATCHED_NAMES:
                try:
                    found[os.path.relpath(entry.path, root)] = entry.stat().st_mtime_ns
                except OSError:
                    pass
    return found


def changes(before: dict[str, int], after: dict[str, int]) -> tuple[list[str], list[str]]:
    changed = [path for path, mtime in after.items() if before.get(path) != mtime]
    removed = [path for path in before if path not in after]
    return changed, removed


# ---------------------------------------------------------------- crate graph


@dataclass
class Graph:
    """Which workspace package owns a file, and which daemons reach it."""

    dirs: list[tuple[str, str]]  # (package dir relative to cmux-tui/, package), longest first
    reaches: dict[str, set[str]]  # daemon package -> every workspace package it depends on

    @classmethod
    def load(cls, workspace: Path) -> "Graph":
        out = subprocess.run(
            ["cargo", "metadata", "--format-version", "1", "--no-deps", "--offline"],
            cwd=workspace, capture_output=True, text=True,
        )
        if out.returncode != 0:
            out = subprocess.run(["cargo", "metadata", "--format-version", "1", "--no-deps"],
                                 cwd=workspace, capture_output=True, text=True, check=True)
        meta = json.loads(out.stdout)
        packages = {p["name"]: p for p in meta["packages"]}
        dirs = []
        for name, package in packages.items():
            folder = os.path.relpath(Path(package["manifest_path"]).parent, workspace)
            dirs.append(("" if folder == "." else folder + "/", name))
        dirs.sort(key=lambda d: len(d[0]), reverse=True)
        reaches = {}
        for daemon in DAEMONS:
            seen, todo = set(), [daemon]
            while todo:
                name = todo.pop()
                if name in seen or name not in packages:
                    continue
                seen.add(name)
                todo.extend(d["name"] for d in packages[name]["dependencies"]
                            if d.get("path") and d.get("kind") != "dev")
            reaches[daemon] = seen
        return cls(dirs, reaches)

    def package_of(self, relpath: str) -> str | None:
        for folder, name in self.dirs:
            if relpath.startswith(folder):
                return name
        return None

    def daemons_for(self, relpaths: list[str]) -> tuple[list[str], list[str]]:
        """(daemon packages to rebuild, packages changed). A workspace-level
        file (Cargo.lock, the root Cargo.toml) rebuilds every daemon."""
        packages = sorted({self.package_of(p) or "*" for p in relpaths})
        if "*" in packages or any(p in ("Cargo.lock", "Cargo.toml") for p in relpaths):
            return list(DAEMONS), packages
        return [d for d in DAEMONS if self.reaches[d] & set(packages)], packages


# ---------------------------------------------------------------- building


def outside_path_deps(workspace: Path) -> list[str]:
    """Folders of path dependencies outside cmux-tui/ (relative to the repo root), which a
    build host needs too: cmux-tui depends on workers/cmux-vm, for one."""
    out = subprocess.run(["cargo", "metadata", "--format-version", "1", "--offline"],
                         cwd=workspace, capture_output=True, text=True)
    if out.returncode != 0:
        out = subprocess.run(["cargo", "metadata", "--format-version", "1"],
                             cwd=workspace, capture_output=True, text=True, check=True)
    root = workspace.parent.resolve()
    folders = set()
    for package in json.loads(out.stdout)["packages"]:
        if package.get("source") is not None:
            continue  # crates.io or git: cargo fetches those itself
        folder = Path(package["manifest_path"]).parent.resolve()
        if workspace.resolve() in folder.parents or folder == workspace.resolve():
            continue
        if root not in folder.parents:
            continue
        # A crate that inherits from its own workspace (`edition.workspace = true`) needs that
        # workspace's Cargo.toml too, so send the workspace folder.
        for parent in [folder, *folder.parents]:
            if parent == root:
                break
            manifest = parent / "Cargo.toml"
            if manifest.is_file() and "[workspace]" in manifest.read_text(errors="replace"):
                folder = parent
                break
        folders.add(str(folder.relative_to(root)))
    # Keep only the outermost folders.
    return sorted(f for f in folders if not any(f.startswith(o + "/") for o in folders if o != f))


def control_dir() -> str:
    """This user's ssh ControlMaster folder: short (a socket path is capped near 104 bytes on macOS), kept across runs
    (ControlPersist), and refused unless it is a real 700 folder this user owns, so another account cannot plant the
    socket an ssh here then talks to."""
    path = f"/tmp/rust-live-{os.getuid()}"
    try:
        os.mkdir(path, 0o700)
    except FileExistsError:
        pass
    st = os.lstat(path)
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077:
        sys.exit(f"rust-live: {path} is not a private folder of this user's; remove it")
    return path


def ssh_options(state: Path) -> list[str]:
    # One connection kept open: each step after the first costs one round trip.
    # CMUX_RUST_LIVE_SSH_OPTS: more ssh options (a port, a jump host, a known-hosts file).
    extra = shlex.split(os.environ.get("CMUX_RUST_LIVE_SSH_OPTS", ""))
    return ["-o", "BatchMode=yes", "-o", "ControlMaster=auto",
            # %C is 40 characters; a socket path under a deep state folder passes macOS's 104 limit.
            "-o", f"ControlPath={control_dir()}/%C", "-o", "ControlPersist=900", *extra]


def run(argv: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(argv, capture_output=True, text=True, **kwargs)


# The cargo profile to build (CMUX_RUST_LIVE_PROFILE): dev, so the checkout's warm dev build is reused.
PROFILE = os.environ.get("CMUX_RUST_LIVE_PROFILE") or "dev"


def cargo_args(daemons: list[str], target: str | None) -> list[str]:
    argv = ["cargo", "build", "--message-format=short", "--profile", PROFILE]
    if target:
        argv += ["--target", target]
    for package in daemons:
        argv += ["-p", package, "--bin", DAEMONS[package][0]]
    return argv


class Builder:
    """Builds here, or on --build-host in a tree kept for this checkout."""

    def __init__(self, tree: Path, state: Path, host: str | None, target: str | None):
        self.tree, self.state, self.host, self.target = tree, state, host, target
        key = hashlib.sha256(f"{socket.gethostname()}:{tree}".encode()).hexdigest()[:12]
        self.remote = f".cache/cmux-live-rust/{key}"
        self.incoming = state / "incoming"
        self.incoming.mkdir(parents=True, exist_ok=True)
        self.synced = False
        self.current: subprocess.Popen | None = None  # the build running now, if any

    def cancel(self) -> None:
        """End the running build (its own process group: cargo or the ssh that runs it)."""
        proc = self.current
        if proc and proc.poll() is None:
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                pass

    def run_build(self, argv: list[str], **kwargs) -> subprocess.CompletedProcess:
        proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                start_new_session=True, **kwargs)
        self.current = proc
        try:
            out, err = proc.communicate()
        finally:
            self.current = None
        return subprocess.CompletedProcess(argv, proc.returncode, out, err)

    def sync(self, changed: list[str], removed: list[str]) -> None:
        """Bring the build host's tree up to the checkout (nothing to do here)."""
        if not self.host:
            return
        rsh = " ".join(["ssh", *map(shlex.quote, ssh_options(self.state))])
        source = f"{self.tree}/cmux-tui/"
        dest = f"{self.host}:{self.remote}/cmux-tui/"
        if not self.synced or removed:
            run(["ssh", *ssh_options(self.state), self.host, f"mkdir -p {self.remote}/cmux-tui"], check=True)
            argv = ["rsync", "-a", "--delete", "-e", rsh,
                    *[f"--exclude=/{d}/" for d in ("target", ".git")], source, dest]
            result = run(argv)
            if result.returncode != 0:
                raise RuntimeError(f"rsync to {self.host}: {result.stderr.strip()}")
            # ghostty-vt-sys builds libghostty-vt from the repo root's ghostty-next submodule, and
            # some path dependencies live outside cmux-tui/ (workers/cmux-vm).
            outside = outside_path_deps(self.tree / "cmux-tui")
            if (self.tree / "ghostty-next/build.zig").is_file():
                outside.append("ghostty-next")
            for folder in outside:
                if self.synced and folder == "ghostty-next":
                    continue
                run(["ssh", *ssh_options(self.state), self.host, f"mkdir -p {self.remote}/{folder}"], check=True)
                result = run(["rsync", "-a", "--delete", "-e", rsh, "--exclude=.git", "--exclude=zig-out/",
                              "--exclude=.zig-cache/", "--exclude=/target/", "--exclude=node_modules/",
                              f"{self.tree / folder}/", f"{self.host}:{self.remote}/{folder}/"])
                if result.returncode != 0:
                    raise RuntimeError(f"rsync {folder} to {self.host}: {result.stderr.strip()}")
            self.synced = True
            return
        result = subprocess.run(["rsync", "-a", "-e", rsh, "--files-from=-", source, dest],
                                input="\n".join(changed) + "\n", capture_output=True, text=True)
        if result.returncode != 0:
            self.synced = False  # the next save sends the whole tree, so this edit is not lost
            raise RuntimeError(f"rsync to {self.host}: {result.stderr.strip()}")

    def build(self, daemons: list[str]) -> tuple[bool, str]:
        cargo = shlex.join(cargo_args(daemons, self.target))
        if self.host:
            script = (f"cd {self.remote}/cmux-tui && export CARGO_TARGET_DIR=$HOME/{self.remote}/target; "
                      "[ -z \"$RUSTC_WRAPPER\" ] && command -v sccache >/dev/null && export RUSTC_WRAPPER=sccache; "
                      f"exec {cargo}")
            result = self.run_build(["ssh", *ssh_options(self.state), self.host, f"bash -lc {shlex.quote(script)}"])
        else:
            env = dict(os.environ)
            if not env.get("RUSTC_WRAPPER") and shutil.which("sccache"):
                env["RUSTC_WRAPPER"] = "sccache"
            result = self.run_build(cargo_args(daemons, self.target), cwd=self.tree / "cmux-tui", env=env)
        output = (result.stderr or "") + (result.stdout or "")
        return result.returncode == 0, output

    def out_dir(self) -> str:
        folder = "debug" if PROFILE == "dev" else PROFILE
        return f"{self.target}/{folder}" if self.target else folder

    def fetch(self, daemons: list[str], generation: Path) -> dict[str, Path]:
        """Copy each built daemon into its own folder for this build."""
        generation.mkdir(parents=True, exist_ok=True)
        built = {}
        for package in daemons:
            binary, shipped = DAEMONS[package]
            staged = self.incoming / shipped
            if self.host:
                rsh = " ".join(["ssh", *map(shlex.quote, ssh_options(self.state))])
                built_file = f"{self.remote}/target/{self.out_dir()}/{binary}"
                # Without its debug info the debug cmux-tui is 263 MB, not 614 (x86_64 Linux,
                # 2026-11-05), and rsync then sends only what changed against the last build here.
                strip = (f"objcopy --strip-debug {built_file} {built_file}.live 2>/dev/null"
                         f" || strip -S -o {built_file}.live {built_file}")
                result = run(["ssh", *ssh_options(self.state), self.host, strip])
                if result.returncode != 0:
                    raise RuntimeError(f"strip on {self.host}: {result.stderr.strip()}")
                source = f"{self.host}:{built_file}.live"
                result = run(["rsync", "-z", "-e", rsh, source, str(staged)])
                if result.returncode != 0:
                    raise RuntimeError(f"rsync from {self.host}: {result.stderr.strip()}")
            else:
                target = self.tree / "cmux-tui" / (os.environ.get("CARGO_TARGET_DIR") or "target")
                staged = target / self.out_dir() / binary
            dest = generation / shipped
            try:
                # cargo replaces its output with a new file on the next build, so a link keeps this one.
                os.link(staged, dest)
            except OSError:
                shutil.copy2(staged, dest)
            dest.chmod(0o755)
            built[package] = dest
        return built


# ---------------------------------------------------------------- swapping


class Swapper:
    """Swaps a session's running daemons for new builds, keeping their work."""

    def __init__(self, session: str | None, sock: str | None, env: dict | None = None, state: Path | None = None):
        self.selector = (["--socket", sock] if sock else []) + (["--session", session] if session else [])
        self.sock = sock
        self.env = env
        self.previous: Path | None = None  # the last cmux-tui this loop swapped in
        # An app's daemon file and the copy of what it held before the first swap. Kept in the state
        # folder, one marker per session/socket, so a watcher that died never takes a swapped file for
        # the app's, and a watcher on another session never restores this one's.
        self.state = state
        self.app_original: tuple[Path, Path] | None = None
        marker = self.marker()
        if marker and marker.is_file():
            try:
                saved = json.loads(marker.read_text())
                if saved.get("selector") == self.selector:
                    self.app_original = (Path(saved["file"]), Path(saved["copy"]))
            except (OSError, ValueError, KeyError):
                pass

    def marker(self) -> Path | None:
        if not self.state:
            return None
        key = hashlib.sha256(json.dumps(self.selector).encode()).hexdigest()[:12]
        return self.state / f"app-original-{key}.json"

    def cli(self, binary: Path, *words: str, timeout: float = 60) -> subprocess.CompletedProcess:
        return run([str(binary), *self.selector, *words], env=self.env, timeout=timeout)

    def running_binary(self, cli: Path) -> Path | None:
        """The executable of the daemon running before the first swap, so a failed swap can
        put it back (`server status` names its pid)."""
        owner = self.owner(cli)
        return owner[1] if owner else None

    def owner(self, cli: Path, timeout: float = 60) -> tuple[int, Path] | None:
        """The running owner's pid and executable, from `server status`; None when none answers in
        `timeout` seconds."""
        try:
            # JSON: the text form pads its columns (`pid         4242`), and its layout is not a contract.
            status = self.cli(cli, "--json", "server", "status", timeout=max(timeout, 0.1))
        except subprocess.TimeoutExpired:
            return None
        match = re.search(r'"pid"\s*:\s*(\d+)', status.stdout)
        if not match:
            return None
        pid = match.group(1)
        try:
            # Linux names a file renamed over since the process started "PATH (deleted)", as an app's
            # owner's is right after a swap renames the new build over it; the owner still runs PATH's.
            exe = Path(os.readlink(f"/proc/{pid}/exe").removesuffix(" (deleted)"))
        except OSError:
            # macOS has no /proc: lsof names the process's executable (its "txt" file) by full path.
            out = run(["lsof", "-a", "-p", pid, "-d", "txt", "-Fn"])
            names = [line[1:] for line in out.stdout.splitlines() if line.startswith("n/")]
            exe = Path(names[0]) if names else Path("")
        return (int(pid), exe) if exe.is_absolute() and exe.is_file() else None

    @staticmethod
    def app_file(exe: Path) -> Path | None:
        """The file a cmux app runs its daemon from, when `exe` is in an app's bin folder (the real
        file: `cmux-tui` there is a link to `cmux`, and both must stay one build)."""
        return exe.resolve() if APP_BIN in str(exe) else None

    def app_handoff(self, new: Path, pid: int, target: Path) -> None:
        """Swaps an app's daemon the way the app hands off its own: `new` renamed over `target`, then
        SIGTERM to the owner (`pid`), whose terminal hosts stay for the next owner; the app's
        reconnect runs `server ensure` from `target`, with its own install key. A new owner that
        does not answer in APP_OWNER_SECS puts the file that was there back."""
        if self.app_original is None or self.app_original[0] != target:
            marker = self.marker()
            keep = (marker.with_suffix("") if marker else Path(tempfile.mkdtemp(prefix="rust-live-app-"))) / target.name
            keep.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(target, keep)
            self.app_original = (target, keep)
            if marker:
                marker.write_text(json.dumps({"selector": self.selector, "file": str(target), "copy": str(keep)}) + "\n")
        before = target.with_name(f".{target.name}.rust-live-before")
        staged = target.with_name(f".{target.name}.rust-live")
        shutil.copy2(target, before)
        shutil.copy2(new, staged)
        staged.chmod(0o755)
        os.replace(staged, target)  # the running owner keeps the file it mapped
        self.terminate_owner(new, pid)
        if self.wait_for_new_owner(new, pid) is None:
            os.replace(before, target)  # the app's next ensure runs the build that ran before
            late = self.owner(target, timeout=10)
            if late and late[0] != pid:
                # An owner that came up after the last poll runs the new build, and while it answers the
                # app's ensure starts nothing: hand off once more, to the file that is back.
                self.handoff_to_file(late[0], target)
            raise RuntimeError(f"no new daemon answered {APP_OWNER_SECS} s after the handoff; {target} is back as it was")
        before.unlink(missing_ok=True)

    def handoff_to_file(self, pid: int, target: Path) -> int | None:
        """SIGTERM to the owner `pid`; the app's reconnect starts the next one from `target`. Returns
        the next owner's pid, or None when none answered in APP_OWNER_SECS."""
        self.terminate_owner(target, pid)
        return self.wait_for_new_owner(target, pid)

    def terminate_owner(self, cli: Path, pid: int) -> None:
        """SIGTERM to `pid` only while it is still the session's owner: the copies before this can take
        seconds, and a pid that exited in that time can belong to another process (or the app's next
        owner) by now."""
        current = self.owner(cli, timeout=10)
        if not current or current[0] != pid:
            return
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass

    def wait_for_new_owner(self, cli: Path, old: int) -> int | None:
        deadline = time.monotonic() + APP_OWNER_SECS
        while time.monotonic() < deadline:
            owner = self.owner(cli, timeout=deadline - time.monotonic())
            if owner and owner[0] != old:
                return owner[0]
            time.sleep(0.05)
        return None

    def restore_app(self) -> str | None:
        """Puts the app's own daemon file back and hands the daemon back to it (`stop`)."""
        if self.app_original is None:
            return None
        target, keep = self.app_original
        if not keep.is_file():
            return None
        owner = self.owner(target)
        staged = target.with_name(f".{target.name}.rust-live")
        shutil.copy2(keep, staged)
        os.replace(staged, target)
        # Only this app's owner hands off: one running from somewhere else is not the swapped build.
        if owner and self.app_file(owner[1]) == target and self.handoff_to_file(owner[0], target) is None:
            # The file is the app's own again, but its daemon still runs the swapped build (or none
            # answers): the marker stays, so the next `stop` hands off again.
            raise RuntimeError(f"{target} is the app's own build again, but no daemon from it answered "
                               f"{APP_OWNER_SECS} s after the handoff; run stop again")
        marker = self.marker()
        if marker:
            marker.unlink(missing_ok=True)
        self.app_original = None
        return str(target)

    def swap(self, built: dict[str, Path]) -> dict:
        steps: dict = {}
        if "cmux-tui" in built:
            new = built["cmux-tui"]
            t0 = time.monotonic()
            owner = self.owner(new)
            target = self.app_file(owner[1]) if owner else None
            if self.previous is None:
                self.previous = owner[1] if owner else None
            if owner and target:
                self.app_handoff(new, owner[0], target)
                steps["cmux-tui"] = "app handoff"
                steps["cmux-tui_secs"] = round(time.monotonic() - t0, 3)
                self.previous = new
                return self.swap_acpmux(built, steps)
            restart = self.cli(new, "server", "restart")
            if restart.returncode == 0:
                steps["cmux-tui"] = "server restart"
            else:
                # A build without `server restart` (before cmux#36313): the same two steps.
                stop = self.cli(new, "server", "stop")
                if stop.returncode != 0 and "not_running" not in stop.stdout + stop.stderr:
                    raise RuntimeError(f"server stop: {(stop.stderr or stop.stdout).strip()}")
                ensure = self.cli(new, "server", "ensure")
                if ensure.returncode != 0:
                    # Never leave the session without a daemon: the last build that ran goes back.
                    back = self.cli(self.previous, "server", "ensure") if self.previous else None
                    raise RuntimeError(f"server ensure: {(ensure.stderr or ensure.stdout).strip()}"
                                       + ("; the previous build is back" if back and back.returncode == 0 else ""))
                steps["cmux-tui"] = "server stop + ensure"
            steps["cmux-tui_secs"] = round(time.monotonic() - t0, 3)
            self.previous = new
        return self.swap_acpmux(built, steps)

    def swap_acpmux(self, built: dict[str, Path], steps: dict) -> dict:
        if "acpmux" in built:
            t0 = time.monotonic()
            result = run([str(built["acpmux"]), "daemon", "restart"], env=self.env, timeout=60)
            if result.returncode != 0:
                raise RuntimeError(f"acpmux daemon restart: {(result.stderr or result.stdout).strip()}")
            steps["acpmux"] = "daemon restart"
            steps["acpmux_secs"] = round(time.monotonic() - t0, 3)
        return steps


# ---------------------------------------------------------------- the loop


@dataclass
class Loop:
    tree: Path
    state: Path
    builder: Builder
    swapper: Swapper
    on_swap: object = None  # called with each record (measure)
    only: tuple = tuple(DAEMONS)  # the daemons this loop may swap (measure: cmux-tui alone)
    stop_event: threading.Event = field(default_factory=threading.Event)
    watching: threading.Event = field(default_factory=threading.Event)  # set after the first scan

    def __post_init__(self):
        self.root = self.tree / "cmux-tui"
        self.graph = Graph.load(self.root)
        self.generation = 0

    def record(self, entry: dict) -> None:
        self.state.mkdir(parents=True, exist_ok=True)
        (self.state / "last.json").write_text(json.dumps(entry, indent=2) + "\n")
        with open(self.state / "history.jsonl", "a") as history:
            history.write(json.dumps(entry) + "\n")
        if self.on_swap:
            self.on_swap(entry)

    def prune(self) -> None:
        builds = sorted((self.state / "builds").glob("*"), key=lambda p: p.stat().st_mtime)
        rollback = self.swapper.previous.parent if self.swapper.previous else None
        for old in builds[:-KEEP_BUILDS]:
            if old == rollback:
                continue  # the cmux-tui a failed swap goes back to, however many acpmux builds came since
            shutil.rmtree(old, ignore_errors=True)  # only folders this loop made

    def once(self, changed: list[str], removed: list[str], saved_at: float, detected_at: float) -> dict:
        if any(p.endswith("Cargo.toml") for p in changed + removed):
            self.graph = Graph.load(self.root)  # a new crate or path dependency
        daemons, packages = self.graph.daemons_for(changed + removed)
        daemons = [d for d in daemons if d in self.only]
        entry: dict = {
            "saved_at": round(saved_at, 3), "files": (changed + removed)[:20], "packages": packages,
            "daemons": daemons, "build_host": self.builder.host or "here",
            "detect_secs": round(detected_at - saved_at, 3),
        }
        if not daemons:
            entry.update(outcome="skipped", reason="no daemon reaches the changed crates")
            return entry
        t = time.time()
        self.builder.sync(changed, removed)
        entry["sync_secs"] = round(time.time() - t, 3)
        t = time.time()
        ok, output = self.builder.build(daemons)
        entry["build_secs"] = round(time.time() - t, 3)
        if not ok:
            errors = [line for line in output.splitlines() if line.startswith(("error", "warning: build failed"))]
            entry.update(outcome="build_failed", errors=errors[:10] or output.strip().splitlines()[-10:])
            return entry
        self.generation += 1
        t = time.time()
        stamp = time.strftime("%Y%m%dT%H%M%S", time.gmtime())
        built = self.builder.fetch(daemons, self.state / "builds" / f"{stamp}-{self.generation}")
        entry["transfer_secs"] = round(time.time() - t, 3)
        entry["bytes"] = sum(p.stat().st_size for p in built.values())
        if self.stop_event.is_set():
            entry.update(outcome="stopped", reason="the loop was stopped during the build")
            return entry
        t = time.time()
        entry["swap"] = self.swapper.swap(built)
        swapped_at = time.time()
        entry["swap_secs"] = round(swapped_at - t, 3)
        entry["swapped_at"] = round(swapped_at, 3)
        entry["save_to_swapped_secs"] = round(swapped_at - saved_at, 3)
        entry["binaries"] = {k: str(v) for k, v in built.items()}
        entry["outcome"] = "swapped"
        self.prune()
        return entry

    def run(self) -> None:
        log(f"watching {self.root} (build: {self.builder.host or 'here'})")
        files = scan(self.root)  # before the sync: a save during a slow first sync is still seen
        self.builder.sync([], [])
        self.watching.set()
        (self.state / "watch.ready").write_text(f"{os.getpid()}\n")
        while not self.stop_event.is_set():
            time.sleep(POLL_SECS)
            now = scan(self.root)
            changed, removed = changes(files, now)
            if not (changed or removed):
                continue
            # An editor's save can be several writes: wait for them to settle.
            while True:
                time.sleep(SETTLE_SECS)
                later = scan(self.root)
                if later == now:
                    break
                now = later
            changed, removed = changes(files, now)
            files = now
            saved_at = max((now[p] for p in changed), default=time.time_ns()) / 1e9
            detected_at = time.time()
            try:
                entry = self.once(changed, removed, saved_at, detected_at)
            except Exception as error:  # noqa: BLE001 - one bad save must not end the loop
                entry = {"saved_at": round(saved_at, 3), "files": changed[:20], "outcome": "failed",
                         "error": str(error)}
            log(summary(entry))
            self.record(entry)
            # Edits saved during that build are picked up by the next scan.


def summary(entry: dict) -> str:
    when = time.strftime("%H:%M:%SZ", time.gmtime(entry.get("saved_at", 0)))
    files = ", ".join(entry.get("files") or []) or "?"
    if entry.get("outcome") != "swapped":
        reason = entry.get("reason") or entry.get("error") or "; ".join(entry.get("errors") or [])
        return f"save at {when} ({files}): {entry.get('outcome')}: {reason}"
    parts = [f"{k[:-5]} {entry[k]:.2f}" for k in ("detect_secs", "sync_secs", "build_secs", "transfer_secs", "swap_secs")
             if k in entry]
    return (f"save at {when} ({files}): swapped {', '.join(entry['daemons'])} in "
            f"{entry['save_to_swapped_secs']:.2f} s from the save ({', '.join(parts)} s)")


# ---------------------------------------------------------------- commands


def pid_file(state: Path) -> Path:
    return state / "watch.pid"


def running_pid(state: Path) -> int | None:
    """The recorded watcher, only while that pid is still this script."""
    try:
        pid = int(pid_file(state).read_text().split()[0])
    except (OSError, ValueError, IndexError):
        return None
    out = run(["ps", "-o", "command=", "-p", str(pid)])
    return pid if "rust-live.py" in out.stdout and "--foreground" in out.stdout else None


def command_start(args) -> int:
    tree = checkout(args.worktree)
    state = state_dir()
    state.mkdir(parents=True, exist_ok=True)
    if args.foreground:
        return run_watcher(args, tree, state)
    # One `start` at a time: the check, the spawn and the wait for the watcher are one step.
    with open(state / "start.lock", "w") as start_lock:
        fcntl.flock(start_lock, fcntl.LOCK_EX)
        return spawn_watcher(args, tree, state)


def spawn_watcher(args, tree: Path, state: Path) -> int:
    if (pid := running_pid(state)) and not args.foreground:
        watched = pid_file(state).read_text().split(maxsplit=1)[1].strip()
        print(f"rust-live: already watching {watched} (pid {pid}); `cmux live stop --rust` stops it")
        return 0
    if not args.foreground:
        argv = [sys.executable, str(Path(__file__).resolve()), "start", "--foreground", "--worktree", str(tree)]
        for flag in ("build_host", "target", "session", "socket"):
            if getattr(args, flag):
                argv += [f"--{flag.replace('_', '-')}", getattr(args, flag)]
        ready = state / "watch.ready"
        ready.unlink(missing_ok=True)
        with open(state / "watch.log", "ab") as out:
            log_start = out.tell()
            proc = subprocess.Popen(argv, stdout=out, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                    start_new_session=True)
        # Say "watching" only once it is: the crate graph read and the first sync to a build host done.
        deadline = time.monotonic() + START_TIMEOUT_SECS
        while proc.poll() is None and time.monotonic() < deadline:
            if ready.is_file() and ready.read_text().strip() == str(proc.pid):
                break
            time.sleep(0.1)
        if proc.poll() is not None:
            with open(state / "watch.log", "rb") as log_file:
                log_file.seek(log_start)
                tail = log_file.read().decode(errors="replace").strip().splitlines()[-10:]
            print("rust-live: the watcher could not start:\n  " + "\n  ".join(tail), file=sys.stderr)
            return 1
        if not ready.is_file():
            print(f"rust-live: still setting up after {START_TIMEOUT_SECS} s (pid {proc.pid}); "
                  f"see {state / 'watch.log'}")
            return 0
        where = args.build_host or "this machine"
        print(f"rust-live: watching {tree}/cmux-tui; a saved .rs swaps the running daemon "
              f"(builds on {where}; log {state / 'watch.log'}). `cmux live status` shows the last swap.")
        return 0
    return run_watcher(args, tree, state)


def run_watcher(args, tree: Path, state: Path) -> int:
    # The watcher holds watch.lock while it lives, so a second one (a racing `start`, or a
    # `--foreground` run by hand) exits instead of building and swapping on the same saves.
    lock = open(state / "watch.lock", "w")  # noqa: SIM115 - held until the process ends
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("rust-live: another watcher already runs for this state folder; `cmux live stop --rust` stops it")
        return 1
    pid_file(state).write_text(f"{os.getpid()} {tree}\n")
    builder = Builder(tree, state, args.build_host, args.target)
    loop = Loop(tree, state, builder, Swapper(args.session, args.socket, state=state))
    signal.signal(signal.SIGTERM, lambda *_: loop.stop_event.set())
    try:
        loop.run()
    except KeyboardInterrupt:
        pass
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or "").strip().splitlines()[-1:] or [f"exit {error.returncode}"]
        print(f"rust-live: `{' '.join(map(str, error.cmd[:1] + error.cmd[-1:]))}` failed: {detail[0]}")
        return 1
    except RuntimeError as error:
        print(f"rust-live: {error}")
        return 1
    finally:
        # An app's daemon file goes back to the app's own build, and so does its daemon (hosts kept).
        try:
            restored = loop.swapper.restore_app()
        except RuntimeError as error:
            print(f"rust-live: {error}", file=sys.stderr)
            return 1
        if restored:
            print(f"rust-live: {restored} is the app's own build again, and its daemon too")
    return 0


def restore_left_apps(state: Path) -> int:
    """Hands every app daemon a watcher left swapped (its marker is still there: the watcher's own
    restore timed out, or it died) back to the app's own build. 0 when none is left."""
    failed = 0
    for marker in sorted(state.glob("app-original-*.json")):
        try:
            selector = json.loads(marker.read_text())["selector"]
        except (OSError, ValueError, KeyError):
            continue
        named = dict(zip(selector[::2], selector[1::2]))
        swapper = Swapper(named.get("--session"), named.get("--socket"), state=state)
        try:
            restored = swapper.restore_app()
        except RuntimeError as error:
            print(f"rust-live: {error}", file=sys.stderr)
            failed += 1
            continue
        if restored:
            print(f"rust-live: {restored} is the app's own build again, and its daemon too")
    return 1 if failed else 0


def command_stop(_args) -> int:
    state = state_dir()
    pid = running_pid(state)
    if pid is None:
        if any(state.glob("app-original-*.json")):
            return restore_left_apps(state)
        print("rust-live: not watching")
        return 0
    os.kill(pid, signal.SIGTERM)
    # It ends after the build under way, if any (and swaps nothing more); wait so no second loop starts.
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline and running_pid(state) == pid:
        time.sleep(0.1)
    if running_pid(state) == pid:
        # Still finishing a build; it swaps nothing more. Its pid file stays, so no second loop starts.
        print(f"rust-live: pid {pid} is finishing its build and then ends; it will swap nothing more")
        return 0
    pid_file(state).unlink(missing_ok=True)
    print(f"rust-live: stopped watching (pid {pid}); the daemon keeps the last build it swapped in")
    # The watcher puts an app's daemon back on its way out; a marker it left means that did not finish.
    return restore_left_apps(state)


def command_status(args) -> int:
    state = state_dir()
    pid = running_pid(state)
    last = None
    try:
        last = json.loads((state / "last.json").read_text())
    except (OSError, ValueError):
        pass
    if args.if_used and pid is None and last is None:
        return 0
    if args.json:
        print(json.dumps({"watching": pid is not None, "pid": pid, "last": last}, indent=2))
        return 0
    tree = pid_file(state).read_text().split(maxsplit=1)[1].strip() if pid else None
    print(f"Rust live: watching {tree} (pid {pid})" if pid else "Rust live: not watching")
    print(f"  last swap: {summary(last)}" if last else "  last swap: none yet")
    return 0


# ---------------------------------------------------------------- measuring


def request(sock: Path, payload: dict, timeout: float = 10.0) -> dict:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.settimeout(timeout)
        conn.connect(str(sock))
        conn.sendall((json.dumps(payload) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(65536)
            if not chunk:
                break
            buf += chunk
    response = json.loads(buf)
    if response.get("ok") is not True:
        raise RuntimeError(f"{payload.get('cmd')}: {response}")
    return response.get("data") or {}


def wait_until(what: str, deadline: float, probe):
    last = None
    while time.monotonic() < deadline:
        try:
            value = probe()
        except (OSError, RuntimeError, ValueError) as error:
            last, value = error, None
        if value:
            return value
        time.sleep(0.02)
    raise TimeoutError(f"{what}: timed out (last: {last})")


def shell_pid(screen: str, tag: str) -> int | None:
    for line in reversed(screen.splitlines()):
        line = line.strip()
        if line.startswith(f"{tag}=") and line[len(tag) + 1:].isdigit():
            return int(line[len(tag) + 1:])
    return None


def host_pids(state: Path) -> dict[str, int]:
    found: dict[str, int] = {}
    for path in state.rglob("*.json"):
        try:
            record = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        if isinstance(record, dict) and "host_pid" in record:
            found[str(record.get("terminal_id") or record.get("id") or path.stem)] = int(record["host_pid"])
    return found


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, round(fraction * (len(ordered) - 1))))
    return ordered[index]


def command_measure(args) -> int:
    tree = checkout(args.worktree)
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="rust-live-"))
    work.chmod(0o700)
    state = work / "loop"
    edit_path = tree / EDIT_FILE
    original = edit_path.read_text()
    if EDIT_ANCHOR not in original:
        print(json.dumps({"passed": False, "error": f"{EDIT_FILE} no longer has the edit anchor"}))
        return 1
    sock = work / "mux.sock"
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("ACPMUX_", "CMUX_")) and k not in ("ENV", "BASH_ENV")}
    # Every daemon this run touches is its own: scratch acpmux and config homes too.
    for folder in ("acpmux", "xdg"):
        (work / folder).mkdir(mode=0o700)
    env.update(ACPMUX_HOME=str(work / "acpmux"), XDG_CONFIG_HOME=str(work / "xdg"))
    env.update(CMUX_TUI_STATE_DIR=str(work / "sessions"), CMUX_TUI_HOST_EXE_DIR=str(work / "host-exe"),
               CMUX_TUI_SHELL_INTEGRATION="none", SHELL="/bin/sh")
    report: dict = {"tree": str(tree), "host": socket.gethostname(), "runs": [], "build_host": args.build_host or "here"}
    builder = Builder(tree, state, args.build_host, args.target)
    swapper = Swapper("rust-live-measure", str(sock), env)
    swaps: list[dict] = []
    swapped = threading.Condition()

    def on_swap(entry: dict) -> None:
        with swapped:
            swaps.append(entry)
            swapped.notify_all()

    loop = Loop(tree, state, builder, swapper, on_swap=on_swap, only=("cmux-tui",))

    def interrupted(*_):
        raise KeyboardInterrupt  # a fleet timeout's SIGTERM: the edit is taken back in `finally`
    signal.signal(signal.SIGTERM, interrupted)
    started_hosts: dict[str, int] = {}
    first = None
    watcher: threading.Thread | None = None
    try:
        # Warm build (the first build of a fresh checkout is a full one), then the old daemon.
        t = time.time()
        builder.sync([], [])
        ok, output = builder.build(["cmux-tui"])
        report["warm_build_secs"] = round(time.time() - t, 1)
        if not ok:
            raise RuntimeError("warm build failed: " + output.strip()[-2000:])
        first = builder.fetch(["cmux-tui"], state / "builds" / "0-warm")["cmux-tui"]
        ensure = swapper.cli(first, "server", "ensure")
        if ensure.returncode != 0:
            raise RuntimeError(f"server ensure: {(ensure.stderr or ensure.stdout).strip()}")
        wait_until("daemon", time.monotonic() + 30, lambda: request(sock, {"cmd": "identify"}))
        terms = []
        for i in range(args.terminals):
            created = request(sock, {"cmd": "run", "argv": ["/bin/sh"], "new_workspace": True})
            terms.append({"terminal_id": created["terminal_id"], "surface": created["surface"],
                          "incarnation": created["terminal_incarnation"], "marker": f"rust-live-{os.getpid()}-{i}"})
        for t_ in terms:
            request(sock, {"cmd": "send", "surface": t_["surface"],
                           "text": f"echo {t_['marker']}; echo PID$((0))=$$\n"})
        for t_ in terms:
            screen = wait_until("marker", time.monotonic() + 15, lambda t_=t_: (
                s := request(sock, {"cmd": "read-screen", "surface": t_["surface"]}).get("text") or "")
                and t_["marker"] in s and shell_pid(s, "PID0") and s)
            t_["shell_pid"] = shell_pid(screen, "PID0")
        started_hosts.update(host_pids(work))

        watcher = threading.Thread(target=loop.run, daemon=True, name="rust-live-watcher")
        watcher.start()
        loop.watching.wait(timeout=60)  # the loop's first scan, before the first edit
        for run_index in range(args.runs):
            token = f"r{run_index}-{os.getpid()}"
            # A marker per run, written just before the save: the swap must keep the screen it is on
            # (the first run's marker scrolls off the visible screen after a few runs).
            for t_ in terms:
                # A swap gives each adopted terminal a new surface id: resolve it again.
                t_["surface"] = wait_until("terminal", time.monotonic() + 30, lambda t_=t_: (
                    x := request(sock, {"cmd": "resolve-terminal", "terminal_id": t_["terminal_id"]}))
                    and x.get("lifecycle") == "running" and x.get("surface"))
                t_["marker"] = f"before-{token}-{t_['terminal_id']}"
                request(sock, {"cmd": "send", "surface": t_["surface"], "text": f"clear; echo {t_['marker']}\n"})
            for t_ in terms:
                wait_until("marker", time.monotonic() + 15, lambda t_=t_: t_["marker"] in (
                    request(sock, {"cmd": "read-screen", "surface": t_["surface"]}).get("text") or "").replace(
                    f"echo {t_['marker']}", ""))
            seen = len(swaps)
            edit_path.write_text(original.replace(EDIT_ANCHOR, EDIT_ANCHOR + f'        "live_probe": "{token}",\n', 1))
            saved_at = edit_path.stat().st_mtime_ns / 1e9
            with swapped:
                swapped.wait_for(lambda: len(swaps) > seen, timeout=args.timeout)
            entry = swaps[seen] if len(swaps) > seen else {"outcome": "timed_out"}
            result = {"run": run_index, "outcome": entry.get("outcome"), **{k: entry.get(k) for k in (
                "detect_secs", "sync_secs", "build_secs", "transfer_secs", "swap_secs", "save_to_swapped_secs", "swap",
                "bytes", "errors", "error")}}
            if entry.get("outcome") == "swapped":
                ident = request(sock, {"cmd": "identify"})
                answered_at = time.time()
                result["probe_answered"] = ident.get("live_probe") == token
                result["save_to_answer_secs"] = round(answered_at - saved_at, 3)
                result["daemon_pid"] = ident.get("pid")
                checks = []
                deadline = time.monotonic() + 30
                for t_ in terms:
                    try:
                        r = wait_until("adopted", deadline, lambda t_=t_: (
                            x := request(sock, {"cmd": "resolve-terminal", "terminal_id": t_["terminal_id"]}))
                            and x.get("lifecycle") == "running" and x.get("terminal_incarnation") == t_["incarnation"]
                            and x.get("surface"))
                        tag = f"PID{run_index + 1}"
                        request(sock, {"cmd": "send", "surface": r, "text": f"echo {tag}=$$\n"})
                        screen = wait_until("echo", deadline, lambda r=r, tag=tag: (
                            s := request(sock, {"cmd": "read-screen", "surface": r}).get("text") or "")
                            and shell_pid(s, tag) and s)
                        checks.append({"same_shell": shell_pid(screen, tag) == t_["shell_pid"],
                                       "scrollback_kept": t_["marker"] in screen})
                    except TimeoutError as error:
                        checks.append({"same_shell": False, "error": str(error)})
                result["terminals"] = checks
                result["terminals_survived"] = all(c.get("same_shell") and c.get("scrollback_kept") for c in checks)
            report["runs"].append(result)
            print(f"rust-live measure: run {run_index}: {json.dumps(result)}", file=sys.stderr, flush=True)
    except KeyboardInterrupt:
        report["error"] = "interrupted (SIGINT or SIGTERM)"
    except Exception as error:  # noqa: BLE001 - the report says what failed
        report["error"] = str(error)
    finally:
        loop.stop_event.set()
        loop.builder.cancel()
        if watcher is not None:
            watcher.join(timeout=60)  # never restore the file or remove state under a live watcher
        edit_path.write_text(original)
        try:
            ident = request(sock, {"cmd": "identify"})
            request(sock, {"cmd": "shutdown-daemon", "pid": ident.get("pid"),
                           "generation": ident.get("generation"), "end_terminals": True})
        except (OSError, RuntimeError, ValueError):
            pass
        started_hosts.update(host_pids(work))
        time.sleep(0.5)
        for pid in started_hosts.values():  # only the hosts this measurement started
            try:
                os.kill(pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
        shutil.copy2(state / "history.jsonl", out / "history.jsonl") if (state / "history.jsonl").exists() else None
        if not args.keep:
            shutil.rmtree(work, ignore_errors=True)
    good = [r for r in report["runs"] if r.get("outcome") == "swapped" and r.get("probe_answered")]
    if good:
        for key in ("save_to_swapped_secs", "save_to_answer_secs", "build_secs", "transfer_secs", "swap_secs", "detect_secs"):
            values = [r[key] for r in good if isinstance(r.get(key), (int, float))]
            if values:
                report[key.replace("_secs", "")] = {
                    "p50": round(statistics.median(values), 3), "p95": round(percentile(values, 0.95), 3),
                    "min": round(min(values), 3), "max": round(max(values), 3)}
    report["passed"] = bool(report["runs"]) and "error" not in report and len(good) == args.runs and all(
        r.get("terminals_survived") for r in good)
    (out / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 0 if report["passed"] else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("start", "measure"):
        p = sub.add_parser(name)
        p.add_argument("--worktree")
        p.add_argument("--build-host", help="ssh host that builds (default: build here)")
        p.add_argument("--target", help="target triple when the build host's differs from this machine's")
        if name == "start":
            p.add_argument("--session")
            p.add_argument("--socket")
            p.add_argument("--foreground", action="store_true")
        else:
            p.add_argument("--out", required=True)
            p.add_argument("--runs", type=int, default=20)
            p.add_argument("--terminals", type=int, default=3)
            p.add_argument("--timeout", type=float, default=300)
            p.add_argument("--keep", action="store_true")
    sub.add_parser("stop")
    status = sub.add_parser("status")
    status.add_argument("--json", action="store_true")
    status.add_argument("--if-used", action="store_true", help="print nothing when the loop never ran")
    args = parser.parse_args()
    return {"start": command_start, "stop": command_stop, "status": command_status,
            "measure": command_measure}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
