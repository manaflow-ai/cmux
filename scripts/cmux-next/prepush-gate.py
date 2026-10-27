#!/usr/bin/env python3
"""cmux-next pre-push gate: refuse a push that adds a static-check violation.

Runs, in seconds and with no build, the static checks of the "cmux-next checks" CI job
(.github/workflows/cmux-next.yml, job `checks`) plus pinned syntax tools, and fails only on what
the pushed commits ADD. Base debt never blocks a push.

Which commits are the push's own (push_range.py, shared with guardrails.py, the arch ratchet and the web lint,
so all of them judge the same range): the commits of each pushed head that none of its remote head, its
remote-tracking ref, this clone's origin/feat-cmux-next and the remote's HEAD reaches. Their boundary is the
base: the remote head for a second push (every new commit is judged, nothing pushed before), where HEAD meets
origin/feat-cmux-next for a new branch or a rebase onto it (the upstream commits the rebase brought in are not
judged; the rebased commits are). A branch that merged origin/feat-cmux-next in is judged over the upstream it
merged, less what its old remote head already had over the upstream it started from (gate_own), so upstream's
changes are never the push's and an upstream removal never pays for the branch's debt. With none of those refs
in the clone, or a shallow clone cut below the pushed commits, every ref of the remote bounds the walk; when even
that gives no boundary the push is refused with what to fetch. The gate prints, per pushed head, the base it
chose and how many commits are its own.

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
  swiftformat  --lint with scripts/cmux-next/lint/swiftformat.conf; local only: the pre-push hook and a plain
               local run, never --base/--head, --commits or GitHub Actions (no new CI gate, lead 2026-10-27)
  swiftlint    swift-syntax rules only (scripts/cmux-next/lint/swiftlint.yml), no SourceKit
Tool versions are pinned in scripts/cmux-next/lint-tools.lock and downloaded once (sha256 checked)
to $CMUX_LINT_TOOLS_DIR (default ~/Library/Caches/cmux-lint-tools, ~/.cache/cmux-lint-tools on Linux).

Also on every push, whatever it changes: "Ghostty-default keys" (check-ghostty-reserved-keys.py): the
exported default keymap keeps Ghostty's split keys (schemas/keybindings/ghostty-reserved-keys.json),
and the push removes no reserved entry. CMUX_NEXT_CHECKS_SKIP_REASON does not skip it; only a
`Ghostty-defaults-OK: <the user's words>` trailer on a pushed commit does (Lawrence 2026-10-20).
Also on every push: "Sidebar look owner" (plans/cmux-next/sidebar-owner.md): a commit that changes the
sidebar package's code (CmuxNextSidebar/, not its strings, resources or mock) carries a `Sidebar-Look: <the user's words, or "no visual
change">` trailer, and a visual change also edits plans/cmux-next/sidebar-owner.md in the same commit.
233 sidebar commits in four days with no owner undid each other (Lawrence 2026-10-23: "why were there so
many changes to sidebar?"). CMUX_NEXT_CHECKS_SKIP_REASON does not skip it. A commit the owner logged in
that note (its 11-character sha) passes. CI also sweeps every commit since the check landed
(`--only sidebar --commits`), so a push from an old hook copy or a cancelled CI run is still caught.
Also on every push, in any file: "Merge conflict markers": a file the push adds both a `<<<<<<< ` and
a `>>>>>>> ` line to (c779988d57d, 2026-10-22, broke CmuxNextAppTests). Nothing skips it.
Also on every push: "Leo's bans" (check-leo-bans.py): the UI font stays Inter, bundled, with its
calculated tracking (schemas/type-scale/leo-bans.json), and no webviews stylesheet names the system
font. It is not skippable either; only a `Leo-order: <Leo's words>` trailer changes the pin.

Also on every local run (the hook and a plain run; never --commits, never under GitHub Actions, so CI
gains no gate; Lawrence 2026-10-23): "Guardrails" (guardrails.py, plans/cmux-next/codebase-health.md):
refuses NEW unjustified @unchecked Sendable / nonisolated(unsafe) (the crash ratchet's class and escape, which
its per-module count cannot see before a push), DispatchQueue.main.async, ObservableObject/@Published, store
references in list rows, generic classes with an implicit deinit, waiting action binds, detached tasks without a
priority and bench hooks in shipped builds, in lines the push adds, and CmuxNextApp composition-root growth beyond
its wiring budget or a new App file that is not a move (`app-size`, a net count) and a new type that is not a move
in an existing App file or a moved one (`app-type`); sleeps and assumeIsolated are the scanners' rules above
(check-concurrency.sh, crash_ratchet.py), never repeated here. Warns on CmuxNextApp source growth, `// perf-hot:`
functions and OWNERS.md areas. Skip one push with
CMUX_GUARDRAILS_SKIP_REASON="<rule>[,<rule>]: <why>" (it skips only the named rules); the guardrails get the
gate's own ranges (above), so lines a push only brings in from origin/feat-cmux-next (a merge or rebase onto
it) never count; --no-guardrails turns it off for a manual run.
The guardrails include the arch ratchet (guardrails.py runs arch-ratchet.py; plans/cmux-next/arch-ratchet.json):
it refuses a push that raises the total of an architecture count (layer edges, stateful singletons, global
mutable statics, assumeIsolated outside seam adapters, app broadcast names, observer sites; arch_counts.py
defines them), counting only the files the push changes (a move between packages passes), or that raises the
json's own totals; its rule modules (arch_rules/, the layer gate) refuse what they find. guardrails' ratchet
starts on a thread before the scanners, so a push pays what is left of it at the guardrails (its cost is the
Swift files it reads and analyzes; --timings prints the wait). Its one escape is a dated exception in
arch-ratchet.json; --no-guardrails turns it off for a manual run; it fails open.

Not here (they stay on CI and the fleet): generated-file freshness (gen-*.py --check), god files,
the app size cap, script tests, Swift and Rust builds and tests.

  scripts/cmux-next/prepush-gate.py                  # what HEAD adds over origin/feat-cmux-next
  scripts/cmux-next/prepush-gate.py --base A --head B  # exactly what B adds over A
  scripts/cmux-next/prepush-gate.py --pre-push       # the hook: reads pre-push stdin
  scripts/cmux-next/prepush-gate.py --commits A..B   # CI: each commit against its parent, named
Escape hatch for one push: CMUX_NEXT_CHECKS_SKIP_REASON="<check> fails in files this push does not
touch (base <sha>)". The reason is printed; say it in your report.
"""
from __future__ import annotations

