#!/usr/bin/env python3
"""The react-apps-check shards a pull request runs: shard 1, and each other shard that holds a test the change
touches. A feat-cmux-next push runs every shard (ci-web.yml calls this only on a pull request).

    webviews_pr_shards.py --base REF [--head REF] --count N [--repo DIR]
    webviews_pr_shards.py --all --count N        # every shard: a push, the full-ci label, a failed pick
    webviews_pr_shards.py --base REF [--head REF] --count N --files-of 1,3   # those shards' test files
    webviews_pr_shards.py --base REF [--head REF] --count N --direct-out F   # also each picked shard's touched tests

Prints the shard matrix as JSON (`[{"shard": 1, "shard_count": N}, ...]`) on stdout, and why on stderr.

Leo, 2026-11-21: "id rather we simply cut shit now and revisit later." Over 11-13..19 (16,970 pull request heads,
cmuxterm-hq docs/ci/bottleneck-and-skip-candidates-2026-11-21.md), shards 2 to 12 were 20.5% of pull request
runner-minutes and never caught a red that no other check caught (0 of 3,078 heads); shard 1 caught 9 of its own. So
a pull request runs:
  - shard 1 always (it holds the shard-independent checks: Oxlint, Oxfmt, type check, budgets, PR-scoped rules);
  - a shard from 2 to N only when it holds a touched test: a test file the change edits, or a test that itself
    imports a changed webviews file (one hop of webviews_affected.py's import graph, not its closure, and not its
    always-run set: the browser, Vite and file-reading tests that run on nearly every change are what the 0% above
    measured skipping; the closure put a test of every shard behind any shared module);
    the picked shards from 2 to N become one job that runs only those touched tests (--direct-out), not each shard's
    whole share of the affected closure: the shards were picked for them, and the closure share is what the 0%
    above measured. Shard 1 keeps its whole share;
  - every shard for a build or runner input (webviews_affected.EVERYTHING: package.json, bun.lock, vite configs, the
    runner scripts, ci-web.yml, this file, the preload and what it imports). A test helper (test/support/) or
    webviews script (webviews/scripts/) counts as a source here: the tests that import it, or that are or import a
    module reading it as data. A deleted source counts by the files that still name it in an import;
  - shard 1 and two sampled shards when the change's only every-shard input is ci-web.yml or a selection script
    (SAMPLED: webviews_affected.py, focused_tests.py, this file), plus the one job of touched tests from the rest of
    the change. The two come from the head commit, so each push of a CI iteration runs a different pair. On 98
    replayed every-shard heads from 2026-11-21 13Z to 11-22 07Z, ci-web.yml edits were 37 heads and 39% of their
    minutes; every one changed the react-apps-check jobs, so they still run shard 1's checks and two shards' whole
    file lists rather than none. The full-ci label runs every shard; CI_WEBVIEWS_CI_EDIT_SAMPLE=0 (a repository
    variable) runs every shard for them again, as before.
A shard's files come from the very split it makes itself (run-webviews-tests.sh CMUX_WEB_TEST_LIST_ONLY with the
run's one duration manifest, widths and head start, passed in the environment), so the pick and the shards agree.
Every feat-cmux-next post-merge batch still runs all N shards over every file: a red a skipped shard would have
caught shows on the base's next batch run (cmux-next-post-merge.yml, suite `web`) and its base-red tracking.

Any error picks every shard: the pick may only ever run more.

--files-of prints the test files (webviews-relative, one a line) that the named shards run for this change, from the
same split. react-apps-base-early replays the base's red files only among them (RFD 0023 item 3, cmuxterm-hq
docs/rfd/0023-ci-cd-design.md): a head red can only be in a file a head shard ran, so a base verdict on any other file
is never read. Any error exits non-zero and prints nothing; the job then keeps its whole affected list.
"""
from __future__ import annotations

import argparse
import json
import os
import random
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import webviews_affected as wa  # noqa: E402

