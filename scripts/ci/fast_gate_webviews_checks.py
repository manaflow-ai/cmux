#!/usr/bin/env python3
"""The webviews checks that fail a feat-cmux-next pull request, compared with its base per error.

    fast_gate_webviews_checks.py [--base BASE] [--repo PATH] [--no-install] [--only CHECK]... [--skip CHECK]... [--advisory-out FILE]

Installs webviews' node_modules (bun install --frozen-lockfile; --no-install when the job already did) and runs, in
webviews/, every check in CHECKS, each on its own: a red never stops the next. ci-web's "Check webviews" step runs
this on a pull request (BASE the merge parent) and on a push (no BASE), and the fast gates run it on a dispatch.

Only findings the pull request adds fail: a check that fails on the merge runs again on BASE (a worktree of it,
sharing the merge's node_modules), and the gate fails only on findings BASE does not have as often. A finding is
one diagnostic of the type check (Oxlint's report: `path: code: message`), or else one output line (with the
checkout root, `path:line` numbers and timings ignored, since the pull request may move lines; a check's own
counts still compare). The base's findings are warnings, never charged to the pull request. Without BASE (a push)
every red is the commit's. Exits 1 when any check adds a finding.

--only and --skip pick from CHECKS: ci-web runs the type check (`--only typecheck`) in its own job,
webviews-typecheck, and the rest (`--skip typecheck`) in react-apps-check (1), so a type error is a red check of
its own and never the test shard's (Leo, 2026-11-19: "the CI doesn't necessarily have to fail and like give up ...
just as if it were like a follow-up"). The bundles, the gallery and the tests build transpile-only (Vite, bun), so
they run on a tree with a type error.

#23763 (2026-10-21) merged a TS2339 in test/composer-row-layout.test.ts: the base was red, so its own red read as
"the same base red". Compared per error, it is the one new finding (tests/test_cmux_next_fast_gates.py replays it).

cmux_next_fast_gates.py runs this only on a dispatch (pr=N, against the current tip): on a pull_request event
ci-web already ran these checks on the same merge commit. A merger dispatches when a check path
(scripts/ci/check-paths.txt) changed on the base after the pull request's last fast-gates base, so a check that
landed after the pull request's CI runs on it before it merges (2026-10-21: #22967, #22975 and #23094 merged past
the new check:fixed-waits; replayed, #22975 merged with 01ea78b3 adds
"test/agent-pane-queued-images.test.ts: 2 fixed waits, baseline 0" to the two findings the base already had).

The nightly passes --advisory-out FILE: a failed check of class `lint` (CHECK_CLASSES) is a warning written to FILE
(JSON, {"failed": [{"check", "findings"}]}) for nightly_fix_forward_issue.py, and only a `blocks` check fails the
step. Leo, 2026-11-20, after check:design-tokens held the NEXT nightly for 15 h: "aren't these a bit bad to halt the
nightly on? what about the fixit/ignoring and fixing forward for things?" Without the flag every check counts.
"""
from __future__ import annotations

import argparse
import json
import os
from collections import Counter
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

CHECKS = (
    "check:effect-cleanup",
    "check:browser-lanes",
    "check:fixed-waits",
    "check:whole-list-rows",
    "check:design-tokens",
    "check:ui-review",
    "typecheck",
    "check:catalog-keys",
    "check:catalog-unused",
    "check:popup-hover-reveals",
)
# Per check: ("lint", "") reports and is fixed forward on the nightly (--advisory-out); ("blocks", why) still fails it.
LINT = ("lint", "")
CHECK_CLASSES = {
    "check:effect-cleanup": LINT,
    "check:browser-lanes": LINT,
    "check:fixed-waits": LINT,
    "check:whole-list-rows": LINT,
    "check:design-tokens": LINT,
    "check:ui-review": LINT,
    "typecheck": ("blocks", "#32056's TS2448 broke every agent pane and was published 2026-11-02"),
    "check:catalog-keys": LINT,
    "check:catalog-unused": LINT,
    "check:popup-hover-reveals": LINT,
}
ADVISORY_EXCERPT = 40  # findings per check in the advisory report; the run log holds them all
# A typecheck red only in files the app never ships (benches, tests, galleries, the dev server, scripts) says
# nothing about whether the app works, so on the nightly it is fixed forward like a lint. Leo, 2026-11-20, after
# a TS2367 in bench/composer-typing.bench.ts held the NEXT nightly (run 44661110467): "failed on a webview check i
# thought we didnt panic for these types of things? ... where's our fixit type things". A red in app source blocks.
# Build-time code under dev-server/ and scripts/ (Vite plugins) is read by the build, but a type error there does not
# change the emitted JS, so it is still outside what the app runs.
NOT_SHIPPED = re.compile(r"^(?:webviews/)?(?:bench|test|tests|e2e|dev-server|scripts)/"
                         r"|\.(?:test|spec|gallery|bench)\.[cm]?[jt]sx?:")