import argparse
import collections
import concurrent.futures
import fcntl
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
import time
import urllib.request
import zipfile
from pathlib import Path

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
    ("No raw spawns in the daemon (cmux_process, reviews of pl-holder-11)",
     ["python3", "-I", "{s}/check-no-raw-spawn.py", "{root}"], ("cmux-tui/", "scripts/cmux-next/raw-spawn-baseline.tsv")),
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
# The sidebar package's code, not only Views/: a702 (9a2fceefbbb, 2026-10-25) changed the pinned section from tiles
# to rows in Sections/ and the gate never asked. Strings and resources (copy, catalogs) and the mock are left out.
SIDEBAR_CODE = "Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/"
SIDEBAR_EXEMPT = ("Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/Resources/",
                  "Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/Mock/",
                  "Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/Strings")
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
# A reviewed crash allowlist or baseline raise (lead 2026-10-24: the hook runs the INSTALLED crash data, so a
# reviewed entry, PL-blocking's Debug trap, could not pass it): a commit's `Crash-allow-OK: <reviewer or review id>`
# trailer lets the hook read that commit's own additions to crash-allowlist.json (entries added or with a higher
# count) and crash-safety-baseline.json (rows raised), and nothing else; CI names each commit that adds an allowlist
# entry without one (CRASH_ALLOW_CHECK).
CRASH_ALLOWLIST = SCRIPTS + "/crash-allowlist.json"
CRASH_BASELINE = SCRIPTS + "/crash-safety-baseline.json"
CRASH_OK = re.compile(r"^Crash-allow-OK:[ \t]*(\S.*)$", re.MULTILINE)
CRASH_ALLOW_CHECK = "Crash allowlist review (Crash-allow-OK trailer)"
FREEZE_CHECK = "Coordinator path freeze (WINDOW FREEZE lines)"
# The coordinator's WINDOW (`FREEZE: <path prefix> token=<token>` lines; a `# LIFTED ...` line is not one). It
# exists on the coordinator's Mac only; elsewhere the check finds no file and checks nothing.
WINDOW_FILE = Path(os.environ.get("CMUX_WINDOW_FILE") or
                   Path.home() / "fun/cmuxterm-hq/.cmux-scratch/nx-coordinator/WINDOW")
FREEZE_LINE = re.compile(r"(?m)^FREEZE:[ \t]*(\S+)[ \t]+token=(\S+)")
FREEZE_TRAILER = re.compile(r"(?mi)^Freeze-Token:[ \t]*(\S+)[ \t]*$")

# The UI font is Inter with its calculated tracking (Leo 2026-10-21, ask-52da478628).
LEO_BANS_CHECK = "Leo's bans (Inter UI font and tracking, schemas/type-scale/leo-bans.json)"
LEO_BANS_SCRIPT = SCRIPTS + "/check-leo-bans.py"

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


PUSH_RANGE = "push_range.py"
PUSH_RANGE_MODULE = "cmux_next_push_range"


def load_push_range(repo: Path, trusted_scripts: Path | None):
    """push_range.py (the push's own range, shared with guardrails.py, arch-ratchet.py and the web lint): the
    installed reviewed copy for the hook, else this checkout's. The gate cannot judge a push without it: a
    missing copy exits with what to do (main() refuses the push)."""
    name = PUSH_RANGE_MODULE
    if name in sys.modules:
        return sys.modules[name]
    script = (trusted_scripts or repo / SCRIPTS) / PUSH_RANGE
    if not script.is_file():
        raise SystemExit(f"prepush-gate: {script} is missing; rerun scripts/install-git-hooks.sh")
    spec = importlib.util.spec_from_file_location(name, script)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # dataclasses resolve their module through sys.modules
    spec.loader.exec_module(module)
    return module


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
            if side == "head":
                taken = apply_reviewed_crash_data(repo, base, head, dest / SCRIPTS)
                if taken:
                    log("prepush-gate: Crash safety reads these reviewed raises of the pushed crash data:\n  "
                        + "\n  ".join(taken))
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


class Finding(str):
    """A finding as printed, plus KEY: its identity across runs (normalize(): file, rule and source text, no tree
    path, line or count numbers). gate_own matches a merge's runs by KEY: their trees and line numbers differ."""

    key: str

    def __new__(cls, text: str, key: str) -> "Finding":
        finding = super().__new__(cls, text)
        finding.key = key
        return finding


def new_records(base_out: str, head_out: str, base_tree: Path, head_tree: Path) -> list[str]:
    seen = collections.Counter(normalize(r, base_tree) for r in records(base_out))
    fresh = []
    for record in records(head_out):
        key = normalize(record, head_tree)
        if seen[key] > 0:
            seen[key] -= 1
        elif not re.search(r": ok\b|^All |passed|^ok\b", record) and not INFO.match(record):
            # Both spellings of the temporary tree (macOS: /var is /private/var).
            text = record.replace(str(head_tree.resolve()) + "/", "").replace(str(head_tree) + "/", "")
            fresh.append(Finding(text, key))
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


