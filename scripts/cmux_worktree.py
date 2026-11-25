#!/usr/bin/env python3
"""Make, slim and collect a clone's git worktrees: seconds to make, near-zero disk.

A plain `git worktree add` of feat-cmux-next writes all 54,000 tracked files:
1.3 GiB of new disk and about 16 s, every time, for every agent. On APFS the
files can instead be clones (clonefile(2)) of a clean checkout kept for that
purpose, the seed: the clones share the seed's blocks until one is written, so
a new worktree costs only its metadata. The catch is git's index: it records
each file's inode and ctime, which a clone does not keep, so git would read and
hash all 1.3 GiB again (about 14 s) on the first `git status`. A clone is
byte-for-byte the seed's file, whose blob the seed's index already names, so
this tool writes the new worktree's index itself: the seed's entries with the
clones' own stat data. Then `git read-tree -m -u` moves the files from the
seed's commit to the one asked for, writing only the files that differ.

    add [-b BRANCH | -B BRANCH | --detach] PATH [COMMIT]
        `git worktree add` with cloned files (COMMIT defaults to
        origin/feat-cmux-next when it exists, else HEAD). Where clones are not
        possible (another volume, not APFS) it checks out as git would.
        --cargo DIR (repeatable): also seed DIR/target with clones of the
        newest sibling worktree's DIR/target built by the same toolchain,
        without its `incremental` folders (they hold that sibling's own
        crates, which differ by path), under that target's cargo lock.
    seed [COMMIT]
        Make the seed, or move it to COMMIT. `add` moves it on its own once
        the seed is more than SEED_STALE_FILES files behind.
    dedupe [--apply] [--idle-hours N]
        Turn the unchanged tracked files of idle existing worktrees into
        clones of the seed's, the same files, so they share its blocks.
        Each file must match its index entry (size, mtime, inode, ctime)
        and have the seed's blob; the worktree's git index lock is held
        throughout and its index is rewritten with the clones' stat data,
        keeping each file's own mtime. Lists only, unless --apply.
    gc [--apply] [--idle-days N] [--json]
        Sort every worktree: removable (clean, nothing untracked, HEAD on
        origin/feat-cmux-next or origin/main, idle N days), and the ones kept:
        unpushed commits, uncommitted or untracked files, pushed but not
        landed, locked, or recently used. Lists only, unless --apply, which
        runs a plain `git worktree remove` (git refuses anything not clean)
        on the removable ones and `git worktree prune` for missing folders.

Why not symlinks: a symlinked node_modules resolves to the other worktree's
real path, so Vite, Metro and Node's resolver see packages outside the project
and load a second copy of React; a shared Cargo target dir makes concurrent
builds wait on one lock and lets one worktree's binary overwrite another's.
bun already installs node_modules as clones of its global store on APFS (4.8 s
and about 13 MB of new disk for webviews), so `bun install` stays the way to
get node_modules.
"""

from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import errno
import fcntl
import hashlib
import json
import os
import shutil
import signal
import struct
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Tuple

LANDING_REFS = ("origin/feat-cmux-next", "origin/main")
DEFAULT_BASES = ("origin/feat-cmux-next", "HEAD")
# The seed moves to the commit asked for once this many files differ.
SEED_STALE_FILES = 1500
SEED_LOCK_REASON = "cmux-worktree seed: clean checkout new worktrees clone; never edit it"
# Index extensions kept on a rewrite: the cache tree and resolve-undo hold no
# stat data or offsets. The rest (untracked cache, fsmonitor, offset tables)
# are rebuilt by git; a split or sparse index is refused.
KEPT_EXTENSIONS = (b"TREE", b"REUC")
REFUSED_EXTENSIONS = (b"link", b"sdir")
CLONE_NOFOLLOW = 0x0001
F_LOG2PHYS = 49  # <sys/fcntl.h>
GITLINK_MODE = 0o160000


# ---------------------------------------------------------------- utilities

def git(cwd: Path, *args: str, check: bool = True, env: Optional[dict] = None) -> str:
    result = subprocess.run(
        ["git", "-C", str(cwd), *args], text=True, capture_output=True, env=env,
        stdin=subprocess.DEVNULL,
    )
    if check and result.returncode != 0:
        raise GitError(f"git {' '.join(args)}: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout


class GitError(RuntimeError):
    pass


def git_ok(cwd: Path, *args: str) -> bool:
    return subprocess.run(
        ["git", "-C", str(cwd), *args], capture_output=True, stdin=subprocess.DEVNULL,
    ).returncode == 0


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


_libc = None


def libc():
    global _libc
    if _libc is None and sys.platform == "darwin":
        _libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
        _libc.clonefile.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint32]
        _libc.clonefile.restype = ctypes.c_int
    return _libc