# bun's own lines around a check's output, never a finding: the script it ran and its exit (job 136040412192).
BUN_RUN_LINE = re.compile(r'^(?:\$ .*|error: script "[^"]+" exited with code \d+)$')


def outside_the_app(lines: list[str]) -> bool:
    """Whether every finding names a file the app never ships (NOT_SHIPPED); a finding with no path counts as app."""
    found = [line for line in lines if not BUN_RUN_LINE.match(line.strip())]
    return bool(found) and all(NOT_SHIPPED.search(line.split(" ", 1)[0]) for line in found)


def advisory_class(check: str, lines: list[str]) -> bool:
    """Whether a failed CHECK is reported and fixed forward on the nightly instead of failing it."""
    return CHECK_CLASSES[check][0] == "lint" or (check == "typecheck" and outside_the_app(lines))
LINE_REF = re.compile(r"(\S):\d+(?::\d+)?\b")
TIMING = re.compile(r"\b\d+(?:\.\d+)?\s?(?:ms|s)\b")
ANSI = re.compile(r"\x1b\[[0-9;]*m")
# Oxlint's graphical report (the type check, `vp lint`): `  x typescript(TS2339): message`, wrapped lines of the
# message, `   ,-[path:line:col]`, a code frame and `help:` lines. One finding per diagnostic, its whole message.
# Oxlint draws the frame in ASCII or Unicode (`╭─[`, `│`, `·`, `╰`) depending on the terminal; both are read.
DIAGNOSTIC = re.compile(r"^\s*[x!×⚠]\s+(?P<code>[\w/@-]+\([^)]*\)):\s*(?P<message>.*?)\s*$")
LOCATION = re.compile(r"^\s*(?:,-|╭─)\[(?P<path>[^\]]+?)(?::\d+:\d+)?\]\s*$")
FRAME = re.compile(r"^\s*(?:\d+\s*[|│]|[:·]|`-+|╰─+)")
HELP = re.compile(r"^\s*help:")
# Lines that describe a run, not a finding: `vp fmt`'s closing `Finished in 528ms on 2481 files using 4 threads.`
# (`vp lint`'s adds `with 162 rules`), whose file count moves whenever the change adds or removes a file (#24274's
# and #24524's fast gates read it as the one finding the merge added), and `vp fmt`'s `Format issues found in above
# N files.`, whose count falls when the change fixes one of the base's files.
NOISE = re.compile(r"^(?:error: (?:Type errors|Formatting issues|Lint issues) found$"
                   r"|Finished in \S+ on \d+ files?(?: with \d+ rules?)? using \d+ threads?\.$|note: You are running"
                   r"|Format issues found in above \d+ files?\. Run without `--check` to fix\.$)")
# A finding as a GitHub workflow command, which `vp lint` (Oxlint) prints in GitHub Actions:
# `::warning file=PATH,line=N,endLine=N,col=C,endColumn=C,title=eslint(rule)::MESSAGE`. GitHub turns the line into an
# annotation and its log keeps only `##[warning]MESSAGE`, so a finding shown as that raw line names no file (#44638's
# web lint printed `Expected expression to be used` and nothing else). Keyed by level, path, title and message; shown
# as `PATH:LINE:COL: MESSAGE [level title]`, which starts with no `::`.
ANNOTATION = re.compile(r"^::(?P<level>error|warning|notice)(?:\s+(?P<props>[^:]*))?::(?P<message>.*)$")


def unescape(value: str, prop: bool = False) -> str:
    """A workflow command's escaped text: %25, %0D and %0A everywhere, %3A and %2C in a property."""
    pairs = (("%0D", " "), ("%0A", " ")) + ((("%3A", ":"), ("%2C", ",")) if prop else ())
    for coded, plain in pairs:
        value = value.replace(coded, plain).replace(coded.lower(), plain)
    return value.replace("%25", "%")