# A SwiftFormat --lint finding line (0.64): `/abs/path/A.swift:3:1: error: (consecutiveBlankLines) Remove ...`.
SWIFTFORMAT_FINDING = re.compile(r"^\S.*\.swift:\d+:\d+: (?:error|warning): \([A-Za-z]+\) ")


def swiftformat(binary: Path, config: Path, tree: Path, swift: list[str]) -> str:
    present = [p for p in swift if (tree / p).is_file()]
    if not present:
        return ""
    cache = tools_dir() / "swiftformat.cache"
    # No --quiet: with it SwiftFormat 0.64 prints only "Source input did not pass lint check." and no finding, so this
    # layer never refused anything. Its findings are `<path>:<line>:<col>: error: (<rule>) <message>` lines.
    _, out = run([str(binary), "--lint", "--config", str(config), "--cache", str(cache), *present], tree)
    return "\n".join(l for l in out.splitlines() if SWIFTFORMAT_FINDING.match(l))


def swiftlint(binary: Path, config: Path, tree: Path, swift: list[str]) -> str:
    present = [p for p in swift if (tree / p).is_file()]
    if not present:
        return ""
    _, out = run([str(binary), "lint", "--config", str(config), "--quiet", "--no-cache", "--reporter", "xcode",
                  *present], tree)
    return "\n".join(l for l in out.splitlines() if LOCATION.search(l))


# ---------------------------------------------------------------- gate

def _json_at(repo: Path, rev: str, path: str) -> dict:
    result = subprocess.run(["git", "-C", str(repo), "show", f"{rev}:{path}"], capture_output=True)
    try:
        value = json.loads(result.stdout) if result.returncode == 0 else {}
    except ValueError:
        value = {}
    return value if isinstance(value, dict) else {}


def _allow_entries(data: dict) -> dict[tuple, dict]:
    return {(e.get("path"), e.get("class")): e for e in data.get("allow") or [] if isinstance(e, dict)}


def _rows(data: object, prefix: tuple = ()) -> dict[tuple, int]:
    """The baseline's leaves {(section, ..., module): hits}."""
    if isinstance(data, dict):
        out = {}
        for key, value in data.items():
            if not str(key).startswith("_"):
                out.update(_rows(value, prefix + (str(key),)))
        return out
    return {prefix: data} if isinstance(data, int) and not isinstance(data, bool) else {}


def crash_raises(repo: Path, base: str, head: str) -> list[tuple[str, str, str | None, dict, dict]]:
    """Per non-merge commit of BASE..HEAD that changes the crash data: (sha, subject, its Crash-allow-OK trailer or
    None, {allowlist key: entry added or raised}, {baseline row: value raised}), against the commit's own parent."""
    out = git(repo, "log", "--reverse", "--no-merges", "--format=%x1e%H%x1f%B", f"{base}..{head}", "--",
              CRASH_ALLOWLIST, CRASH_BASELINE, check=False).decode(errors="replace")
    found = []
    for record in out.split("\x1e")[1:]:
        sha, _, message = record.partition("\x1f")
        sha = sha.strip()
        if not re.fullmatch(r"[0-9a-f]{40}", sha):
            continue
        old, new = _allow_entries(_json_at(repo, sha + "^", CRASH_ALLOWLIST)), _allow_entries(_json_at(repo, sha, CRASH_ALLOWLIST))
        allow = {k: e for k, e in new.items() if k not in old or (e.get("count") or 0) > (old[k].get("count") or 0)}
        old_rows, new_rows = _rows(_json_at(repo, sha + "^", CRASH_BASELINE)), _rows(_json_at(repo, sha, CRASH_BASELINE))
        rows = {k: v for k, v in new_rows.items() if v > old_rows.get(k, 0)}
        if allow or rows:
            trailer = CRASH_OK.search(message)
            subject = message.strip().splitlines()[0] if message.strip() else ""
            found.append((sha, subject, trailer.group(1).strip() if trailer else None, allow, rows))
    return found


def apply_reviewed_crash_data(repo: Path, base: str, head: str, scripts_dir: Path) -> list[str]:
    """Write into SCRIPTS_DIR (the head tree's installed scripts) the crash data raises of the pushed commits that
    carry a Crash-allow-OK trailer, over the installed files; a raise without one stays out, so it is still refused.
    Returns what was taken, one line each, for the gate to print."""
    taken: list[str] = []
    allow_path, baseline_path = scripts_dir / Path(CRASH_ALLOWLIST).name, scripts_dir / Path(CRASH_BASELINE).name
    try:
        allow_data = json.loads(allow_path.read_text()) if allow_path.is_file() else {"banned": [], "allow": []}
        baseline = json.loads(baseline_path.read_text()) if baseline_path.is_file() else {}
    except (OSError, ValueError):
        return taken
    changed = False
    for sha, subject, trailer, allow, rows in crash_raises(repo, base, head):
        if trailer is None:
            continue
        entries = [e for e in allow_data.setdefault("allow", []) if isinstance(e, dict)]
        for key, entry in allow.items():
            entries = [e for e in entries if (e.get("path"), e.get("class")) != key] + [entry]
            taken.append(f"{sha[:11]} (Crash-allow-OK: {trailer[:60]}): allow {key[1]} in {key[0]} count {entry.get('count')}")
        allow_data["allow"] = entries
        for row, value in rows.items():
            node = baseline
            for part in row[:-1]:
                node = node.setdefault(part, {}) if isinstance(node, dict) else None
            if isinstance(node, dict) and value > (node.get(row[-1]) or 0):
                node[row[-1]] = value
                taken.append(f"{sha[:11]} (Crash-allow-OK: {trailer[:60]}): baseline {'.'.join(row)} -> {value}")
        changed = changed or bool(allow or rows)
    if changed:
        allow_path.write_text(json.dumps(allow_data, indent=1) + "\n")
        baseline_path.write_text(json.dumps(baseline, indent=1, sort_keys=True) + "\n")
    return taken


