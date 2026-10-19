#!/usr/bin/env python3
"""Say whether a web test can see a diff: is any changed file in its import graph?

    python3 scripts/ci/test_touches_diff.py web/tests/vm-route-deadlines.test.ts --base origin/main --head HEAD
    python3 scripts/ci/test_touches_diff.py tests/foo.test.ts --base A --head B --coverage --json

It bundles the test at the head commit with `bun build --metafile`, packages
left external, together with bunfig's test preloads (they run before every
test), and walks the bundle's local inputs. Each changed file gets one verdict:

  not imported      outside the graph; the test cannot load it
  tree-shaken       imported, but none of its code reaches the bundle (only
                    types, or exports the test never uses)
  imported          its code is bundled into the test
  executed          (--coverage) the test ran at least one changed line
  not executed      (--coverage) the file loaded, but no changed line ran
  no code changed   (--coverage) every changed line is a comment, blank, a
                    type declaration, or above the file's first code block

bun's lcov lists only the line where each block starts, so a changed line
counts as run when the nearest listed line above it ran. A comment edited
inside a function that runs therefore counts as run: the check errs toward
blaming the diff.
  runner            the test runner or its dependencies (package.json, bun.lock,
                    bunfig.toml, tsconfig.json, run-tests.sh): every test sees it

The default check needs only git and bun, and is built not to run the head's
code. The head's web/ is extracted with `git archive` (the commit must exist
locally: `git fetch origin pull/N/head`). The check then refuses, as "can't
analyse safely" (exit 2), any tree where bundling might run code: a symlink, an import
attribute clause anywhere (bun runs `with { type: "macro" }` imports while
bundling), an import() with a second argument (or one it can't read to its
end), or a package.json that mentions macros.
The head's bunfig.toml is read as data and never handed to bun.

The sandbox is the guarantee. bun runs only in a Linux user namespace with
no network, the filesystem read-only except its own work directory, your home
directory hidden, and an allowlisted environment (PATH, LANG, LC_ALL, TERM,
and a throwaway HOME and TMPDIR).
Without user namespaces (macOS), the check refuses ("can't analyse safely")
unless you pass --allow-unsandboxed, which means bun runs as you and can read
your files: only for a commit you trust. The attribute scan above is a
second line of defence, not the guarantee.

--coverage RUNS THE HEAD'S TEST CODE, with this checkout's web/node_modules,
under the same rules. web_test_verdict.py refuses it, and any unsandboxed
run, for fork pull requests.

What it cannot see, and says so in its output: a test that reads a file at
run time (fs, fetch, spawn), import() of a computed path, `mock.module()`
targets, and deleted files (gone at the head, so outside any graph).
"""

from __future__ import annotations

import argparse
import functools
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections import deque
from collections.abc import Iterable, Mapping
from pathlib import Path

WEB = "web"
RUNNER_FILES = {
    "web/package.json", "web/bun.lock", "web/bunfig.toml", "web/tsconfig.json", "web/scripts/run-tests.sh",
    ".github/workflows/ci-web.yml",
}
# Large binary trees a bundle never resolves; leaving them out keeps the extract small.
SKIP_EXTRACT = ("web/public", "web/e2e", "web/dashboard-app/public")
MEDIA = re.compile(r"\.(?:png|jpe?g|gif|webp|avif|ico|mp4|webm|mov|woff2?|ttf|otf|pdf|zip|wasm)$", re.IGNORECASE)
HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(?P<start>\d+)(?:,(?P<count>\d+))? @@")

NOT_IMPORTED, TREE_SHAKEN, IMPORTED = "not imported", "tree-shaken", "imported"
EXECUTED, NOT_EXECUTED, NO_CODE, RUNNER = "executed", "not executed", "no code changed", "runner"
TOUCHING = {IMPORTED, EXECUTED, RUNNER}
BLIND_SPOTS = "not seen: run-time file reads, import() of computed paths, mock.module() targets"


def git(repo: Path, *args: str, binary: bool = False) -> str | bytes:
    out = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, check=True)
    return out.stdout if binary else out.stdout.decode("utf-8", "replace")


