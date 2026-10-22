#!/usr/bin/env python3
"""Run every checker in leo-bans.json: the UI patterns Leo killed must not come back.

    leo_bans.py check [--root DIR] [--ref REF] [--base REF] [--only ID[,ID]] [--skip-kind KIND] [--json FILE]
    leo_bans.py list
    leo_bans.py update-baselines [--root DIR]

Each ban in leo-bans.json names the pattern, Leo's words, the date, the pull request that fixed it
and its checkers (README.md beside this file). `check` runs every checker on the tree at --root and
prints one `::error` per broken ban, naming the ban, the quote and the fix PR.

With --base (a pull request's base, a push's previous tip) the verdict is the change's own: a
finding the base does not have fails; a finding the base has too is a warning (a base red, fixed
in its own PR). A failing bun-test or command checker reruns on a detached worktree of the base.
Without --base a finding fails unless the checker is `pending` (its fix PR is still open), which
is a warning.

Two ratchets run beside the bans (leo-bans.json `escape_rulings` and `default_on_tunables`): every
lint escape comment (`text-focus-allow:`, `theme-fixed:`, ...) carries `ruling: <link>` on its
line, and every Debug toggle defaults off unless tunables-default-on.txt lists it. Their baselines
hold today's exceptions and may only shrink.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
BANS_FILE = HERE / "leo-bans.json"
REL = "scripts/cmux-next/leo-bans"
KINDS = ("grep", "tunable-default", "bun-test", "command", "python")
TUNABLE_DEFAULT = re.compile(r'default:\s*([^,\n]+?)\s*,\s*code:\s*"([^"]+)"')
BOOL_TUNABLE = re.compile(r'default:\s*(true|false)\s*,\s*code:\s*"([^"]+)"')


def glob_regex(pattern: str) -> re.Pattern[str]:
    """A path glob as a regex: `**/` is any number of directories, `*` stays inside one."""
    out, i = [], 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif pattern.startswith("**", i):
            out.append(".*")
            i += 2
        elif pattern[i] == "*":
            out.append("[^/]*")
            i += 1
        elif pattern[i] == "?":
            out.append("[^/]")
            i += 1
        elif pattern[i] == "{":
            end = pattern.index("}", i)
            out.append("(?:" + "|".join(re.escape(p) for p in pattern[i + 1:end].split(",")) + ")")
            i = end + 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    return re.compile("".join(out) + r"\Z")


def matches(path: str, globs: list[str]) -> bool:
    return any(glob_regex(g).match(path) for g in globs)


class Tree:
    """A checkout (a directory) or a commit (a git ref read through git)."""

    def __init__(self, root: Path, ref: str | None = None):
        self.root, self.ref = root, ref
        self._files: list[str] | None = None
        self._cache: dict[str, str | None] = {}

    def label(self) -> str:
        return self.ref or str(self.root)

    def files(self) -> list[str]:
        if self._files is None:
            if self.ref:
                cmd = ["git", "-C", str(self.root), "ls-tree", "-r", "--name-only", "-z", self.ref]
            else:
                cmd = ["git", "-C", str(self.root), "ls-files", "-z"]
            run = subprocess.run(cmd, capture_output=True)
            if run.returncode == 0:
                self._files = [p for p in run.stdout.decode("utf-8", "replace").split("\0") if p]
            elif self.ref:
                raise RuntimeError(f"cannot list {self.ref}: {run.stderr.decode().strip()}")
            else:
                self._files = sorted(
                    p.relative_to(self.root).as_posix() for p in self.root.rglob("*") if p.is_file()
                )
        return self._files

    def select(self, globs: list[str], exclude: list[str] | None = None) -> list[str]:
        inc = [glob_regex(g) for g in globs]
        exc = [glob_regex(g) for g in exclude or []]
        return [p for p in self.files() if any(r.match(p) for r in inc) and not any(r.match(p) for r in exc)]

    def read(self, path: str) -> str | None:
        if path not in self._cache:
            if self.ref:
                run = subprocess.run(["git", "-C", str(self.root), "show", f"{self.ref}:{path}"], capture_output=True)
                self._cache[path] = run.stdout.decode("utf-8", "replace") if run.returncode == 0 else None
            else:
                try:
                    self._cache[path] = (self.root / path).read_text(encoding="utf-8", errors="replace")
                except OSError:
                    self._cache[path] = None
        return self._cache[path]

    def grep_files(self, needles: list[str], globs: list[str], exclude: list[str]) -> list[str]:
        """Files under the globs holding any of the fixed strings (git grep, then the globs)."""
        cmd = ["git", "-C", str(self.root), "grep", "-l", "-I", "-F"]
        for needle in needles:
            cmd += ["-e", needle]
        if self.ref:
            cmd.append(self.ref)
        run = subprocess.run(cmd, capture_output=True)
        if run.returncode not in (0, 1):
            return [p for p in self.select(globs, exclude) if any(n in (self.read(p) or "") for n in needles)]
        prefix = f"{self.ref}:" if self.ref else ""
        found = [line[len(prefix):] if line.startswith(prefix) else line
                 for line in run.stdout.decode("utf-8", "replace").splitlines()]
        inc = [glob_regex(g) for g in globs]
        exc = [glob_regex(g) for g in exclude]
        return sorted(p for p in found if any(r.match(p) for r in inc) and not any(r.match(p) for r in exc))

    def checkout(self) -> Path:
        """A directory holding this tree, for checkers that run programs."""
        if not self.ref:
            return self.root
        return worktree_for(self.root, self.ref)


_WORKTREES: dict[str, Path] = {}


def worktree_for(root: Path, ref: str) -> Path:
    if ref not in _WORKTREES:
        where = Path(tempfile.mkdtemp(prefix="leo-bans-base-")) / "tree"
        subprocess.run(["git", "-C", str(root), "worktree", "add", "--detach", "--quiet", str(where), ref], check=True)
        # The head's installed packages serve the base's tests (one install per job).
        modules = root / "webviews" / "node_modules"
        if modules.is_dir() and (where / "webviews").is_dir() and not (where / "webviews" / "node_modules").exists():
            (where / "webviews" / "node_modules").symlink_to(modules)
        _WORKTREES[ref] = where
    return _WORKTREES[ref]


def drop_worktrees(root: Path) -> None:
    for where in _WORKTREES.values():
        subprocess.run(["git", "-C", str(root), "worktree", "remove", "--force", str(where)], capture_output=True)
        shutil.rmtree(where.parent, ignore_errors=True)
    _WORKTREES.clear()


# A finding is (key, text): the key ignores line numbers, so a base comparison survives edits above it.
Finding = tuple[str, str]


def run_grep(check: dict, tree: Tree) -> list[Finding]:
    pattern = re.compile(check["pattern"], re.MULTILINE | (re.DOTALL if check.get("multiline") else 0))
    expect = check.get("expect", "absent")
    hits: list[Finding] = []
    for path in tree.select(check["paths"], check.get("exclude")):
        text = tree.read(path)
        if text is None:
            continue
        for m in pattern.finditer(text):
            line = text.count("\n", 0, m.start()) + 1
            snippet = " ".join(m.group(0).split())[:160]
            hits.append((f"{path}: {snippet}", f"{path}:{line}: {snippet}"))
    if expect == "present":
        want = int(check.get("count", 0))
        if not hits:
            return [("missing", f"nothing under {', '.join(check['paths'])} matches /{check['pattern']}/")]
        if want and len(hits) != want:
            return [("count", f"/{check['pattern']}/ matches {len(hits)} times, expected {want}")]
        return []
    return hits


def run_tunable_default(check: dict, tree: Tree) -> list[Finding]:
    code, want = check["code"], str(check["default"]).strip()
    found = []
    for path in tree.grep_files([f'code: "{code}"'], check.get("paths", ["Packages/**/*.swift"]), []):
        for m in TUNABLE_DEFAULT.finditer(tree.read(path) or ""):
            if m.group(2) == code:
                found.append((path, m.group(1).strip()))
    if not found:
        return [(f"{code}: missing", f"no Tunable with code \"{code}\" (renamed? update leo-bans.json)")]
    return [(f"{code}: {value}", f"{path}: {code} defaults to {value}, not {want}") for path, value in found if value != want]


def run_program(argv: list[str], cwd: Path, env: dict[str, str] | None = None) -> tuple[int, str]:
    try:
        run = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, timeout=900,
                             env={**os.environ, **(env or {})})
    except (OSError, subprocess.TimeoutExpired) as error:
        return 127, str(error)
    return run.returncode, (run.stdout or "") + (run.stderr or "")


def tail(text: str, lines: int = 25) -> str:
    return "\n".join(text.rstrip().splitlines()[-lines:])


def run_bun_test(check: dict, tree: Tree) -> list[Finding]:
    root = tree.checkout()
    webviews = root / "webviews"
    if not (webviews / check["file"]).is_file():
        return [(f"{check['file']}: missing", f"webviews/{check['file']} does not exist")]
    argv = ["bun", "test", check["file"]]
    if check.get("name"):
        argv += ["-t", check["name"]]
    code, out = run_program(argv, webviews)
    passed = re.search(r"^\s*(\d+) pass", out, re.MULTILINE)
    if code == 0 and passed and int(passed.group(1)) > 0:
        return []
    why = "no test matched" if code == 0 else f"exit {code}"
    return [(f"{check['file']} {check.get('name', '')}: fails",
             f"bun test {check['file']}{' -t ' + repr(check['name']) if check.get('name') else ''} ({why}):\n{tail(out)}")]


def run_command(check: dict, tree: Tree) -> list[Finding]:
    root = tree.checkout()
    code, out = run_program(check["argv"], root / check.get("cwd", "."), check.get("env"))
    return [] if code == 0 else [(f"{' '.join(check['argv'])}: fails", f"{' '.join(check['argv'])} exit {code}:\n{tail(out)}")]


# --- the two ratchets ------------------------------------------------------------------------------

def read_counts(text: str | None) -> dict[tuple[str, str], int]:
    counts: dict[tuple[str, str], int] = {}
    for line in (text or "").splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        path, marker, count = line.split("\t")
        counts[(path, marker)] = int(count)
    return counts


def unruled_escapes(config: dict, tree: Tree) -> dict[tuple[str, str], list[str]]:
    """{(path, marker): [line, ...]} for escape comments with no `ruling: <link>` on their line."""
    ruling = re.compile(config["ruling"])
    markers = {m: re.compile(r"(?<![\w-])" + re.escape(m) + r"(?![\w-])") for m in config["markers"]}
    found: dict[tuple[str, str], list[str]] = {}
    for path in tree.grep_files(list(config["markers"]), config["scan"], config.get("exclude", [])):
        for number, line in enumerate((tree.read(path) or "").splitlines(), 1):
            if ruling.search(line):
                continue
            for marker, regex in markers.items():
                if regex.search(line):
                    found.setdefault((path, marker), []).append(f"{path}:{number}: {line.strip()[:160]}")
    return found


def check_escape_rulings(bans: dict, tree: Tree, base: Tree | None) -> list[Finding]:
    config = bans["escape_rulings"]
    baseline_path = f"{REL}/{config['baseline']}"
    baseline = read_counts(tree.read(baseline_path))
    findings: list[Finding] = []
    for key, lines in sorted(unruled_escapes(config, tree).items()):
        allowed = baseline.get(key, 0)
        if len(lines) > allowed:
            for line in lines[allowed:] if allowed else lines:
                findings.append((f"{key[0]}: {key[1]} unruled", f"{line}  <- add `ruling: <link>` to Leo's ruling on this line"))
    if base is not None:
        base_text = base.read(baseline_path)
        if base_text is not None:
            before = read_counts(base_text)
            for key, count in sorted(baseline.items()):
                if count > before.get(key, 0):
                    findings.append((f"baseline {key}", f"{baseline_path}: {key[0]} {key[1]} rose to {count} "
                                                        f"(base {before.get(key, 0)}); the baseline only shrinks"))
    return findings


def read_tunable_baseline(text: str | None) -> dict[str, str]:
    """{code: the line's comment} from tunables-default-on.txt."""
    rows = {}
    for line in (text or "").splitlines():
        body, _, note = line.partition("#")
        if body.strip():
            rows[body.strip()] = note.strip()
    return rows


def default_on_tunables(config: dict, tree: Tree) -> dict[str, str]:
    """{code: path} for every Bool Tunable whose default is true."""
    on = {}
    for path in tree.grep_files(["default: true"], config["paths"], config.get("exclude", [])):
        for m in BOOL_TUNABLE.finditer(tree.read(path) or ""):
            if m.group(1) == "true":
                on[m.group(2)] = path
    return on


def check_default_on_tunables(bans: dict, tree: Tree, base: Tree | None) -> list[Finding]:
    config = bans["default_on_tunables"]
    baseline_path = f"{REL}/{config['baseline']}"
    listed = read_tunable_baseline(tree.read(baseline_path))
    findings: list[Finding] = []
    for code, path in sorted(default_on_tunables(config, tree).items()):
        if code not in listed:
            findings.append((f"{code}: on", f"{path}: Debug toggle {code} defaults on. New dev surfaces ship off "
                                            f"(cmux#22662); if Leo ruled it on, list it in {baseline_path} with "
                                            "`# ruling: <link>`"))
    if base is not None:
        before_text = base.read(baseline_path)
        if before_text is not None:
            before = read_tunable_baseline(before_text)
            ruling = re.compile(bans["escape_rulings"]["ruling"])
            for code, note in sorted(listed.items()):
                if code not in before and not ruling.search(note):
                    findings.append((f"baseline {code}", f"{baseline_path}: {code} was added with no `ruling: <link>`"))
    return findings


PYTHON_CHECKS = {
    "escape_rulings": check_escape_rulings,
    "default_on_tunables": check_default_on_tunables,
}


# --- judging -----------------------------------------------------------------------------------------

@dataclass
class Verdict:
    ban: dict
    check: dict
    failures: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)