def crash_allow_unreviewed(repo: Path, base: str, head: str) -> list[str]:
    """Each commit of BASE..HEAD that adds or raises a crash allowlist entry without a Crash-allow-OK trailer."""
    return [f"{sha[:11]} {subject[:70]}: adds {', '.join(f'{k[1]} in {k[0]}' for k in list(allow)[:3])}"
            f"{f' and {len(allow) - 3} more' if len(allow) > 3 else ''} to {CRASH_ALLOWLIST} without a "
            "`Crash-allow-OK: <reviewer or review id>` trailer"
            for sha, subject, trailer, allow, _ in crash_raises(repo, base, head) if allow and trailer is None]


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


def leo_bans(repo: Path, base: str, head: str, trusted_scripts: Path | None = None) -> list[str]:
    """What head adds to Leo's bans (LEO_BANS_CHECK) over base: findings base does not have, and a
    pin change in base..head with no `Leo-order:` trailer."""
    trusted = trusted_scripts / Path(LEO_BANS_SCRIPT).name if trusted_scripts else None
    if trusted and trusted.is_file():
        script = trusted.read_bytes()
    else:
        result = subprocess.run(["git", "-C", str(repo), "show", f"{head}:{LEO_BANS_SCRIPT}"], capture_output=True)
        if result.returncode != 0:
            return []  # a commit older than this check
        script = result.stdout
    with tempfile.TemporaryDirectory(prefix="cmux-leo-bans-") as tmp:
        check = Path(tmp) / "check.py"
        check.write_bytes(script)

        def findings(*args: str) -> list[str]:
            code, out = run(["python3", "-I", str(check), "--repo", str(repo), *args], Path(tmp), timeout=600)
            if code == 124:
                return [f"check-leo-bans.py {' '.join(args)}: {out}"]
            return [line for line in out.splitlines() if line.strip() and not line.startswith("leo bans:")]

        base_lines = set(findings("--rev", base))
        return [line for line in findings("--rev", head, "--base", base) if line not in base_lines]


def conflict_markers(repo: Path, base: str, head: str) -> list[str]:
    """`file:line` of each conflict marker the push adds, in any file of the repository.

    2026-10-22: c779988d57d landed `<<<<<<< HEAD` in SidebarNowLineTests.swift and CmuxNextAppTests
    stopped compiling; no scanner reads a test file. A file counts only when the push adds both an
    opening and a closing marker to it, so a fixture that mentions one marker never matches.
    """
    # Fixed prefixes: with a user's diff.noprefix the `+++ b/` headers this parse reads would be missing. No
    # inter-hunk context: a user's diff.interHunkContext would put unchanged lines between the added ones.
    diff = git(repo, "diff", "-U0", "--inter-hunk-context=0", "--no-color", "--no-renames", "--no-ext-diff",
               "--src-prefix=a/", "--dst-prefix=b/", base, head).decode("utf-8", "replace")
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
        elif line.startswith(" ") and name:  # a context line, should one come, is a head line too
            number += 1
    return [f"{name}:{n}: {text}" for name, marks in sorted(found.items())
            if any(CONFLICT_OPEN.match(t) for _, t in marks) and any(CONFLICT_CLOSE.match(t) for _, t in marks)
            for n, text in marks]


def window_freezes(repo: Path, base: str, head: str, window: Path | None = None) -> list[str]:
    """Each pushed commit that changes a path a WINDOW FREEZE line holds without that line's token.

    2026-10-25 (Lawrence): "freeze for all" on cmux.xcodeproj/project.pbxproj; landq honored the FREEZE lines,
    a direct push did not. A commit passes with a `Freeze-Token: <token>` trailer equal to the line's token
    (a slot grant replaces `none` with a token; `none` never matches). No WINDOW file: nothing is checked.
    """
    try:
        text = (window or WINDOW_FILE).read_text()
    except OSError:
        return []
    freezes = FREEZE_LINE.findall(text)
    if not freezes:
        return []
    found: list[str] = []
    out = git(repo, "log", "--reverse", "--no-merges", "--name-only", "--format=%x1e%H%x1f%B%x1f",
              f"{base}..{head}", "--", check=False).decode(errors="replace")
    for record in out.split("\x1e")[1:]:
        sha, message, names = (record.split("\x1f") + ["", ""])[:3]
        files = [f for f in names.split("\n") if f]
        tokens = set(FREEZE_TRAILER.findall(message))
        for prefix, token in freezes:
            hit = sorted(f for f in files if f == prefix or f.startswith(prefix.rstrip("/") + "/"))
            if hit and (token.startswith("none") or token not in tokens):
                found.append(f"{sha[:11]} changes {hit[0]}, frozen in WINDOW (`FREEZE: {prefix} token={token}`). "
                             f"Ask the coordinator for a slot grant, then add `Freeze-Token: <its token>` to the commit.")
    return found