def clone_path(src: Path, dst: Path) -> None:
    """Clone a file or a whole folder tree (dst must not exist).

    macOS: clonefile(2), which clones a folder tree in one call on APFS.
    Elsewhere: `cp -a --reflink=auto`, a copy-on-write clone where the file
    system has one and a plain copy where it does not.
    """
    lib = libc()
    if lib is not None:
        if lib.clonefile(os.fsencode(src), os.fsencode(dst), CLONE_NOFOLLOW) != 0:
            code = ctypes.get_errno()
            raise OSError(code, f"clonefile {src} -> {dst}: {os.strerror(code)}")
        return
    result = subprocess.run(["cp", "-a", "--reflink=auto", str(src), str(dst)], capture_output=True, text=True)
    if result.returncode != 0:
        raise OSError(errno.EIO, f"cp {src} -> {dst}: {result.stderr.strip()}")


def can_clone_cheaply() -> bool:
    return libc() is not None


def physical_offset(path: Path) -> Optional[int]:
    """The device offset of a file's first block (macOS), or None.

    Two files whose first blocks sit at the same device offset share them:
    one is a clone of the other.
    """
    if sys.platform != "darwin":
        return None
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError:
        return None
    try:
        # struct log2phys is packed to 4: u32 flags, off_t contigbytes, off_t devoffset.
        out = fcntl.fcntl(fd, F_LOG2PHYS, b"\0" * 20)
        return struct.unpack("=Iqq", out)[2]
    except OSError:
        return None
    finally:
        os.close(fd)


def common_dir(repo: Path) -> Path:
    raw = git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir").strip()
    return Path(raw).resolve()


def default_seed_dir(repo: Path) -> Path:
    override = os.environ.get("CMUX_WORKTREE_SEED_DIR")
    if override:
        return Path(override)
    key = hashlib.sha256(str(common_dir(repo)).encode()).hexdigest()[:12]
    if sys.platform == "darwin":
        base = Path.home() / "Library" / "Caches"
    else:
        base = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache")
    return base / "cmux-worktree-seed" / key


class FileLock:
    """flock(2) on a file; shared or exclusive, blocking or not."""

    def __init__(self, path: Path, exclusive: bool, blocking: bool = True):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
        flags = fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH
        if not blocking:
            flags |= fcntl.LOCK_NB
        try:
            fcntl.flock(self.fd, flags)
        except BlockingIOError:
            os.close(self.fd)
            raise

    def release(self) -> None:
        if self.fd >= 0:
            os.close(self.fd)
            self.fd = -1

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.release()


# ---------------------------------------------------------------- git index

@dataclass
class IndexEntry:
    stat: List[int]  # ctime_s, ctime_ns, mtime_s, mtime_ns, dev, ino, mode, uid, gid, size
    oid: bytes
    flags: int
    extended: int
    path: bytes

    @property
    def mode(self) -> int:
        return self.stat[6]

    @property
    def stage(self) -> int:
        return (self.flags >> 12) & 3


@dataclass
class Index:
    version: int
    entries: List[IndexEntry]
    extensions: List[Tuple[bytes, bytes]] = field(default_factory=list)
    oid_size: int = 20


def _varint(data: bytes, pos: int) -> Tuple[int, int]:
    """Git's offset varint (index v4 path prefix lengths)."""
    byte = data[pos]
    pos += 1
    value = byte & 0x7F
    while byte & 0x80:
        byte = data[pos]
        pos += 1
        value = ((value + 1) << 7) | (byte & 0x7F)
    return value, pos


def read_index(path: Path, oid_size: int = 20) -> Index:
    data = path.read_bytes()
    trailer = len(data) - oid_size
    if data[:4] != b"DIRC":
        raise ValueError(f"{path}: not a git index")
    version, count = struct.unpack(">II", data[4:12])
    if version not in (2, 3, 4):
        raise ValueError(f"{path}: index version {version}")
    pos = 12
    entries: List[IndexEntry] = []
    previous = b""
    for _ in range(count):
        start = pos
        stat = list(struct.unpack(">10I", data[pos:pos + 40]))
        pos += 40
        oid = data[pos:pos + oid_size]
        pos += oid_size
        (flags,) = struct.unpack(">H", data[pos:pos + 2])
        pos += 2
        extended = 0
        if flags & 0x4000:
            (extended,) = struct.unpack(">H", data[pos:pos + 2])
            pos += 2
        if version == 4:
            strip, pos = _varint(data, pos)
            end = data.index(b"\0", pos)
            name = previous[: len(previous) - strip] + data[pos:end]
            pos = end + 1
        else:
            end = data.index(b"\0", pos)
            name = data[pos:end]
            pos = start + ((end - start + 8) & ~7)
        previous = name
        entries.append(IndexEntry(stat, oid, flags, extended, name))
    extensions: List[Tuple[bytes, bytes]] = []
    while pos + 8 <= trailer:
        sig = data[pos:pos + 4]
        (size,) = struct.unpack(">I", data[pos + 4:pos + 8])
        extensions.append((sig, data[pos + 8:pos + 8 + size]))
        pos += 8 + size
    return Index(version, entries, extensions, oid_size)