def test_path(path: str) -> str:
    """The test as a repository path under web/."""
    path = path.replace("\\", "/")
    while path.startswith("./"):
        path = path[2:]
    return path if path.startswith(f"{WEB}/") else f"{WEB}/{path}"


def changed_files(repo: Path, base: str, head: str) -> list[str]:
    out = str(git(repo, "diff", "--name-only", "--diff-filter=d", f"{base}...{head}"))
    return [line for line in out.splitlines() if line]


def deleted_files(repo: Path, base: str, head: str) -> list[str]:
    out = str(git(repo, "diff", "--name-only", "--diff-filter=D", f"{base}...{head}"))
    return [line for line in out.splitlines() if line]


def changed_lines(repo: Path, base: str, head: str, path: str) -> set[int]:
    """Head-side line numbers the diff adds or changes in one file. A pure deletion
    (`+N,0`) names the lines on either side of it, so the block that lost code is checked."""
    out = str(git(repo, "diff", "-U0", f"{base}...{head}", "--", path))
    lines: set[int] = set()
    for line in out.splitlines():
        if found := HUNK.match(line):
            start, count = int(found["start"]), int(found["count"] or 1)
            lines.update(range(start, start + count) if count else {max(start, 1), start + 1})
    return lines


def preloads(web_root: Path) -> list[str]:
    """bunfig.toml's [test] preload entries, as paths relative to web/."""
    config = web_root / "bunfig.toml"
    if not config.exists():
        return []
    try:
        import tomllib
    except ImportError:  # Python < 3.11
        return []
    data = tomllib.loads(config.read_text(encoding="utf-8"))
    value = (data.get("test") or {}).get("preload") or []
    return [str(Path(p))
            for p in ([value] if isinstance(value, str) else value)]


def extract_web(repo: Path, head: str, into: Path) -> Path:
    """The head's web/ source tree (no media, no public assets) under `into`."""
    names = [n for n in str(git(repo, "ls-tree", "-r", "--name-only", head, "--", WEB)).splitlines()
             if not MEDIA.search(n) and not n.startswith(SKIP_EXTRACT)]
    archive = into / "web.tar"
    with archive.open("wb") as handle:
        subprocess.run(["git", "-C", str(repo), "archive", "--format=tar", head, "--", *names],
                       stdout=handle, check=True)
    subprocess.run(["tar", "-xf", str(archive), "-C", str(into)], check=True)
    archive.unlink()
    return into / WEB


class UnsafeToAnalyse(Exception):
    """The head contains something that could make bun run its code while bundling."""


SOURCE = re.compile(r"\.(?:[cm]?[jt]sx?|json)$")
# A second line of defence: the sandbox (run_bun) is what keeps head code off the host.
# Every JS line terminator becomes \n and every JS whitespace character a space before
# matching, so a comment can't end where the pattern doesn't expect it.
_TERMINATORS = re.compile("\r\n?|[\u2028\u2029]")
_WHITESPACE = re.compile("[\ufeff\u00a0\u1680\u2000-\u200a\u202f\u205f\u3000\t\v\f]")
# Whitespace and comments bun allows between tokens. The block-comment form is the unrolled,
# linear one, so a crafted file can't make the scan quadratic.
_GAP = r"(?:[ \n]|/\*[^*]*\*+(?:[^/*][^*]*\*+)*/|//[^\n]*(?:\n|$))*"
# bun runs `import x from "./m" with { type: "macro" }` while bundling, and bun 1.3's
# --no-macros does not stop it. Rather than recognise macros (a denylist), any attribute
# clause after a module specifier is refused: nothing in web/ uses one.
ATTRIBUTE_CLAUSE = re.compile(r"""["'`]""" + _GAP + r"(?:with|assert)" + _GAP + r"\{")
# import(specifier, { with: {...} }) carries attributes in its second argument, which can be
# spelled any number of ways ([key], a variable), so any second argument is refused.
DYNAMIC_IMPORT = re.compile(r"\bimport" + _GAP + r"\(")
MAX_IMPORT_CALL = 4096
MAX_TEMPLATE_NESTING = 16
MAX_SCAN_BYTES = 2_000_000
# bun's config files: withheld from bun, and package.json may remap imports to macros.
BUN_CONFIG = ("bunfig.toml", ".bunfig.toml")


