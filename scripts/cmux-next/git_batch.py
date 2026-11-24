#!/usr/bin/env python3
"""Git calls that send request bytes on stdin, shared by prepush-gate.py and guardrails.py.

The request goes through a temporary file, never a pipe: on some hosts a subprocess with more than
about 10 KB of piped stdin hangs (cmux-lawrence, e8b8e40e4e9: even `cat`), and a big `cat-file --batch`
answer can fill the stdout pipe while the request is still being written. A hang there would leave the
pre-push hook running forever, which no fail-open `except` can catch.

Each importer loads this file from its own folder (prepush-gate.py from the checkout or beside the
installed hook copy, guardrails.py from the checkout or the installed checks snapshot): `python3 -I`
puts no script folder on sys.path.
"""
from __future__ import annotations

import os
import re
import subprocess
import tempfile
from pathlib import Path

OBJECT_HEADER = re.compile(rb"^[0-9a-f]{40,64} (blob|tree|commit|tag) (\d+)$")
# The longest the one prefetch of a partial clone's missing blobs may take before cat_file goes on without it.
PREFETCH_TIMEOUT = 300
# From this many `<rev>:<path>` specs of one rev, cat_file reads them by blob id from one `ls-tree -r` of the rev
# (resolve_specs): git resolves each `<rev>:<path>` from the root tree again, about 4 ms a spec on big-red's cmux mirror
# (13,462 specs: 57.7 s by path, 0.7 s ls-tree + 1.3 s by id). Below it the listing (0.35 s) costs more than it saves.
RESOLVE_MIN_SPECS = 64
_git_version: tuple[int, int] | None = None


class GitError(RuntimeError):
    """A git call failed or answered less than it was asked."""


def run(repo: Path, args: list[str], data: bytes | None = None, env: dict[str, str] | None = None,
        timeout: float | None = None) -> subprocess.CompletedProcess:
    """`git -C REPO ARGS` with DATA (or nothing) on stdin from a temporary file; output captured as bytes."""
    with tempfile.TemporaryFile() as stdin:
        if data is not None:
            stdin.write(data)
            stdin.seek(0)
        return subprocess.run(["git", "-C", str(repo), *args], stdin=stdin, capture_output=True, env=env,
                              timeout=timeout)


def promisor_remote(repo: Path, env: dict[str, str] | None = None) -> str | None:
    """REPO's promisor remote (a partial clone's: `remote.<name>.promisor` true, or an older git's
    `extensions.partialClone`), or None when REPO is a whole clone."""
    marked = run(repo, ["config", "--type=bool", "--get-regexp", r"^remote\..*\.promisor$"], env=env).stdout
    for line in marked.decode("utf-8", "replace").splitlines():
        key, _, value = line.partition(" ")
        if value == "true" and key.startswith("remote.") and key.endswith(".promisor"):
            return key[len("remote."):-len(".promisor")]
    return run(repo, ["config", "--get", "extensions.partialClone"], env=env).stdout.decode().strip() or None


def honors_no_lazy_fetch(env: dict[str, str] | None = None) -> bool:
    """True when this git honors GIT_NO_LAZY_FETCH (2.44 and later). An older git fetches a missing blob while it
    is only asked whether it has it, so a probe would cost the very round trips it is meant to save."""
    global _git_version
    if _git_version is None:
        out = subprocess.run(["git", "--version"], capture_output=True, env=env).stdout.decode()
        found = re.search(r"(\d+)\.(\d+)", out)
        _git_version = (int(found.group(1)), int(found.group(2))) if found else (0, 0)
    return _git_version >= (2, 44)


# Which of the named objects a clone holds, never fetching, on every git: rev-list turns lazy fetching off in-process
# (`--missing=print`) and never scans the promisor packs for a miss. A named object the clone lacks is dropped
# (`--ignore-missing`; git 2.43 prints no `?` line for it), so what is missing is what was asked less what came back
# (scripts/ci/git_tree.py, leo-workspace tools/git_missing.py).
MISSING_ARGS = ["rev-list", "--objects", "--no-walk", "--ignore-missing", "--missing=print", "--stdin"]


def blob_ids(repo: Path, specs: list[str], env: dict[str, str] | None = None) -> set[str]:
    """The blob ids `<rev>:<path>` SPECS name, from `ls-tree` of each rev (trees only: local in a blobless clone, so
    nothing is fetched). A path a rev lacks, a tree or a rev ls-tree cannot read adds nothing."""
    quiet = {**(os.environ if env is None else env), "GIT_NO_LAZY_FETCH": "1"}
    wanted: dict[str, set[str]] = {}
    for spec in specs:
        rev, sep, path = spec.partition(":")
        if sep and rev and path:
            wanted.setdefault(rev, set()).add(path)
    oids: set[str] = set()
    for rev, paths in wanted.items():
        # A few paths: ls-tree of those alone; many: one listing of the whole tree (cheaper than a long pathspec).
        args = (["--literal-pathspecs", "ls-tree", "-z", "--full-tree", "--end-of-options", rev, "--", *sorted(paths)]
                if len(paths) < RESOLVE_MIN_SPECS else ["ls-tree", "-r", "-z", "--full-tree", "--end-of-options", rev])
        listing = run(repo, args, env=quiet, timeout=PREFETCH_TIMEOUT)
        if listing.returncode != 0:
            continue
        for entry in listing.stdout.split(b"\0"):
            meta, _, name = entry.partition(b"\t")
            fields = meta.split()
            if len(fields) == 3 and fields[1] == b"blob" and name.decode("utf-8", "surrogateescape") in paths:
                oids.add(fields[2].decode())
    return oids