RUNNER = Path(__file__).resolve().parent / "run-webviews-tests.sh"
# Build inputs webviews_affected.EVERYTHING lists that a pull request's pick treats as sources: test helpers and
# webviews scripts. On 11-20's merges they made 14 of 17 every-shard picks; the import graph reaches their tests.
HOP = re.compile(r"^webviews/(test/support/|scripts/)")
# A JS block or line comment (a line comment starts a line or follows a space, so `https://` in a string stays).
# Inputs whose edit changes how the shards run or pick, not what a test imports: every shard before; now shard 1 and
# SAMPLE_COUNT sampled shards (pick below), unless CI_WEBVIEWS_CI_EDIT_SAMPLE is 0.
SAMPLED = re.compile(r"^(\.github/workflows/ci-web\.yml|scripts/ci/(webviews_affected|focused_tests|webviews_pr_shards)\.py)$")
SAMPLE_COUNT = 2
SAMPLE_WHY = "sampled shards"
# Push classes (Leo, 2026-11-22: "there must surely be some changes which can get the fast track route. like a nexus
# card."). Every pull request push gets one, named in the step summary with the rule that fired:
#   fast:    every changed file is a doc no webviews file names, or a comment-only edit with no tool directive: shard 1
#            runs its shard-independent checks (Oxlint, Oxfmt, type check, budgets, PR-scoped rules) and no test file;
#   sampled: shard 1 and the touched tests; when the change has an every-shard input outside FULL, also two shards
#            sampled from the head commit (the base batch runs every shard and bisects a red to its PR);
#   full:    a FULL path below, the full-ci label, a base push, the base batch, or a failed pick: every shard.
# The repository variable CI_WEBVIEWS_PUSH_CLASSES=0 runs the pick as it was before the classes.
# FULL stays short: each is an input whose miss only a full run can show, because it decides what every shard runs.
FULL = (
    (re.compile(r"^scripts/ci/run-webviews-tests\.sh$"),
     "the test runner: a slip can run no file, or skip its retries, in every shard and still pass"),
    (re.compile(r"^scripts/ci/webviews_test_shards\.py$"),
     "the shard splitter: a bad split drops or repeats files between shards, which sampled shards cannot see"),
    (re.compile(r"^scripts/ci/webviews_test_results\.py$"),
     "the result parser: a misread turns reds green in every shard"),
    (re.compile(r"^webviews/(package\.json|bun\.lock|bunfig\.toml)$"),
     "a dependency or toolchain pin: a new bun, React or test library version changes every test file"),
    (re.compile(r"^webviews/test/preload"), "the test preload: every test file loads it first"),
)
DOCS = re.compile(r"\.(md|markdown|rst|txt)$", re.I)
SLASH_COMMENT = (".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts", ".css")
HASH_COMMENT = (".py", ".sh", ".bash", ".yml", ".yaml", ".toml")
# A comment some tool reads: an edit to one is a code change (types, lint, bundling, test environment, tree shaking).
DIRECTIVE = re.compile(r"@ts-|eslint|oxlint|oxfmt|biome|prettier|@vite|@vitest|@jest|@jsx|@refresh|webpack|"
                       r"__PURE__|__NO_SIDE_EFFECTS__|istanbul|c8 |<reference|sourceMappingURL|noqa|type:|"
                       r"shellcheck|yaml-language-server|#!|-\*-", re.I)
COMMENT = re.compile(r"/\*[\s\S]*?\*/|(?:^|(?<=\s))//[^\n]*", re.M)


def matrix(shards: list[int], count: int) -> str:
    return json.dumps([{"shard": shard, "shard_count": count} for shard in shards], separators=(",", ":"))