def annotation(line: str, root: str = "") -> tuple[str, str] | None:
    """(key, shown) for one workflow-command finding, or None for any other line."""
    match = ANNOTATION.match(line.strip())
    if not match:
        return None
    props = {}
    for part in (match["props"] or "").split(","):
        name, _, value = part.partition("=")
        if name.strip():
            props[name.strip()] = unescape(value, prop=True)
    message = unescape(match["message"]).strip()
    path, title, level = props.get("file", ""), props.get("title", ""), match["level"]
    where = ":".join(part for part in (path, props.get("line", ""), props.get("col", "")) if part)
    tag = f" [{level} {title}]" if title else f" [{level}]"
    shown = f"{where}: {message}{tag}" if where else f"{message}{tag}"
    return f"{level} {unroot(path, root)}: {title}: {message}", shown


# The run's count, a line that falls when the change fixes one of the base's errors: the type check's `Found 1 error
# and 0 warnings in 9 files (1.0s)`, `vp lint`'s `Found 0 warnings and 1 error.` (#24538's web lint read the second
# as the one finding the merge added after it fixed 3 of the base's 4 errors). Only the whole line, with only a timing
# in parentheses, so a crash after it (`...: panic`, `... (panic)`) stays a finding; and never the next line of an
# unframed diagnostic's message, which wraps with no blank line between (Oxlint ends each diagnostic with one).
SUMMARY = re.compile(r"^Found \d+ (?:errors? and \d+ warnings?|warnings? and \d+ errors?)(?: in \d+ files?)?"
                     r"(?: \(\d+(?:\.\d+)?m?s(?:, \d+ threads?)?\))?\.?$")


# The type check of the tree under test runs inside fixit-compile (ci-oops 0a): when every type error has one safe
# language-service fix it writes the fixup patch for fixit-compile-push, and still exits with the check's status.
FIXIT_COMPILE = Path(__file__).resolve().parent / "oops" / "fixit_compile.py"


def run_check(webviews: Path, check: str, fixit: bool = False) -> tuple[int, str]:
    argv = ["bun", "run", check]
    if not (fixit and check == "typecheck" and FIXIT_COMPILE.is_file()):
        result = subprocess.run(argv, cwd=webviews, capture_output=True, text=True)
        return result.returncode, result.stdout + result.stderr
    # Its own lines go to a report printed apart, so the findings compared with the base are the check's alone.
    with tempfile.NamedTemporaryFile("r", suffix=".log") as report:
        result = subprocess.run([sys.executable, "-I", str(FIXIT_COMPILE), "run", "--kind", "tsc", "--report",
                                 report.name, "--", *argv], cwd=webviews, capture_output=True, text=True)
        print(report.read(), end="", flush=True)
    return result.returncode, result.stdout + result.stderr


def key(line: str, root: str = "") -> str:
    """A line as a finding: stripped, its checkout root, `path:line[:col]` numbers and timings dropped."""
    return TIMING.sub("<time>", LINE_REF.sub(r"\1", unroot(line, root).strip()))


def unroot(text: str, root: str) -> str:
    """The checkout root, as given and resolved (macOS /var is /private/var), as <root>."""
    for form in sorted({root, os.path.realpath(root)} if root else (), key=len, reverse=True):
        text = text.replace(form, "<root>")
    return text


def findings(output: str, root: str = "") -> list[tuple[str, str]]:
    """(key, shown) per finding: each Oxlint diagnostic, keyed by its path, code and whole message (wrapped lines
    and help included, the line number not), each GitHub workflow-command finding (ANNOTATION, keyed without its
    line and shown as `path:line:col: message`), and every other line of output, so an error the parser does not
    know (a crash, a config failure) is a finding of its own and never hides behind a known one."""
    out: list[tuple[str, str]] = []
    record: dict | None = None

    def close() -> None:
        nonlocal record
        if record:
            message = " ".join(record["message"])
            path = record["path"]
            found = f"{unroot(path, root)}: {message}" if path else message
            out.append((found, f"{path}: {message}" if path else message))
        record = None

    lines = ANSI.sub("", output).splitlines()

    def noise(i: int) -> bool:
        text = lines[i].strip()
        wraps = record is not None and not record["framed"] and i > 0 and lines[i - 1].strip() != ""
        return bool(NOISE.match(text)) or (not wraps and bool(SUMMARY.match(text)))

    for i, line in enumerate(lines):
        header = DIAGNOSTIC.match(line)
        if header:
            close()
            record = {"message": [f"{header['code']}: {header['message']}"], "path": "", "framed": False}
            continue
        if record is not None and ANNOTATION.match(line.strip()):
            close()  # a workflow-command finding is never part of an open diagnostic's message
        if record is not None:
            where = LOCATION.match(line)
            if where and not record["path"]:
                record["path"], record["framed"] = where["path"], True
                continue
            if FRAME.match(line) and record["framed"]:
                continue
            if HELP.match(line) or (not record["framed"] and line.strip() and not noise(i)):
                record["message"].append(line.strip().lstrip("|").strip())
                continue
            if not line.strip():
                continue
            close()
        if line.strip() and not noise(i):
            out.append(annotation(line, root) or (key(line, root), line.rstrip()))
    close()
    return out


