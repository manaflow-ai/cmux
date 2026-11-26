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
import time
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
        self.execs: list[tuple[str, list[str]]] = []  # (pid file, argv) of every execve that succeeded
        self.connects: set[str] = set()
        self.by_pid: dict[str, set[str]] = {}  # pid file -> every path it touched (to find who read .git)
        self.pid = ""
        self.cwd: dict[str, str] = {}  # pid file -> its working directory (strace -y decorates AT_FDCWD)

    def feed(self, line: str) -> None:
        m = LINE.match(line)
        if not m:
            return
        call, args, ret = m.group("call"), split_args(m.group("args")), m.group("ret")
        if self.pid not in self.cwd and "AT_FDCWD<" in m.group("args"):
            d = DECOR.match(m.group("args").split("AT_FDCWD", 1)[1].join(["AT_FDCWD", ""]))
            if d:
                self.cwd[self.pid] = unescape(d.group("path"))
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
                self.execs.append((self.pid, [unescape(s) for s in QUOTED.findall(args[1])]))
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
        self.by_pid.setdefault(self.pid, set()).update(paths)
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


TREE_REVS = {"HEAD", "HEAD^{tree}", "@"}


def classify_git(argv: list[str], root: str = "", cwd: str = "") -> tuple[str | None, list[str]]:
    """(class, paths). Class None: harmless or keyed by PATHS (tree reads at HEAD); 'L': the answer is a function of
    the path list; 'H': reads history or the commit itself, so the job has no tree key."""
    words = argv[1:]
    sub = None
    i = 0
    where = cwd
    while i < len(words):
        w = words[i]
        if w in ("-C", "-c", "--git-dir", "--work-tree"):
            if w == "-C" and i + 1 < len(words):
                where = os.path.normpath(os.path.join(where or "/", words[i + 1]))
            i += 2
            continue
        if w.startswith("-") and w not in ("--version",):
            i += 1
            continue
        sub = w
        break
    rest = words[i + 1:] if sub else []
    # git run inside a gitlink (a submodule) reads that module, which the gitlink's commit fixes: key on the gitlink.
    if root and where and where != root and where.startswith(root + "/"):
        return None, [where[len(root) + 1:]]
    if sub is None or sub in GIT_HARMLESS:
        return None, []
    if sub in GIT_PATHLIST:
        return "L", []
    if sub == "rev-parse" and all(a.startswith("--show-") or a.startswith("--is-") or a == "--git-dir"
                                  or a == "--absolute-git-dir" for a in rest):
        return None, []
    # A read of the committed tree at HEAD, by path, is that path's object: `show HEAD:P`, `cat-file -p|-e|-t HEAD:P`,
    # `rev-parse HEAD:P`, `ls-tree HEAD [--] P...`.
    if sub in ("show", "cat-file", "rev-parse"):
        args = [a for a in rest if not a.startswith("-")]
        paths = []
        for a in args:
            rev, sep, path = a.partition(":")
            if not sep or rev not in TREE_REVS:
                return "H", []
            paths.append(path.strip("/"))
        if paths:
            return None, paths
    if sub == "ls-tree":
        args = [a for a in rest if a != "--"]
        flags = [a for a in args if a.startswith("-")]
        pos = [a for a in args if not a.startswith("-")]
        if pos and pos[0] in TREE_REVS and not any(f in ("-r", "-t", "--full-tree") for f in flags):
            return None, [p.strip("/") for p in pos[1:]] or [""]
    return "H", []


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
    # Only a process that read this checkout's .git asked git about this tree; a test's own scratch repository in a
    # temporary directory is not an input.
    git_pids = {pid for pid, ps in tr.by_pid.items() if any(p == gitdir or p.startswith(gitdir + "/") for p in ps)}
    for pid, argv in tr.execs:
        if pid in git_pids and argv and os.path.basename(argv[0]) == "git":
            c, paths = classify_git(argv, rs, tr.cwd.get(pid, ""))
            for p in paths:
                add("F" if p else "N", os.path.join(rs, p) if p else rs)
            git_calls.append({"argv": argv[:8], "class": c, "paths": paths[:5]})
            if c == "H" or (c == "L" and git_class is None):
                git_class = c
    git_exec_pids = {pid for pid, argv in tr.execs if argv and os.path.basename(argv[0]) == "git"}
    benign = (gitdir, gitdir + "/config", gitdir + "/info/exclude", gitdir + "/commondir")
    for pid in git_pids - git_exec_pids:
        # .git read by something other than git (a library, a script reading HEAD or refs): the commit, not the tree.
        if any((p == gitdir or p.startswith(gitdir + "/")) and p not in benign for p in tr.by_pid[pid]):
            git_class = "H"
            git_calls.append({"argv": [f"(pid file {pid} read .git)"], "class": "H"})
            break
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
        raw = Path(a.raw) if a.raw else Path(tmp)
        raw.mkdir(parents=True, exist_ok=True)
        # One file per process (-ff): a pid's reads stay with its own execve, so we know which process asked git.
        n = sum(1 for _ in raw.glob("t.*"))
        st = subprocess.run(["strace", "-f", "-ff", "--seccomp-bpf", "-qq", "-y", "-s", "4096", "-e", f"trace={SYSCALLS}",
                             "-e", "signal=none", "-o", str(raw / f"t{n:03d}" if n else raw / "t"), *a.cmd])
        man = manifest_from_raw(raw, root, a.rev, a.cmd)
    man["exit"] = st.returncode
    write_manifest(man, Path(a.out), a.append)
    print(f"traced_inputs: {sum(man['counts'].values())} inputs {man['counts']} git={man['git']} "
          f"untracked={len(man['risks']['untracked_reads'])} network={len(man['risks']['network'])} -> {a.out}",
          file=sys.stderr)
    return st.returncode