def lacking(repo: Path, oids, env: dict[str, str] | None = None) -> set[str]:
    """Which of OIDS the clone at REPO does not hold, asked of rev-list once (MISSING_ARGS), fetching nothing.
    Raises GitError when rev-list fails."""
    oids = sorted(set(oids))
    if not oids:
        return set()
    listed = run(repo, MISSING_ARGS, "".join(f"{oid}\n" for oid in oids).encode(),
                 {**(os.environ if env is None else env), "GIT_NO_LAZY_FETCH": "1"}, PREFETCH_TIMEOUT)
    if listed.returncode != 0:
        raise GitError(f"git rev-list --missing=print exited {listed.returncode}")
    present = {line.split()[0] for line in listed.stdout.decode("utf-8", "replace").splitlines()
               if line and not line.startswith("?")}
    return {oid for oid in oids if oid not in present}


def fetch_ids(repo: Path, remote: str, oids, env: dict[str, str] | None = None) -> int:
    """Fetch the objects OIDS from REMOTE in ONE fetch: the command git itself runs for a lazy fetch, with every id on
    stdin instead of one. Returns how many it asked for (0 for none or on any failure)."""
    oids = sorted(set(oids))
    if not oids:
        return 0
    try:
        fetch = run(repo, ["-c", "fetch.negotiationAlgorithm=noop", "fetch", remote, "--no-tags",
                           "--no-write-fetch-head", "--recurse-submodules=no", "--filter=blob:none", "--stdin"],
                    "".join(f"{oid}\n" for oid in oids).encode(),
                    {**(os.environ if env is None else env), "GIT_TERMINAL_PROMPT": "0"}, PREFETCH_TIMEOUT)
    except (OSError, subprocess.SubprocessError):
        return 0
    return len(oids) if fetch.returncode == 0 else 0


def fetch_missing_ids(repo: Path, remote: str, oids, env: dict[str, str] | None = None) -> int:
    """Fetch the objects of OIDS the clone lacks (lacking) in one fetch; how many it lacked and fetched (0 when it
    lacks none, which costs one rev-list and no fetch; 0 on any failure: the caller reads as before)."""
    try:
        return fetch_ids(repo, remote, lacking(repo, oids, env), env)
    except (OSError, subprocess.SubprocessError, GitError):
        return 0


def fetch_blobs(repo: Path, remote: str, specs: list[str], env: dict[str, str] | None = None,
                only_missing: bool = False) -> int:
    """Fetch the blobs `<rev>:<path>` SPECS name from REMOTE in ONE fetch (ONLY_MISSING: only those the clone lacks,
    asked of rev-list first); returns how many ids it fetched (0 on any failure: the caller then reads as before,
    fetching blob by blob)."""
    try:
        oids = blob_ids(repo, specs, env)
    except (OSError, subprocess.SubprocessError):
        return 0
    return fetch_missing_ids(repo, remote, oids, env) if only_missing else fetch_ids(repo, remote, oids, env)


def cat_file(repo: Path, specs: list[str], env: dict[str, str] | None = None, ids: dict[str, str] | None = None
             ) -> dict[str, bytes | None]:
    """{spec: blob bytes, or None when the spec names no blob} for `<rev>:<path>` SPECS in one `cat-file --batch`.

    IDS, when given, gets each found blob's object id by spec.

    In a partial clone (the blobless clones agents push from), a plain `cat-file --batch` fetches each blob the
    clone lacks with its own round trip to the promisor remote: the pre-push gate builds trees of about 9,000 files
    at base and head, and on 2026-11-21 a merge push spent the gate's whole 600 s limit in here, three times in a
    row (0.49 s a blob on big-red; a cold clone's 9,000 now take 14 s). So the read there runs with
    GIT_NO_LAZY_FETCH first, which answers `missing` instead of fetching; the specs it misses get their blobs in
    one fetch (fetch_blobs) and are read again the plain way, which still fetches whatever the one fetch did not
    bring. A warm clone pays nothing extra: the first read is the whole read. A git before 2.44 asks rev-list which
    blobs it lacks first and fetches those in one fetch (fetch_blobs, only_missing).

    Raises GitError when git exits non-zero or its answer does not cover every spec in order (git stopped
    early, or an answer this parser does not know), so a caller never judges a file whose text it lacks.
    """
    if not specs:
        return {}
    # Many specs of one rev are read by blob id (resolve_specs): the same blobs, the same answer, a fraction of the time.
    queries = resolve_specs(repo, specs, env)
    remote = promisor_remote(repo, env)
    if remote is None:
        return _cat_file_batch(repo, specs, env, ids, set(), queries)
    if not honors_no_lazy_fetch(env):
        # A git before 2.44 (2.43: the GCP lane VMs') ignores GIT_NO_LAZY_FETCH, so the probe below would fetch blob
        # by blob itself. Ask rev-list which blobs the clone lacks instead, fetch those in one fetch, then read.
        # fs-agent-lane-10, 2026-11-24: reads blob by blob wrote a pack a second, 2372 in an hour, into the host's
        # shared wt mirror.
        fetch_blobs(repo, remote, specs, env, only_missing=True)
        return _cat_file_batch(repo, specs, env, ids, set(), queries)
    missing: set[str] = set()
    quiet = {**(os.environ if env is None else env), "GIT_NO_LAZY_FETCH": "1"}
    try:
        found = _cat_file_batch(repo, specs, quiet, ids, missing, queries)
    except GitError:
        # Fail open: the plain read, as before this probe existed.
        return _cat_file_batch(repo, specs, env, ids, set())
    if missing:
        again = [spec for spec in specs if spec in missing]
        fetch_blobs(repo, remote, again, env)
        found.update(_cat_file_batch(repo, again, env, ids, set(), queries))
    return found