def read_beyond_imports(selector: "wa.Selector", f: str) -> tuple[str, set[str]]:
    """Why a helper or script change must run every shard ("" when it need not), and the modules that read it.

    A vite or compiler config (a code file at the top of webviews/) that imports it, directly or not, or names its
    path (`new URL("./scripts/lint/x.mjs")`) feeds every bundle a test may load: every shard. A module some test
    reaches that names its path without importing it reads it as data, and one that reads files and quotes its
    basename (10 or more characters, outside comments) may read it by a joined path: none of those is an import edge,
    so those readers stand for it as a changed source would (their tests, and the tests importing them). On
    2026-11-21 13Z to 11-22 07Z such reads sent baselines and capture files to all 12 shards. A script only shard 1's
    checks run (package.json scripts, a check's own baseline) needs no other shard: shard 1 always runs.
    """
    rel = f.removeprefix(wa.WEB)
    name = Path(f).name
    importers = selector.graph.importers.get(f, set())
    for source in selector.text:
        if "/" not in source.removeprefix(wa.WEB) and source.endswith(wa.ft.EXTENSIONS) and wa.EVERYTHING.search(source) \
                and (f in selector.closure(source) or rel in selector.text[source]):
            return f"{f} is loaded by the build input {source}", set()
    reached = set().union(*(selector.closure(t) for t in selector.graph.tests))
    reads = set().union(*(selector.closure(t) for t in selector.always)) if selector.always else set()
    quoted = re.compile(r"[\"'`]" + re.escape(name) + r"[\"'`]")
    readers: set[str] = set()
    for source in sorted(reached - importers - {f}):
        text = COMMENT.sub("", selector.text.get(source, ""))
        if rel in text or f in text or source in reads and len(name) >= wa.NAME_MIN and quoted.search(text):
            if not wa.NARROW:
                return f"{f} is read as data by {source}", set()
            readers.add(source)
    return "", readers


def touched(selector: "wa.Selector", files: list[str]) -> tuple[set[str] | None, str]:
    """The tests the change touches directly (repo paths), or None for every shard, and why."""
    out: set[str] = set()
    for f in files:
        if f in selector.preload or (wa.EVERYTHING.search(f) and not HOP.search(f)):
            return None, f"{f} is a build or runner input"
        if wa.EVERYTHING.search(f):
            # A test helper or webviews script (not the preload's): the tests that import it, as for a source, unless a
            # build input loads it or a file reads it as data (below). A file nothing imports or names touches none;
            # shard 1 still runs its whole share.
            why, readers = read_beyond_imports(selector, f)
            if why:
                return None, why
            for source in readers | {f}:
                out |= {source} & selector.graph.tests
                out |= {t for t in selector.graph.importers.get(source, ()) if t in selector.graph.tests}
            continue
        if not f.startswith(wa.WEB):
            continue
        if f in selector.graph.tests:
            out.add(f)
            continue
        if not (selector.root / f).exists() and f.endswith(wa.ft.EXTENSIONS) and not wa.ft.WEB_TEST.search(f):
            # A deleted source: the files that still name it in an import stand for it (a broken one fails the type
            # check, an edited one is in the diff): those that are tests, and the tests importing them.
            namers = selector.deleted_namers(f)
            if namers is None:
                return None, f"{f} was deleted, and a non-code file or a short name may load it"
            out |= {t for t in namers if t in selector.graph.tests}
            out |= {t for n in namers for t in selector.graph.importers.get(n, ()) if t in selector.graph.tests}
            continue
        # One hop: the tests that import the changed file themselves. The whole import closure reached 278 to 1,856
        # tests for one source edit on 2026-11-20's feat-cmux-next commits, every shard every time.
        out |= {t for t in selector.graph.importers.get(f, ()) if t in selector.graph.tests}
    return out, ""


def shard_files(repo: Path, shard: int, count: int, selected: set[str] | None) -> set[str]:
    """SHARD's test files (repo paths), as run-webviews-tests.sh splits them with this environment."""
    env = dict(os.environ, CMUX_WEB_TEST_LIST_ONLY="1", CMUX_WEB_TEST_SHARD=str(shard), CMUX_WEB_TEST_SHARD_COUNT=str(count))
    env.pop("CMUX_WEB_TEST_FILES", None)
    if selected is not None:
        env["CMUX_WEB_TEST_FILES"] = "\n".join(sorted(f.removeprefix(wa.WEB) for f in selected))
    out = subprocess.run(["bash", str(RUNNER)], cwd=repo / "webviews", env=env, capture_output=True, text=True,
                         check=True).stdout
    return {wa.WEB + line for line in out.splitlines() if line}


def sampled_shards(head_sha: str, count: int) -> list[int]:
    """SAMPLE_COUNT shards from 2 to COUNT, the same for one head commit and different across commits."""
    rest = list(range(2, count + 1))
    return sorted(random.Random(head_sha).sample(rest, min(SAMPLE_COUNT, len(rest))))


