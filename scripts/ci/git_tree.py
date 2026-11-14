#!/usr/bin/env python3
"""One commit's tree, read from git's object database and never from the working tree.

A check that reads declared or manifest paths "from this checkout" with `(root / path).is_file()` and
`read_text()` sees only what the working tree holds: a sparse checkout (`wt new`, `sparse-checkout: scripts/ci`)
leaves whole directories out, so a path the commit has reads as missing and the check fails with a reason that has
nothing to do with the file (cmux-next-ios/rust/Cargo.toml "is not a text file GitHub served", 2026-11-11). GitTree
reads the commit instead:

- `git ls-tree -r -t` lists every entry with its mode, so a sparse checkout lists the same paths a full one does;
- a symlink (mode 120000) is followed inside the tree, never read as the text of its target's name, and one that
  leaves the tree or loops is refused;
- a directory, a submodule (mode 160000), a binary blob (a NUL byte in its first 8000, git's own test) and a path the
  commit does not have are each refused by name;
- a blob a partial clone (`--filter=blob:none`) never fetched is refused as NeedsFullTree, never read as missing, and
  never fetched behind the caller's back.

Which blobs this clone lacks is asked first, once per tree, of `git rev-list --objects --no-walk --missing=print
--stdin` (a `?oid` line is missing), the probe leo-workspace's tools/git_missing.py uses (LW#4389). rev-list turns lazy
fetching off in-process on every git and does not scan the promisor packs for a miss. `cat-file` is then asked only
for blobs that are present: on a missing blob it lazily fetches where git ignores GIT_NO_LAZY_FETCH (before 2.44 and
its backports), scans every promisor pack where git honours it (976-5538 s on a blobless mirror), and on Git 2.43
answers an empty line, not `missing`. Present blobs are read through one `git cat-file --batch` process, so a scan of
thousands of files costs two processes.
"""
from __future__ import annotations

import os
import posixpath
import signal
import subprocess
from pathlib import Path
from typing import Callable

GIT_SECONDS = 120
# Which named objects this clone lacks, never fetching (leo-workspace tools/git_missing.py's ARGS): `?oid` lines are
# missing; --ignore-missing keeps a missing named object from failing the call; --no-walk reads only what is named.
MISSING_ARGS = ("rev-list", "--objects", "--no-walk", "--filter=tree:1", "--ignore-missing", "--missing=print",
                "--stdin")
SYMLINK_HOPS = 40
BINARY_PROBE = 8000  # bytes git reads for a NUL before calling a blob binary (buffer_is_binary)
REGULAR = ("100644", "100755")
SYMLINK = "120000"
SUBMODULE = "160000"
DIRECTORY = "040000"


class Unreadable(Exception):
    """PATH is not a text file of the tree: missing, a directory, a submodule, binary, or a symlink out of it."""


class NeedsFullTree(Unreadable):
    """The tree has PATH but this clone does not hold its blob (a partial clone): the answer needs a full tree."""


def _env() -> dict[str, str]:
    return {**os.environ, "GIT_NO_LAZY_FETCH": "1", "GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "",
            "SSH_ASKPASS": "", "LC_ALL": "C"}


