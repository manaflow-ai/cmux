#!/usr/bin/env python3
"""cmux-next pre-push gate: refuse a push that adds a static-check violation.

Runs, in seconds and with no build, the static checks of the "cmux-next checks" CI job
(.github/workflows/cmux-next.yml, job `checks`) plus pinned syntax tools, and fails only on what
the pushed commits ADD. Base debt never blocks a push.

How: the files the push changes are written into two small trees, one at the base and one at the
head, next to the check scripts (from the head) and their baselines (from each side). Every check
runs on both trees; a finding is new when the head has it and the base does not. A finding is keyed
by file, rule and the text of its source line, not its line number, so moving code is not new.

Layers (each one only on files the push changes under Packages/macOS/CmuxNext, cmux-tui, webviews):
  scanners     the CI job's line scanners: concurrency, crash safety, dialog key hints, type scale,
               motion, scrollbars, state roots, process scan, Swift CLI, closed history, test
               notification centers, string tables, module resources, capability text, browser
               chrome icons
  ast-grep     scripts/cmux-next/lint/ast-grep-rules: try!, blocking calls, raw font sizes, system
               dialogs (tree-sitter, so comments, strings and `case .alert` never match)
  swiftformat  --lint with scripts/cmux-next/lint/swiftformat.conf
  swiftlint    swift-syntax rules only (scripts/cmux-next/lint/swiftlint.yml), no SourceKit
Tool versions are pinned in scripts/cmux-next/lint-tools.lock and downloaded once (sha256 checked)
to $CMUX_LINT_TOOLS_DIR (default ~/Library/Caches/cmux-lint-tools, ~/.cache/cmux-lint-tools on Linux).

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
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
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
)

# Reviewed escapes the CI scanners honor, per ast-grep rule (same line or the comment block above).
ESCAPES = {
    "no-try-bang": re.compile(r"//\s*crash-allow:\s*\S"),
    "no-main-thread-block": re.compile(r"//\s*concurrency-allow:\s*\S"),
    "no-system-dialog": re.compile(r"dialog-keys-exempt:\s*\S"),
}
COMMENT_LINE = re.compile(r"^\s*(//|\*|/\*)")
LOCATION = re.compile(r"(?P<path>[\w.+@/-]+\.(?:swift|rs|ts|tsx|py|sh|json|xcstrings|md)):(?P<line>\d+)(?::\d+)?")
NUMBER = re.compile(r"\d+")
# Lines a scanner prints that are not findings: summaries, backlogs and warning-tier annotations.
INFO = re.compile(r"^(needs_review \(machine translated\)|\d+ tables, \d+ keys|::warning|.*ratchet debt)")
# A check that crashed instead of judging (both sides crash alike, so the diff alone would hide it).
BROKEN = re.compile(r"Traceback \(most recent call last\)|No such file or directory|command not found|SyntaxError")
# The warning tiers CI gives the ratchets (cmux-next.yml, checks job).
CI_ENV = {"L10N_STYLE_WARN_MAX": "100", "SCROLLBARS_WARN_MAX": "10", "GODFILES_WARN_SLACK": "20"}


def log(message: str) -> None:
    print(message, file=sys.stderr)


def git(repo: Path, *args: str, check: bool = True, data: bytes | None = None) -> bytes:
    # Request bytes go through a file, not a pipe: a big `cat-file --batch` answer fills the
    # stdout pipe while the request is still being written.
    with tempfile.TemporaryFile() as stdin:
        if data is not None:
            stdin.write(data)
            stdin.seek(0)
        result = subprocess.run(["git", "-C", str(repo), *args], stdin=stdin, capture_output=True)
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
    return sorted(n for n in names.split("\0") if n and n.startswith(SCOPES + ("Packages/Shared/",)))


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
    request = "".join(f"{files[p]}:{p}\n" for p in paths).encode()
    out = git(repo, "cat-file", "--batch", data=request)
    cursor = 0
    for path in paths:
        header_end = out.index(b"\n", cursor)
        header = out[cursor:header_end].split()
        cursor = header_end + 1
        if len(header) < 3 or header[1] != b"blob":
            continue  # missing at this rev (added or deleted file)
        size = int(header[2])
        target = dest / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(out[cursor:cursor + size])
        if path.endswith(".sh"):
            target.chmod(0o755)
        cursor += size + 1
    (dest / PKG / "Sources").mkdir(parents=True, exist_ok=True)
    (dest / PKG / "Tests").mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "init", "-q", str(dest)], check=True)
    subprocess.run(["git", "-C", str(dest), "add", "-A"], check=True, capture_output=True)


def ls_tree(repo: Path, rev: str, prefix: str) -> list[str]:
    out = git(repo, "ls-tree", "-r", "-z", "--name-only", rev, "--", prefix).decode()
    return [p for p in out.split("\0") if p]


def build_trees(repo: Path, base: str, head: str, changed: list[str], work: Path) -> tuple[Path, Path]:
    # The check scripts and their data sit at the top of scripts/cmux-next (plus lint/); its test,
    # release and harness subfolders are not read by any check and would only slow the copy.
    scripts = [p for p in ls_tree(repo, head, SCRIPTS + "/")
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

def gate(repo: Path, base: str, head: str, only: set[str] | None, timings: bool) -> list[tuple[str, list[str]]]:
    """[(check, new findings)] that head adds over base."""
    changed = changed_files(repo, base, head)
    if not changed:
        return []
    swift = [p for p in changed if p.startswith(SWIFT_SCOPE) and p.endswith(".swift")]
    sources = [p for p in swift if p.startswith(PKG + "/Sources/")]
    started = time.monotonic()
    found: list[tuple[str, list[str]]] = []
    with tempfile.TemporaryDirectory(prefix="cmux-prepush-") as tmp:
        base_tree, head_tree = build_trees(repo, base, head, changed, Path(tmp))
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
dialogs. A reviewed escape comment (`// concurrency-allow: <why>`, `// crash-allow: <why>`,
`dialog-keys-exempt: <why>`) is allowed only when the code is provably safe.
Never --no-verify: CI names every commit that adds a violation (step "Pushed commits add no violations")."""


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", default=None)
    parser.add_argument("--base")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--pre-push", action="store_true", help="read pre-push stdin (the hook)")
    parser.add_argument("--commits", help="CI: check each non-merge commit of RANGE against its first parent")
    parser.add_argument("--only", help="comma list of layers: scanners,ast-grep,swiftformat,swiftlint")
    parser.add_argument("--timings", action="store_true")
    args = parser.parse_args(argv)
    repo = Path(args.repo or git(Path.cwd(), "rev-parse", "--show-toplevel").decode().strip())
    only = set(args.only.split(",")) if args.only else None
    started = time.monotonic()

    if args.commits:
        commits = git(repo, "rev-list", "--reverse", "--no-merges", args.commits).decode().split()
        bad = 0
        for sha in commits:
            parent = f"{sha}^"
            if not rev_ok(repo, parent):
                continue
            found = gate(repo, parent, sha, only, args.timings)
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
    found_any = []
    for base, head in ranges:
        found_any += gate(repo, base, head, only, args.timings)
    elapsed = time.monotonic() - started
    if not found_any:
        print(f"prepush-gate: no new violations ({elapsed:.1f}s)")
        return 0
    skip = os.environ.get("CMUX_NEXT_CHECKS_SKIP_REASON", "").strip()
    print_findings(found_any, "prepush-gate: this push adds violations:")
    if skip:
        print(f"prepush-gate: SKIPPED by CMUX_NEXT_CHECKS_SKIP_REASON={skip!r}. Say so in your report; "
              "CI still names the commit.")
        return 0
    print(HOW_TO_FIX)
    print(f"prepush-gate: push refused ({elapsed:.1f}s)")
    return 1


if __name__ == "__main__":
    sys.exit(main())
