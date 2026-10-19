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

The default check needs only git and bun and runs none of the head's code:
the head's web/ is extracted with `git archive` (the commit must exist
locally: `git fetch origin pull/N/head`), macro import attributes are
stripped from that copy (bun runs macros while bundling), and the head's
bunfig.toml is read as data, never handed to bun.

--coverage RUNS THE HEAD'S TEST CODE on this machine, with this checkout's
web/node_modules. Use it only on commits you trust; web_test_verdict.py
refuses it for fork pull requests. bun gets an environment without tokens
or secrets and a throwaway HOME, which limits but does not sandbox it.

What it cannot see, and says so in its output: a test that reads a file at
run time (fs, fetch, spawn), import() of a computed path, `mock.module()`
targets, and deleted files (gone at the head, so outside any graph).
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
    """Head-side line numbers the diff adds or changes in one file."""
    out = str(git(repo, "diff", "-U0", f"{base}...{head}", "--", path))
    lines: set[int] = set()
    for line in out.splitlines():
        if found := HUNK.match(line):
            start, count = int(found["start"]), int(found["count"] or 1)
            lines.update(range(start, start + count))
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
    data = tomllib.loads(config.read_text())
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


# `import x from "./m" with { type: "macro" }` runs m at bundle time, and bun
# 1.3's `--no-macros` does not stop it, so the extracted copy loses the
# attribute and the macro is bundled like any other import.
MACRO_ATTRIBUTE = re.compile(r"""\s*(?:with|assert)\s*\{\s*type\s*:\s*["']macro["']\s*,?\s*\}""")
SOURCE = re.compile(r"\.[cm]?[jt]sx?$")
SECRET_ENV = re.compile(r"TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|AUTH|KEY|^GH_|^GITHUB_|^AWS_|^NPM_", re.IGNORECASE)


def neutralize_macros(web_root: Path) -> list[str]:
    """Strip macro import attributes from every source file in the extracted copy; the files changed."""
    changed = []
    for path in web_root.rglob("*"):
        if not path.is_file() or not SOURCE.search(path.name):
            continue
        text = path.read_text(errors="replace")
        if "macro" not in text:
            continue
        stripped = MACRO_ATTRIBUTE.sub("", text)
        if stripped != text:
            path.write_text(stripped)
            changed.append(str(path.relative_to(web_root)))
    return sorted(changed)


def scrubbed_env(home: Path) -> dict[str, str]:
    """The environment for bun, without credentials and with a throwaway HOME."""
    env = {k: v for k, v in os.environ.items() if not SECRET_ENV.search(k)}
    env["HOME"] = str(home)
    home.mkdir(parents=True, exist_ok=True)
    return env


def bundle(web_root: Path, entries: Iterable[str], outdir: Path) -> dict:
    """bun's metafile for the entries, packages external."""
    meta = outdir / "meta.json"
    cmd = ["bun", "build", *entries, "--target=bun", "--packages=external",
           f"--outdir={outdir / 'out'}", f"--metafile={meta}"]
    result = subprocess.run(cmd, cwd=web_root, capture_output=True, text=True, env=scrubbed_env(outdir / "home"))
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


def run_coverage(web_root: Path, test: str, outdir: Path) -> dict[str, dict[int, int]]:
    cmd = ["bun", "test", "--isolate", "--coverage", "--coverage-reporter=lcov",
           f"--coverage-dir={outdir}", test]
    # This runs the head's code. web_test_verdict.py refuses it for fork PRs;
    # the credentials stay out of its environment either way.
    result = subprocess.run(cmd, cwd=web_root, capture_output=True, text=True, env=scrubbed_env(outdir / "home"))
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
          coverage: bool = False) -> dict:
    """The import-graph report for one test against base...head (or an explicit changed list)."""
    test = test_path(test)
    if changed is None:
        if not base:
            raise SystemExit("give --base or --changed")
        changed = changed_files(repo, base, head)
    head_sha = str(git(repo, "rev-parse", f"{head}^{{commit}}")).strip()
    deleted = deleted_files(repo, base, head) if base else []
    with tempfile.TemporaryDirectory(prefix="test-touches-diff-") as tmp:
        work = Path(tmp)
        # Always a copy of the commit: the bundle may then be edited (macros), and a dirty
        # checkout never stands in for the head.
        web_root = extract_web(repo, head_sha, work)
        rel_test = test[len(WEB) + 1:]
        if not (web_root / rel_test).exists():
            raise SystemExit(f"{test} does not exist at {head_sha[:12]}")
        entries = [rel_test, *[p for p in preloads(web_root) if (web_root / p).exists()]]
        neutralized = neutralize_macros(web_root)
        # The preloads are read above as data; bun build never sees the head's bunfig.
        config = web_root / "bunfig.toml"
        parked = work / "bunfig.toml.parked"
        if config.exists():
            config.rename(parked)
        meta = bundle(web_root, entries, work)
        if parked.exists():
            parked.rename(config)
        edges, sizes = graph(meta, web_root)
        hits = None
        lines = None
        if coverage:
            if web_root != repo / WEB and (repo / WEB / "node_modules").is_dir():
                (web_root / "node_modules").symlink_to((repo / WEB / "node_modules").resolve())
            if (web_root / "package.json").exists() and not (web_root / "node_modules").exists():
                raise SystemExit("--coverage needs web/node_modules (run `bun install` in web/)")
            hits = run_coverage(web_root, rel_test, work / "coverage")
            lines = None
            if base:
                lines = {}
                for p in changed:
                    source = web_root / p[len(WEB) + 1:] if p.startswith(f"{WEB}/") else None
                    code = code_lines(source.read_text(errors="replace")) if source and source.exists() else None
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
        "macros_neutralized": neutralized,
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
    if report.get("macros_neutralized"):
        lines.append(f"  macro imports bundled without running: {', '.join(report['macros_neutralized'][:5])}")
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
    parser.add_argument("--repo", type=Path, default=None)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    if shutil.which("bun") is None:
        raise SystemExit("bun is not on PATH")
    repo = args.repo or Path(str(git(Path.cwd(), "rev-parse", "--show-toplevel")).strip())
    if args.coverage:
        print("--coverage runs the head's test code on this machine; use it only on trusted commits.",
              file=sys.stderr)
    report = check(repo, args.test, args.base, args.head, changed=args.changed, coverage=args.coverage)
    print(json.dumps(report, indent=2) if args.json else render(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
