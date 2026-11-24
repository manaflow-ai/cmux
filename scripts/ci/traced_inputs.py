#!/usr/bin/env python3
"""Traced job inputs: derive what a check reads by watching one run, then key its receipt on exactly that.

hq RFD 0148 row 9. Receipts keyed by a check's declared inputs hit 0 to 2% where the check declares `**` and 84%
where the inputs are narrow (hq RFD 0023, receipts-replay-results.txt); a hand-written input list was once rolled
back because it missed a file (job_input_fingerprint.py). This script does not trust a list: it runs the check under
strace and records every repository path the check opened, listed, probed or executed.

Manifest entry kinds (paths relative to the repository root):
  F  a file opened for reading or executed       -> keyed on its git blob id and mode
  N  a directory whose entries were listed       -> keyed on the names and types of its entries (not their contents)
  E  a path stat'ed, probed or opened and absent -> keyed on what is there: blob mode, tree, or nothing
Reads of paths the job itself wrote and git does not track are outputs, not inputs. Reads under `.git/` and git
subprocesses are classified by command: `ls-files` keys on the whole path list (`L`), anything that reads history
or the commit itself makes the job unkeyable by tree. A connect() to a non-local address, and a read of an
untracked file the job did not write, are recorded as risks: shadow mode reports them, and `key` refuses with
--strict.

Shadow mode (nothing is skipped): `shadow` keys this run with the previous run's manifest, finds the receipt a
reusing scheduler would have used, and reports `would_reuse`; the run then executes in full and its own fresh
manifest re-keys both trees. When the old manifest says "same inputs" but the fresh one does not, the tracer missed
a read (`unsound`); when a reuse would have hidden a red, that is `wrong_pass`. Both must stay at zero before
anything is skipped.

usage:
  traced_inputs.py trace --root DIR --out MANIFEST [--rev REV] -- CMD [ARG...]   run CMD traced; exit with its status
  traced_inputs.py key --manifest M --rev REV [--root DIR] [--salt S] [--strict] -> `key=<sha256>` or `key=` + why
  traced_inputs.py entries --manifest M --rev REV [--root DIR]                  -> one `KIND path state` line each
  traced_inputs.py shadow --manifest-old M0 --manifest-new M1 --rev REV --prior-rev P [--root DIR]
                                                                                -> `shadow=<json>`
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

VERSION = 1
SYSCALLS = "%file,getdents64,connect"
WRITE_FLAGS = ("O_WRONLY", "O_RDWR", "O_CREAT", "O_TRUNC", "O_APPEND", "O_TMPFILE")
MUTATING = {"unlink", "unlinkat", "rename", "renameat", "renameat2", "mkdir", "mkdirat", "rmdir", "symlink",
            "symlinkat", "link", "linkat", "creat", "truncate", "utimensat", "chmod", "fchmodat", "fchmodat2",
            "chown", "fchownat", "lchown", "mknod", "mknodat"}
PROBES = {"stat", "lstat", "newfstatat", "fstatat64", "statx", "access", "faccessat", "faccessat2", "readlink",
          "readlinkat", "chdir", "statfs", "getxattr", "lgetxattr", "listxattr", "llistxattr", "inotify_add_watch"}
OPENS = {"open", "openat", "openat2"}
EXECS = {"execve", "execveat"}
# git subcommands whose answer is a function of the tree's path list or of the index built from it.
GIT_PATHLIST = {"ls-files", "check-ignore", "check-attr"}
# git subcommands that read nothing a tree key misses.
GIT_HARMLESS = {"--version", "version", "config", "var", "help", "hash-object", "check-ref-format"}
LINE = re.compile(r"^(?:\[pid\s+\d+\]\s+)?(?P<call>[a-z_0-9]+)\((?P<args>.*)\)\s+=\s+(?P<ret>.*)$")
DECOR = re.compile(r"^(?:AT_FDCWD|-?\d+)<(?P<path>(?:[^>\\]|\\.)*)>")
QUOTED = re.compile(r'"((?:[^"\\]|\\.)*)"')
IGNORED_UNTRACKED = re.compile(r"(^|/)(__pycache__/.*|[^/]*\.pyc|\.pytest_cache/.*|\.mypy_cache/.*)$")


def unescape(s: str) -> str:
    """Undo strace's C escaping of a path string."""
    return bytes(s, "latin-1").decode("unicode_escape").encode("latin-1").decode("utf-8", "surrogateescape")