def strace_usable() -> bool:
    """strace exists and may ptrace here (a container without CAP_SYS_PTRACE, or yama scope 3, refuses)."""
    if not shutil.which("strace"):
        return False
    try:
        return subprocess.run(["strace", "-f", "-qq", "-e", "trace=none", "true"], capture_output=True,
                              timeout=30).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def job_steps(workflow: Path, job: str) -> list[tuple[str, str, dict]]:
    """(name, script, env) of every `run:` step after the job's checkout that can fail the job (not continue-on-error),
    as the workflow file has them. A step env
    value that is an expression is left out (this is the shadow audit, not the job)."""
    return [(name, script, env) for _id, name, script, env in job_steps_with_ids(workflow, job)]


def job_steps_with_ids(workflow: Path, job: str) -> list[tuple[str, str, str, dict]]:
    """job_steps with each step's `id` first ("" when it has none)."""
    import yaml  # PyYAML: the guard venv and the Linux runners have it.

    steps = yaml.load(workflow.read_text(), Loader=yaml.BaseLoader)["jobs"][job]["steps"]
    out, seen_checkout = [], False
    for st in steps:
        if str(st.get("uses", "")).startswith("actions/checkout@"):
            seen_checkout = True
            continue
        if not seen_checkout or "run" not in st or str(st.get("continue-on-error", "")) == "true":
            continue  # before the checkout (workspace cleanup), or a shadow step of its own
        env = {k: v for k, v in (st.get("env") or {}).items() if "${{" not in str(v)}
        out.append((st.get("id", ""), st.get("name", st["run"].splitlines()[0]), st["run"], env))
    return out