def run_check(bans: dict, check: dict, tree: Tree, base: Tree | None) -> list[Finding]:
    kind = check["kind"]
    if kind == "grep":
        return run_grep(check, tree)
    if kind == "tunable-default":
        return run_tunable_default(check, tree)
    if kind == "bun-test":
        return run_bun_test(check, tree)
    if kind == "command":
        return run_command(check, tree)
    if kind == "python":
        return PYTHON_CHECKS[check["function"]](bans, tree, base)
    raise ValueError(f"unknown checker kind {kind!r}")


def judge(bans: dict, ban: dict, check: dict, head: Tree, base: Tree | None) -> Verdict:
    verdict = Verdict(ban, check)
    found = run_check(bans, check, head, base)
    if not found:
        return verdict
    if base is not None:
        try:
            before = {key for key, _ in run_check(bans, check, base, None)}
        except Exception as error:  # an unreadable base makes every finding the change's
            print(f"::warning::{ban['id']}: could not run the checker on the base: {error}")
            before = set()
        for key, text in found:
            (verdict.warnings if key in before else verdict.failures).append(text)
        return verdict
    for _, text in found:
        (verdict.warnings if check.get("pending") else verdict.failures).append(text)
    return verdict


def describe(ban: dict, check: dict) -> str:
    quote = f'Leo ({ban["date"]}): "{ban["quote"]}"' if ban.get("quote") else f"(no quote found; {ban.get('quote_checked', '')})"
    pending = f" Fix still open: {check['pending']}." if check.get("pending") else ""
    return f"{ban['description']} {quote} Fixed in {ban['fix_pr']}.{pending}"