def sidebar_owner(repo: Path, base: str, head: str, ack_rev: str | None = None) -> list[str]:
    """Each pushed commit that changes the sidebar's drawing code without the owner's record.

    A commit touching the sidebar package's code (`SIDEBAR_CODE` but `SIDEBAR_EXEMPT`) needs a `Sidebar-Look:` trailer: the user's words that asked for the
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
        views = sorted(f for f in files if f.startswith(SIDEBAR_CODE) and not f.startswith(SIDEBAR_EXEMPT))
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
         trusted_scripts: Path | None = None, ack_rev: str | None = None,
         restrict: set[str] | None = None, swiftformat_layer: bool = False) -> list[tuple[str, list[str]]]:
    """[(check, new findings)] that head adds over base; the tree checks read only RESTRICT's files when given.

    SWIFTFORMAT_LAYER: run SwiftFormat (main() sets it for the local pre-push hook and a plain local run only), or
    when `--only` names swiftformat."""
    reserved: list[tuple[str, list[str]]] = []
    if only is None or "reserved" in only:
        fresh = reserved_keys(repo, base, head, trusted_scripts)
        reserved = [(RESERVED_CHECK, fresh)] if fresh else []
    if only is None or "leo-bans" in only:
        fresh = leo_bans(repo, base, head, trusted_scripts)
        reserved += [(LEO_BANS_CHECK, fresh)] if fresh else []
    if only is None or "conflicts" in only:
        markers = conflict_markers(repo, base, head)
        if markers:
            reserved.append((CONFLICT_CHECK, markers))
    if only is None or "sidebar" in only:
        owner = sidebar_owner(repo, base, head, ack_rev)
        if owner:
            reserved.append((SIDEBAR_CHECK, owner))
    if only is None or "freeze" in only:
        frozen = window_freezes(repo, base, head)
        if frozen:
            reserved.append((FREEZE_CHECK, frozen))
    if only is None or "crash-allow" in only:
        unreviewed = crash_allow_unreviewed(repo, base, head)
        if unreviewed:
            reserved.append((CRASH_ALLOW_CHECK, unreviewed))
    # The git-only checks above need no trees: a run of only those (CI's sidebar sweep) stops here.
    if only is not None and not only & {"scanners", "ast-grep", "swiftformat", "swiftlint"}:
        return reserved
    changed = changed_files(repo, base, head)
    if restrict is not None:
        changed = [p for p in changed if p in restrict]
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
        # Local only (lead 2026-10-27): CI and the merge-time gates (fast gates, car guards: --base/--head; pushes:
        # --commits) never refused a SwiftFormat finding, and must not start to (CLAUDE.md: no new CI gates).
        if swift and (swiftformat_layer if only is None else "swiftformat" in only):
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


COMPILE_REMOTE = re.compile(r"github\.com[:/]+manaflow-ai/cmux(\.git)?/?$")
COMPILE_REF = "refs/heads/feat-cmux-next"


def compile_ranges(repo: Path, pushed_lines: list[str], push_range=None,
                   remote: str | None = "origin") -> list[tuple[str, str]]:
    """The pushed ranges the compile trailer rule applies to: those that update manaflow-ai/cmux's feat-cmux-next (the
    hook passes the remote's URL in CMUX_PREPUSH_REMOTE_URL), as (base, head) of the push's own commits
    (PUSH_RANGE.pushed_ranges over REMOTE; PUSH_RANGE is the push_range.py next to this file when None; a merge's base
    is the merged upstream). A row whose own range cannot be told is left out: main() refuses the push for it. A side
    branch is where an agent pushes a commit to compile it (cmux-ci compile-check needs it pushed), so a side-branch
    push needs no trailer."""
    if not COMPILE_REMOTE.search(os.environ.get("CMUX_PREPUSH_REMOTE_URL", "")):
        return []
    lines = [line for line in pushed_lines if len(line.split()) == 4 and line.split()[2] == COMPILE_REF]
    if not lines:
        return []
    push_range = push_range or load_push_range(repo, Path(__file__).resolve().parent)
    ranges, _errors = push_range.pushed_ranges(repo, lines, remote)
    return [(own.base, own.head) for own in ranges]


def compile_trailer(repo: Path, ranges: list[tuple[str, str]], trusted_scripts: Path | None) -> bool:
    """The compile trailer rule (compile_trailer.py, lead 2026-10-24): a push that changes Swift names a passing compile
    job (`Compiled: <cmux-ci job id>`) of its Swift. Local only (like the guardrails), from the installed copy for the
    hook; any error or a controller that does not answer in 5 s lets the push through with a loud
    `!!! COMPILE TRAILER NOT CHECKED` line naming the reason. True: refused."""
    script = (trusted_scripts / "compile_trailer.py") if trusted_scripts else (repo / SCRIPTS / "compile_trailer.py")
    if not ranges or not script.is_file():
        return False
    try:
        spec = importlib.util.spec_from_file_location("cmux_next_compile_trailer", script)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        refused, lines = module.check(repo, ranges)
    except Exception as error:  # noqa: BLE001 - fail open: a bug here must not block every push
        log(f"!!! COMPILE TRAILER NOT CHECKED: compile_trailer.py failed ({type(error).__name__}: {error}). The push "
            "goes through UNCHECKED; the tip may not build. Say so in your report. !!!")
        return False
    for line in lines:
        log(line)
    return bool(refused)


def finding_key(record: str) -> str:
    """What gate_own matches a finding by: a scanner's normalized key, else (a git-only check) its text."""
    return getattr(record, "key", record)