def split_args(args: str) -> list[str]:
    """Split strace's argument text on top-level commas (not inside quotes, braces, brackets or <decorations>)."""
    out, depth, cur, quote, esc = [], 0, [], False, False
    for ch in args:
        if quote:
            cur.append(ch)
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                quote = False
            continue
        if ch == '"':
            quote = True
        elif ch in "{[<(":
            depth += 1
        elif ch in "}]>)":
            depth -= 1
        elif ch == "," and depth == 0:
            out.append("".join(cur).strip())
            cur = []
            continue
        cur.append(ch)
    if cur:
        out.append("".join(cur).strip())
    return out


def resolve(dirarg: str | None, path: str) -> str:
    if path.startswith("/"):
        return os.path.normpath(path)
    base = None
    if dirarg:
        m = DECOR.match(dirarg)
        if m:
            base = unescape(m.group("path"))
    return os.path.normpath(os.path.join(base or "/", path))


class Trace:
    """What one traced run did, by absolute path."""

    def __init__(self) -> None:
        self.reads: set[str] = set()      # opened for reading, existed
        self.listed: set[str] = set()     # getdents on it
        self.probed: set[str] = set()     # stat/access/readlink, or an open that failed
        self.written: set[str] = set()
        self.execs: list[list[str]] = []  # argv of every execve that succeeded
        self.connects: set[str] = set()

    def feed(self, line: str) -> None:
        m = LINE.match(line)
        if not m:
            return
        call, args, ret = m.group("call"), split_args(m.group("args")), m.group("ret")
        ok = not ret.startswith("-1")
        if call == "getdents64" or call == "getdents":
            d = DECOR.match(args[0]) if args else None
            if d:
                self.listed.add(unescape(d.group("path")))
            return
        if call == "connect":
            if ok or "EINPROGRESS" in ret:
                text = args[1] if len(args) > 1 else ""
                if "AF_UNIX" not in text and "127.0.0.1" not in text and '"::1"' not in text:
                    self.connects.add(text[:200])
            return
        if call in EXECS:
            if ok and len(args) > 1:
                self.execs.append([unescape(s) for s in QUOTED.findall(args[1])])
                q = QUOTED.match(args[0]) if call == "execve" else None
                if q:
                    self.reads.add(resolve(None, unescape(q.group(1))))
            return
        # Every other traced call names one or two paths; the dirfd before a path resolves it.
        paths = []
        for i, a in enumerate(args):
            q = QUOTED.fullmatch(a)
            if q:
                paths.append(resolve(args[i - 1] if i and DECOR.match(args[i - 1] or "") else None, unescape(q.group(1))))
        if not paths:
            return
        if call in OPENS:
            flags = args[2] if call != "open" and len(args) > 2 else (args[1] if len(args) > 1 else "")
            if any(f in flags for f in WRITE_FLAGS):
                self.written.add(paths[0])
            elif ok and "O_DIRECTORY" not in flags:
                self.reads.add(paths[0])
            else:
                self.probed.add(paths[0])
        elif call in MUTATING:
            self.written.update(paths)
        else:
            self.probed.update(paths)


def git(root: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True, text=True,
                          errors="surrogateescape").stdout


def tree_index(root: Path, rev: str) -> dict[str, tuple[str, str, str]]:
    """path -> (mode, type, object id) for every blob and tree at REV, plus '' for the root tree."""
    out = {"": ("040000", "tree", git(root, "rev-parse", f"{rev}^{{tree}}").strip())}
    raw = subprocess.run(["git", "-C", str(root), "ls-tree", "-r", "-t", "-z", "--full-tree", rev],
                         check=True, capture_output=True).stdout
    for rec in raw.split(b"\0"):
        if not rec:
            continue
        meta, path = rec.split(b"\t", 1)
        mode, typ, oid = meta.decode().split()
        out[path.decode("utf-8", "surrogateescape")] = (mode, typ, oid)
    return out


def classify_git(argv: list[str]) -> str | None:
    """None: harmless; 'L': answer is a function of the path list; 'H': reads history or the commit."""
    words = argv[1:]
    sub = None
    i = 0
    while i < len(words):
        w = words[i]
        if w in ("-C", "-c", "--git-dir", "--work-tree"):
            i += 2
            continue
        if w.startswith("-") and w not in ("--version",):
            i += 1
            continue
        sub = w
        break
    if sub is None or sub in GIT_HARMLESS:
        return None
    if sub in GIT_PATHLIST:
        return "L"
    if sub == "rev-parse" and all(a.startswith("--show-") or a.startswith("--is-") or a == "--git-dir"
                                  or a == "--absolute-git-dir" for a in words[i + 1:]):
        return None
    return "H"


