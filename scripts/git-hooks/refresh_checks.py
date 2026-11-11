#!/usr/bin/env python3
"""Refresh the clone's installed cmux-next checks from the fetched feat-cmux-next before a push to it.

The pre-push gate runs the copy of scripts/cmux-next that install-git-hooks.sh put in the clone's hook folder
(cmux-next-checks, a link to a versioned copy). post-merge reinstalls it only in a checkout fast-forwarded to
exactly feat-cmux-next, and agents fetch and rebase in worktrees, so their copy stayed at the last pull: the
per-symbol compile trailer rule (2026-10-28) landed and no agent's push ran it. So pre-push runs this first.

On a push to feat-cmux-next of the canonical manaflow-ai/cmux remote, when what the copy is made from (every path
scripts/git-hooks/checks-copy-inputs lists, read at the fetched refs/remotes/<remote>/feat-cmux-next of a remote
with the canonical URL) differs from what the installed copy was made from (its .source stamp), and the stamp's
commit does not already contain that commit, this writes a new copy from that commit's blobs, never from the
working tree, and points the link at it with one rename (the installer's scheme: a running gate holds its copy
through a shared flock on .in-use). It also refreshes the gate entry point and its git helper in the hook folder.
It never refuses a push: on any error the push runs the copy it has.

The stamp is "<commit> <digest>", the digest a hash of the tree entries of exactly the listed paths at that commit;
install-git-hooks.sh writes it with `--stamp`, so both derive it from the one list. It used to be the
scripts/cmux-next tree alone, so a feat-cmux-next that changed only tests/workflow_jobs.py, which the copy also
carries, never reached an installed hook (Codex on #40894).
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

CANONICAL = (
    "git@github.com:manaflow-ai/cmux.git",
    "ssh://git@github.com/manaflow-ai/cmux.git",
    "https://github.com/manaflow-ai/cmux.git",
    "https://github.com/manaflow-ai/cmux",
)
BRANCH = "feat-cmux-next"
CHECKS = "cmux-next-checks"
INPUTS = "scripts/git-hooks/checks-copy-inputs"  # what the copy is made from: the installer's list and this one's
STAMP = ".source"  # "<commit> <digest of the INPUTS paths>" of the copy, or "worktree" for an install from a dirty tree
ENTRY_POINTS = {"prepush-gate.py": "cmux_next_prepush_gate.py", "git_batch.py": "git_batch.py",
                "github_release_download.py": "github_release_download.py"}


def git(repo: Path, *args: str, check: bool = True, data: bytes | None = None) -> bytes:
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    # DATA goes through a file, never `input=`: on a Mac short of pipe memory a write into a pipe blocks in the
    # kernel, where `timeout` never runs; pushes hung here for up to an hour on 2026-10-28 (git_batch.py).
    with tempfile.TemporaryFile() as stdin:
        if data is not None:
            stdin.write(data)
            stdin.seek(0)
        result = subprocess.run(["git", "-C", str(repo), *args], stdin=stdin, capture_output=True, env=env, timeout=60)
    if check and result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args[:2])} failed: {result.stderr.decode(errors='replace').strip()[:200]}")
    return result.stdout if result.returncode == 0 else b""


def trusted_commit(repo: Path) -> str | None:
    """The fetched feat-cmux-next of the first remote with the canonical URL, or None."""
    for remote in git(repo, "remote").decode().split():
        url = git(repo, "remote", "get-url", remote, check=False).decode().strip()
        if url in CANONICAL:
            sha = git(repo, "rev-parse", "--verify", "-q", f"refs/remotes/{remote}/{BRANCH}^{{commit}}",
                      check=False).decode().strip()
            if sha:
                return sha
    return None


def parse_inputs(text: str) -> list[str]:
    """The paths of a checks-copy-inputs file: one per line, `#` comments and blank lines skipped."""
    return [line.strip() for line in text.splitlines() if line.strip() and not line.strip().startswith("#")]


def inputs_at(repo: Path, commit: str) -> list[str] | None:
    """The INPUTS list at COMMIT, or None for a commit from before the list."""
    text = git(repo, "cat-file", "blob", f"{commit}:{INPUTS}", check=False)
    return parse_inputs(text.decode()) if text else None


def digest(repo: Path, commit: str, inputs: list[str]) -> str:
    """A hash of the tree entries (mode, id, path) of exactly the INPUTS paths at COMMIT; a path the commit lacks
    adds nothing, so adding it changes the digest."""
    listing = git(repo, "ls-tree", "-z", "--full-tree", commit, "--", *(entry.rstrip("/") for entry in inputs))
    return hashlib.sha256(listing).hexdigest()


def stamp_for(repo: Path, commit: str) -> str:
    """The .source stamp of a copy made from COMMIT ("worktree" when COMMIT has no INPUTS list)."""
    sha = git(repo, "rev-parse", "--verify", f"{commit}^{{commit}}").decode().strip()
    inputs = inputs_at(repo, sha)
    return "worktree" if inputs is None else f"{sha} {digest(repo, sha, inputs)}"


def wanted(relative: str) -> bool:
    """The installer's selection in a listed folder: its own files, and lint/ and arch_rules/ below it."""
    return "/" not in relative or relative.startswith(("lint/", "arch_rules/"))