def gate_own(repo: Path, own, only: set[str] | None, timings: bool,
             trusted_scripts: Path | None = None, swiftformat_layer: bool = False) -> list[tuple[str, list[str]]]:
    """[(check, findings)] the push's own range OWN (push_range.OwnRange) adds.

    gate() over own.base..own.head; for a merge (own.before), less what gate() finds over each range the push
    does not own (push_range.less): the old remote head's delta over the upstream it started from. Findings are
    matched by finding_key (a scanner's by file, rule and source text with no line or count numbers; a git-only
    check's by its text). Those runs read only the files the push's own range changes (a finding elsewhere
    cannot take one off), so a merge costs the branch's delta, never the files upstream changed. A scanner whose
    text depends on other files in its tree can word one finding differently in the two runs; it is then not
    taken off and refuses (fails closed). A record without a file location in a check that also printed located
    ones describes them (`check-crash-safety: 1 violation(s)`): it is kept only when one of that check's located
    findings is."""
    found = gate(repo, own.base, own.head, only, timings, trusted_scripts, swiftformat_layer=swiftformat_layer)
    if not own.before or not found:
        return found
    changed = set(changed_files(repo, own.base, own.head))
    before = [dict(gate(repo, b, a, only, timings, trusted_scripts, restrict=changed, swiftformat_layer=swiftformat_layer))
              for b, a in own.before]
    push_range = sys.modules[PUSH_RANGE_MODULE]
    kept = []
    for name, fresh in found:
        mine = push_range.less(fresh, [run.get(name, []) for run in before], key=finding_key)
        if any(LOCATION.search(r) for r in fresh) and not any(LOCATION.search(r) for r in mine):
            mine = []
        if mine:
            kept.append((name, mine))
    return kept


CHECKS_IN_USE = ".in-use"


def claim_trusted_scripts(link: Path):
    """(the checks copy LINK points at, an open handle that holds it in use until this process exits).

    install-git-hooks.sh removes a copy only when it can take an exclusive flock on the copy's .in-use, and
    renames it away first while holding that lock; this takes a shared one. A copy removed between resolving
    the link and taking the lock is seen (open fails, or the file has no link left) and the link resolved
    again: a link only ever moves to a newer copy. A copy without .in-use is from an install before the lock
    (handle None), as is a link that points at nothing (the caller refuses it).
    """
    target = link.resolve()
    while True:
        try:
            handle = open(target / CHECKS_IN_USE, "rb")
        except FileNotFoundError:
            again = link.resolve()
            if again == target:
                return target, None
            target = again
            continue
        fcntl.flock(handle, fcntl.LOCK_SH)
        if os.fstat(handle.fileno()).st_nlink > 0:
            return target, handle
        handle.close()
        target = link.resolve()


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


def start_guardrails(repo: Path, ranges: list, trusted_scripts: Path | None):
    """(module, ratchet, error): guardrails.py loaded, and its arch ratchet started on a thread at once.

    The ratchet runs next to the scanners, so the push pays what is left of it when the gate reaches the
    guardrails (its cost is the Swift files it reads and analyzes; guardrails.Ratchet). A load error is
    reported there (fail open).
    """
    try:
        module = load_guardrails(repo, trusted_scripts)
        if module is None:
            return None, None, ("guardrails.py is not installed; rerun scripts/install-git-hooks.sh"
                                if trusted_scripts else None)
        start = getattr(module, "start_ratchet", None)
        return module, (start(repo, ranges) if start is not None else None), None
    except (Exception, SystemExit) as error:  # SystemExit: guardrails.git() exits on a failed git call
        return None, None, (f"WARNING: guardrails.py failed ({type(error).__name__}: {error}); not applied to this "
                            "push. Tell the Performance Lead (PL-guardrails) with this line.")


def guardrails(repo: Path, ranges: list, started) -> bool:
    """Print the guardrail warnings and refusals (line rules and arch ratchet) for RANGES; True when they refuse.

    STARTED is start_guardrails()'s result. The rules are advisory debt checks in every agent's hook: a bug in
    one rule turns off only that rule (guardrails.check warns and runs the rest); a bug outside the rules (a
    failed load or git call, a parse edge) prints a warning and lets the push through instead of blocking
    every push with a traceback. RANGES are the gate's push_range.OwnRange values, so the guardrails judge the
    same own commits as the scanners: what a push only brings in from origin/feat-cmux-next (a merge of it, or a
    rebase onto it and a force push) never counts, because CI never runs these rules and that base can carry
    debt.
    """
    module, ratchet, error = started
    if error:
        log(f"prepush-gate: {error}")
        return False
    if module is None:
        return False
    try:
        return bool(module.run_push(repo, ranges, ratchet))
    except (Exception, SystemExit) as error:  # SystemExit: guardrails.git() exits on a failed git call
        log(f"prepush-gate: WARNING: guardrails.py failed ({type(error).__name__}: {error}); not applied to "
            "this push. Tell the Performance Lead (PL-guardrails) with this line.")
        return False


# The perf cron's unit tests (scripts/cmux-next/perf-cron.py) never run on CI (Lawrence 2026-10-23: no new CI tests;
# the owner runs them), so the push runs the fast file itself when it changes the cron or its tests. Local only,
# like the guardrails. The two slower files (test_perf_cron_io.py, 22 s; test_perf_cron_arch_report.py, 82 s:
# real git clones and subprocesses) are run by hand.
PERF_CRON_PATHS = ("scripts/cmux-next/perf-cron", "scripts/cmux-next/tests/test_perf_cron")
PERF_CRON_FILES = ("scripts/cmux-next/perf-cron.py", "scripts/cmux-next/perf-budgets.py", "scripts/cmux-next/perf-budgets.json",
                   "scripts/cmux-next/perf-profile-split.py", "scripts/cmux-next/tests/test_perf_cron.py",
                   "scripts/cmux-next/tests/fixtures", "scripts/perf-bench")
PERF_CRON_TIMEOUT = 60


