#!/usr/bin/env python3
"""cmux-next pre-push gate: refuse a push that adds a static-check violation.

Runs, in seconds and with no build, the static checks of the "cmux-next checks" CI job
(.github/workflows/cmux-next.yml, job `checks`) plus pinned syntax tools, and fails only on what
the pushed commits ADD. Base debt never blocks a push.

How: the files the push changes are written into two small trees, one at the base and one at the
head, next to the check scripts (from the head) and their baselines (from each side). Every check
runs on both trees; a finding is new when the head has it and the base does not. A finding is keyed
by file, rule and the text of its source line, not its line number, so moving code is not new.

Layers (each one only on files the push changes under Packages/macOS/CmuxNext, cmux-tui, webviews, cmux-next-ios):
  scanners     the CI job's line scanners: concurrency, crash safety, dialog key hints, type scale,
               motion, scrollbars, state roots, process scan, Swift CLI, closed history, test
               notification centers, string tables, module resources, capability text, browser
               chrome icons, App Store review rules (also on cmux-next-ios/ changes), the perf
               source guard, fleet host names in gallery fixtures (also on Packages/ changes)
  ast-grep     scripts/cmux-next/lint/ast-grep-rules: try!, blocking calls, raw font sizes, system
               dialogs, opaque glass (tree-sitter, so comments, strings and `case .alert` never match)
  swiftformat  --lint with scripts/cmux-next/lint/swiftformat.conf
  swiftlint    swift-syntax rules only (scripts/cmux-next/lint/swiftlint.yml), no SourceKit
Tool versions are pinned in scripts/cmux-next/lint-tools.lock and downloaded once (sha256 checked)
to $CMUX_LINT_TOOLS_DIR (default ~/Library/Caches/cmux-lint-tools, ~/.cache/cmux-lint-tools on Linux).

Also on every push, whatever it changes: "Ghostty-default keys" (check-ghostty-reserved-keys.py): the
exported default keymap keeps Ghostty's split keys (schemas/keybindings/ghostty-reserved-keys.json),
and the push removes no reserved entry. CMUX_NEXT_CHECKS_SKIP_REASON does not skip it; only a
`Ghostty-defaults-OK: <the user's words>` trailer on a pushed commit does (Lawrence 2026-10-20).
Also on every push: "Sidebar look owner" (plans/cmux-next/sidebar-owner.md): a commit that changes the
sidebar's drawing code (CmuxNextSidebar/Views/) carries a `Sidebar-Look: <the user's words, or "no visual
change">` trailer, and a visual change also edits plans/cmux-next/sidebar-owner.md in the same commit.
233 sidebar commits in four days with no owner undid each other (Lawrence 2026-10-23: "why were there so
many changes to sidebar?"). CMUX_NEXT_CHECKS_SKIP_REASON does not skip it. A commit the owner logged in
that note (its 11-character sha) passes. CI also sweeps every commit since the check landed
(`--only sidebar --commits`), so a push from an old hook copy or a cancelled CI run is still caught.
Also on every push, in any file: "Merge conflict markers": a file the push adds both a `<<<<<<< ` and
a `>>>>>>> ` line to (c779988d57d, 2026-10-22, broke CmuxNextAppTests). Nothing skips it.

Also on every local run (the hook and a plain run; never --commits, never under GitHub Actions, so CI
gains no gate; Lawrence 2026-10-23): "Guardrails" (guardrails.py, plans/cmux-next/codebase-health.md):
refuses NEW singletons, unjustified @unchecked Sendable / nonisolated(unsafe) (the crash ratchet's class,
which its per-module count cannot see before a push), DispatchQueue.main.async, new Notification.Name
broadcasts, ObservableObject/@Published, store references in list rows, generic classes with an implicit
deinit and bench hooks in shipped builds, in lines the push adds, and CmuxNextApp composition-root growth
beyond its wiring budget or a new App file that is not a move (`app-size`, a net count); sleeps and
assumeIsolated are the scanners' rules above. Warns on CmuxNextApp source growth, `// perf-hot:` functions
and OWNERS.md areas. Skip one push with
CMUX_GUARDRAILS_SKIP_REASON="<rule>[,<rule>]: <why>" (it skips only the named rules); lines a push only
brings in from origin/feat-cmux-next (a merge or rebase onto it) never count; --no-guardrails turns it off
for a manual run.
In the same local-only place: "Arch ratchet" (arch-ratchet.py, plans/cmux-next/arch-ratchet.json): refuses a
push that raises the total of an architecture count (layer edges, stateful singletons, global mutable statics,
assumeIsolated outside seam adapters, app broadcast names, observer sites; arch_counts.py defines them),
counting only the files the push changes; a move between packages passes. It starts on a thread before the
scanners (it only waits on git), so a push pays only what is left of it at the guardrails. Skip one row for one
push with ARCH_RATCHET_SKIP_REASON="<row>: <why>"; --no-guardrails turns it off too; it fails open.

Not here (they stay on CI and the fleet): generated-file freshness (gen-*.py --check), god files,
the app size cap, script tests, Swift and Rust builds and tests.

  scripts/cmux-next/prepush-gate.py                  # what HEAD adds over origin/feat-cmux-next
  scripts/cmux-next/prepush-gate.py --base A --head B
  scripts/cmux-next/prepush-gate.py --pre-push       # the hook: reads pre-push stdin
  scripts/cmux-next/prepush-gate.py --commits A..B   # CI: each commit against its parent, named
Escape hatch for one push: CMUX_NEXT_CHECKS_SKIP_REASON="<check> fails in files this push does not
touch (base <sha>)". The reason is printed; say it in your report.
"""
from __future__ import annotations

import argparse
import collections
import concurrent.futures
import hashlib
import importlib.util
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import zipfile
from pathlib import Path