def files_at(repo: Path, commit: str, folder: str) -> list[tuple[str, str]]:
    """(mode, path under FOLDER) of the copy's files from FOLDER at COMMIT."""
    folder = folder.rstrip("/")
    out = []
    for row in git(repo, "ls-tree", "-r", "-z", "--full-tree", commit, "--", folder).split(b"\0"):
        if not row:
            continue
        meta, _, path = row.decode().partition("\t")
        mode, kind, _ = meta.split(" ")
        relative = path[len(folder) + 1:]
        if kind == "blob" and mode in ("100644", "100755") and wanted(relative):
            out.append((mode, relative))
    return out


def blobs(repo: Path, specs: list[str]) -> list[bytes]:
    data = git(repo, "cat-file", "--batch", data="\n".join(specs).encode() + b"\n")
    out, at = [], 0
    for spec in specs:
        end = data.index(b"\n", at)
        header = data[at:end].decode()
        if header.endswith(" missing"):
            raise RuntimeError(f"{spec} is missing")
        size = int(header.rsplit(" ", 1)[1])
        out.append(data[end + 1:end + 1 + size])
        at = end + 1 + size + 1
    return out


def stale(repo: Path, hook_dir: Path, commit: str, tree: str) -> bool:
    """True when the installed copy is not made from TREE (the digest of the INPUTS paths) and does not already
    contain COMMIT (made from it or a
    descendant). A copy made from a commit feat-cmux-next never got (an agent's unpushed or rebased-away commit) is
    stale: keeping it until it became an ancestor kept its unreviewed checks forever."""
    try:
        stamp = (hook_dir / CHECKS / STAMP).read_text().split()
    except OSError:
        return True  # an install from before the stamp
    if len(stamp) != 2:
        return True  # an install from a dirty tree: the fetched feat-cmux-next is the reviewed rule
    if stamp[1] == tree:
        return False
    if not ok(repo, "cat-file", "-e", f"{stamp[0]}^{{commit}}"):
        return True  # made from a commit this clone does not have
    return not ok(repo, "merge-base", "--is-ancestor", commit, stamp[0])  # never back to an older rule


def ok(repo: Path, *args: str) -> bool:
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, env=env, timeout=60).returncode == 0