def serialize_index(index: Index) -> bytes:
    extended = any(entry.flags & 0x4000 for entry in index.entries)
    version = 3 if extended else 2
    out = bytearray(b"DIRC" + struct.pack(">II", version, len(index.entries)))
    for entry in index.entries:
        start = len(out)
        out += struct.pack(">10I", *[value & 0xFFFFFFFF for value in entry.stat])
        out += entry.oid
        flags = (entry.flags & ~0x0FFF) | min(len(entry.path), 0x0FFF)
        out += struct.pack(">H", flags)
        if flags & 0x4000:
            out += struct.pack(">H", entry.extended)
        out += entry.path
        length = len(out) - start
        out += b"\0" * (((length + 8) & ~7) - length)
    for sig, payload in index.extensions:
        if sig in KEPT_EXTENSIONS:
            out += sig + struct.pack(">I", len(payload)) + payload
    hasher = hashlib.sha1() if index.oid_size == 20 else hashlib.sha256()
    hasher.update(out)
    out += hasher.digest()
    return bytes(out)


def check_index_rewritable(index: Index, where: Path) -> None:
    for sig, _ in index.extensions:
        if sig in REFUSED_EXTENSIONS:
            raise ValueError(f"{where}: index has a {sig.decode()} extension (split or sparse index)")


def stat_fields(st: os.stat_result, mode: int) -> List[int]:
    """An index entry's ten stat words for `st`, cut to 32 bits as git stores them."""
    values = [
        st.st_ctime_ns // 1_000_000_000, st.st_ctime_ns % 1_000_000_000,
        st.st_mtime_ns // 1_000_000_000, st.st_mtime_ns % 1_000_000_000,
        st.st_dev, st.st_ino, mode, st.st_uid, st.st_gid, st.st_size,
    ]
    return [value & 0xFFFFFFFF for value in values]


def same_stat(fresh: List[int], recorded: List[int]) -> bool:
    """Whether a file's stat words are the ones its index entry records, as git compares
    them: never the device (git does not without USE_STDEV, and macOS numbers a volume
    anew after a restart: 16777232 in old entries, 16777233 now on this Mac), and only
    the seconds where a git built without nanosecond stat stored 0."""
    for position, (now, then) in enumerate(zip(fresh, recorded)):
        if position == 4 or (position in (1, 3) and then == 0):
            continue
        if now != then:
            return False
    return True


def oid_size_of(repo: Path) -> int:
    fmt = git(repo, "rev-parse", "--show-object-format", check=False).strip() or "sha1"
    return 32 if fmt == "sha256" else 20


def git_dir(worktree: Path) -> Path:
    return Path(git(worktree, "rev-parse", "--path-format=absolute", "--git-dir").strip())