def pick(repo: Path, base: str, head: str, count: int) -> tuple[list[int], str, dict[int, list[str]]]:
    """The shards to run, why, and for each shard from 2 to N its touched tests (webviews-relative)."""
    everything = list(range(1, count + 1))
    try:
        files = wa.changed(repo, base, head)
    except subprocess.CalledProcessError as err:
        return everything, f"cannot diff {base}..{head} ({err.stderr.strip()})", {}
    selector = wa.Selector(repo)
    sampled_inputs = sorted(f for f in files if SAMPLED.search(f))
    if sampled_inputs and os.environ.get("CI_WEBVIEWS_CI_EDIT_SAMPLE", "1") != "0":
        # The rest of the change decides as it would alone: a build input there still runs every shard.
        direct, why = touched(selector, [f for f in files if not SAMPLED.search(f)])
        if direct is None:
            return everything, why, {}
        head_sha = subprocess.run(["git", "-C", str(repo), "rev-parse", head], capture_output=True, text=True,
                                  check=True).stdout.strip()
        sample = sampled_shards(head_sha, count)
        # The sampled shards run their whole split (the selection is every file for these inputs); touched tests
        # in the other shards past 1 become one job, as below.
        hits = {shard: shard_files(repo, shard, count, None) & direct for shard in everything[1:]
                if direct and shard not in sample}
        hits = {shard: hit for shard, hit in hits.items() if hit}
        own = {}
        if hits:
            own = {min(hits): sorted(f.removeprefix(wa.WEB) for hit in hits.values() for f in hit)}
        why = (f"{', '.join(sampled_inputs)} changed: shard 1 and {SAMPLE_WHY} {','.join(map(str, sample))} of "
               f"{count} (from head {head_sha[:12]})" + (f", and {len(next(iter(own.values())))} touched tests in one job"
                                                          if own else ""))
        return sorted({1, *sample, *own}), why, own
    direct, why = touched(selector, files)
    if direct is None:
        return everything, why, {}
    if not direct:
        return [1], "the change touches no webviews test", {}
    selected, _ = selector.select(files)  # what each shard runs (None: every file), as the shards pick it
    hits = {shard: shard_files(repo, shard, count, selected) & direct for shard in everything[1:]}
    hits = {shard: hit for shard, hit in hits.items() if hit}
    if not hits:
        return [1], f"{len(direct)} touched tests, all in shard 1", {}
    # One job carries every touched test outside shard 1: a dozen files do not need a runner each, and each shard
    # job pays its own checkout, install and engines before its first test. It takes the lowest picked number.
    first = min(hits)
    own = {first: sorted(f.removeprefix(wa.WEB) for hit in hits.values() for f in hit)}
    return [1, first], f"{len(direct)} touched tests, {len(own[first])} outside shard 1 in one job", own


def classes_on() -> bool:
    return os.environ.get("CI_WEBVIEWS_PUSH_CLASSES", "1") != "0"


def full_rule(files: list[str]) -> str:
    """Why the change needs every shard as a FULL path ("" when none is)."""
    for f in files:
        for pattern, why in FULL:
            if pattern.search(f):
                return f"{f} is {why}"
    return ""


def git_show(repo: Path, ref: str, path: str) -> str | None:
    """PATH's text at REF, or None when it is absent or not text (a font or an image is never a comment-only edit)."""
    out = subprocess.run(["git", "-C", str(repo), "show", f"{ref}:{path}"], capture_output=True)
    if out.returncode != 0:
        return None
    try:
        return out.stdout.decode("utf-8")
    except UnicodeDecodeError:
        return None


def strip_comments(text: str, path: str) -> str:
    """TEXT without its comments and blank space, for telling a comment-only edit."""
    if path.endswith(SLASH_COMMENT):
        text = COMMENT.sub("", text)
    else:
        text = re.sub(r"(?m)^\s*#.*$", "", text)
    return re.sub(r"\s+", " ", text).strip()


def changed_lines(before: str, after: str) -> list[str]:
    import difflib
    return [line[1:] for line in difflib.unified_diff(before.splitlines(), after.splitlines(), lineterm="", n=0)
            if line[:1] in "+-" and not line.startswith(("+++", "---"))]