def perf_cron_tests(repo: Path, ranges: list) -> bool:
    """Run test_perf_cron.py on each pushed head whose own changes touch the perf cron; True when a test fails.

    RANGES are push_range.OwnRange values: a path counts when it changes over the base and since the head of
    every range the push does not own (a merge of origin/feat-cmux-next that only brings in a cron change runs
    nothing). It runs the head's own files (git
    archive), not the checkout's. It fails open: a git error, a missing file at an older head, a broken Python or
    a run past PERF_CRON_TIMEOUT prints a warning and lets the push through."""
    refused = False
    for own in ranges:
        head = own.head
        try:
            # changed_files keeps only the app's source scopes; the cron is under scripts/.
            changed = [{p for p in git(repo, "diff", "--name-only", "--no-renames", "-z", base, head).decode().split("\0") if p}
                       for base in [own.base, *(a for _, a in own.before)]]
            if not any(p.startswith(PERF_CRON_PATHS) for p in set.intersection(*changed)):
                continue
            with tempfile.TemporaryDirectory(prefix="cmux-prepush-perf-cron-") as tmp:
                present = [p for p in PERF_CRON_FILES if git(repo, "ls-tree", "--name-only", head, "--", p, check=False).strip()]
                if "scripts/cmux-next/tests/test_perf_cron.py" not in present:
                    continue
                archive = git(repo, "archive", head, "--", *present)
                subprocess.run(["tar", "-x", "-C", tmp], input=archive, check=True, capture_output=True, timeout=60)
                done = subprocess.run([sys.executable, "-I", "-m", "unittest", "discover", "-s", "scripts/cmux-next/tests",
                                       "-p", "test_perf_cron.py"], cwd=tmp, capture_output=True, text=True,
                                      timeout=PERF_CRON_TIMEOUT)
        except (Exception, SystemExit) as error:  # SystemExit: git() exits on a failed git call
            log(f"prepush-gate: WARNING: the perf cron tests did not run ({type(error).__name__}: {error}); not applied "
                "to this push. Run python3 -I -m unittest discover -s scripts/cmux-next/tests -p 'test_perf_cron*.py'.")
            continue
        if done.returncode != 0:
            tail = "\n".join((done.stderr or done.stdout).splitlines()[-25:])
            log(f"prepush-gate: the perf cron tests fail at {head[:12]} (scripts/cmux-next/tests/test_perf_cron.py):\n{tail}")
            refused = True
    return refused


# guardrails.py loads count-swift-code-lines.py (CI's lexer) from the installed copy: an old one counts
# source lines unlike CI's check-app-size.sh. push_range.py decides which commits are the push's own, for the
# gate, guardrails.py and arch-ratchet.py alike. The arch_rules/*.py modules are compared as a folder
# (_stale_rules), so a rule module added upstream needs no entry here.
TRUSTED_COPIES = ("prepush-gate.py", "guardrails.py", "count-swift-code-lines.py", "arch-ratchet.py", "arch_counts.py",
                  "push_range.py", "git_batch.py")
RULES_SUBDIR = "arch_rules"


def _blob_id(data: bytes, hex_len: int) -> str:
    """The git object id of a blob with DATA (sha1, or sha256 in a sha256 repository)."""
    digest = hashlib.sha256 if hex_len == 64 else hashlib.sha1
    return digest(b"blob %d\0" % len(data) + data).hexdigest()


def _stale_rules(tree: bytes, hex_len: int, installed: Path) -> list[str]:
    """The arch_rules/*.py files whose installed copy differs from TREE's (a raw git tree object)."""
    want: dict[str, str] = {}
    raw_len = hex_len // 2
    i = 0
    while i < len(tree):
        nul = tree.find(b"\0", i)
        if nul < 0:
            break
        mode, _, name = tree[i:nul].partition(b" ")
        oid = tree[nul + 1:nul + 1 + raw_len].hex()
        i = nul + 1 + raw_len
        if mode.startswith(b"100") and name.endswith(b".py"):
            want[name.decode(errors="replace")] = oid
    have = {p.name: p for p in installed.glob("*.py")} if installed.is_dir() else {}
    stale = [f"{RULES_SUBDIR}/{n}" for n, oid in sorted(want.items())
             if n not in have or _blob_id(have[n].read_bytes(), hex_len) != oid]
    stale += [f"{RULES_SUBDIR}/{n} (removed upstream)" for n in sorted(set(have) - set(want))]
    return stale