def normalized(text: str) -> str:
    return _WHITESPACE.sub(" ", _TERMINATORS.sub("\n", text))


class _Unreadable(Exception):
    """An import() call the scan can't read to its end."""


def _string_end(text: str, i: int, limit: int) -> int:
    quote, i = text[i], i + 1
    while i < limit:
        if text[i] == "\\":
            i += 2
        elif text[i] == quote:
            return i + 1
        elif text[i] == "\n":
            break
        else:
            i += 1
    raise _Unreadable("an unterminated string")


def _template_end(text: str, i: int, limit: int, nesting: int) -> int:
    i += 1
    while i < limit:
        if text[i] == "\\":
            i += 2
        elif text[i] == "`":
            return i + 1
        elif text.startswith("${", i):
            i, _ = _code_until(text, i + 2, limit, "}", nesting + 1)
        else:
            i += 1
    raise _Unreadable("an unterminated template")


def _code_until(text: str, i: int, limit: int, closer: str, nesting: int) -> tuple[int, bool]:
    """(index just past `closer`, whether a second argument came after a top-level comma).
    Strings, templates, brackets and comments are skipped; anything ambiguous is unreadable:
    a `/` (regex or division), another import, or no closer within the limit."""
    if nesting > MAX_TEMPLATE_NESTING:
        raise _Unreadable("templates nested too deep")
    depth, after_comma, second = 0, False, False
    while i < limit:
        c = text[i]
        if c in " \n":
            i += 1
            continue
        if text.startswith("//", i):
            end = text.find("\n", i, limit)
            if end < 0:
                break
            i = end + 1
            continue
        if text.startswith("/*", i):
            end = text.find("*/", i + 2, limit)
            if end < 0:
                break
            i = end + 2
            continue
        if depth == 0 and c == closer:
            return i + 1, second
        second = second or (after_comma and depth == 0)
        if c in "\"'":
            i = _string_end(text, i, limit)
            continue
        if c == "`":
            i = _template_end(text, i, limit, nesting)
            continue
        if c == "/":
            raise _Unreadable("a `/` it can't tell from a regular expression")
        if text.startswith("import", i) and not re.match(r"[\w$]", text[i - 1] if i else " ") \
                and not re.match(r"[\w$]", text[i + 6:i + 7]):
            raise _Unreadable("an import inside import()")
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth < 0:
                raise _Unreadable("unbalanced brackets")
        elif c == "," and depth == 0:
            after_comma = True
        i += 1
    raise _Unreadable("no end within reach")


def dynamic_import_problem(text: str) -> str | None:
    """Why some import(...) in normalized text may carry options, or None when every call
    provably takes one argument (a trailing comma allowed). Linear: each call is read once."""
    pos = 0
    while found := DYNAMIC_IMPORT.search(text, pos):
        try:
            pos, second = _code_until(text, found.end(), min(len(text), found.end() + MAX_IMPORT_CALL), ")", 0)
        except _Unreadable as error:
            return f"has an import() it can't read ({error})"
        if second:
            return "passes a second argument (options) to import()"
    return None


def unsafe_reasons(web_root: Path) -> list[str]:
    """Why bundling this tree could run its code, or [] when nothing was found (fail closed)."""
    reasons = []
    for path in sorted(web_root.rglob("*")):
        rel = str(path.relative_to(web_root))
        if path.is_symlink():
            reasons.append(f"{rel} is a symlink")
            continue
        if not path.is_file():
            continue
        if path.name == "package.json":
            if "macro" in path.read_text(encoding="utf-8", errors="replace").lower():
                reasons.append(f"{rel} mentions macros")
            continue
        if not SOURCE.search(path.name) or path.suffix == ".json":
            continue
        if path.stat().st_size > MAX_SCAN_BYTES:
            reasons.append(f"{rel} is too large to scan")
            continue
        # UTF-8 as bun reads it: under another locale, U+2028/U+2029 would not end a comment here.
        text = normalized(path.read_text(encoding="utf-8", errors="replace"))
        if ATTRIBUTE_CLAUSE.search(text):
            reasons.append(f"{rel} has an import attribute clause")
        elif problem := dynamic_import_problem(text):
            reasons.append(f"{rel} {problem}")
    return reasons