def build_manifest(tr: Trace, root: Path, rev: str, command: list[str]) -> dict:
    root = root.resolve()
    rs = str(root)
    idx = tree_index(root, rev)
    gitdir = os.path.join(rs, ".git")

    def rel(p: str) -> str | None:
        if p == rs:
            return ""
        if p.startswith(rs + "/"):
            return p[len(rs) + 1:]
        return None

    entries: dict[str, str] = {}
    untracked, git_paths, outside = set(), set(), {}
    written = {r for r in (rel(p) for p in tr.written) if r is not None}

    def add(kind: str, p: str) -> None:
        r = rel(p)
        if r is None:
            top = "/".join(p.split("/")[:3])
            outside[top] = outside.get(top, 0) + 1
            return
        if p == gitdir or p.startswith(gitdir + "/"):
            git_paths.add(r)
            return
        tracked = r in idx
        if not tracked and kind != "E":
            if r in written or any(r.startswith(w + "/") for w in written) or IGNORED_UNTRACKED.search(r):
                return
            untracked.add(r)
            kind = "E"  # key on its absence at REV; the risk list names it
        if not tracked and r in written:
            return
        rank = {"E": 0, "N": 1, "F": 2}
        if idx.get(r, ("", "", ""))[1] == "tree" and kind == "F":
            kind = "N"
        if rank[kind] >= rank.get(entries.get(r, "E"), 0) or r not in entries:
            if r in entries and rank[entries[r]] > rank[kind]:
                return
            entries[r] = kind

    for p in tr.probed:
        add("E", p)
    for p in tr.listed:
        add("N", p)
    for p in tr.reads:
        add("F", p)
    git_class = None
    git_calls = []
    for argv in tr.execs:
        if argv and os.path.basename(argv[0]) == "git":
            c = classify_git(argv)
            git_calls.append({"argv": argv[:8], "class": c})
            if c == "H" or (c == "L" and git_class is None):
                git_class = c
    if git_paths and git_class is None:
        # .git was read by something other than a git subprocess we saw (a library, a script reading HEAD).
        heads = {p for p in git_paths if p not in (".git", ".git/config", ".git/info/exclude", ".git/commondir")}
        if heads:
            git_class = "H"
    return {
        "version": VERSION,
        "rev": git(root, "rev-parse", rev).strip(),
        "command": command,
        "entries": dict(sorted(entries.items())),
        "git": git_class,
        "git_calls": git_calls[:200],
        "git_paths": sorted(git_paths)[:200],
        "risks": {"untracked_reads": sorted(untracked)[:500], "network": sorted(tr.connects)},
        "outside": dict(sorted(outside.items(), key=lambda kv: -kv[1])[:40]),
        "counts": {k: sum(1 for v in entries.values() if v == k) for k in "FNE"},
    }


def cmd_trace(a: argparse.Namespace) -> int:
    if not shutil.which("strace"):
        print("traced_inputs: strace is not installed", file=sys.stderr)
        return 127
    root = Path(a.root).resolve()
    with tempfile.TemporaryDirectory(prefix="traced-inputs-") as tmp:
        prefix = os.path.join(tmp, "t")
        st = subprocess.run(["strace", "-f", "-ff", "--seccomp-bpf", "-qq", "-y", "-e", f"trace={SYSCALLS}",
                             "-e", "signal=none", "-o", prefix, *a.cmd])
        tr = Trace()
        for f in os.listdir(tmp):
            with open(os.path.join(tmp, f), encoding="latin-1") as fh:
                pending: dict[str, str] = {}
                for line in fh:
                    line = line.rstrip("\n")
                    if line.endswith("<unfinished ...>"):
                        pending["x"] = line[: -len("<unfinished ...>")].rstrip()
                        continue
                    if "resumed>" in line and "x" in pending:
                        line = pending.pop("x") + line.split("resumed>", 1)[1]
                    tr.feed(line)
    man = build_manifest(tr, root, a.rev, a.cmd)
    man["exit"] = st.returncode
    Path(a.out).write_text(json.dumps(man, indent=1) + "\n")
    print(f"traced_inputs: {sum(man['counts'].values())} inputs {man['counts']} git={man['git']} "
          f"untracked={len(man['risks']['untracked_reads'])} network={len(man['risks']['network'])} -> {a.out}",
          file=sys.stderr)
    return st.returncode


def states(man: dict, root: Path, rev: str, idx: dict | None = None) -> list[tuple[str, str, str]]:
    idx = idx if idx is not None else tree_index(root, rev)
    children: dict[str, list[str]] | None = None
    out = []
    for path, kind in man["entries"].items():
        mode, typ, oid = idx.get(path, ("", "absent", ""))
        if kind == "F":
            st = f"{mode} {typ} {oid}" if typ != "tree" else "tree"
        elif kind == "N":
            if typ != "tree":
                st = typ
            else:
                if children is None:
                    children = {}
                    for p, (_m, t, _o) in idx.items():
                        if p:
                            parent, _, name = p.rpartition("/")
                            children.setdefault(parent, []).append(f"{t[0]}:{name}")
                st = hashlib.sha256("\n".join(sorted(children.get(path, []))).encode("utf-8", "surrogateescape")).hexdigest()
        else:
            st = typ if typ != "blob" else f"blob {mode}"
        out.append((kind, path, st))
    if man.get("git") == "L":
        names = "\n".join(sorted(p for p, v in idx.items() if p and v[1] == "blob"))
        out.append(("L", "", hashlib.sha256(names.encode("utf-8", "surrogateescape")).hexdigest()))
    return out