def cmd_trace_job(a: argparse.Namespace) -> int:
    """Trace every `run:` step of one workflow job into one manifest, then audit it against the committed list.
    Shadow only: it never fails the workflow's verdict (the job itself ran the same steps untraced)."""
    root = Path(a.root).resolve()
    if not strace_usable():
        print("traced_inputs: strace missing or ptrace refused here; no audit")
        return 0
    out = Path(a.out)
    out.unlink(missing_ok=True)
    # --step ID=LIST (RFD 0148 row 34): trace only those steps, each into its own manifest (OUT with .ID before its
    # suffix), and audit each against its own list. A step receipt's list covers that step's reads alone.
    own = dict(spec.split("=", 1) for spec in a.step)
    steps = job_steps_with_ids(Path(a.workflow), a.job)
    unknown = sorted(set(own) - {sid for sid, _, _, _ in steps})
    if unknown:
        print(f"traced_inputs: {a.job} has no run step with id {unknown}", file=sys.stderr)
        return 2
    with tempfile.TemporaryDirectory(prefix="traced-job-") as tmp:
        for i, (sid, name, script, env) in enumerate(steps):
            if own and sid not in own:
                continue
            sh = Path(tmp) / f"step{i}.sh"
            sh.write_text(script)
            raw = Path(tmp) / f"raw{i}"
            raw.mkdir()
            t0 = time.monotonic()
            st = subprocess.run(["strace", "-f", "-ff", "--seccomp-bpf", "-qq", "-y", "-s", "4096", "-e",
                                 f"trace={SYSCALLS}", "-e", "signal=none", "-o", str(raw / "t"), "bash", "--noprofile",
                                 "--norc", "-eo", "pipefail", str(sh)], cwd=root, env={**os.environ, **env},
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            man = manifest_from_raw(raw, root, a.rev, [name])
            man["exit"] = st.returncode
            step_out = out.with_suffix(f".{sid}{out.suffix}") if own else out
            write_manifest(man, step_out, not own)
            shutil.rmtree(raw)
            print(f"traced_inputs: step {i} exit={st.returncode} {time.monotonic() - t0:.0f}s {man['counts']} "
                  f"git={man['git']}: {name}")
            if own:
                cmd_audit(argparse.Namespace(manifest=str(step_out), inputs=own[sid], strict=False, label=f" {sid}"))
    if own or not a.inputs:
        return 0
    return cmd_audit(argparse.Namespace(manifest=str(out), inputs=a.inputs, strict=a.strict))


def parse_raw(raw: Path) -> Trace:
    tr = Trace()
    for f in sorted(raw.iterdir()):
        tr.pid = f.name
        with f.open(encoding="latin-1") as fh:
            pending = ""
            for line in fh:
                line = line.rstrip("\n")
                if line.endswith("<unfinished ...>"):
                    pending = line[: -len("<unfinished ...>")].rstrip()
                    continue
                if "resumed>" in line and pending:
                    line, pending = pending + line.split("resumed>", 1)[1], ""
                tr.feed(line)
    return tr


def manifest_from_raw(raw: Path, root: Path, rev: str, command: list[str]) -> dict:
    return build_manifest(parse_raw(raw), root, rev, command)


def write_manifest(man: dict, out: Path, append: bool) -> None:
    """Write MAN; with append, merge it into the manifest already at OUT (one step of a multi-step job each)."""
    if append and out.exists():
        old = json.loads(out.read_text())
        rank = {"E": 0, "N": 1, "F": 2}
        for p, k in old["entries"].items():
            if rank[k] > rank.get(man["entries"].get(p, "E"), -1) or p not in man["entries"]:
                man["entries"][p] = k
        man["entries"] = dict(sorted(man["entries"].items()))
        order = {None: 0, "L": 1, "H": 2}
        man["git"] = max(old.get("git"), man.get("git"), key=lambda g: order[g])
        man["git_calls"] = (old.get("git_calls", []) + man["git_calls"])[:200]
        man["git_paths"] = sorted(set(old.get("git_paths", [])) | set(man["git_paths"]))[:200]
        for r in ("untracked_reads", "network"):
            man["risks"][r] = sorted(set(old["risks"][r]) | set(man["risks"][r]))[:500]
        man["command"] = old["command"] + [man["command"]] if isinstance(old["command"][0], list) else [old["command"], man["command"]]
        man["exit"] = max(old.get("exit", 0), man.get("exit", 0))
        man["counts"] = {k: sum(1 for v in man["entries"].values() if v == k) for k in "FNE"}
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(man, indent=1) + "\n")


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


ROW_KIND = {"F": "blob", "E": "blob", "N": "names", "T": "tree"}