def compare(merge_output: str, base_output: str, merge_root: str = "", base_root: str = "") -> tuple[list, list]:
    """(new, old): the merge's findings beyond the base's, and those the base has too, in the merge's order.
    Counted, not a set: a second finding that reads like one the base already has is still new."""
    left = Counter(found for found, _ in findings(base_output, base_root))
    new, old = [], []
    for found, shown in findings(merge_output, merge_root):
        if left[found] > 0:
            left[found] -= 1
            old.append(shown)
        else:
            new.append(shown)
    return new, old


def added(merge_output: str, base_output: str, merge_root: str = "", base_root: str = "") -> list[str]:
    """The merge's findings the base does not have (compare's first half)."""
    return compare(merge_output, base_output, merge_root, base_root)[0]


def shares_deps(repo: Path, base: str, directory: str) -> bool:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    import web_lint_prepush  # noqa: PLC0415  (scripts/web_lint_prepush.py)

    return web_lint_prepush.shares_deps(repo, base, directory)


def generate_strings(webviews: Path) -> None:
    """A worktree's page strings (generated/strings.json, gitignored) that bun install's postinstall writes;
    a base sharing the merge's node_modules installs nothing, and the type check reads them."""
    if (webviews / "scripts/pages/gen-strings.mjs").is_file():
        subprocess.run(["bun", "scripts/pages/gen-strings.mjs", "--best-effort"], cwd=webviews, capture_output=True)