ZERO_SHA = "0" * 40
DEFAULT_BASE_REFS = ("origin/feat-cmux-next",)
PKG = "Packages/macOS/CmuxNext"
SCRIPTS = "scripts/cmux-next"
SCOPES = (PKG + "/", "cmux-tui/", "webviews/")
SWIFT_SCOPE = PKG + "/"
# Files a scanner reads besides the changed ones: present in both trees, so they never differ.
CONTEXT = (
    PKG + "/Package.swift",
    PKG + "/Sources/CmuxNextApp/CmuxNextApp.swift",
    PKG + "/Sources/CmuxNextIcons/IconName+Members.swift",
    PKG + "/Sources/CmuxNextIcons/Resources/icon-catalog.json",
    "cmux.xcodeproj/project.pbxproj",
    "cmux-next-ios/project.yml",
)
DATA_SUFFIXES = (".tsv", ".json")

# (CI step name, command, path prefixes that make it run). {root} is the tree, {pkg} its CmuxNext
# package, {s} its scripts/cmux-next. Mirrors the job's steps; tests/test_cmux_next_prepush_gate.py
# keeps this list in step with the workflow.
SCANNERS = (
    ("Dialog buttons show their keys (u2647)", ["python3", "-I", "{s}/check-dialog-key-hints.py", "{root}"], (PKG + "/", "webviews/")),
    ("Main-thread concurrency", ["/bin/bash", "{s}/check-concurrency.sh", "{pkg}"], (PKG + "/", "Packages/Shared/")),
    ("Crash safety", ["/bin/bash", "{s}/check-crash-safety.sh", "{pkg}"], (PKG + "/", "cmux-tui/")),
    ("Type scale", ["python3", "-I", "{s}/check-swift-type-scale.py", "--root", "{root}",
                    "--baseline", "{s}/swift-type-scale-baseline.tsv"], (PKG + "/",)),
    ("Motion tokens", ["/bin/bash", "{s}/check-motion.sh", "{pkg}"], (PKG + "/",)),
    ("Overlays are glass, never solid", ["python3", "-I", "{s}/check-overlay-glass.py", "{root}"], (PKG + "/",)),
    ("Scrollbars thin, one style", ["/bin/bash", "{s}/check-scrollbars.sh", "{root}"], (PKG + "/", "webviews/")),
    ("No literal state roots (per-build isolation S7, cx-is1kf.8)", ["/bin/bash", "{s}/check-state-roots.sh", "{root}"], SCOPES),
    ("No process scanning (holders register themselves, plans/cmux-next/pty-holder.md 4)",
     ["python3", "-I", "{s}/check-no-process-scan.py", "{root}"], SCOPES),
    ("No Swift CLI (the cmux CLI is Rust, plans/cmux-next/cli.md)", ["/bin/bash", "{s}/check-no-swift-cli.sh", "{root}"], (PKG + "/",)),
    ("No Swift closed history (the daemon owns it, plans/cmux-next/reopen-closed.md 9)",
     ["/bin/bash", "{s}/check-no-swift-closed-history.sh", "{root}"], (PKG + "/",)),
    ("Tests inject their notification center", ["/bin/bash", "{s}/check-test-notification-centers.sh", "{pkg}"], (PKG + "/",)),
    ("String tables (21 languages)", ["/bin/bash", "{s}/check-l10n.sh", "{root}"], (PKG + "/",)),
    ("Module resource bundles", ["/bin/bash", "{s}/check-module-resources.sh", "{pkg}"], (PKG + "/",)),
    ("Capability texts never say update the app", ["python3", "-I", "{s}/check-capability-text.py", "--root", "{root}"], ("cmux-tui/",)),
    ("Browser chrome icons", ["python3", "-I", "{s}/lint-browser-chrome-icons.py"], (PKG + "/",)),
    ("App Store review rules (cmux-next-ios intents, Info.plist)",
     ["python3", "-I", "{s}/check-app-store-rules.py", "--source", "{root}"], ("cmux-next-ios/",)),
    ("Perf source guard (no window capture or CATransaction.flush)",
     ["python3", "-I", "{s}/check-perf-source-guard.py", "{root}"], (PKG + "/",)),
    ("No fleet host names in gallery fixtures",
     ["python3", "-I", "{s}/check-fixture-host-names.py", "{root}"], ("Packages/", "webviews/src/")),
)

# Ghostty's default split keys stay Ghostty's (Lawrence 2026-10-20, after 2f3e1f95983).
RESERVED_CHECK = "Ghostty-default keys (schemas/keybindings/ghostty-reserved-keys.json)"
CONFLICT_CHECK = "Merge conflict markers"
SIDEBAR_CHECK = "Sidebar look owner (plans/cmux-next/sidebar-owner.md)"
SIDEBAR_VIEWS = "Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/Views/"
SIDEBAR_NOTE = "plans/cmux-next/sidebar-owner.md"
SIDEBAR_TRAILER = re.compile(r"^Sidebar-Look:[ \t]*(\S.*)$", re.MULTILINE)
SIDEBAR_NO_VISUAL = re.compile(r"^no visual change\b", re.IGNORECASE)
# An added line that opens or closes a conflict hunk (`=======` alone is a Markdown or RST rule).
CONFLICT_OPEN = re.compile(r"^<{7} ")
CONFLICT_CLOSE = re.compile(r"^>{7} ")
RESERVED_SCRIPT = SCRIPTS + "/check-ghostty-reserved-keys.py"
RESERVED_LIST = "schemas/keybindings/ghostty-reserved-keys.json"
RESERVED_SURFACES = "plans/cmux-next/action-surfaces.json"
RESERVED_OK = re.compile(r"^Ghostty-defaults-OK:\s*\S", re.MULTILINE)