def write_index_locked(worktree_git_dir: Path, index: Index) -> None:
    """Write the index the way git does: into index.lock (made exclusively), then rename."""
    target = worktree_git_dir / "index"
    lock = worktree_git_dir / "index.lock"
    fd = os.open(lock, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(serialize_index(index))
        os.replace(lock, target)
    except BaseException:
        try:
            os.unlink(lock)
        except FileNotFoundError:
            pass
        raise


# ---------------------------------------------------------------- the seed

@dataclass
class Seed:
    root: Path

    @property
    def lock_path(self) -> Path:
        return self.root.parent / (self.root.name + ".lock")

    def exists(self) -> bool:
        return (self.root / ".git").is_file()

    def commit(self) -> str:
        return git(self.root, "rev-parse", "HEAD").strip()

    def is_clean(self) -> bool:
        out = git(self.root, "status", "--porcelain=v1", "--ignored=traditional", "--untracked-files=all", check=False)
        return out == ""


def ensure_seed(repo: Path, seed_dir: Path, commit: str) -> Seed:
    """The seed checkout, made at `commit` when there is none, and clean.

    Checked under the seed's lock held shared (a move holds it exclusive, so a
    seed half way through one never looks changed); made again, when missing or
    changed, under it held exclusive, after a second look."""
    seed = Seed(seed_dir)
    with FileLock(seed.lock_path, exclusive=False):
        if seed.exists() and seed.is_clean():
            return seed
    with FileLock(seed.lock_path, exclusive=True):
        if seed.exists():
            if seed.is_clean():
                return seed
            log(f"cmux-worktree: the seed {seed_dir} has changes; making it again")
            git(repo, "worktree", "remove", "--force", "--force", str(seed_dir), check=False)
            shutil.rmtree(seed_dir, ignore_errors=True)
        seed_dir.parent.mkdir(parents=True, exist_ok=True)
        # A seed folder deleted from the cache stays registered and locked: unlock it so prune drops it.
        git(repo, "worktree", "unlock", str(seed_dir), check=False)
        git(repo, "worktree", "prune")
        git(repo, "worktree", "add", "--detach", str(seed_dir), commit)
        git(repo, "worktree", "lock", "--reason", SEED_LOCK_REASON, str(seed_dir), check=False)
    return seed


def move_seed(seed: Seed, commit: str) -> bool:
    """Move the seed to `commit`, unless a clone holds it now."""
    try:
        lock = FileLock(seed.lock_path, exclusive=True, blocking=False)
    except BlockingIOError:
        return False
    with lock:
        git(seed.root, "checkout", "-q", "--detach", commit)
    return True


def changed_files(repo: Path, a: str, b: str) -> int:
    if a == b:
        return 0
    out = git(repo, "diff", "--no-renames", "--name-only", "-z", a, b)
    return out.count("\0")


# ---------------------------------------------------------------- add

@dataclass
class AddResult:
    path: str
    commit: str
    method: str  # "clone" or "checkout"
    seconds: float
    seed_commit: Optional[str] = None
    files_written: Optional[int] = None
    seed_moved: bool = False
    note: Optional[str] = None
    cargo: List[dict] = field(default_factory=list)


def resolve_commit(repo: Path, commit: Optional[str]) -> str:
    candidates = [commit] if commit else list(DEFAULT_BASES)
    for candidate in candidates:
        if git_ok(repo, "rev-parse", "--verify", "--quiet", f"{candidate}^{{commit}}"):
            return candidate
    raise GitError(f"no such commit: {commit or ' or '.join(DEFAULT_BASES)}")


def clone_from_seed(seed: Seed, dest: Path, oid_size: int) -> Tuple[str, int]:
    """Fill `dest` (a worktree made with --no-checkout) with clones of the seed's
    files, and write its index: the seed's entries with the clones' stat data.
    Returns the seed's commit and the number of entries. Holds the seed's lock
    shared, so the seed does not move meanwhile."""
    with FileLock(seed.lock_path, exclusive=False):
        seed_commit = seed.commit()
        seed_index = read_index(git_dir(seed.root) / "index", oid_size)
        check_index_rewritable(seed_index, seed.root)
        made: List[Path] = []
        try:
            for name in sorted(os.listdir(seed.root)):
                if name == ".git":
                    continue
                target = dest / name
                clone_path(seed.root / name, target)
                made.append(target)
        except BaseException:
            for target in made:
                if target.is_dir() and not target.is_symlink():
                    shutil.rmtree(target, ignore_errors=True)
                else:
                    target.unlink(missing_ok=True)
            raise
    entries = []
    for entry in seed_index.entries:
        if entry.mode == GITLINK_MODE or entry.flags & 0x8000:  # submodule or assume-valid: as the seed has it
            entries.append(entry)
            continue
        # A file the clean seed lacks raises: the caller checks out instead.
        st = os.lstat(dest / os.fsdecode(entry.path))
        entries.append(IndexEntry(stat_fields(st, entry.mode), entry.oid, entry.flags, entry.extended, entry.path))
    write_index_locked(git_dir(dest), Index(seed_index.version, entries, seed_index.extensions, oid_size))
    return seed_commit, len(entries)


def seed_cargo_target(repo: Path, dest: Path, crate_dir: str) -> dict:
    """Clone the newest sibling worktree's `crate_dir/target` (same toolchain) into dest."""
    report = {"dir": crate_dir}
    mine = dest / crate_dir
    if not mine.is_dir():
        report["skipped"] = "no such folder"
        return report
    if (mine / "target").exists():
        report["skipped"] = "target exists"
        return report
    toolchain = _toolchain_text(dest, mine)
    donors = []
    for wt in list_worktrees(repo):
        root = Path(wt["worktree"])
        if root.resolve() == dest.resolve():
            continue
        target = root / crate_dir / "target"
        if not target.is_dir() or _toolchain_text(root, root / crate_dir) != toolchain:
            continue
        donors.append((target.stat().st_mtime, target))
    for _, target in sorted(donors, reverse=True):
        locks = []
        try:
            for profile in target.iterdir():
                if not profile.is_dir():
                    continue
                for lock_file in sorted(profile.glob(".cargo*lock")):
                    locks.append(FileLock(lock_file, exclusive=False, blocking=False))
        except BlockingIOError:
            for lock in locks:
                lock.release()
            continue  # building now: try the next one
        try:
            (mine / "target").mkdir(parents=True)
            for item in target.iterdir():
                if item.is_dir() and not item.is_symlink() and (item / "incremental").is_dir():
                    (mine / "target" / item.name).mkdir()
                    for sub in item.iterdir():
                        if sub.name != "incremental":
                            clone_path(sub, mine / "target" / item.name / sub.name)
                else:
                    clone_path(item, mine / "target" / item.name)
            report["from"] = str(target)
            return report
        finally:
            for lock in locks:
                lock.release()
    report["skipped"] = "no sibling target with this toolchain"
    return report


def _toolchain_text(root: Path, start: Path) -> str:
    folder = start
    while True:
        for name in ("rust-toolchain.toml", "rust-toolchain"):
            candidate = folder / name
            if candidate.is_file():
                return candidate.read_text(errors="replace")
        if folder == root or folder.parent == folder:
            return ""
        folder = folder.parent


def add(repo: Path, path: Path, commit: Optional[str], branch_flag: Optional[str], branch: Optional[str],
        seed_dir: Path, cargo_dirs: List[str]) -> AddResult:
    started = time.monotonic()
    base = resolve_commit(repo, commit)
    args = ["worktree", "add", "--no-checkout"]
    if branch_flag:
        args += [branch_flag] + ([branch] if branch else [])
    args += [str(path), base]
    git(repo, *args)
    target_commit = git(path, "rev-parse", "HEAD").strip()
    oid_size = oid_size_of(repo)
    result = AddResult(str(path), target_commit, "checkout", 0.0)
    try:
        if os.environ.get("CMUX_WORKTREE_NO_CLONE") == "1":
            raise OSError(errno.ENOTSUP, "CMUX_WORKTREE_NO_CLONE=1")
        seed = ensure_seed(repo, seed_dir, target_commit)
        seed_commit, _ = clone_from_seed(seed, path, oid_size)
        result.method = "clone"
        result.seed_commit = seed_commit
    except (OSError, ValueError, GitError) as error:
        result.note = f"cloning failed, checked out instead: {error}"
        log(f"cmux-worktree: {result.note}")
        seed_commit = None
    if seed_commit is None:
        git(path, "read-tree", "-u", "--reset", "HEAD")
        result.files_written = None
    elif seed_commit != target_commit:
        result.files_written = changed_files(repo, seed_commit, target_commit)
        git(path, "read-tree", "-m", "-u", seed_commit, target_commit)
    else:
        result.files_written = 0
    for crate_dir in cargo_dirs:
        result.cargo.append(seed_cargo_target(repo, path, crate_dir))
    result.seconds = round(time.monotonic() - started, 2)
    if result.method == "clone" and (result.files_written or 0) > SEED_STALE_FILES:
        result.seed_moved = move_seed(Seed(seed_dir), target_commit)
    return result


# ---------------------------------------------------------------- worktree list

def list_worktrees(repo: Path) -> List[dict]:
    out = git(repo, "worktree", "list", "--porcelain")
    items: List[dict] = []
    current: dict = {}
    for line in out.splitlines():
        if not line:
            if current:
                items.append(current)
            current = {}
            continue
        key, _, value = line.partition(" ")
        current[key] = value if value else True
    if current:
        items.append(current)
    return items


def last_used(worktree: Path) -> Optional[float]:
    try:
        gdir = git_dir(worktree)
    except GitError:
        return None
    times = []
    for name in ("index", "HEAD", "logs/HEAD", "index.lock"):
        try:
            times.append((gdir / name).stat().st_mtime)
        except OSError:
            pass
    return max(times) if times else None


# ---------------------------------------------------------------- dedupe

@dataclass
class DedupeReport:
    worktree: str
    status: str
    files: int = 0
    bytes: int = 0


def dedupe_worktree(worktree: Path, seed: Seed, seed_entries: Dict[bytes, IndexEntry], oid_size: int,
                    apply: bool, seed_offsets: Optional[Dict[bytes, Optional[int]]] = None) -> DedupeReport:
    seed_offsets = {} if seed_offsets is None else seed_offsets
    report = DedupeReport(str(worktree), "ok")
    gdir = git_dir(worktree)
    lock_path = gdir / "index.lock"
    try:
        lock_fd = os.open(lock_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644) if apply else -1
    except FileExistsError:
        report.status = "busy: git holds its index"
        return report
    try:
        index_path = gdir / "index"
        index_stat = index_path.stat()
        index_mtime_s = index_stat.st_mtime_ns // 1_000_000_000
        index = read_index(index_path, oid_size)
        check_index_rewritable(index, worktree)
        try:
            _dedupe_entries(worktree, seed, seed_entries, index, index_mtime_s, apply, seed_offsets, report)
        finally:
            # Also when stopped part way (SIGTERM unwinds as SystemExit): the files already
            # replaced get their new stat data, so git need not read them again.
            if apply and report.files:
                with os.fdopen(lock_fd, "wb") as handle:
                    lock_fd = -1
                    handle.write(serialize_index(index))
                os.replace(lock_path, index_path)
                # Keep the index's times: `gc` reads them as when the worktree was last used, and
                # every file kept its mtime, older than this, so none becomes racily clean.
                os.utime(index_path, ns=(index_stat.st_atime_ns, index_stat.st_mtime_ns))
    except (OSError, ValueError, GitError) as error:
        report.status = f"skipped: {error}"
    finally:
        if lock_fd >= 0:
            os.close(lock_fd)
        if apply and lock_path.exists():
            try:
                os.unlink(lock_path)
            except FileNotFoundError:
                pass
    return report


def _dedupe_entries(worktree: Path, seed: Seed, seed_entries: Dict[bytes, IndexEntry], index: Index,
                    index_mtime_s: int, apply: bool, seed_offsets: Dict[bytes, Optional[int]],
                    report: DedupeReport) -> None:
    """Count (and with `apply`, clone the seed's file over) each unchanged file. With
    `apply`, report.files counts only the files already replaced, at any point."""
    for entry in index.entries:
        seed_entry = seed_entries.get(entry.path)
        mode = entry.mode
        if (seed_entry is None or entry.stage != 0 or mode & 0o170000 != 0o100000
                or entry.flags & 0x8000 or entry.extended & 0x4000
                or seed_entry.oid != entry.oid or seed_entry.mode != mode or entry.stat[9] == 0):
            continue
        file_path = worktree / os.fsdecode(entry.path)
        try:
            st = os.lstat(file_path)
        except OSError:
            continue
        if not same_stat(stat_fields(st, mode), entry.stat):
            continue  # changed (or only stat-dirty) since git last looked: leave it
        if st.st_mtime_ns // 1_000_000_000 >= index_mtime_s:
            continue  # racily clean: git itself would read it again
        seed_file = seed.root / os.fsdecode(entry.path)
        if entry.path not in seed_offsets:
            seed_offsets[entry.path] = physical_offset(seed_file)
        seed_offset = seed_offsets[entry.path]
        if seed_offset is not None and seed_offset == physical_offset(file_path):
            continue  # already a clone of the seed's
        report.files += 1
        report.bytes += st.st_size
        if not apply:
            continue
        temp = file_path.with_name(f".{file_path.name}.cmux-dedupe")
        report.files -= 1  # counted again once the clone is in place
        report.bytes -= st.st_size
        try:
            temp.unlink()
        except FileNotFoundError:
            pass
        try:
            clone_path(seed_file, temp)
            os.utime(temp, ns=(st.st_atime_ns, st.st_mtime_ns), follow_symlinks=False)
            if not same_stat(stat_fields(os.lstat(file_path), mode), entry.stat):  # written meanwhile
                continue
            os.replace(temp, file_path)
        finally:
            try:
                temp.unlink()
            except FileNotFoundError:
                pass
        entry.stat = stat_fields(os.lstat(file_path), mode)
        report.files += 1
        report.bytes += st.st_size


def dedupe(repo: Path, seed_dir: Path, apply: bool, idle_hours: float, only: Optional[List[str]],
           jobs: int = 1) -> List[DedupeReport]:
    if not can_clone_cheaply():
        raise SystemExit("cmux-worktree dedupe: needs APFS clones (macOS)")
    seed = Seed(seed_dir)
    if not seed.exists() or not seed.is_clean():
        raise SystemExit(f"cmux-worktree dedupe: no clean seed at {seed_dir}; run `seed` first")
    oid_size = oid_size_of(repo)
    reports: List[DedupeReport] = []
    with FileLock(seed.lock_path, exclusive=False):
        seed_index = read_index(git_dir(seed.root) / "index", oid_size)
        seed_entries = {entry.path: entry for entry in seed_index.entries if entry.stage == 0}
        now = time.time()
        seed_offsets: Dict[bytes, Optional[int]] = {}
        todo: List[Path] = []
        for wt in list_worktrees(repo):
            root = Path(wt["worktree"])
            if only and str(root) not in only and str(root.resolve()) not in only:
                continue
            if root.resolve() == seed.root.resolve() or wt.get("bare"):
                continue
            if wt.get("prunable") or not root.is_dir():
                reports.append(DedupeReport(str(root), "missing"))
                continue
            used = last_used(root)
            if not only and (used is None or now - used < idle_hours * 3600):
                reports.append(DedupeReport(str(root), "in use"))
                continue
            todo.append(root)

        def one(root: Path) -> DedupeReport:
            report = dedupe_worktree(root, seed, seed_entries, oid_size, apply, seed_offsets)
            log(f"dedupe: {report.status} {report.files} files {report.bytes / 2**30:.2f} GiB {root}")
            return report

        with ThreadPoolExecutor(max_workers=max(1, jobs)) as pool:
            reports += list(pool.map(one, todo))
    return reports


# ---------------------------------------------------------------- gc

@dataclass
class GcEntry:
    worktree: str
    branch: Optional[str]
    verdict: str  # remove | prune | keep
    reason: str
    idle_days: Optional[float] = None
    unpushed: int = 0


def classify(repo: Path, wt: dict, seed_dir: Path, idle_days: float, landing: List[str], now: float) -> GcEntry:
    root = Path(wt["worktree"])
    branch = wt.get("branch")
    branch_name = branch[len("refs/heads/"):] if isinstance(branch, str) and branch.startswith("refs/heads/") else None
    entry = GcEntry(str(root), branch_name, "keep", "")
    if root.resolve() == seed_dir.resolve():
        entry.reason = "the seed"
        return entry
    if wt.get("bare") or root.resolve() == common_dir(repo).parent.resolve():
        entry.reason = "the main checkout"
        return entry
    if wt.get("prunable") or not root.is_dir():
        entry.verdict, entry.reason = "prune", "folder is gone"
        return entry
    if wt.get("locked"):
        entry.reason = f"locked: {wt['locked']}" if isinstance(wt["locked"], str) else "locked"
        return entry
    used = last_used(root)
    entry.idle_days = None if used is None else round((now - used) / 86400, 1)
    head = wt.get("HEAD")
    if not isinstance(head, str):
        entry.reason = "no HEAD"
        return entry
    # --no-optional-locks: no index refresh written, which would make it look just used.
    status = git(root, "--no-optional-locks", "status", "--porcelain=v1", "--untracked-files=normal", check=False)
    on_landing = [ref for ref in landing if git_ok(repo, "merge-base", "--is-ancestor", head, ref)]
    if not on_landing:
        upstream = f"origin/{branch_name}" if branch_name else None
        if upstream and git_ok(repo, "rev-parse", "--verify", "--quiet", upstream) and \
                git_ok(repo, "merge-base", "--is-ancestor", head, upstream):
            entry.reason = f"pushed to {upstream}, not landed"
        else:
            existing = [ref for ref in landing if git_ok(repo, "rev-parse", "--verify", "--quiet", ref)]
            count = git(repo, "rev-list", "--count", head, *[f"^{ref}" for ref in existing], check=False).strip()
            entry.unpushed = int(count or 0)
            entry.reason = f"{entry.unpushed} unpushed commit(s)"
        if status:
            entry.reason += f"; {len(status.splitlines())} uncommitted or untracked file(s)"
        return entry
    if status:
        entry.reason = f"landed, but {len(status.splitlines())} uncommitted or untracked file(s)"
        return entry
    if entry.idle_days is None or entry.idle_days < idle_days:
        entry.reason = f"landed, used {entry.idle_days} day(s) ago"
        return entry
    entry.verdict, entry.reason = "remove", f"clean, on {on_landing[0]}, idle {entry.idle_days} day(s)"
    return entry


def gc(repo: Path, seed_dir: Path, idle_days: float, apply: bool, landing: List[str]) -> List[GcEntry]:
    now = time.time()
    with ThreadPoolExecutor(max_workers=4) as pool:
        entries = list(pool.map(lambda wt: classify(repo, wt, seed_dir, idle_days, landing, now), list_worktrees(repo)))
    if apply:
        for entry in entries:
            if entry.verdict == "remove":
                result = subprocess.run(["git", "-C", str(repo), "worktree", "remove", entry.worktree],
                                        capture_output=True, text=True)
                if result.returncode != 0:
                    entry.verdict, entry.reason = "keep", f"git refused: {result.stderr.strip()}"
                else:
                    entry.verdict = "removed"
        if any(entry.verdict == "prune" for entry in entries):
            git(repo, "worktree", "prune")
            for entry in entries:
                if entry.verdict == "prune":
                    entry.verdict = "pruned"
    return entries


# ---------------------------------------------------------------- CLI

def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="cmux-worktree", description=__doc__.split("\n\n")[0])
    parser.add_argument("-C", dest="repo", default=".", help="the repository (default: the current folder)")
    parser.add_argument("--seed-dir", help="the seed checkout (default: a per-clone folder in the user cache)")
    sub = parser.add_subparsers(dest="command", required=True)

    p_add = sub.add_parser("add", help="git worktree add, with files cloned from the seed")
    group = p_add.add_mutually_exclusive_group()
    group.add_argument("-b", dest="new_branch")
    group.add_argument("-B", dest="reset_branch")
    group.add_argument("--detach", action="store_true")
    p_add.add_argument("--cargo", action="append", default=[], metavar="DIR",
                       help="also seed DIR/target from the newest sibling worktree's (repeatable)")
    p_add.add_argument("--json", action="store_true")
    p_add.add_argument("path")
    p_add.add_argument("commit", nargs="?")

    p_seed = sub.add_parser("seed", help="make the seed, or move it to COMMIT")
    p_seed.add_argument("commit", nargs="?")

    p_dedupe = sub.add_parser("dedupe", help="make idle worktrees' unchanged files clones of the seed's")
    p_dedupe.add_argument("--apply", action="store_true")
    p_dedupe.add_argument("--idle-hours", type=float, default=24.0)
    p_dedupe.add_argument("--only", action="append", help="just this worktree (any idle time)")
    p_dedupe.add_argument("--jobs", type=int, default=1, help="worktrees at once (default 1)")
    p_dedupe.add_argument("--json", action="store_true")

    p_gc = sub.add_parser("gc", help="list (or --apply: remove) landed, clean, idle worktrees")
    p_gc.add_argument("--apply", action="store_true")
    p_gc.add_argument("--idle-days", type=float, default=3.0)
    p_gc.add_argument("--landing", action="append", help=f"refs that count as landed (default {', '.join(LANDING_REFS)})")
    p_gc.add_argument("--json", action="store_true")

    args = parser.parse_args(argv)
    # A stop (SIGTERM) unwinds like an exception, so each `finally` lets go of a git index
    # lock and removes a half-made clone.
    signal.signal(signal.SIGTERM, lambda number, frame: sys.exit(128 + number))
    repo = Path(args.repo).resolve()
    seed_dir = Path(args.seed_dir) if args.seed_dir else default_seed_dir(repo)

    if args.command == "add":
        flag, branch = None, None
        if args.new_branch:
            flag, branch = "-b", args.new_branch
        elif args.reset_branch:
            flag, branch = "-B", args.reset_branch
        elif args.detach:
            flag = "--detach"
        result = add(repo, Path(args.path).absolute(), args.commit, flag, branch, seed_dir, args.cargo)
        if args.json:
            print(json.dumps(result.__dict__, indent=2))
        else:
            how = "cloned from the seed" if result.method == "clone" else "checked out"
            print(f"{result.path}: {how} at {result.commit[:12]} in {result.seconds}s"
                  + (f" ({result.files_written} file(s) differ from the seed)" if result.method == "clone" else ""))
            for cargo in result.cargo:
                print(f"  {cargo['dir']}/target: " + (f"cloned from {cargo['from']}" if "from" in cargo else cargo["skipped"]))
        return 0
    if args.command == "seed":
        commit = resolve_commit(repo, args.commit)
        seed = ensure_seed(repo, seed_dir, commit)
        target = git(repo, "rev-parse", f"{commit}^{{commit}}").strip()
        if seed.commit() != target and not move_seed(seed, target):
            print(f"{seed_dir}: in use; not moved", file=sys.stderr)
            return 1
        print(f"{seed_dir}: seed at {seed.commit()[:12]}")
        return 0
    if args.command == "dedupe":
        reports = dedupe(repo, seed_dir, args.apply, args.idle_hours, args.only, args.jobs)
        if args.json:
            print(json.dumps([report.__dict__ for report in reports], indent=2))
        else:
            total_files = sum(report.files for report in reports)
            total_bytes = sum(report.bytes for report in reports)
            for report in reports:
                if report.files or report.status != "ok":
                    print(f"{report.status:<12} {report.files:>6} files {report.bytes / 2**30:7.2f} GiB  {report.worktree}")
            verb = "made clones of" if args.apply else "would make clones of"
            print(f"{verb} {total_files} files, {total_bytes / 2**30:.2f} GiB")
        return 0
    if args.command == "gc":
        entries = gc(repo, seed_dir, args.idle_days, args.apply, args.landing or list(LANDING_REFS))
        if args.json:
            print(json.dumps([entry.__dict__ for entry in entries], indent=2))
        else:
            for entry in sorted(entries, key=lambda e: (e.verdict, e.worktree)):
                print(f"{entry.verdict:<8} {entry.worktree}  ({entry.reason})")
            counts: Dict[str, int] = {}
            for entry in entries:
                counts[entry.verdict] = counts.get(entry.verdict, 0) + 1
            print(", ".join(f"{n} {verdict}" for verdict, n in sorted(counts.items())))
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