def compute_key(man: dict, root: Path, rev: str, salt: str = "", strict: bool = False,
                idx: dict | None = None) -> tuple[str, str]:
    if man.get("git") == "H":
        return "", "reads git history or the commit"
    if strict and (man["risks"]["network"] or man["risks"]["untracked_reads"]):
        return "", "network or untracked reads"
    h = hashlib.sha256(f"traced-inputs-v{VERSION}\n{salt}\n{json.dumps(man['command'])}\n".encode())
    for kind, path, st in states(man, root, rev, idx):
        h.update(f"{kind}\t{path}\t{st}\n".encode("utf-8", "surrogateescape"))
    return h.hexdigest(), ""


def load(p: str) -> dict:
    return json.loads(Path(p).read_text())


def cmd_key(a: argparse.Namespace) -> int:
    k, why = compute_key(load(a.manifest), Path(a.root), a.rev, a.salt, a.strict)
    print(f"key={k}" + (f"\nwhy={why}" if why else ""))
    return 0


def cmd_entries(a: argparse.Namespace) -> int:
    for kind, path, st in states(load(a.manifest), Path(a.root), a.rev):
        print(kind, path or ".", st)
    return 0


def cmd_shadow(a: argparse.Namespace) -> int:
    root = Path(a.root)
    old, new = load(a.manifest_old), load(a.manifest_new)
    idx_now, idx_prior = tree_index(root, a.rev), tree_index(root, a.prior_rev)
    k_old_now, why = compute_key(old, root, a.rev, a.salt, idx=idx_now)
    k_old_prior, _ = compute_key(old, root, a.prior_rev, a.salt, idx=idx_prior)
    would = bool(k_old_now) and k_old_now == k_old_prior
    k_new_now, why_new = compute_key(new, root, a.rev, a.salt, idx=idx_now)
    k_new_prior, _ = compute_key(new, root, a.prior_rev, a.salt, idx=idx_prior)
    fresh_same = bool(k_new_now) and k_new_now == k_new_prior
    missed = []
    if would and not fresh_same:
        s_now = {(k, p): s for k, p, s in states(new, root, a.rev, idx_now)}
        s_prior = {(k, p): s for k, p, s in states(new, root, a.prior_rev, idx_prior)}
        missed = sorted(f"{k} {p}" for (k, p), s in s_now.items() if s_prior.get((k, p)) != s)[:50]
    added = sorted(set(new["entries"]) - set(old["entries"]))
    out = {
        "would_reuse": would, "unsound": would and not fresh_same, "missed": missed,
        "why_unkeyable": why or why_new, "key_old": k_old_now, "key_new": k_new_now,
        "manifest_growth": len(added), "added": added[:50],
        "risks": new["risks"]["network"][:5] + new["risks"]["untracked_reads"][:5],
    }
    print("shadow=" + json.dumps(out, separators=(",", ":")))
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="sub", required=True)
    t = sub.add_parser("trace")
    t.add_argument("--root", default=".")
    t.add_argument("--rev", default="HEAD")
    t.add_argument("--out", required=True)
    t.add_argument("command", nargs=argparse.REMAINDER)
    k = sub.add_parser("key")
    e = sub.add_parser("entries")
    for p in (k, e):
        p.add_argument("--manifest", required=True)
        p.add_argument("--rev", required=True)
        p.add_argument("--root", default=".")
        p.add_argument("--salt", default="")
    k.add_argument("--strict", action="store_true")
    s = sub.add_parser("shadow")
    s.add_argument("--manifest-old", required=True)
    s.add_argument("--manifest-new", required=True)
    s.add_argument("--rev", required=True)
    s.add_argument("--prior-rev", required=True)
    s.add_argument("--root", default=".")
    s.add_argument("--salt", default="")
    a = ap.parse_args(argv)
    if a.sub == "trace":
        a.cmd = a.command[1:] if a.command[:1] == ["--"] else a.command
        if not a.cmd:
            ap.error("trace needs a command after --")
        return cmd_trace(a)
    return {"key": cmd_key, "entries": cmd_entries, "shadow": cmd_shadow}[a.sub](a)


if __name__ == "__main__":
    sys.exit(main())