def escape(text: str) -> str:
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def load(root: Path) -> dict:
    return json.loads((root / REL / "leo-bans.json").read_text(encoding="utf-8"))


def all_checks(bans: dict) -> list[tuple[dict, dict]]:
    rows = [(ban, check) for ban in bans["bans"] for check in ban["checkers"]]
    rows.append(({"id": "escape-rulings", "description": bans["escape_rulings"]["description"],
                  "quote": None, "quote_checked": "a gate rule, not a ban", "date": "", "fix_pr": "this ratchet"},
                 {"kind": "python", "function": "escape_rulings"}))
    return rows


def cmd_check(args: argparse.Namespace) -> int:
    root = Path(args.root).resolve()
    bans = load(root)
    head = Tree(root, args.ref) if args.ref else Tree(root)
    base = Tree(root, args.base) if args.base else None
    only = set(filter(None, (args.only or "").split(",")))
    skip = set(args.skip_kind or [])
    verdicts: list[Verdict] = []
    try:
        for ban, check in all_checks(bans):
            if (only and ban["id"] not in only) or check["kind"] in skip:
                continue
            verdict = judge(bans, ban, check, head, base)
            verdicts.append(verdict)
            state = "FAIL" if verdict.failures else "warn" if verdict.warnings else "ok"
            label = check.get("name") or check.get("file") or check.get("code") or check.get("function") or check.get("pattern", "")
            print(f"{state:4}  {ban['id']:28} {check['kind']:15} {str(label)[:70]}")
    finally:
        drop_worktrees(root)
    failed = 0
    for v in verdicts:
        title = f"Leo ban: {v.ban['id']}"
        if v.failures:
            failed += 1
            body = describe(v.ban, v.check) + "\n" + "\n".join(v.failures[:40])
            print(f"::error title={title}::{escape(body)}")
        if v.warnings:
            why = "known, fix still open" if v.check.get("pending") else "also on the base (a base red)"
            body = f"{why}: " + describe(v.ban, v.check) + "\n" + "\n".join(v.warnings[:40])
            print(f"::warning title={title}::{escape(body)}")
    if args.json:
        Path(args.json).write_text(json.dumps([{"ban": v.ban["id"], "kind": v.check["kind"], "failures": v.failures,
                                                 "warnings": v.warnings} for v in verdicts], indent=2) + "\n")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as out:
            out.write("### Leo's bans\n\n| Ban | Checker | Result |\n|---|---|---|\n")
            for v in verdicts:
                state = "red" if v.failures else "warning" if v.warnings else "ok"
                out.write(f"| {v.ban['id']} | {v.check['kind']} | {state} |\n")
    print(f"{len(verdicts)} checkers: {failed} red, {sum(1 for v in verdicts if v.warnings and not v.failures)} warning")
    return 1 if failed else 0