# Everything bun gets from this environment; anything else (tokens, DBUS, XDG_*) stays out.
ENV_ALLOW = ("PATH", "LANG", "LC_ALL", "TERM")


def bun_env(home: Path) -> dict[str, str]:
    """An allowlisted environment with a throwaway HOME and TMPDIR."""
    home.mkdir(parents=True, exist_ok=True)
    env = {k: os.environ[k] for k in ENV_ALLOW if k in os.environ}
    env.update({"HOME": str(home), "TMPDIR": str(home), "NO_COLOR": "1"})
    return env


@functools.lru_cache(maxsize=1)
def can_sandbox() -> bool:
    """Linux user namespaces and mount_setattr (5.12+): the sandbox below, without root."""
    if not sys.platform.startswith("linux") or shutil.which("unshare") is None:
        return False
    with tempfile.TemporaryDirectory(prefix="test-touches-diff-probe-") as tmp:
        cmd = sandbox_command(["true"], Path(tmp), {})
        try:
            probe = subprocess.run(cmd, capture_output=True, env=bun_env(Path(tmp) / "home"), timeout=30)
        except subprocess.TimeoutExpired:
            return False
        return probe.returncode == 0


# Runs as root (pid 1) in a new user, mount, pid and network namespace, then execs argv[2:].
# Directories that hold sockets or other users' scratch files (/tmp, /run, /dev/shm, $HOME)
# go behind empty tmpfs mounts: read-only doesn't stop connect() on a socket file. The work
# directory and binds are opened first and mounted back in through those handles. Every mount
# goes read-only (mount_setattr keeps each mount's other flags, which plain remount can't),
# then the work directory goes back to read-write (binds under it stay read-only), and so
# does /proc, without its submounts, for the inner namespace's uid map. The
# command runs in a second user namespace: mounts copied into it are locked, so root there
# can't remount them read-write or unmount the tmpfs over $HOME.
SANDBOX_SETUP = r"""
import ctypes, json, os, sys
libc = ctypes.CDLL(None, use_errno=True)
MS_BIND, MS_REC, MS_PRIVATE = 0x1000, 0x4000, 0x40000
AT_FDCWD, AT_RECURSIVE, MOUNT_ATTR_RDONLY, SYS_MOUNT_SETATTR = -100, 0x8000, 1, 442

class MountAttr(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint64) for name in ("attr_set", "attr_clr", "propagation", "userns_fd")]

def ok(ret, what):
    if ret != 0:
        raise SystemExit(f"sandbox: {what}: {os.strerror(ctypes.get_errno())}")

def mount(src, dst, fstype, flags):
    ok(libc.mount(src and src.encode(), dst.encode(), fstype and fstype.encode(),
                  ctypes.c_ulong(flags), None), f"mount {dst}")

def set_attrs(path, flags, set_=0, clr=0):
    attr = MountAttr(set_, clr, 0, 0)
    ok(libc.syscall(ctypes.c_long(SYS_MOUNT_SETATTR), ctypes.c_int(AT_FDCWD), path.encode(),
                    ctypes.c_uint(flags), ctypes.byref(attr), ctypes.c_size_t(ctypes.sizeof(attr))),
       f"mount_setattr {path}")

plan = json.loads(sys.argv[1])
work = plan["work"]
mount(None, "/", None, MS_REC | MS_PRIVATE)
keep = [(os.open(src, os.O_PATH), dst) for src, dst in [[work, work], *plan["binds"]]]
for path in plan["hide"]:
    mount("tmpfs", path, "tmpfs", 0)
for fd, dst in keep:
    if not os.path.lexists(dst):
        if os.path.isdir(f"/proc/self/fd/{fd}"):
            os.makedirs(dst)
        else:
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            open(dst, "x").close()
    mount(f"/proc/self/fd/{fd}", dst, None, MS_BIND)
    os.close(fd)
set_attrs("/", AT_RECURSIVE, set_=MOUNT_ATTR_RDONLY)
set_attrs(work, 0, clr=MOUNT_ATTR_RDONLY)
set_attrs("/proc", 0, clr=MOUNT_ATTR_RDONLY)  # the inner unshare writes /proc/self/uid_map
os.execv(plan["unshare"], [plan["unshare"], "--user", "--map-root-user", "--mount", "--", *sys.argv[2:]])
"""