def comment_only(path: str, before: str | None, after: str | None) -> bool:
    """Whether BEFORE to AFTER changes only comments (and blank lines), none of them a tool directive.

    Both checks must hold: every changed line is blank or a comment line, and the text without comments is the same
    (so a `* factor` continuation line, or a `//` inside a string, is never taken for a comment)."""
    if before is None or after is None or before == after:
        return False
    if path.endswith(SLASH_COMMENT):
        markers = ("//", "/*", "*")
    elif path.endswith(HASH_COMMENT):
        markers = ("#",)
    else:
        return False
    for line in changed_lines(before, after):
        stripped = line.strip()
        if stripped and (not stripped.startswith(markers) or DIRECTIVE.search(stripped)):
            return False
    return strip_comments(before, path) == strip_comments(after, path)


def doc_unread(selector: "wa.Selector", f: str) -> bool:
    """Whether F is a doc that no webviews file imports or names (its basename anywhere counts: `./x.md?raw`)."""
    if not DOCS.search(f) or selector.graph.importers.get(f):
        return False
    name = Path(f).name
    return not any(name in text for text in selector.text.values())


def fast_why(repo: Path, selector: "wa.Selector", base: str, head: str, f: str) -> str:
    """Why F alone is a fast-track change ("" when it is not)."""
    if doc_unread(selector, f):
        return f"{f} is a doc no webviews file reads"
    if comment_only(f, git_show(repo, base, f), git_show(repo, head, f)):
        return f"{f} changes only comments"
    return ""


def classify(repo: Path, base: str, head: str, count: int) -> tuple[str, list[int], str, dict[int, list[str]]]:
    """(class, the shards to run, the rule that fired, the touched tests of the one shard past 1)."""
    everything = list(range(1, count + 1))
    try:
        files = wa.changed(repo, base, head)
    except subprocess.CalledProcessError as err:
        return "full", everything, f"cannot diff {base}..{head} ({err.stderr.strip()})", {}
    why = full_rule(files)
    if why:
        return "full", everything, why, {}
    selector = wa.Selector(repo)
    fast = {f: fast_why(repo, selector, base, head, f) for f in files}
    rest = [f for f in files if not fast[f]]
    if not rest:
        shown = "; ".join(fast[f] for f in files[:3]) + (f"; and {len(files) - 3} more" if len(files) > 3 else "")
        return "fast", [1], f"{shown or 'no file changed'}: shard 1's checks, no test file", {}
    direct: set[str] = set()
    wide: list[str] = []
    for f in rest:
        found, reason = touched(selector, [f])
        if found is None:
            wide.append(reason)
        else:
            direct |= found
    if wide:
        head_sha = subprocess.run(["git", "-C", str(repo), "rev-parse", head], capture_output=True, text=True,
                                  check=True).stdout.strip()
        sample = sampled_shards(head_sha, count)
        hits = {shard: shard_files(repo, shard, count, None) & direct for shard in everything[1:]
                if direct and shard not in sample}
        hits = {shard: hit for shard, hit in hits.items() if hit}
        own = {min(hits): sorted(f.removeprefix(wa.WEB) for hit in hits.values() for f in hit)} if hits else {}
        more = f" (and {len(wide) - 1} more)" if len(wide) > 1 else ""
        why = (f"{wide[0]}{more}: shard 1 and {SAMPLE_WHY} {','.join(map(str, sample))} of {count} (from head "
               f"{head_sha[:12]})" + (f", and {len(next(iter(own.values())))} touched tests in one job" if own else ""))
        return "sampled", sorted({1, *sample, *own}), why, own
    if not direct:
        return "sampled", [1], "the change touches no webviews test: shard 1", {}
    selected, _ = selector.select(rest)
    hits = {shard: shard_files(repo, shard, count, selected) & direct for shard in everything[1:]}
    hits = {shard: hit for shard, hit in hits.items() if hit}
    if not hits:
        return "sampled", [1], f"{len(direct)} touched tests, all in shard 1", {}
    first = min(hits)
    own = {first: sorted(f.removeprefix(wa.WEB) for hit in hits.values() for f in hit)}
    return "sampled", [1, first], f"{len(direct)} touched tests, {len(own[first])} outside shard 1 in one job", own


HOW_FULL = ("To run every shard, add the `full-ci` label and re-run. To turn the classes off for every pull request, "
            "set the repository variable `CI_WEBVIEWS_PUSH_CLASSES` to `0`.")