class BaseTree:
    """A worktree of BASE, made on first use. Its webviews/node_modules is the merge's only when the two install
    the same thing (web_lint_prepush.shares_deps: package.json, bun.lock, file: dependencies); otherwise it installs
    its own, so a pull request that bumps a dependency is never compared with a base checked on that bump."""

    def __init__(self, repo: Path, base: str):
        self.repo, self.base, self.path = repo, base, None

    def webviews(self) -> Path | None:
        if self.path is None:
            holder = Path(tempfile.mkdtemp(prefix="fast-gate-webviews-base-"))
            made = subprocess.run(["git", "-C", str(self.repo), "worktree", "add", "--quiet", "--detach",
                                   str(holder / "base"), self.base], capture_output=True, text=True)
            if made.returncode != 0:
                print(f"webviews checks: could not check out the base {self.base}: {made.stderr.strip()}", flush=True)
                shutil.rmtree(holder, ignore_errors=True)
                self.path = False
                return None
            modules = self.repo / "webviews" / "node_modules"
            if modules.is_dir() and shares_deps(self.repo, self.base, "webviews"):
                (holder / "base" / "webviews" / "node_modules").symlink_to(modules.resolve())
            elif subprocess.run(["bun", "install", "--frozen-lockfile"], cwd=holder / "base" / "webviews").returncode:
                print(f"webviews checks: bun install failed on the base {self.base}", flush=True)
                subprocess.run(["git", "-C", str(self.repo), "worktree", "remove", "--force", str(holder / "base")],
                               capture_output=True)
                shutil.rmtree(holder, ignore_errors=True)
                self.path = False
                return None
            generate_strings(holder / "base" / "webviews")
            self.path = holder / "base"
        return self.path / "webviews" if self.path else None

    def close(self) -> None:
        if self.path:
            subprocess.run(["git", "-C", str(self.repo), "worktree", "remove", "--force", str(self.path)],
                           capture_output=True)
            shutil.rmtree(self.path.parent, ignore_errors=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base", default="", help="the base sha (or ref) to compare with; none charges every red")
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--no-install", action="store_true", help="webviews' node_modules is already installed")
    parser.add_argument("--only", action="append", default=[], metavar="CHECK", help="run only this check (repeat)")
    parser.add_argument("--skip", action="append", default=[], metavar="CHECK", help="leave this check out (repeat)")
    parser.add_argument("--advisory-out", type=Path, default=None,
                        help="the nightly: lint-class reds go to this JSON report and never fail the run")
    args = parser.parse_args(argv)
    unknown = sorted(set(args.only + args.skip) - set(CHECKS))
    if unknown:
        parser.error(f"not in CHECKS: {', '.join(unknown)}")
    checks = [c for c in CHECKS if (not args.only or c in args.only) and c not in args.skip]
    repo = args.repo.resolve()
    webviews = repo / "webviews"
    if not args.no_install and subprocess.run(["bun", "install", "--frozen-lockfile"], cwd=webviews).returncode != 0:
        print("webviews checks: bun install --frozen-lockfile failed", flush=True)
        return 1
    base = BaseTree(repo, args.base) if args.base else None
    failed = []
    shown: dict[str, list[str]] = {}  # a failed check's findings, for --advisory-out
    try:
        for check in checks:
            code, output = run_check(webviews, check, fixit=True)
            print(output, end="", flush=True)
            if code == 0:
                continue
            base_webviews = base.webviews() if base else None
            if base_webviews is None:  # a push, or no base to compare with: the red is charged here
                failed.append(check)
                shown[check] = [line for _, line in findings(output, str(repo))]
                continue
            # A new ratchet is intentionally introduced in the same PR as its baseline and
            # package script. Until that PR lands, the merge parent cannot run this check; do not
            # charge the transition PR for the base's missing command. Later PRs see the script on
            # the base and are compared normally.
            if check == "check:design-tokens" and not (base_webviews / "scripts/check-design-tokens.ts").is_file():
                print("webviews checks: check:design-tokens is new; base has no command, so this transition is not charged", flush=True)
                continue
            if check == "check:ui-review" and not (base_webviews / "scripts/check-ui-review.ts").is_file():
                print("webviews checks: check:ui-review is new; base has no command, so this transition is not charged", flush=True)
                continue
            base_code, base_output = run_check(base_webviews, check)
            new, old = (compare(output, base_output, str(repo), str(base_webviews.parent)) if base_code != 0
                        else ([shown for _, shown in findings(output, str(repo))], []))
            if not new and not old:
                new = [f"{check} failed (exit {code}) and printed no finding to compare with the base"]
            if old:
                print(f"::warning title=webviews {check} (base)::{len(old)} error(s) the base {args.base[:12]} "
                      "has too; not this change's", flush=True)
                for line in old:
                    print(f"  base: {line}", flush=True)
            if not new:
                print(f"webviews checks: {check} fails on the base {args.base[:12]} too and this adds nothing to it",
                      flush=True)
                continue
            failed.append(check)
            shown[check] = new
            advisory = args.advisory_out is not None and advisory_class(check, new)
            print(f"webviews checks: {check} adds, over the base {args.base[:12]}:", flush=True)
            for line in new:
                print(f"  {line}", flush=True)
                print(f"::{'warning' if advisory else 'error'} title=webviews {check}::{line}", flush=True)
    finally:
        if base:
            base.close()
    where = "the pull request merged with its base" if args.base else "this commit"
    advisory = ([c for c in failed if advisory_class(c, shown.get(c, []))] if args.advisory_out is not None else [])
    for check in failed:
        if check in advisory:
            kind = "lint-class" if CHECK_CLASSES[check][0] == "lint" else "only in files the app never ships"
            print(f"::warning title=webviews {check} (fix forward)::{check} fails on {where}; {kind}, so it is "
                  "reported and never fails the nightly")
        else:
            print(f"::error title=webviews {check}::{check} fails on {where}")
    if args.advisory_out is not None:
        report = {"failed": [{"check": c, "findings": shown.get(c, [])[:ADVISORY_EXCERPT]} for c in advisory]}
        args.advisory_out.parent.mkdir(parents=True, exist_ok=True)
        args.advisory_out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"webviews checks: {', '.join(failed) + ' failed' if failed else 'all passed'}", flush=True)
    return 1 if any(c not in advisory for c in failed) else 0


if __name__ == "__main__":
    sys.exit(main())