def resolve_specs(repo: Path, specs: list[str], env: dict[str, str] | None = None) -> dict[str, str]:
    """{spec: the blob id it names} for each `<rev>:<path>` of SPECS whose rev has RESOLVE_MIN_SPECS specs or more,
    from one `ls-tree -r` of that rev (trees only: local in a blobless clone, read with GIT_NO_LAZY_FETCH).

    `cat-file --batch` resolves every `<rev>:<path>` from the rev's root tree again: on 2026-11-21 the pre-push gate's
    trees of a merge push (about 13,000 files at each of four revs) spent 26-33 s a side in it on big-red, about 350 s
    of the 798 s gate. A spec this leaves out (a path the rev lacks, a tree, a submodule, a rev ls-tree cannot read)
    is asked by its own text as before, so its answer is unchanged."""
    by_rev: dict[str, set[str]] = {}
    for spec in specs:
        rev, sep, path = spec.partition(":")
        if sep and rev and path:
            by_rev.setdefault(rev, set()).add(path)
    quiet = {**(os.environ if env is None else env), "GIT_NO_LAZY_FETCH": "1"}
    queries: dict[str, str] = {}
    for rev, paths in by_rev.items():
        if len(paths) < RESOLVE_MIN_SPECS:
            continue
        try:
            listing = run(repo, ["ls-tree", "-r", "-z", "--full-tree", "--end-of-options", rev], env=quiet,
                          timeout=PREFETCH_TIMEOUT)
        except (OSError, subprocess.SubprocessError):
            continue
        if listing.returncode != 0:
            continue
        for entry in listing.stdout.split(b"\0"):
            meta, _, name = entry.partition(b"\t")
            fields = meta.split()
            path = name.decode("utf-8", "surrogateescape")
            if len(fields) == 3 and fields[1] == b"blob" and path in paths:
                queries[f"{rev}:{path}"] = fields[2].decode()
    return queries


def _cat_file_batch(repo: Path, specs: list[str], env: dict[str, str] | None, ids: dict[str, str] | None,
                    missing: set[str], queries: dict[str, str] | None = None) -> dict[str, bytes | None]:
    """One `cat-file --batch` over SPECS (cat_file's answer); each spec git answers `missing` goes into MISSING.
    QUERIES: what to ask git for a spec instead of its own text (resolve_specs' blob ids)."""
    asked = [(queries or {}).get(spec, spec) for spec in specs]
    result = run(repo, ["cat-file", "--batch"], "".join(f"{query}\n" for query in asked).encode(), env)
    if result.returncode != 0:
        raise GitError(f"git cat-file --batch exited {result.returncode}: "
                       f"{result.stderr.decode('utf-8', 'replace').strip()}")
    out, cursor, found = result.stdout, 0, {}
    for spec, query in zip(specs, asked):
        end = out.find(b"\n", cursor)
        if end < 0:
            raise GitError(f"git cat-file --batch stopped before {spec!r} ({len(found)} of {len(specs)} answered)")
        header = out[cursor:end]
        cursor = end + 1
        match = OBJECT_HEADER.match(header)
        if match is None:
            if header == query.encode() + b" missing":
                found[spec] = None
                missing.add(spec)
                continue
            raise GitError(f"git cat-file --batch answered {header[:200]!r} for {spec!r}")
        size = int(match.group(2))
        if cursor + size + 1 > len(out):
            raise GitError(f"git cat-file --batch cut {spec!r} short")
        found[spec] = out[cursor:cursor + size] if match.group(1) == b"blob" else None
        if ids is not None and found[spec] is not None:
            ids[spec] = header.split(b" ", 1)[0].decode()
        cursor += size + 1
    return found