def compact(entries: dict[str, str], idx: dict[str, tuple[str, str, str]]) -> dict[str, str]:
    """Fold each directory the check listed and read whole (every entry a file it read, or a directory it read whole)
    into one T (tree) entry. A tree id covers exactly what its entries keyed (names, contents, and any absent path
    appearing), so the key is the same set of changes, in far fewer rows."""
    children: dict[str, list[str]] = {}
    for path in idx:
        if path:
            children.setdefault(path.rpartition("/")[0], []).append(path)
    full: set[str] = set()
    for d in sorted((p for p, v in idx.items() if v[1] == "tree" and p), key=lambda p: -p.count("/")):
        if entries.get(d) == "N" and all(c in full if idx[c][1] == "tree" else entries.get(c) == "F"
                                         for c in children.get(d, [])):
            full.add(d)
    tops = {d for d in full if not any(d.startswith(a + "/") for a in _ancestors(d) if a in full)}
    out = {p: k for p, k in entries.items() if not any(p == t or p.startswith(t + "/") for t in _ancestors(p) | {p}
                                                        if t in tops)}
    out.update({t: "T" for t in tops})
    return out


def _ancestors(path: str) -> set[str]:
    parts = path.split("/")
    return {"/".join(parts[:i]) for i in range(1, len(parts))}


def listable(path: str) -> bool:
    return not any(c in path for c in " #") and path.isprintable() and path.isascii()


def export_rows(man: dict, pinned: list[str], idx: dict | None = None) -> list[str]:
    """The manifest as receipt_input_key rows (`* KIND PATH`): F -> blob, N -> names, E -> blob (keyed absent or
    present). A path both listed and read through is a tree only when PINNED names it (the check's own code).
    With IDX (the traced revision's tree index), a path that is a directory there and was only probed or opened
    (E or F, never listed) is an `exists` row: states() keys it as `tree`, and a blob row would be its whole tree."""
    rows = []
    for path, kind in man["entries"].items():
        if not path:
            if kind == "N":  # the root listed: `REV:` is its tree, keyed on its names
                rows.append("* names .")
            continue  # the root stat'ed or opened: it always exists, so it keys nothing
        if not listable(path):
            # receipt_input_key splits on whitespace and the controller takes printable ASCII only: such a path
            # cannot be listed, so the check is keyed on its nearest listable ancestor's whole tree instead.
            parent = path
            while parent and not listable(parent):
                parent = parent.rpartition("/")[0]
            rows.append(f"* tree {parent or '.'}")
            continue
        if idx is not None and kind in ("E", "F") and idx.get(path, ("", "", ""))[1] == "tree":
            rows.append(f"* exists {path}")
            continue
        rows.append(f"* {ROW_KIND[kind]} {path}")
    rows += [f"* blob {p}" for p in pinned]
    return sorted(set(rows))


def cmd_export(a: argparse.Namespace) -> int:
    man = load(a.manifest)
    if man.get("git") == "H":
        print("traced_inputs: the check reads git history or the commit; it has no tree key", file=sys.stderr)
        return 2
    if man.get("git") == "L":
        print("traced_inputs: the check asks git for the path list; keyed on the root listing too", file=sys.stderr)
    entries = man["entries"]
    idx = tree_index(Path(a.root), man["rev"])
    man = {**man, "entries": compact(entries, idx)}
    rows = export_rows(man, a.pin, idx)
    if man.get("git") == "L":
        rows.append("* tree .")
    head = [f"# Traced inputs of {a.check} (scripts/ci/traced_inputs.py; cmuxterm-hq RFD 0148 row 9). Generated:",
            f"# python3 scripts/ci/traced_inputs.py export --check {a.check} --manifest M --out THIS; do not edit.",
            f"# {man['counts']['F']} files read, {man['counts']['N']} directories listed, {man['counts']['E']} paths "
            "probed absent; traced at " + man["rev"][:12] + "."]
    Path(a.out).write_text("\n".join(head + sorted(set(rows))) + "\n")
    print(f"traced_inputs: {len(set(rows))} rows -> {a.out}", file=sys.stderr)
    return 0