SCRATCH_DIRS = ("/tmp", "/var/tmp", "/run", "/dev/shm")


def hidden_dirs(work: Path) -> list[Path]:
    """Directories the sandbox covers with an empty tmpfs: the scratch and socket directories
    that exist as real directories, and $HOME unless `work` is in it."""
    home = Path.home().resolve()
    dirs = [Path(d) for d in SCRATCH_DIRS if os.path.isdir(d) and not os.path.islink(d)]
    if not work.resolve().is_relative_to(home) and home not in dirs:
        dirs.append(home)
    return dirs


def sandbox_command(argv: list[str], work: Path, binds: Mapping[Path, Path]) -> list[str]:
    """argv in the sandbox: no network, no host processes, only `work` writable, and the
    scratch directories and $HOME hidden (`work` and `binds` are mounted back in)."""
    work = work.resolve()
    unshare = str(Path(shutil.which("unshare") or "unshare").resolve())
    plan = {
        "work": str(work),
        "binds": [[str(src), str(dst)] for src, dst in binds.items()],
        "hide": [str(d) for d in hidden_dirs(work)],
        "unshare": unshare,
    }
    return [unshare, "--user", "--map-root-user", "--mount", "--net", "--pid", "--fork", "--mount-proc", "--",
            sys.executable, "-I", "-S", "-c", SANDBOX_SETUP, json.dumps(plan), *argv]


def run_bun(args: list[str], cwd: Path, work: Path, *, sandbox: bool,
            binds: Mapping[Path, Path] | None = None) -> subprocess.CompletedProcess:
    """Run bun with the allowlisted environment, and when `sandbox`, with no network, no host
    processes, the whole filesystem read-only except `work`, and the scratch directories and the
    user's home directory hidden behind empty tmpfs mounts (`work`, `binds` and bun itself, when
    it lives under a hidden directory, are mounted back in, the binds read-only)."""
    env = bun_env(work / "home")
    bun = str(Path(shutil.which("bun") or "bun").resolve())
    if not sandbox:
        return subprocess.run([bun, *args], cwd=cwd, capture_output=True, text=True, env=env)
    mounts = dict(binds or {})
    if any(Path(bun).is_relative_to(d) for d in hidden_dirs(work)):
        target = work / "bun"
        target.touch()
        mounts[Path(bun)] = target
        bun = str(target)
    for target in mounts.values():
        if not target.exists():
            target.mkdir(parents=True)
    cmd = sandbox_command([bun, *args], work, mounts)
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, env=env)


def bundle(web_root: Path, entries: Iterable[str], outdir: Path, sandbox: bool) -> dict:
    """bun's metafile for the entries, packages external."""
    meta = outdir / "meta.json"
    args = ["build", *entries, "--target=bun", "--packages=external",
            f"--outdir={outdir / 'out'}", f"--metafile={meta}"]
    result = run_bun(args, web_root, outdir, sandbox=sandbox)
    if result.returncode != 0 or not meta.exists():
        raise SystemExit(f"bun build failed:\n{result.stderr.strip()[-2000:]}")
    return json.loads(meta.read_text())


def graph(meta: Mapping, web_root: Path) -> tuple[dict[str, list[str]], dict[str, int]]:
    """({web-relative input: its local imports}, {input: bytes it puts in the bundle})."""
    root = str(web_root.resolve())

    def rel(path: str) -> str:
        path = str(Path(path).resolve()) if os.path.isabs(path) else path
        return os.path.relpath(path, root) if os.path.isabs(path) else path

    edges = {rel(name): [rel(i["path"]) for i in body.get("imports", []) if not i.get("external")]
             for name, body in (meta.get("inputs") or {}).items()}
    sizes: dict[str, int] = {}
    for output in (meta.get("outputs") or {}).values():
        for name, body in (output.get("inputs") or {}).items():
            sizes[rel(name)] = sizes.get(rel(name), 0) + int(body.get("bytesInOutput") or 0)
    return edges, sizes