# Reviewed escapes the CI scanners honor, per ast-grep rule (same line or the comment block above).
ESCAPES = {
    "no-try-bang": re.compile(r"//\s*crash-allow:\s*\S"),
    "no-main-thread-block": re.compile(r"//\s*concurrency-allow:\s*\S"),
    "no-system-dialog": re.compile(r"dialog-keys-exempt:\s*\S"),
    "no-opaque-glass": re.compile(r"//\s*glass-opaque-allow:\s*\S"),
}
COMMENT_LINE = re.compile(r"^\s*(//|\*|/\*)")
LOCATION = re.compile(r"(?P<path>[\w.+@/-]+\.(?:swift|rs|ts|tsx|py|sh|json|xcstrings|md)):(?P<line>\d+)(?::\d+)?")
NUMBER = re.compile(r"\d+")
# Lines a scanner prints that are not findings: summaries, backlogs and warning-tier annotations.
INFO = re.compile(r"^(needs_review \(machine translated\)|\d+ tables, \d+ keys|::warning|.*ratchet debt|perf source guard: )")
# A check that crashed instead of judging (both sides crash alike, so the diff alone would hide it).
BROKEN = re.compile(r"Traceback \(most recent call last\)|No such file or directory|command not found|SyntaxError")
# The warning tiers CI gives the ratchets (cmux-next.yml, checks job).
CI_ENV = {"L10N_STYLE_WARN_MAX": "100", "SCROLLBARS_WARN_MAX": "10", "GODFILES_WARN_SLACK": "20"}


def log(message: str) -> None:
    print(message, file=sys.stderr)


def load_sibling(name: str, filename: str):
    """The module FILENAME beside this file (scripts/cmux-next in a checkout; the hook folder for the installed copy)."""
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# Request bytes go through a file, not a pipe (git_batch.py says why); guardrails.py uses the same helper.
git_batch = load_sibling("cmux_next_git_batch", "git_batch.py")