def cmd_audit(a: argparse.Namespace) -> int:
    """A fresh trace against the committed list: every read the list does not cover is a reuse the key would get
    wrong. Prints `audit=<json>`; exits 1 on a miss with --strict."""
    man = load(a.manifest)
    covered: dict[str, str] = {}
    trees: list[str] = []
    for raw in Path(a.inputs).read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        _unit, kind, rel = line.split()
        rel = "" if rel == "." else rel
        if kind == "tree":
            trees.append("" if rel == "." else rel)
        covered[rel] = kind

    def under_tree(p: str) -> bool:
        return any(t == "" or p == t or p.startswith(t + "/") for t in trees)

    missed = []
    for path, kind in man["entries"].items():
        if under_tree(path) or (not path and kind != "N"):  # the root always exists: only its listing keys
            continue
        have = covered.get(path)
        # names covers a listing, blob covers a file read or an absent probe; a blob row on a directory is its tree.
        # exists covers a probe, and a read of a path that is a directory (states() keys both as its type); it
        # never covers a listing, and it keys a file on its blob id, so it covers a file read too.
        if have is None or (kind == "N" and have not in ("names", "blob")) or (kind != "N" and have == "names"):
            missed.append(f"{kind} {path}")
    out = {"missed": len(missed), "examples": missed[:30], "git": man.get("git"),
           "untracked_reads": man["risks"]["untracked_reads"][:10], "network": man["risks"]["network"][:10]}
    print(f"audit{getattr(a, 'label', '')}=" + json.dumps(out, separators=(",", ":")))
    return 1 if a.strict and (missed or man.get("git") == "H") else 0


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
    t.add_argument("--raw", help="keep strace's per-process logs here (re-parse them with `parse`)")
    t.add_argument("--append", action="store_true", help="merge into the manifest already at --out")
    pr = sub.add_parser("parse")
    pr.add_argument("--raw", required=True)
    pr.add_argument("--root", default=".")
    pr.add_argument("--rev", default="HEAD")
    pr.add_argument("--out", required=True)
    t.add_argument("command", nargs=argparse.REMAINDER)
    k = sub.add_parser("key")
    e = sub.add_parser("entries")
    for p in (k, e):
        p.add_argument("--manifest", required=True)
        p.add_argument("--rev", required=True)
        p.add_argument("--root", default=".")
        p.add_argument("--salt", default="")
    k.add_argument("--strict", action="store_true")
    tj = sub.add_parser("trace-job", help="trace every run: step of a workflow job, then audit the committed list")
    tj.add_argument("--workflow", required=True)
    tj.add_argument("--job", required=True)
    tj.add_argument("--root", default=".")
    tj.add_argument("--rev", default="HEAD")
    tj.add_argument("--out", required=True)
    tj.add_argument("--inputs", default="")
    tj.add_argument("--strict", action="store_true")
    tj.add_argument("--step", action="append", default=[], metavar="ID=LIST",
                    help="trace only the step with this id and audit it against its own list (repeatable)")
    x = sub.add_parser("export")
    x.add_argument("--check", required=True)
    x.add_argument("--root", default=".")
    x.add_argument("--manifest", required=True)
    x.add_argument("--out", required=True)
    x.add_argument("--pin", action="append", default=[], help="a file always in the key (the workflow, the list)")
    au = sub.add_parser("audit")
    au.add_argument("--manifest", required=True)
    au.add_argument("--inputs", required=True)
    au.add_argument("--strict", action="store_true")
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
    if a.sub == "trace-job":
        return cmd_trace_job(a)
    if a.sub == "parse":
        man = manifest_from_raw(Path(a.raw), Path(a.root).resolve(), a.rev, ["(parsed)"])
        write_manifest(man, Path(a.out), False)
        print(f"traced_inputs: {man['counts']} git={man['git']}", file=sys.stderr)
        return 0
    return {"key": cmd_key, "entries": cmd_entries, "shadow": cmd_shadow, "export": cmd_export,
            "audit": cmd_audit}[a.sub](a)


if __name__ == "__main__":
    sys.exit(main())