def chain(edges: Mapping[str, list[str]], starts: Iterable[str], target: str) -> list[str]:
    """The shortest import path from an entry to `target`, or []."""
    queue = deque([[s] for s in starts])
    seen = set(starts)
    while queue:
        path = queue.popleft()
        if path[-1] == target:
            return path
        for nxt in edges.get(path[-1], []):
            if nxt not in seen:
                seen.add(nxt)
                queue.append([*path, nxt])
    return []


def parse_lcov(text: str, web_root: Path) -> dict[str, dict[int, int]]:
    """{web-relative file: {line: hits}} from an lcov report."""
    hits: dict[str, dict[int, int]] = {}
    current: dict[int, int] | None = None
    for line in text.splitlines():
        if line.startswith("SF:"):
            path = line[3:].strip()
            if os.path.isabs(path):
                path = os.path.relpath(path, web_root.resolve())
            current = hits.setdefault(path, {})
        elif line.startswith("DA:") and current is not None:
            number, count = line[3:].split(",")[:2]
            current[int(number)] = current.get(int(number), 0) + int(count)
        elif line == "end_of_record":
            current = None
    return hits


TYPE_START = re.compile(r"^\s*(?:export\s+)?(?:declare\s+)?(?:type\s+\w+.*=|interface\s+\w+)")


def code_lines(text: str) -> set[int]:
    """Line numbers that can hold run-time code: not blank, not only a comment, not inside a
    `type X = ...` or `interface X {...}` declaration (brace-balanced, a heuristic)."""
    out: set[int] = set()
    in_comment = False
    type_depth = 0
    in_type = False
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if in_comment:
            if "*/" in line:
                in_comment = False
                line = line.split("*/", 1)[1].strip()
            else:
                continue
        if line.startswith("/*"):
            if "*/" not in line:
                in_comment = True
                continue
            line = line.split("*/", 1)[1].strip()
        if not line or line.startswith("//"):
            continue
        if not in_type and TYPE_START.match(line):
            in_type, type_depth = True, 0
        if in_type:
            type_depth += line.count("{") + line.count("(") - line.count("}") - line.count(")")
            if type_depth <= 0 and (line.endswith(";") or line.endswith("}") or not line.endswith(("=", "|", "&", ","))):
                in_type = False
            continue
        out.add(number)
    return out


def block_hits(file_hits: Mapping[int, int], wanted: set[int] | None) -> dict[int, int]:
    """{changed line: hits} under bun's block coverage.

    bun's lcov lists a line only where a block starts (an uncalled function
    shows just its first line, with 0 hits), so a changed line takes the hits
    of the nearest listed line at or above it. Lines above the first listed
    line (imports, top-level types) are not code. Without changed lines
    (no base), every listed line counts."""
    if wanted is None:
        return dict(file_hits)
    starts = sorted(file_hits)
    out: dict[int, int] = {}
    for line in sorted(wanted):
        below = [s for s in starts if s <= line]
        if below:
            out[line] = file_hits[below[-1]]
    return out


def run_coverage(web_root: Path, test: str, outdir: Path, sandbox: bool,
                 node_modules: Path | None) -> dict[str, dict[int, int]]:
    """Run the head's test with lcov coverage. This executes its code."""
    args = ["test", "--isolate", "--coverage", "--coverage-reporter=lcov", f"--coverage-dir={outdir}", test]
    binds = {node_modules: web_root / "node_modules"} if node_modules else None
    if node_modules and not sandbox:
        (web_root / "node_modules").symlink_to(node_modules)
    result = run_bun(args, web_root, outdir.parent, sandbox=sandbox, binds=binds)
    report = outdir / "lcov.info"
    if not report.exists():
        raise SystemExit(f"bun test --coverage wrote no lcov report (exit {result.returncode}):\n"
                         f"{result.stderr.strip()[-2000:]}")
    return parse_lcov(report.read_text(), web_root)