def summary(cls: str, shards: list[int], count: int, why: str) -> str:
    """The step summary's section: the class, the rule that fired, and how to get a full run."""
    head = f"### react-apps-check: {cls or 'pick'}, {len(shards)} of {count} shards ({','.join(map(str, shards))})\n\n"
    return head + f"Rule: {why}.\n" + ("" if cls == "full" else f"\n{HOW_FULL}\n")


def files_of(repo: Path, base: str, head: str, count: int, shards: list[int]) -> list[str]:
    """The test files SHARDS run for BASE..HEAD (webviews-relative), as each splits them."""
    selected, _ = wa.Selector(repo).select(wa.changed(repo, base, head))
    out: set[str] = set()
    for shard in shards:
        out |= shard_files(repo, shard, count, selected)
    return sorted(f.removeprefix(wa.WEB) for f in out)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base")
    ap.add_argument("--head", default="HEAD")
    ap.add_argument("--count", type=int, required=True)
    ap.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    ap.add_argument("--all", action="store_true", help="every shard (a push, full-ci): print the whole matrix")
    ap.add_argument("--files-of", help="comma-separated shards: print the test files they run, one a line")
    ap.add_argument("--direct-out", type=Path,
                    help="write {shard: [touched test files]} for the one picked shard past 1 (JSON)")
    ap.add_argument("--summary", type=Path, help="append the pick to this Markdown file (the job's step summary)")
    ap.add_argument("--class-out", type=Path, help="write the push class (fast, sampled, full) to this file")
    ap.add_argument("--full-why", help="with --all: the rule that ran every shard, for --summary (a push, full-ci)")
    args = ap.parse_args(argv)
    if args.files_of:
        if not args.base:
            ap.error("--base is required with --files-of")
        shards = [int(x) for x in args.files_of.split(",") if x.strip()]
        if not shards or any(not 1 <= x <= args.count for x in shards):
            ap.error(f"--files-of names shards outside 1..{args.count}")
        files = files_of(args.repo, args.base, args.head, args.count, shards)
        print(f"webviews pr shards: {len(files)} test files in shards {args.files_of}", file=sys.stderr)
        sys.stdout.write("".join(f + "\n" for f in files))
        return 0
    if args.all:
        everything = list(range(1, args.count + 1))
        if args.class_out:
            args.class_out.write_text("full\n")
        if args.summary and args.full_why:
            with args.summary.open("a") as out:
                out.write(summary("full", everything, args.count, args.full_why))
        print(matrix(everything, args.count))
        return 0
    if not args.base:
        ap.error("--base is required without --all")
    own: dict[int, list[str]] = {}
    cls = ""
    try:
        if classes_on():
            cls, shards, why, own = classify(args.repo, args.base, args.head, args.count)
        else:
            shards, why, own = pick(args.repo, args.base, args.head, args.count)
    except Exception as err:  # noqa: BLE001 - any failure runs every shard
        cls, shards, why, own = ("full" if classes_on() else ""), list(range(1, args.count + 1)), \
            f"the pick failed ({type(err).__name__}: {err})", {}
    if args.class_out:
        args.class_out.write_text(cls + "\n")
    if args.direct_out:
        # No entry for a shard (an empty map on every-shard picks) runs that shard's whole affected split.
        args.direct_out.write_text(json.dumps({str(k): v for k, v in own.items()}, separators=(",", ":")) + "\n")
    print(f"webviews pr shards: {len(shards)} of {args.count} ({','.join(map(str, shards))}): {why}", file=sys.stderr)
    if args.summary and cls:
        with args.summary.open("a") as out:
            out.write(summary(cls, shards, args.count, why))
    elif args.summary:
        with args.summary.open("a") as out:
            out.write(f"### react-apps-check shards: {len(shards)} of {args.count} ({','.join(map(str, shards))})\n\n{why}.\n")
            if SAMPLE_WHY in why:
                out.write("\nThis run samples shards instead of running all of them. To run every shard, add the "
                          "`full-ci` label and re-run; to turn sampling off for every pull request, set the repository "
                          "variable `CI_WEBVIEWS_CI_EDIT_SAMPLE` to `0`.\n")
    print(matrix(shards, args.count))
    return 0


if __name__ == "__main__":
    sys.exit(main())