def stale_hook_warning(repo: Path, trusted_scripts: Path) -> None:
    """Warn when the installed checker copies differ from origin/feat-cmux-next's (a rebase never refreshes them).

    The copies: TRUSTED_COPIES and every arch_rules/*.py module (a rule the install missed never runs).
    """
    for ref in DEFAULT_BASE_REFS:
        if not rev_ok(repo, ref):
            continue
        stale = []
        # One `git cat-file --batch` for every copy and the arch_rules tree (a `git show` each cost a process).
        names = [f"{SCRIPTS}/{name}" for name in TRUSTED_COPIES] + [f"{SCRIPTS}/{RULES_SUBDIR}"]
        batch = "".join(f"{ref}:{name}\n" for name in names).encode()
        out = git_batch.run(repo, ["cat-file", "--batch"], batch).stdout
        i = 0
        for index, name in enumerate(names):
            nl = out.find(b"\n", i)
            if nl < 0:
                break
            header = out[i:nl].split()
            i = nl + 1
            if len(header) < 3 or header[1] not in (b"blob", b"tree"):
                continue
            size = int(header[2])
            theirs = out[i:i + size]
            i += size + 1
            if header[1] == b"tree":
                stale += _stale_rules(theirs, len(header[0]), trusted_scripts / RULES_SUBDIR)
                continue
            mine = trusted_scripts / TRUSTED_COPIES[index]
            if not mine.is_file() or mine.read_bytes() != theirs:
                stale.append(TRUSTED_COPIES[index])
        # The pre-push hook itself (it passes the remote's URL to the compile trailer rule, 7ea27860336): the
        # installed hook sits next to the checks folder.
        hook = trusted_scripts.parent / "pre-push"
        tracked = subprocess.run(["git", "-C", str(repo), "show", f"{ref}:scripts/git-hooks/pre-push"], capture_output=True)
        if tracked.returncode == 0 and hook.is_file() and hook.read_bytes() != tracked.stdout:
            stale.append("pre-push (the hook)")
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
    parser.add_argument("--remote", default="origin",
                        help="the pushed remote's name (the hook's first argument; a URL for a push to a URL)")
    parser.add_argument("--commits", help="CI: check each non-merge commit of RANGE against its first parent")
    parser.add_argument("--only", help="comma list of layers: scanners,ast-grep,swiftformat,swiftlint,reserved,leo-bans,conflicts,"
                                       "sidebar,crash-allow,freeze")
    parser.add_argument("--timings", action="store_true")
    parser.add_argument("--no-guardrails", action="store_true", help="skip guardrails.py and its arch ratchet (they never run on CI)")
    args = parser.parse_args(argv)
    repo = Path(args.repo or git(Path.cwd(), "rev-parse", "--show-toplevel").decode().strip())
    only = set(args.only.split(",")) if args.only else None
    started = time.monotonic()
    # The handle keeps the installed checks copy this run reads in use until main returns (claim_trusted_scripts).
    trusted_scripts, _in_use = (claim_trusted_scripts(Path(args.trusted_scripts_dir)) if args.trusted_scripts_dir
                                else (None, None))
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

    push_range = load_push_range(repo, trusted_scripts)
    pushed_lines: list[str] = []
    try:
        if args.pre_push:
            pushed_lines = sys.stdin.read().splitlines()
            ranges, errors = push_range.pushed_ranges(repo, pushed_lines, args.remote)
        else:
            ranges, errors = [push_range.given_range(repo, args.base, args.head) if args.base
                              else push_range.own_range(repo, args.head)], []
    except ValueError as error:  # a git call failed (a commit gone between two reads)
        ranges, errors = [], [str(error)]
    if errors:
        # Refused on purpose: with no bound on the pushed commits the gate cannot tell what the push adds.
        for error in errors:
            print(f"prepush-gate: cannot tell which commits are this push's own: {error}")
        print("prepush-gate: push refused; nothing was checked. Fix the clone as said above and push again.")
        return 1
    for own in ranges:
        log(f"prepush-gate: judging {own.describe()}")
    # Local only: CI runs this script too (--commits, and --base/--head on pull requests), and must gain no gate.
    local_only = not args.no_guardrails and not os.environ.get("GITHUB_ACTIONS") and only is None
    started_guardrails = start_guardrails(repo, ranges, trusted_scripts) if local_only else None
    # SwiftFormat only for the pre-push hook and a plain local run (no --base: CI's pull request run, the fast gates
    # and the car guards name one), never on GitHub Actions.
    swiftformat_layer = not args.base and not os.environ.get("GITHUB_ACTIONS")
    found_any = []
    for own in ranges:
        found_any += gate_own(repo, own, only, args.timings, trusted_scripts, swiftformat_layer)
    if args.pre_push and trusted_scripts:
        stale_hook_warning(repo, trusted_scripts)
    guarded = False
    if local_only:
        t0 = time.monotonic()
        guarded = guardrails(repo, ranges, started_guardrails)
        if args.timings:
            ratchet = started_guardrails[1]
            waited = getattr(ratchet, "waited", None)
            log(f"  {time.monotonic() - t0:5.2f}s  guardrails (line rules, and the arch ratchet's wait left: it "
                "ran next to the scanners)"
                + (f"; of it {waited:.2f}s waiting for the arch ratchet" if isinstance(waited, float) else ""))
        t0 = time.monotonic()
        guarded = perf_cron_tests(repo, ranges) or guarded
        if args.timings:
            log(f"  {time.monotonic() - t0:5.2f}s  perf cron tests")
        t0 = time.monotonic()
        guarded = compile_trailer(repo, compile_ranges(repo, pushed_lines, push_range, args.remote), trusted_scripts) or guarded
        if args.timings:
            log(f"  {time.monotonic() - t0:5.2f}s  compile trailer")
    elapsed = time.monotonic() - started
    if not found_any:
        if guarded:
            print(f"prepush-gate: push refused by the guardrails, the perf cron tests or the compile trailer ({elapsed:.1f}s)")
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
    elif skip and any(name == LEO_BANS_CHECK for name, _ in found_any):
        print(f"prepush-gate: CMUX_NEXT_CHECKS_SKIP_REASON does not skip {LEO_BANS_CHECK}. The UI font and its "
              "tracking change only by Leo's order, quoted in a `Leo-order: <Leo's words>` commit trailer.")
    elif skip:
        print(f"prepush-gate: SKIPPED by CMUX_NEXT_CHECKS_SKIP_REASON={skip!r}. Say so in your report; "
              "CI still names the commit.")
        if guarded:
            print("prepush-gate: push refused by the guardrails (CMUX_NEXT_CHECKS_SKIP_REASON does not skip them)")
            return 1
        return 0
    print(HOW_TO_FIX)
    print(f"prepush-gate: push refused ({elapsed:.1f}s)")
    return 1


if __name__ == "__main__":
    sys.exit(main())