def verdicts(changed: Iterable[str], edges: Mapping[str, list[str]], sizes: Mapping[str, int],
             entries: list[str], lines: Mapping[str, set[int]] | None = None,
             coverage: Mapping[str, Mapping[int, int]] | None = None) -> list[dict]:
    """One verdict per changed file (repository paths)."""
    out = []
    for path in changed:
        rel = path[len(WEB) + 1:] if path.startswith(f"{WEB}/") else None
        item: dict = {"file": path}
        if path in RUNNER_FILES:
            item["verdict"] = RUNNER
        elif rel is None or rel not in edges:
            item["verdict"] = NOT_IMPORTED
        else:
            item["chain"] = chain(edges, entries, rel)
            item["bytes_in_bundle"] = sizes.get(rel, 0)
            item["verdict"] = IMPORTED if sizes.get(rel, 0) else TREE_SHAKEN
            if coverage is not None and item["verdict"] == IMPORTED:
                file_hits = coverage.get(rel)
                wanted = (lines or {}).get(path)
                measured = block_hits(file_hits or {}, wanted)
                if file_hits is None:
                    item["verdict"] = NOT_EXECUTED
                    item["detail"] = "bundled but never loaded at run time"
                elif not measured:
                    item["verdict"] = NO_CODE
                elif any(measured.values()):
                    item["verdict"] = EXECUTED
                    item["lines_run"] = sorted(n for n, h in measured.items() if h)
                else:
                    item["verdict"] = NOT_EXECUTED
                    item["lines_not_run"] = sorted(measured)
        out.append(item)
    order = [RUNNER, EXECUTED, IMPORTED, NOT_EXECUTED, NO_CODE, TREE_SHAKEN, NOT_IMPORTED]
    return sorted(out, key=lambda i: (order.index(i["verdict"]), i["file"]))


def check(repo: Path, test: str, base: str | None, head: str, *, changed: list[str] | None = None,
          coverage: bool = False, allow_unsandboxed: bool = False) -> dict:
    """The import-graph report for one test against base...head (or an explicit changed list)."""
    test = test_path(test)
    if changed is None:
        if not base:
            raise SystemExit("give --base or --changed")
        changed = changed_files(repo, base, head)
    head_sha = str(git(repo, "rev-parse", f"{head}^{{commit}}")).strip()
    deleted = deleted_files(repo, base, head) if base else []
    sandbox = can_sandbox()
    # The sandbox is the guarantee: without one, bun never touches the head unless the caller
    # vouches for the commit (web_test_verdict.py never does for a fork).
    if not sandbox and not allow_unsandboxed:
        raise UnsafeToAnalyse("can't analyse safely: no sandbox here (needs Linux user namespaces), and bun "
                              "could run the head's code; pass --allow-unsandboxed only for a commit you trust")
    # Outside the home directory, so the sandbox can hide all of it.
    tmp_root = "/tmp" if Path("/tmp").is_dir() else None
    with tempfile.TemporaryDirectory(prefix="test-touches-diff-", dir=tmp_root) as tmp:
        work = Path(tmp)
        # Always a clean copy of the commit: a dirty checkout never stands in for the head.
        web_root = extract_web(repo, head_sha, work)
        rel_test = test[len(WEB) + 1:]
        if not (web_root / rel_test).exists():
            raise SystemExit(f"{test} does not exist at {head_sha[:12]}")
        entries = [rel_test, *[p for p in preloads(web_root) if (web_root / p).exists()]]
        if reasons := unsafe_reasons(web_root):
            raise UnsafeToAnalyse("can't analyse safely: " + "; ".join(reasons[:5]))
        # The preloads are read above as data; bun build never sees the head's bunfig.
        parked = []
        for name in BUN_CONFIG:
            if (web_root / name).exists():
                (web_root / name).rename(work / f"{name}.parked")
                parked.append(name)
        meta = bundle(web_root, entries, work, sandbox)
        for name in parked:
            (work / f"{name}.parked").rename(web_root / name)
        edges, sizes = graph(meta, web_root)
        hits = None
        lines = None
        if coverage:
            node_modules = (repo / WEB / "node_modules").resolve() if (repo / WEB / "node_modules").is_dir() else None
            if (web_root / "package.json").exists() and node_modules is None:
                raise SystemExit("--coverage needs web/node_modules (run `bun install` in web/)")
            hits = run_coverage(web_root, rel_test, work / "coverage", sandbox, node_modules)
            lines = None
            if base:
                lines = {}
                for p in changed:
                    source = web_root / p[len(WEB) + 1:] if p.startswith(f"{WEB}/") else None
                    code = code_lines(source.read_text(encoding="utf-8", errors="replace")) \
                        if source and source.exists() else None
                    found = changed_lines(repo, base, head, p)
                    lines[p] = found & code if code is not None else found
        files = verdicts(changed, edges, sizes, entries, lines, hits)
    touching = [f for f in files if f["verdict"] in TOUCHING]
    return {
        "test": test,
        "head": head_sha,
        "base": base,
        "entries": entries,
        "graph_size": len(edges),
        "changed": len(changed),
        "coverage": coverage,
        "sandboxed": sandbox,
        "deleted": deleted,
        "touches": bool(touching),
        "files": files,
        "summary": summary_line(test, files, coverage),
    }