def git(repo: Path, *args: str, check: bool = True) -> bytes:
    result = git_batch.run(repo, list(args))
    if check and result.returncode != 0:
        raise SystemExit(f"prepush-gate: git {' '.join(args)} failed: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout


def rev_ok(repo: Path, rev: str) -> bool:
    return subprocess.run(["git", "-C", str(repo), "rev-parse", "--verify", "--quiet", f"{rev}^{{commit}}"],
                          capture_output=True).returncode == 0


def default_base(repo: Path, head: str) -> str:
    for ref in DEFAULT_BASE_REFS:
        if rev_ok(repo, ref):
            base = git(repo, "merge-base", head, ref, check=False).decode().strip()
            if base:
                return base
    return f"{head}~1" if rev_ok(repo, f"{head}~1") else head


def pushed_ranges(repo: Path, lines: list[str]) -> list[tuple[str, str]]:
    """Pre-push stdin rows (`<local ref> <local sha> <remote ref> <remote sha>`) as (base, head)."""
    ranges = []
    for line in lines:
        parts = line.split()
        if len(parts) != 4 or parts[1] == ZERO_SHA:
            continue  # a deletion pushes no code
        local_sha, remote_sha = parts[1], parts[3]
        if remote_sha != ZERO_SHA and rev_ok(repo, remote_sha):
            base = git(repo, "merge-base", local_sha, remote_sha, check=False).decode().strip() or remote_sha
        else:
            base = default_base(repo, local_sha)
        ranges.append((base, local_sha))
    return ranges


def changed_files(repo: Path, base: str, head: str) -> list[str]:
    names = git(repo, "diff", "--name-only", "--no-renames", "--diff-filter=ACMRT", "-z", base, head).decode()
    return sorted(n for n in names.split("\0") if n and n.startswith(SCOPES + ("Packages/Shared/", "cmux-next-ios/")))


# ---------------------------------------------------------------- pinned tools

def platform_key() -> str:
    system = {"Darwin": "darwin", "Linux": "linux"}.get(platform.system(), platform.system().lower())
    machine = {"aarch64": "arm64", "amd64": "x86_64"}.get(platform.machine(), platform.machine())
    return f"{system}-{machine}"


def tools_dir() -> Path:
    if os.environ.get("CMUX_LINT_TOOLS_DIR"):
        return Path(os.environ["CMUX_LINT_TOOLS_DIR"])
    if platform.system() == "Darwin":
        return Path.home() / "Library" / "Caches" / "cmux-lint-tools"
    return Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "cmux-lint-tools"


def read_lock(lock: Path) -> dict[str, tuple[str, str, str, str]]:
    rows, key = {}, platform_key()
    for line in lock.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        tool, version, plat, url, sha, member = line.split("\t")
        if plat == key:
            rows[tool] = (version, url, sha, member)
    return rows


def ensure_tool(lock: Path, tool: str) -> Path:
    """The pinned binary, downloaded and sha256-checked once per version."""
    rows = read_lock(lock)
    if tool not in rows:
        raise SystemExit(f"prepush-gate: {tool} has no pinned build for {platform_key()} in {lock}")
    version, url, sha, member = rows[tool]
    target = tools_dir() / f"{tool}-{version}-{platform_key()}" / tool
    if target.is_file() and os.access(target, os.X_OK):
        return target
    target.parent.mkdir(parents=True, exist_ok=True)
    log(f"prepush-gate: downloading {tool} {version} (once) from {url}")
    with tempfile.TemporaryDirectory(dir=target.parent) as tmp:
        archive = Path(tmp) / "tool.zip"
        with urllib.request.urlopen(url, timeout=120) as response, open(archive, "wb") as out:
            shutil.copyfileobj(response, out)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        if digest != sha:
            raise SystemExit(f"prepush-gate: {tool} download sha256 {digest} != pinned {sha}; refusing it")
        with zipfile.ZipFile(archive) as zf:
            extracted = Path(zf.extract(member, tmp))
        extracted.chmod(0o755)
        os.replace(extracted, target)
    return target


# ---------------------------------------------------------------- trees

def write_tree(repo: Path, dest: Path, files: dict[str, str]) -> None:
    """Write {path: rev} blobs into dest (one `git cat-file --batch`), then index them for ls-files."""
    paths = sorted(files)
    try:
        blobs = git_batch.cat_file(repo, [f"{files[p]}:{p}" for p in paths])
    except git_batch.GitError as error:
        raise SystemExit(f"prepush-gate: {error}")
    for path in paths:
        blob = blobs[f"{files[path]}:{path}"]
        if blob is None:
            continue  # missing at this rev (added or deleted file)
        target = dest / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(blob)
        if path.endswith(".sh"):
            target.chmod(0o755)
    (dest / PKG / "Sources").mkdir(parents=True, exist_ok=True)
    (dest / PKG / "Tests").mkdir(parents=True, exist_ok=True)
    # A hook runs with GIT_DIR (and maybe GIT_INDEX_FILE, GIT_WORK_TREE) of the pushing checkout:
    # without them stripped, init and add would rewrite that repository instead of the temp tree.
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    subprocess.run(["git", "init", "-q", str(dest)], check=True, env=env, capture_output=True)
    subprocess.run(["git", "-C", str(dest), "add", "-A"], check=True, capture_output=True, env=env)


def ls_tree(repo: Path, rev: str, prefix: str) -> list[str]:
    out = git(repo, "ls-tree", "-r", "-z", "--name-only", rev, "--", prefix).decode()
    return [p for p in out.split("\0") if p]


def build_trees(repo: Path, base: str, head: str, changed: list[str], work: Path,
                trusted_scripts: Path | None = None) -> tuple[Path, Path]:
    # The check scripts and their data sit at the top of scripts/cmux-next (plus lint/); its test,
    # release and harness subfolders are not read by any check and would only slow the copy.
    scripts = [] if trusted_scripts else [p for p in ls_tree(repo, head, SCRIPTS + "/")
                                          if "/" not in p[len(SCRIPTS) + 1:] or p.startswith(SCRIPTS + "/lint/")]
    base_data = set(ls_tree(repo, base, SCRIPTS + "/"))
    trees = []
    for side, rev in (("base", base), ("head", head)):
        files = {p: head for p in scripts}  # the check code is the head's on both sides
        for p in scripts:
            if p.endswith(DATA_SUFFIXES) and side == "base":
                files[p] = base if p in base_data else head  # each side's own baselines
        for p in CONTEXT:
            files[p] = rev
        for p in changed:
            files[p] = rev
        dest = work / side
        write_tree(repo, dest, files)
        if trusted_scripts:
            shutil.copytree(trusted_scripts, dest / SCRIPTS, dirs_exist_ok=True)
        trees.append(dest)
    return trees[0], trees[1]


# ---------------------------------------------------------------- findings

def source_line(tree: Path, roots: list[Path], rel: str, number: int) -> str | None:
    for root in roots:
        path = root / rel
        if path.is_file():
            try:
                lines = path.read_text(encoding="utf-8", errors="replace").split("\n")
            except OSError:
                return None
            return lines[number - 1].strip() if 0 < number <= len(lines) else None
    return None


def normalize(text: str, tree: Path) -> str:
    """A finding's identity: file, rule and source text; no tree path, no line or count numbers."""
    text = text.replace(str(tree.resolve()) + "/", "").replace(str(tree) + "/", "")
    roots = [tree, tree / PKG, tree / PKG / "Sources", tree / PKG / "Tests", tree / "Packages"]

    def keyed(match: re.Match) -> str:
        line = source_line(tree, roots, match.group("path"), int(match.group("line")))
        return f"{match.group('path')}:«{line}»" if line is not None else match.group("path")
    parts = []
    last = 0
    for match in LOCATION.finditer(text):
        parts.append(NUMBER.sub("N", text[last:match.start()]))
        parts.append(keyed(match))
        last = match.end()
    parts.append(NUMBER.sub("N", text[last:]))
    return "".join(parts).strip()


def records(output: str) -> list[str]:
    """Output lines, an indented line joined to the finding above it."""
    out: list[str] = []
    for line in output.splitlines():
        if not line.strip():
            continue
        if line[:1].isspace() and out and LOCATION.search(out[-1]):
            out[-1] += "\n" + line
        else:
            out.append(line)
    return out


def new_records(base_out: str, head_out: str, base_tree: Path, head_tree: Path) -> list[str]:
    seen = collections.Counter(normalize(r, base_tree) for r in records(base_out))
    fresh = []
    for record in records(head_out):
        key = normalize(record, head_tree)
        if seen[key] > 0:
            seen[key] -= 1
        elif not re.search(r": ok\b|^All |passed|^ok\b", record) and not INFO.match(record):
            fresh.append(record.replace(str(head_tree) + "/", ""))
    return fresh


def run(cmd: list[str], cwd: Path, timeout: int = 120) -> tuple[int, str]:
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")} | CI_ENV
    try:
        result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, env=env,
                                stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return 124, f"timed out after {timeout}s"
    return result.returncode, result.stdout + result.stderr


def fill(cmd: list[str], tree: Path) -> list[str]:
    return [c.format(root=tree, pkg=tree / PKG, s=tree / SCRIPTS) for c in cmd]


def escaped(tree: Path, rel: str, index: int, rule: str) -> bool:
    pattern = ESCAPES.get(rule)
    if pattern is None:
        return False
    try:
        lines = (tree / rel).read_text(encoding="utf-8", errors="replace").split("\n")
    except OSError:
        return False
    if index < len(lines) and pattern.search(lines[index]):
        return True
    j = index - 1
    while j >= 0 and COMMENT_LINE.match(lines[j]):
        if pattern.search(lines[j]):
            return True
        j -= 1
    return False


def ast_grep(binary: Path, config: Path, tree: Path, swift: list[str]) -> str:
    present = [p for p in swift if (tree / p).is_file()]
    if not present:
        return ""
    result = subprocess.run([str(binary), "scan", "-c", str(config), "--json=compact", *present],
                            cwd=tree, capture_output=True, text=True, stdin=subprocess.DEVNULL)
    try:
        matches = json.loads(result.stdout or "[]")
    except json.JSONDecodeError:
        return f"ast-grep failed: {result.stderr.strip()}"
    lines = []
    for m in matches:
        rel, index = m["file"], m["range"]["start"]["line"]
        if escaped(tree, rel, index, m["ruleId"]):
            continue
        lines.append(f"{rel}:{index + 1}: [{m['ruleId']}] {m['message']}")
    return "\n".join(sorted(lines))


def swiftformat(binary: Path, config: Path, tree: Path, swift: list[str]) -> str:
    present = [p for p in swift if (tree / p).is_file()]
    if not present:
        return ""
    cache = tools_dir() / "swiftformat.cache"
    _, out = run([str(binary), "--lint", "--config", str(config), "--cache", str(cache), "--quiet", *present], tree)
    return "\n".join(l for l in out.splitlines() if LOCATION.search(l))


def swiftlint(binary: Path, config: Path, tree: Path, swift: list[str]) -> str:
    present = [p for p in swift if (tree / p).is_file()]
    if not present:
        return ""
    _, out = run([str(binary), "lint", "--config", str(config), "--quiet", "--no-cache", "--reporter", "xcode",
                  *present], tree)
    return "\n".join(l for l in out.splitlines() if LOCATION.search(l))


# ---------------------------------------------------------------- gate

def reserved_keys(repo: Path, base: str, head: str, trusted_scripts: Path | None = None) -> list[str]:
    """What head adds to the Ghostty-default keys check (RESERVED_CHECK) over base."""
    def blob(rev: str, path: str) -> bytes | None:
        result = subprocess.run(["git", "-C", str(repo), "show", f"{rev}:{path}"], capture_output=True)
        return result.stdout if result.returncode == 0 else None

    # The hook runs the installed reviewed checker (as for the scanners), else the head's.
    trusted = trusted_scripts / Path(RESERVED_SCRIPT).name if trusted_scripts else None
    script = trusted.read_bytes() if trusted and trusted.is_file() else blob(head, RESERVED_SCRIPT)
    if script is None:
        return []  # a commit older than this check
    with tempfile.TemporaryDirectory(prefix="cmux-reserved-") as tmp:
        work = Path(tmp)
        (work / "check.py").write_bytes(script)

        def findings(rev: str, base_list: bytes | None) -> list[str] | None:
            reserved, surfaces = blob(rev, RESERVED_LIST), blob(rev, RESERVED_SURFACES)
            if reserved is None or surfaces is None:
                return None
            (work / f"{rev}.reserved.json").write_bytes(reserved)
            (work / f"{rev}.surfaces.json").write_bytes(surfaces)
            cmd = ["python3", "-I", str(work / "check.py"), "--reserved", str(work / f"{rev}.reserved.json"),
                   "--surfaces", str(work / f"{rev}.surfaces.json")]
            if base_list is not None:
                (work / "base-list.json").write_bytes(base_list)
                cmd += ["--base-reserved", str(work / "base-list.json")]
            _, out = run(cmd, work)
            return [line for line in out.splitlines() if line.strip()]

        head_lines = findings(head, blob(base, RESERVED_LIST)) or []
        base_lines = findings(base, None) or []
    fresh = [line for line in head_lines if line not in base_lines]
    if fresh and RESERVED_OK.search(git(repo, "log", "--format=%B", f"{base}..{head}", check=False).decode(errors="replace")):
        log(f"prepush-gate: {RESERVED_CHECK}: allowed by a Ghostty-defaults-OK trailer:\n  " + "\n  ".join(fresh))
        return []
    return fresh


def conflict_markers(repo: Path, base: str, head: str) -> list[str]:
    """`file:line` of each conflict marker the push adds, in any file of the repository.

    2026-10-22: c779988d57d landed `<<<<<<< HEAD` in SidebarNowLineTests.swift and CmuxNextAppTests
    stopped compiling; no scanner reads a test file. A file counts only when the push adds both an
    opening and a closing marker to it, so a fixture that mentions one marker never matches.
    """
    # Fixed prefixes: with a user's diff.noprefix the `+++ b/` headers this parse reads would be missing.
    diff = git(repo, "diff", "-U0", "--no-color", "--no-renames", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/",
               base, head).decode("utf-8", "replace")
    found: dict[str, list[tuple[int, str]]] = collections.defaultdict(list)
    name, number = "", 0
    for line in diff.splitlines():
        if line.startswith("+++ "):
            name = line[6:] if line.startswith("+++ b/") else ""
        elif line.startswith("@@"):
            match = re.search(r"\+(\d+)", line)
            number = int(match.group(1)) if match else 0
        elif line.startswith("+") and name:
            text = line[1:]
            if CONFLICT_OPEN.match(text) or CONFLICT_CLOSE.match(text):
                found[name].append((number, text))
            number += 1
    return [f"{name}:{n}: {text}" for name, marks in sorted(found.items())
            if any(CONFLICT_OPEN.match(t) for _, t in marks) and any(CONFLICT_CLOSE.match(t) for _, t in marks)
            for n, text in marks]


def sidebar_owner(repo: Path, base: str, head: str, ack_rev: str | None = None) -> list[str]:
    """Each pushed commit that changes the sidebar's drawing code without the owner's record.

    A commit touching `SIDEBAR_VIEWS` needs a `Sidebar-Look:` trailer: the user's words that asked for the
    look (a visual change, which must also edit `SIDEBAR_NOTE` in that commit) or `no visual change` (a
    behavior or performance change; the sidebar look contract tests hold the look). Checked per commit, so a
    later commit cannot launder an earlier one.

    A commit the owner has logged passes too: its 11-character sha in `SIDEBAR_NOTE` at `ack_rev` (default
    `head`). That is how a commit that reached the branch without a trailer (an old hook, a cancelled CI
    run; dcd4316ef5c, 2026-10-23) is reviewed once instead of failing every later sweep.
    """
    found: list[str] = []
    note = subprocess.run(["git", "-C", str(repo), "show", f"{ack_rev or head}:{SIDEBAR_NOTE}"], capture_output=True)
    logged = note.stdout.decode(errors="replace") if note.returncode == 0 else ""
    # One `git log` for the whole range (a CI sweep reads every commit since the check landed): per commit a
    # record separator, the sha, the message, then the files it changes.
    out = git(repo, "log", "--reverse", "--no-merges", "--name-only", "--format=%x1e%H%x1f%B%x1f",
              f"{base}..{head}", "--", check=False).decode(errors="replace")
    for record in out.split("\x1e")[1:]:
        sha, message, names = (record.split("\x1f") + ["", ""])[:3]
        files = [f for f in names.split("\n") if f]
        views = sorted(f for f in files if f.startswith(SIDEBAR_VIEWS))
        if not views or sha[:11] in logged:
            continue
        subject = message.strip().splitlines()[0] if message.strip() else ""
        trailer = SIDEBAR_TRAILER.search(message)
        where = f"{sha[:11]} {subject[:70]} ({views[0]}{f' and {len(views) - 1} more' if len(views) > 1 else ''})"
        if trailer is None:
            found.append(f"{where}: no `Sidebar-Look:` trailer. Add `Sidebar-Look: <the user's words>` (and edit "
                         f"{SIDEBAR_NOTE}) or `Sidebar-Look: no visual change`.")
        elif not SIDEBAR_NO_VISUAL.match(trailer.group(1).strip()) and SIDEBAR_NOTE not in files:
            found.append(f"{where}: a visual change (`Sidebar-Look: {trailer.group(1).strip()[:60]}`) must update "
                         f"{SIDEBAR_NOTE} in the same commit: the target look and the commit log.")
    return found


def gate(repo: Path, base: str, head: str, only: set[str] | None, timings: bool,
         trusted_scripts: Path | None = None, ack_rev: str | None = None) -> list[tuple[str, list[str]]]:
    """[(check, new findings)] that head adds over base."""
    reserved: list[tuple[str, list[str]]] = []
    if only is None or "reserved" in only:
        fresh = reserved_keys(repo, base, head, trusted_scripts)
        reserved = [(RESERVED_CHECK, fresh)] if fresh else []
    if only is None or "conflicts" in only:
        markers = conflict_markers(repo, base, head)
        if markers:
            reserved.append((CONFLICT_CHECK, markers))
    if only is None or "sidebar" in only:
        owner = sidebar_owner(repo, base, head, ack_rev)
        if owner:
            reserved.append((SIDEBAR_CHECK, owner))
    # The git-only checks above need no trees: a run of only those (CI's sidebar sweep) stops here.
    if only is not None and not only & {"scanners", "ast-grep", "swiftformat", "swiftlint"}:
        return reserved
    changed = changed_files(repo, base, head)
    if not changed:
        return reserved
    swift = [p for p in changed if p.startswith(SWIFT_SCOPE) and p.endswith(".swift")]
    sources = [p for p in swift if p.startswith(PKG + "/Sources/")]
    started = time.monotonic()
    found: list[tuple[str, list[str]]] = list(reserved)
    with tempfile.TemporaryDirectory(prefix="cmux-prepush-") as tmp:
        base_tree, head_tree = build_trees(repo, base, head, changed, Path(tmp), trusted_scripts)
        # The tool rules and pins come from the head; a commit older than the gate uses the checkout's.
        config_root = head_tree if (head_tree / SCRIPTS / "lint-tools.lock").is_file() else repo
        lint = config_root / SCRIPTS / "lint"
        lock = config_root / SCRIPTS / "lint-tools.lock"
        jobs: dict[str, tuple] = {}
        for name, cmd, prefixes in SCANNERS:
            script = next(Path(c) for c in fill(cmd, head_tree) if c.startswith(str(head_tree / SCRIPTS)))
            if not script.is_file():
                continue  # a commit older than this check
            if any(p.startswith(prefixes) for p in changed) and (only is None or "scanners" in only):
                jobs[name] = ("cmd", cmd)
        if not lock.is_file():
            sources, swift = [], []  # a checkout older than the pinned tools: scanners only
        if sources and (only is None or "ast-grep" in only):
            jobs["ast-grep (scripts/cmux-next/lint/ast-grep-rules)"] = ("fn", ast_grep, ensure_tool(lock, "ast-grep"),
                                                                       lint / "sgconfig.yml", sources)
        if swift and (only is None or "swiftformat" in only):
            jobs["SwiftFormat --lint"] = ("fn", swiftformat, ensure_tool(lock, "swiftformat"),
                                          lint / "swiftformat.conf", swift)
        if swift and (only is None or "swiftlint" in only):
            jobs["SwiftLint (syntax rules)"] = ("fn", swiftlint, ensure_tool(lock, "swiftlint"),
                                                lint / "swiftlint.yml", swift)

        def side(job, tree):
            t0 = time.monotonic()
            if job[0] == "cmd":
                code, out = run(fill(job[1], tree), tree)
            else:
                _, fn, binary, config, files = job
                out = fn(binary, config, tree, files)
                code = 1 if out else 0
            return code, out, time.monotonic() - t0

        with concurrent.futures.ThreadPoolExecutor(max_workers=min(16, (os.cpu_count() or 4))) as pool:
            futures = {(name, tree): pool.submit(side, job, tree)
                       for name, job in jobs.items() for tree in (base_tree, head_tree)}
            for name in jobs:
                _, base_out, base_s = futures[(name, base_tree)].result()
                head_code, head_out, head_s = futures[(name, head_tree)].result()
                if timings:
                    log(f"  {max(base_s, head_s):5.2f}s  {name}")
                if BROKEN.search(head_out):
                    log(f"prepush-gate: WARNING: {name} did not run cleanly in the push's tree; CI still runs it:\n"
                        + "\n".join(head_out.splitlines()[-5:]))
                if os.environ.get("CMUX_PREPUSH_GATE_DEBUG"):
                    log(f"--- {name} (head exit {head_code})\n{head_out}")
                if head_code == 0:
                    continue  # passing on the head: what it prints is a warning tier, as in CI
                fresh = new_records(base_out, head_out, base_tree, head_tree)
                if fresh:
                    found.append((name, fresh))
    if timings:
        log(f"prepush-gate: {len(changed)} changed file(s), {time.monotonic() - started:.1f}s")
    return found


def load_guardrails(repo: Path, trusted_scripts: Path | None):
    """The guardrails module: the installed reviewed copy for the hook, else this checkout's."""
    script = (trusted_scripts / "guardrails.py") if trusted_scripts else (repo / SCRIPTS / "guardrails.py")
    if not script.is_file():
        return None
    spec = importlib.util.spec_from_file_location("cmux_next_guardrails", script)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # dataclasses resolve their module through sys.modules
    spec.loader.exec_module(module)
    return module


def guardrails(repo: Path, ranges: list[tuple[str, str]], trusted_scripts: Path | None) -> bool:
    """Print the guardrail warnings and refusals for RANGES; True when they refuse the push.

    The rules are advisory debt checks in every agent's hook: a bug in one rule turns off only that rule
    (guardrails.check warns and runs the rest); a bug outside the rules (a failed load or git call, a parse
    edge) prints a warning and lets the push through instead of blocking every push with a traceback.
    check_push leaves out what a range only brings in from origin/feat-cmux-next (a merge of it into a branch,
    or a rebase onto it and a force push): CI never runs these rules, so that base can carry debt.
    """
    try:
        module = load_guardrails(repo, trusted_scripts)
        if module is None:
            if trusted_scripts:
                log("prepush-gate: guardrails.py is not installed; rerun scripts/install-git-hooks.sh")
            return False
        refused = False
        check = getattr(module, "check_push", module.check)
        for base, head in ranges:
            refusals, warnings = check(repo, base, head)
            text, refuse = module.format_report(refusals, warnings)
            if text:
                print(text)
            refused = refused or refuse
        return refused
    except (Exception, SystemExit) as error:  # SystemExit: guardrails.git() exits on a failed git call
        log(f"prepush-gate: WARNING: guardrails.py failed ({type(error).__name__}: {error}); not applied to "
            "this push. Tell the Performance Lead (PL-guardrails) with this line.")
        return False


class ArchRatchet:
    """The arch ratchet (arch-ratchet.py) for RANGES, started at once on a thread next to the scanners.

    It waits only on git, so the push pays just what is left of it when the gate reaches the guardrails
    (`finish`). It fails open: a missing or broken script, an error or a run past the wait limit is a
    warning and lets the push through.
    """

    WAIT_LIMIT = 20.0

    def __init__(self, repo: Path, ranges: list[tuple[str, str]], trusted_scripts: Path | None) -> None:
        self.out: list[str] = []
        self.refused = False
        self.error: str | None = None
        self.thread: threading.Thread | None = None
        script = (trusted_scripts / "arch-ratchet.py") if trusted_scripts else (repo / SCRIPTS / "arch-ratchet.py")
        try:
            if not script.is_file():
                if trusted_scripts:
                    self.error = "arch-ratchet.py is not installed; rerun scripts/install-git-hooks.sh"
                return
            spec = importlib.util.spec_from_file_location("cmux_next_arch_ratchet", script)
            module = importlib.util.module_from_spec(spec)
            sys.modules[spec.name] = module  # dataclasses resolve their module through sys.modules
            spec.loader.exec_module(module)
        except (Exception, SystemExit) as error:
            self.error = f"WARNING: arch-ratchet.py failed ({type(error).__name__}: {error}); not applied to this push"
            return

        def run() -> None:
            try:
                self.refused = bool(module.run_push(repo, ranges, out=self.out))
            except (Exception, SystemExit) as error:  # run_push fails open itself; this is the last guard
                self.error = f"WARNING: arch-ratchet.py failed ({type(error).__name__}: {error}); not applied"

        self.thread = threading.Thread(target=run, name="arch-ratchet", daemon=True)
        self.thread.start()

    def finish(self) -> bool:
        """Print its report; True when it refuses the push."""
        if self.thread is not None:
            self.thread.join(self.WAIT_LIMIT)
            if self.thread.is_alive():
                log(f"prepush-gate: WARNING: arch-ratchet.py ran past {self.WAIT_LIMIT:.0f}s; not applied to this push. "
                    "Tell the Performance Lead with this line.")
                return False
        if self.error:
            log(f"prepush-gate: {self.error}. Tell the Performance Lead with this line.")
        for text in self.out:
            print(text)
        return self.refused and self.error is None


# guardrails.py loads count-swift-code-lines.py (CI's lexer) from the installed copy: an old one counts
# source lines unlike CI's check-app-size.sh.
TRUSTED_COPIES = ("prepush-gate.py", "guardrails.py", "count-swift-code-lines.py", "arch-ratchet.py", "arch_counts.py",
                  "arch_rules/__init__.py", "arch_rules/layer_gate.py")


def stale_hook_warning(repo: Path, trusted_scripts: Path) -> None:
    """Warn when the installed checker copies differ from origin/feat-cmux-next's (a rebase never refreshes them)."""
    for ref in DEFAULT_BASE_REFS:
        if not rev_ok(repo, ref):
            continue
        stale = []
        # One `git cat-file --batch` for every copy (a `git show` each cost a process per push).
        batch = "".join(f"{ref}:{SCRIPTS}/{name}\n" for name in TRUSTED_COPIES).encode()
        out = subprocess.run(["git", "-C", str(repo), "cat-file", "--batch"], input=batch, capture_output=True).stdout
        i = 0
        for name in TRUSTED_COPIES:
            nl = out.find(b"\n", i)
            if nl < 0:
                break
            header = out[i:nl].split()
            i = nl + 1
            if len(header) < 3 or header[1] != b"blob":
                continue
            size = int(header[2])
            theirs = out[i:i + size]
            i += size + 1
            mine = trusted_scripts / name
            if not mine.is_file() or mine.read_bytes() != theirs:
                stale.append(name)
        if stale:
            log(f"prepush-gate: WARNING: this clone's installed hook copy of {', '.join(stale)} is not {ref}'s, so its "
                f"rules may be old: run scripts/install-git-hooks.sh from a checkout at {ref} (rebase and fetch do not).")
        return


def print_findings(found: list[tuple[str, list[str]]], header: str) -> None:
    print(header)
    for name, fresh in found:
        print(f"  {name}:")
        for record in fresh:
            for line in record.splitlines():
                print(f"    {line}")


HOW_TO_FIX = """\
Fix them before pushing (AGENTS.md, "Before every push"): background APIs instead of blocking calls,
typed errors instead of try!, TypeScale/Typography fonts, CmuxDialogSpec / CmuxDialogActionButton for
dialogs, translucent theme tints on glass. A reviewed escape comment (`// concurrency-allow: <why>`,
`// crash-allow: <why>`, `dialog-keys-exempt: <why>`, `// glass-opaque-allow: <why>`) is allowed only when the code is provably safe.
Never --no-verify: CI names every commit that adds a violation (step "Pushed commits add no violations")."""


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", default=None)
    parser.add_argument("--base")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--pre-push", action="store_true", help="read pre-push stdin (the hook)")
    parser.add_argument("--trusted-scripts-dir", help="installed reviewed checker snapshot (required with --pre-push)")
    parser.add_argument("--commits", help="CI: check each non-merge commit of RANGE against its first parent")
    parser.add_argument("--only", help="comma list of layers: scanners,ast-grep,swiftformat,swiftlint,reserved,conflicts,sidebar")
    parser.add_argument("--timings", action="store_true")
    parser.add_argument("--no-guardrails", action="store_true", help="skip guardrails.py and arch-ratchet.py (they never run on CI)")
    args = parser.parse_args(argv)
    repo = Path(args.repo or git(Path.cwd(), "rev-parse", "--show-toplevel").decode().strip())
    only = set(args.only.split(",")) if args.only else None
    started = time.monotonic()
    trusted_scripts = Path(args.trusted_scripts_dir).resolve() if args.trusted_scripts_dir else None
    if args.pre_push and (trusted_scripts is None or not trusted_scripts.is_dir()):
        raise SystemExit("prepush-gate: --pre-push requires the installed --trusted-scripts-dir snapshot")

    if args.commits and only == {"sidebar"}:
        # The sidebar sweep: one pass over the range (per commit already: each commit is judged on its own).
        tip = git(repo, "rev-parse", args.commits.split("..")[-1] or "HEAD").decode().strip()
        base = args.commits.split("..")[0]
        fresh = sidebar_owner(repo, base, tip)
        if fresh:
            print_findings([(SIDEBAR_CHECK, fresh)], "prepush-gate: sidebar commits without the owner's record:")
            print(f"::error title=Sidebar look owner::{len(fresh)} commit(s) change the sidebar's drawing code without "
                  "a Sidebar-Look: trailer or an entry in plans/cmux-next/sidebar-owner.md")
        print(f"prepush-gate: sidebar sweep {base[:11]}..{tip[:11]}, {len(fresh)} finding(s) ({time.monotonic() - started:.1f}s)")
        return 1 if fresh else 0

    if args.commits:
        commits = git(repo, "rev-list", "--reverse", "--no-merges", args.commits).decode().split()
        bad = 0
        for sha in commits:
            parent = f"{sha}^"
            if not rev_ok(repo, parent):
                continue
            # The owner's log is read at the tip of the range: a later commit may log an earlier one.
            found = gate(repo, parent, sha, only, args.timings, trusted_scripts, ack_rev=commits[-1])
            if found:
                bad += 1
                subject = git(repo, "log", "-1", "--format=%h %an: %s", sha).decode().strip()
                print_findings(found, f"commit {subject} adds violations:")
                for name, fresh in found:
                    print(f"::error title=commit {sha[:11]} adds violations::{name}: {len(fresh)} new finding(s)")
        print(f"prepush-gate: {len(commits)} commit(s) checked, {bad} add violations "
              f"({time.monotonic() - started:.1f}s)")
        return 1 if bad else 0

    if args.pre_push:
        ranges = pushed_ranges(repo, sys.stdin.read().splitlines())
    else:
        ranges = [(args.base or default_base(repo, args.head), args.head)]
    # Local only: CI runs this script too (--commits, and --base/--head on pull requests), and must gain no gate.
    local_only = not args.no_guardrails and not os.environ.get("GITHUB_ACTIONS") and only is None
    arch = ArchRatchet(repo, ranges, trusted_scripts) if local_only else None
    found_any = []
    for base, head in ranges:
        found_any += gate(repo, base, head, only, args.timings, trusted_scripts)
    if args.pre_push and trusted_scripts:
        stale_hook_warning(repo, trusted_scripts)
    guarded = False
    if local_only:
        t0 = time.monotonic()
        guarded = guardrails(repo, ranges, trusted_scripts)
        if args.timings:
            log(f"  {time.monotonic() - t0:5.2f}s  guardrails")
        t0 = time.monotonic()
        guarded = arch.finish() or guarded
        if args.timings:
            log(f"  {time.monotonic() - t0:5.2f}s  arch ratchet (the wait left; it ran next to the scanners)")
    elapsed = time.monotonic() - started
    if not found_any:
        if guarded:
            print(f"prepush-gate: push refused by the guardrails or the arch ratchet ({elapsed:.1f}s)")
            return 1
        print(f"prepush-gate: no new violations ({elapsed:.1f}s)")
        return 0
    skip = os.environ.get("CMUX_NEXT_CHECKS_SKIP_REASON", "").strip()
    print_findings(found_any, "prepush-gate: this push adds violations:")
    if skip and any(name == CONFLICT_CHECK for name, _ in found_any):
        print(f"prepush-gate: CMUX_NEXT_CHECKS_SKIP_REASON does not skip {CONFLICT_CHECK}: finish the merge "
              "(keep one side of each hunk), then push.")
    elif skip and any(name == SIDEBAR_CHECK for name, _ in found_any):
        print(f"prepush-gate: CMUX_NEXT_CHECKS_SKIP_REASON does not skip {SIDEBAR_CHECK}. Amend the commit with a "
              "`Sidebar-Look:` trailer (and the note for a visual change); the sidebar owner keeps the look.")
    elif skip and any(name == RESERVED_CHECK for name, _ in found_any):
        print(f"prepush-gate: CMUX_NEXT_CHECKS_SKIP_REASON does not skip {RESERVED_CHECK}. Changing a Ghostty-default "
              "shortcut needs the user's explicit OK, quoted in a `Ghostty-defaults-OK: <the user's words>` commit trailer.")
    elif skip:
        print(f"prepush-gate: SKIPPED by CMUX_NEXT_CHECKS_SKIP_REASON={skip!r}. Say so in your report; "
              "CI still names the commit.")
        if guarded:
            print("prepush-gate: push refused by the guardrails or the arch ratchet (CMUX_NEXT_CHECKS_SKIP_REASON "
                  "does not skip them)")
            return 1
        return 0
    print(HOW_TO_FIX)
    print(f"prepush-gate: push refused ({elapsed:.1f}s)")
    return 1


if __name__ == "__main__":
    sys.exit(main())