def cmd_list(args: argparse.Namespace) -> int:
    bans = load(Path(args.root).resolve())
    for ban in bans["bans"]:
        kinds = ", ".join(c["kind"] + (" (pending)" if c.get("pending") else "") for c in ban["checkers"])
        print(f"{ban['id']:28} {ban['date']}  {ban['fix_pr']:52} quote={'yes' if ban.get('quote') else 'no ':3}  {kinds}")
    return 0


def cmd_update_baselines(args: argparse.Namespace) -> int:
    root = Path(args.root).resolve()
    bans, tree = load(root), Tree(Path(args.root).resolve())
    config = bans["escape_rulings"]
    rows = sorted(unruled_escapes(config, tree).items())
    header = [line for line in (tree.read(f"{REL}/{config['baseline']}") or "").splitlines() if line.startswith("#")]
    body = [f"{path}\t{marker}\t{len(lines)}" for (path, marker), lines in rows]
    (root / REL / config["baseline"]).write_text("\n".join(header + body) + "\n", encoding="utf-8")
    tconfig = bans["default_on_tunables"]
    listed = read_tunable_baseline(tree.read(f"{REL}/{tconfig['baseline']}"))
    theader = [line for line in (tree.read(f"{REL}/{tconfig['baseline']}") or "").splitlines() if line.startswith("#")]
    on = default_on_tunables(tconfig, tree)
    tbody = [f"{code}  # {listed[code]}" if listed.get(code) else code for code in sorted(on)]
    (root / REL / tconfig["baseline"]).write_text("\n".join(theader + tbody) + "\n", encoding="utf-8")
    print(f"{len(body)} escape rows, {len(tbody)} default-on toggles")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    check = sub.add_parser("check")
    check.add_argument("--root", default=str(HERE.parents[2]))
    check.add_argument("--base")
    check.add_argument("--ref", help="check this commit instead of the checkout (reads it through git)")
    check.add_argument("--only")
    check.add_argument("--skip-kind", action="append", choices=KINDS)
    check.add_argument("--json")
    listing = sub.add_parser("list")
    listing.add_argument("--root", default=str(HERE.parents[2]))
    update = sub.add_parser("update-baselines")
    update.add_argument("--root", default=str(HERE.parents[2]))
    args = parser.parse_args(argv)
    return {"check": cmd_check, "list": cmd_list, "update-baselines": cmd_update_baselines}[args.command](args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