def summary_line(test: str, files: list[dict], coverage: bool) -> str:
    name = Path(test).name
    counts = {v: sum(1 for f in files if f["verdict"] == v) for v in
              (RUNNER, EXECUTED, IMPORTED, NOT_EXECUTED, NO_CODE, TREE_SHAKEN)}
    if counts[RUNNER]:
        return f"diff changes the web test runner or its dependencies; every test, {name} included, sees it"
    if counts[EXECUTED]:
        return f"{name} runs changed code in {counts[EXECUTED]} file(s)"
    if counts[IMPORTED]:
        return f"{name} imports changed code from {counts[IMPORTED]} file(s)" + \
            ("" if coverage else " (use --coverage to see whether it runs)")
    seen = counts[NOT_EXECUTED] + counts[NO_CODE] + counts[TREE_SHAKEN]
    if seen:
        return f"{name} imports {seen} changed file(s) but runs none of the changed code"
    return f"no changed file is in {name}'s import graph"


def render(report: Mapping) -> str:
    lines = [f"{report['summary']}",
             f"test {report['test']} at {report['head'][:12]}: {report['graph_size']} local modules "
             f"(entries: {', '.join(report['entries'])}); {report['changed']} changed file(s)"]
    for item in report["files"]:
        if item["verdict"] == NOT_IMPORTED:
            continue
        extra = ""
        if item.get("chain"):
            extra = "  via " + " -> ".join(item["chain"])
        if item.get("lines_run"):
            extra += f"  lines run: {item['lines_run'][:10]}"
        if item.get("lines_not_run"):
            extra += f"  lines not run: {item['lines_not_run'][:10]}"
        lines.append(f"  {item['verdict']:<15} {item['file']}{extra}")
    outside = sum(1 for f in report["files"] if f["verdict"] == NOT_IMPORTED)
    lines.append(f"  {outside} changed file(s) not imported")
    if report.get("deleted"):
        lines.append(f"  {len(report['deleted'])} deleted file(s) not checked: {', '.join(report['deleted'][:5])}")
    if not report.get("sandboxed", True):
        lines.append("  bun ran unsandboxed (no Linux user namespaces): it could read your files")
    lines.append(f"  {BLIND_SPOTS}")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("test", help="test file, repository path (web/tests/x.test.ts) or relative to web/")
    parser.add_argument("--base", help="base ref; the diff is base...head (from their merge base)")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--changed", nargs="*", help="repository paths to check instead of git diff")
    parser.add_argument("--coverage", action="store_true",
                        help="also RUN the head's test (trusted commits only) to see whether changed lines execute")
    parser.add_argument("--allow-unsandboxed", action="store_true",
                        help="run bun on the head without a sandbox (macOS): only for commits you trust")
    parser.add_argument("--repo", type=Path, default=None)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    if shutil.which("bun") is None:
        raise SystemExit("bun is not on PATH")
    repo = args.repo or Path(str(git(Path.cwd(), "rev-parse", "--show-toplevel")).strip())
    if args.coverage:
        print("--coverage runs the head's test code on this machine; use it only on trusted commits.",
              file=sys.stderr)
    try:
        report = check(repo, args.test, args.base, args.head, changed=args.changed, coverage=args.coverage,
                       allow_unsandboxed=args.allow_unsandboxed)
    except UnsafeToAnalyse as error:
        print(error, file=sys.stderr)
        return 2
    print(json.dumps(report, indent=2) if args.json else render(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