def write_atomic(path: Path, data: bytes, mode: int) -> None:
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_bytes(data)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def remove_unused(hook_dir: Path) -> None:
    """Remove versioned copies no gate holds (an exclusive flock on .in-use succeeds), except the current one.
    Copies without .in-use, `.partial` stages and `.deleting.` trees are the installer's cleanup."""
    current = os.readlink(hook_dir / CHECKS) if (hook_dir / CHECKS).is_symlink() else None
    for path in sorted(hook_dir.glob(f"{CHECKS}.v*")):
        if path.name == current or path.name.endswith(".partial") or not path.is_dir() or path.is_symlink():
            continue
        try:
            lock = os.open(path / ".in-use", os.O_RDONLY)
        except OSError:
            continue
        try:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                continue  # a push runs it
            claimed = path.with_name(f"{CHECKS}.deleting.{os.getpid()}.{path.name}")
            os.rename(path, claimed)
            shutil.rmtree(claimed, ignore_errors=True)
        finally:
            os.close(lock)


def refresh(repo: Path, hook_dir: Path, commit: str) -> str | None:
    """Write the copy of COMMIT and link it; the line to print, or None when the copy was already current."""
    inputs = inputs_at(repo, commit)
    if inputs is None:
        return None  # a feat-cmux-next from before the list: keep the copy this clone has
    tree = digest(repo, commit, inputs)
    if not stale(repo, hook_dir, commit, tree):
        return None
    lock = os.open(hook_dir / "install.lock", os.O_RDWR | os.O_CREAT, 0o644)
    try:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return "pre-push: an install of the hooks is running; this push runs the checks copy it has."
        if not stale(repo, hook_dir, commit, tree):  # another push refreshed it while this one waited
            return None
        # Every listed path (INPUTS says why each is there): a folder's selected files at the copy's root, a file
        # beside them under its own name.
        files: list[tuple[str, str]] = []
        contents: list[bytes] = []
        for entry in inputs:
            if entry.endswith("/"):
                found = files_at(repo, commit, entry)
                files += found
                contents += blobs(repo, [f"{commit}:{entry}{relative}" for _, relative in found]) if found else []
                continue
            data = git(repo, "cat-file", "blob", f"{commit}:{entry}", check=False)
            if data:
                files.append(("100644", Path(entry).name))
                contents.append(data)
        version = f"{CHECKS}.v{int(time.time())}.{os.getpid()}"
        stage = hook_dir / f"{version}.partial"
        shutil.rmtree(stage, ignore_errors=True)
        stage.mkdir()
        (stage / ".in-use").write_bytes(b"")
        for (mode, relative), data in zip(files, contents):
            target = stage / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            os.chmod(target, 0o755 if mode == "100755" else 0o644)
        (stage / STAMP).write_text(f"{commit} {tree}\n")
        os.rename(stage, hook_dir / version)
        for source, name in ENTRY_POINTS.items():
            if (hook_dir / version / source).is_file():
                write_atomic(hook_dir / name, (hook_dir / version / source).read_bytes(), 0o644)
        link = hook_dir / f"{CHECKS}.link.{os.getpid()}"
        if link.is_symlink() or link.exists():
            link.unlink()
        os.symlink(version, link)
        os.replace(link, hook_dir / CHECKS)
        remove_unused(hook_dir)
        return f"pre-push: refreshed the cmux-next checks to {BRANCH} {commit[:12]} (they were older)."
    finally:
        os.close(lock)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--hook-dir", type=Path)
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--remote-url", default="")
    parser.add_argument("--stamp", metavar="COMMIT",
                        help="print the .source stamp of a copy made from COMMIT and exit (install-git-hooks.sh)")
    args = parser.parse_args()
    if args.stamp:
        print(stamp_for(args.repo, args.stamp))
        return 0
    if args.hook_dir is None:
        parser.error("--hook-dir is required")
    lines = sys.stdin.read().splitlines()
    try:
        if args.remote_url not in CANONICAL:
            return 0
        if not any(len(row.split()) == 4 and row.split()[2] == f"refs/heads/{BRANCH}" for row in lines):
            return 0
        commit = trusted_commit(args.repo)
        if commit is None:
            return 0
        message = refresh(args.repo, args.hook_dir, commit)
        if message:
            print(message, file=sys.stderr)
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        print(f"pre-push: could not refresh the cmux-next checks ({type(error).__name__}: {error}); this push runs "
              "the copy it has.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