class GitTree:
    """The tree of REF (default HEAD) in the repository at ROOT."""

    def __init__(self, root: Path | str, ref: str = "HEAD", *, entries: dict[str, tuple[str, str]] | None = None,
                 read_blob: Callable[[str, str], bytes] | None = None):
        """ENTRIES, when given, is entries() already listed (a caller that keeps one listing per commit). READ_BLOB,
        when given, reads every blob (path, object id) -> bytes in place of cat-file: a promisor cache whose owner
        fetches blobs on demand (base_red_excuse.git_text). It raises NeedsFullTree when it cannot fetch one. Either
        way the path is resolved, followed and refused here, so every reader agrees on what a path names."""
        self.root = Path(root)
        self.ref = ref
        self._entries = entries
        self._read_blob = read_blob
        self._missing: set[str] | None = None
        self._batch: subprocess.Popen | None = None

    def __enter__(self) -> "GitTree":
        return self

    def __exit__(self, *_exc) -> None:
        self.close()

    def __del__(self) -> None:
        try:
            self.close()
        except Exception:  # noqa: BLE001 - interpreter shutdown
            pass

    def close(self) -> None:
        batch, self._batch = self._batch, None
        if batch is not None:
            try:
                batch.stdin.close()
            finally:
                batch.wait(timeout=GIT_SECONDS)
                batch.stdout.close()

    def _git(self, *args: str) -> bytes:
        try:
            done = subprocess.run(["git", "-C", str(self.root), *args], capture_output=True, env=_env(),
                                  stdin=subprocess.DEVNULL, timeout=GIT_SECONDS)
        except (OSError, subprocess.SubprocessError) as why:
            raise Unreadable(f"git {' '.join(args[:2])} failed in {self.root}: {why}") from None
        if done.returncode:
            raise Unreadable(f"git {' '.join(args[:2])} failed in {self.root}: "
                             + done.stderr.decode(errors="replace").strip()[:500])
        return done.stdout

    def entries(self) -> dict[str, tuple[str, str]]:
        """{path: (mode, object id)} of every entry of the tree, directories included."""
        if self._entries is None:
            out = self._git("ls-tree", "-r", "-t", "-z", "--full-tree", self.ref)
            entries: dict[str, tuple[str, str]] = {}
            for record in out.split(b"\0"):
                if not record:
                    continue
                meta, _, name = record.partition(b"\t")
                mode, _kind, oid = meta.decode().split(" ")
                entries[name.decode("utf-8", "surrogateescape")] = (mode, oid)
            self._entries = entries
        return self._entries

    def missing(self) -> set[str]:
        """The object ids of the tree's blobs (files and symlinks) this clone does not hold, asked of rev-list once
        (MISSING_ARGS) so that nothing is fetched and no promisor pack is scanned, on any git. Raises Unreadable when
        git cannot say."""
        if self._missing is None:
            oids = sorted({oid for mode, oid in self.entries().values() if mode in REGULAR or mode == SYMLINK})
            if not oids:
                self._missing = set()
                return self._missing
            try:
                proc = subprocess.Popen(["git", "-C", str(self.root), *MISSING_ARGS], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=_env(),
                                        start_new_session=True)
            except OSError as why:
                raise Unreadable(f"git rev-list failed in {self.root}: {why}") from None
            try:
                out, err = proc.communicate("".join(f"{oid}\n" for oid in oids).encode(), timeout=GIT_SECONDS)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
                proc.communicate()
                raise Unreadable(f"git rev-list in {self.root} could not say within {GIT_SECONDS} s which of "
                                 f"{len(oids)} blobs this clone holds") from None
            if proc.returncode:
                raise Unreadable(f"git rev-list failed in {self.root}: "
                                 + err.decode(errors="replace").strip()[:500])
            present = {line.split()[0] for line in out.decode(errors="replace").splitlines()
                       if line and not line.startswith("?")}
            self._missing = {oid for oid in oids if oid not in present}
        return self._missing

    def _needs_full_tree(self, path: str, oid: str) -> NeedsFullTree:
        return NeedsFullTree(
            f"{self.ref}: {path} (blob {oid[:12]}) is in the tree but not in this clone's objects, a partial clone "
            f"that never fetched it: this check needs a full tree (a clone without --filter, or "
            f"`git -C {self.root} fetch --refetch origin`), and reads nothing in its place")

    def _link(self, path: str, oid: str) -> str:
        target = self._blob(path, oid).decode("utf-8", "surrogateescape")
        if target.startswith("/"):
            raise Unreadable(f"{self.ref}: {path} is a symlink to the absolute path {target}, outside the tree")
        joined = posixpath.normpath(posixpath.join(posixpath.dirname(path), target))
        if joined == ".." or joined.startswith("../"):
            raise Unreadable(f"{self.ref}: {path} is a symlink to {target}, outside the tree")
        return "" if joined == "." else joined

    def real(self, path: str) -> str:
        """PATH with every symlink on the way followed (what Path.resolve gives in a full checkout), or PATH itself
        when the tree has no such path."""
        found = self.resolve(path)
        return path if found is None else found[0]

    def resolve(self, path: str) -> tuple[str, str, str] | None:
        """(path, mode, object id) of PATH with every symlink on the way followed inside the tree; None when the
        tree has no such path. Raises Unreadable for a symlink out of the tree or a loop."""
        entries = self.entries()
        wanted = self._inside(path)
        for _ in range(SYMLINK_HOPS):
            parts = [] if wanted in ("", ".") else wanted.split("/")
            for at in range(1, len(parts) + 1):
                prefix = "/".join(parts[:at])
                found = entries.get(prefix)
                if found is None:
                    return None
                mode, oid = found
                if mode == SYMLINK:
                    rest = parts[at:]
                    wanted = posixpath.normpath(posixpath.join(self._link(prefix, oid), *rest)) if rest \
                        else self._link(prefix, oid)
                    break
                if at < len(parts) and mode != DIRECTORY:
                    return None  # a file or submodule with a path under it
            else:
                if not parts:
                    return "", DIRECTORY, ""
                return wanted, *entries[wanted]
        raise Unreadable(f"{self.ref}: {path} is a symlink loop (over {SYMLINK_HOPS} hops)")

    def _inside(self, path: str) -> str:
        """PATH as a path of the tree (normalized, no trailing "/"); raises Unreadable for one outside it. An absolute
        path is outside, never the tree path it would be with its leading "/" stripped: a Cargo `path = "/dep"` names
        the filesystem's /dep, which Path.resolve read as that, not the repository's dep/."""
        if path.startswith("/"):
            raise Unreadable(f"{self.ref}: {path} is an absolute path, outside the tree")
        wanted = posixpath.normpath(path.rstrip("/")) if path.rstrip("/") else "."
        if wanted == ".." or wanted.startswith("../"):
            raise Unreadable(f"{self.ref}: {path} is outside the tree")
        return wanted

    def is_file(self, path: str) -> bool:
        """Whether PATH is a regular file of the tree, through symlinks."""
        try:
            found = self.resolve(path)
        except NeedsFullTree:
            raise  # a link whose blob this clone lacks is unknown, never "not a file"
        except Unreadable:
            return False
        return found is not None and found[1] in REGULAR

    def files(self, under: str = "", suffix: str = "") -> list[str]:
        """Sorted paths of the regular files and file symlinks under UNDER (the whole tree when empty) whose names end
        in SUFFIX: what `(root / under).rglob("*" + suffix)` lists in a full checkout."""
        inside = self._inside(under) if under else "."
        prefix = "" if inside == "." else inside + "/"
        return sorted(path for path, (mode, _) in self.entries().items()
                      if path.startswith(prefix) and path.endswith(suffix)
                      and (mode in REGULAR or (mode == SYMLINK and self.is_file(path))))

    def _blob(self, path: str, oid: str) -> bytes:
        if self._read_blob is not None:
            return self._read_blob(path, oid)
        if oid in self.missing():
            raise self._needs_full_tree(path, oid)  # never asked of cat-file (missing(), module docs)
        if self._batch is None:
            try:
                self._batch = subprocess.Popen(["git", "-C", str(self.root), "cat-file", "--batch"], env=_env(),
                                               stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                               stderr=subprocess.DEVNULL)
            except OSError as why:
                raise Unreadable(f"git cat-file failed in {self.root}: {why}") from None
        batch = self._batch
        try:
            batch.stdin.write(oid.encode() + b"\n")
            batch.stdin.flush()
            header = batch.stdout.readline().decode(errors="replace").split()
        except OSError as why:
            self._batch = None
            batch.kill()
            batch.wait()
            batch.stdout.close()
            raise Unreadable(f"git cat-file in {self.root} ended reading {path}: {why}") from None
        if not header:
            self._batch = None
            batch.kill()
            code = batch.wait()
            batch.stdout.close()
            raise Unreadable(f"git cat-file in {self.root} ended reading {path} (exit {code})")
        if len(header) == 2 and header[1] == "missing":  # gone since missing() asked
            raise self._needs_full_tree(path, oid)
        if len(header) != 3:
            raise Unreadable(f"git cat-file answered {' '.join(header)!r} for {path}")
        size = int(header[2])
        data = batch.stdout.read(size)
        batch.stdout.read(1)  # the newline after the content
        return data

    def data(self, path: str) -> bytes:
        """PATH's bytes, through symlinks; raises Unreadable (NeedsFullTree for a blob the clone lacks)."""
        found = self.resolve(path)
        if found is None:
            raise Unreadable(f"{self.ref}: {path} is not in the tree")
        where, mode, oid = found
        named = path if where == path else f"{path} (-> {where})"
        if mode == DIRECTORY:
            raise Unreadable(f"{self.ref}: {named} is a directory, not a file")
        if mode == SUBMODULE:
            raise Unreadable(f"{self.ref}: {named} is a submodule, not a file")
        return self._blob(where, oid)

    def text(self, path: str, errors: str = "strict") -> str:
        """PATH's text, through symlinks. Raises Unreadable for a missing path, a directory, a submodule or a binary
        blob, and NeedsFullTree for a blob a partial clone lacks."""
        data = self.data(path)
        if b"\0" in data[:BINARY_PROBE]:
            raise Unreadable(f"{self.ref}: {path} is binary, not text")
        try:
            return data.decode("utf-8", errors)
        except UnicodeDecodeError as why:
            raise Unreadable(f"{self.ref}: {path} is not UTF-8 text ({why})") from None
