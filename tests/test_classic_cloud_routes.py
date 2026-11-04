#!/usr/bin/env python3
"""Classic Cloud route guard: NEXT code adds no new call to classic Cloud.

NEXT's Cloud is built on cmux-platform. Classic Cloud's API (the web app's /api/vm and /api/runs routes, served
from cmux.com or the cmux-staging.vercel.app preview) keeps working for classic customers, but NEXT code
(Packages/macOS/CmuxNext, cmux-tui, webviews) does not add new calls to it. The calls NEXT still makes are
listed in tests/classic-cloud-route-allowlist.json as entries {"file", "pattern", "count", "reason"}; the list
only shrinks.

Patterns (matched in code and string literals; comments, test files, fixtures, mocks, gallery files and Rust
#[cfg(test)] modules are not scanned):

  route:/api/vm         a classic VM route path: "/api/vm", "/api/vm/{id}/exec", `${base}/api/vm/domains`.
  route:/api/runs       a classic Run route path: "/api/runs/{id}/events".
  base:cmux.com         a bare cmux.com origin string ("https://cmux.com", "https://www.cmux.com/") on a line that
                        names an API base (api, base, origin, endpoint, server, backend), the form an API base
                        takes; a browser probe URL, a sample value or an OAuth client_uri does not match. cmux.com with a path (a deeplink, docs, /pair, /whats-new, an auth page,
                        files.cmux.com, /api/hang-reports, /api/models) is not a Cloud API base and never matches.
  base:cmux-staging     the cmux-staging.vercel.app preview, which only ever served classic Cloud's API and auth.

The test fails when a file has a match with no entry, more matches than its entry (a new call), fewer (lower the
count, so the list only shrinks), an entry with no match left (remove it), an unknown pattern, or an entry with no
one-line reason starting "debt: " (a call NEXT still makes until it moves to cmux-platform) or "keep: " (a reviewed
exception). In CI, CMUX_GUARDS_BASE_SHA (or CLASSIC_CLOUD_ROUTES_BASE) names the base commit: an entry added or
raised since that commit's allowlist fails unless its reason starts with "keep: " and says why (a move of an
existing call from Swift to Rust, say, that the same PR or its next step deletes on the other side), so a PR cannot
allowlist a new classic call as debt; and the scanned paths may not shrink.

Run it: python3 tests/test_classic_cloud_routes.py. List the current matches: python3 tests/test_classic_cloud_routes.py --print
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ALLOWLIST = Path(__file__).resolve().parent / "classic-cloud-route-allowlist.json"
SOURCE_SUFFIXES = (".rs", ".ts", ".tsx", ".js", ".mjs", ".cjs", ".swift")
REASON = re.compile(r"(debt|keep): \S[^\n]*$")

PATTERNS = {
    "route:/api/vm": re.compile(r"/api/vm(?![\w-])"),
    "route:/api/runs": re.compile(r"/api/runs(?![\w-])"),
    "base:cmux.com": re.compile(r"""(?<![\w.-])https?://(?:www\.)?cmux\.com/?(?=["'`])"""),
    "base:cmux-staging": re.compile(r"cmux-staging\.vercel\.app"),
}
# A bare cmux.com origin is an API base only when the line names one (apiBase, productionOrigin, API_URL, endpoint,
# server); a browser probe URL, a sample value, a demo tab or an OAuth client_uri is not.
BASE_CONTEXT = re.compile(r"(?i)api|base|origin|endpoint|server|backend")
# Every match needs one of these in its file: a fixed-string git grep narrows the tracked files first.
PREFILTER = ("/api/vm", "/api/runs", "cmux.com", "cmux-staging.vercel.app")

TEST_PART = re.compile(r"^(?:tests?|__tests__|__mocks__|fixtures?|__fixtures__|testdata|test-support|generated|"
                       r"gallery|e2e|mocks?|bench|[A-Za-z0-9]*Tests|[A-Za-z0-9]*TestSupport)$", re.I)
TEST_NAME = re.compile(r"((?:^|[._-])[Mm]ocks?[._-]|^mock[A-Z]|(?:^|[._-])fixtures?[._-]|^tests?\.rs$|_tests?\.rs$|"
                       r"\.test\.|\.spec\.|\.stories\.|\.gallery\.|\.fixture\.|Tests?\.swift$|\.d\.ts$|\.generated\.|"
                       r"_generated\.)")

# ---- source cleanup: blank comments, keep strings ----------------------------------------------------------
STRING_COMMON = r'"""[\s\S]*?"""|"(?:\\.|[^"\\\n])*"'
COMMENT = r"//[^\n]*|/\*[\s\S]*?\*/"
TOKENS = {
    ".rs": re.compile(rf"{STRING_COMMON}|'(?:\\.|[^'\\\n])'|{COMMENT}"),  # a char literal, never a lifetime
    ".swift": re.compile(rf"{STRING_COMMON}|{COMMENT}"),
}
TOKENS_JS = re.compile(rf"{STRING_COMMON}|'(?:\\.|[^'\\\n])*'|`(?:\\.|[^`\\])*`|{COMMENT}")
CFG_TEST = re.compile(r"#\[cfg\(test\)\]\s*(?:#\[[^\]]*\]\s*)*(?:pub(?:\([^)]*\))?\s+)?mod\s+\w+\s*\{")


def spaces(text: str) -> str:
    return re.sub(r"[^\n]", " ", text)


def clean(text: str, suffix: str) -> str:
    """Comments become spaces (newlines kept, so line numbers hold); strings stay, since routes live in them."""
    def one(m: re.Match[str]) -> str:
        t = m.group(0)
        return spaces(t) if t.startswith(("//", "/*")) else t

    code = TOKENS.get(suffix, TOKENS_JS).sub(one, text)
    if suffix != ".rs":
        return code
    # Blank #[cfg(test)] modules, counting braces on a copy with strings blanked too.
    bare = TOKENS[".rs"].sub(lambda m: spaces(m.group(0)), code)
    for m in reversed(list(CFG_TEST.finditer(bare))):
        depth, i = 0, m.end() - 1
        while i < len(bare):
            if bare[i] == "{":
                depth += 1
            elif bare[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        code = code[:m.start()] + spaces(code[m.start():i + 1]) + code[i + 1:]
    return code


def matches(text: str, rel: str) -> dict[str, list[int]]:
    """{pattern: [line, ...]} for one file's source."""
    code = clean(text, Path(rel).suffix)
    out: dict[str, list[int]] = {}
    for name, rx in PATTERNS.items():
        lines = [code.count("\n", 0, m.start()) + 1 for m in rx.finditer(code)
                 if name != "base:cmux.com" or BASE_CONTEXT.search(code, code.rfind("\n", 0, m.start()) + 1, m.start())]
        if lines:
            out[name] = lines
    return out


# ---- the scanned paths -------------------------------------------------------------------------------------
def config(allow: dict) -> dict:
    return allow.get("paths", {})


def in_scope(rel: str, paths: dict) -> bool:
    if not rel.endswith(SOURCE_SUFFIXES):
        return False
    parts = rel.split("/")
    if any(TEST_PART.match(p) for p in parts[:-1]) or TEST_NAME.search(parts[-1]):
        return False
    if any(x in rel for x in paths.get("exclude", [])):
        return False
    return any(rel.startswith(p) for p in paths.get("include", []))


def candidate_files(root: Path, paths: dict) -> list[str]:
    specs = list(paths.get("include", []))
    if not specs:
        return []
    argv = ["git", "-C", str(root), "grep", "-I", "-l", "-z", "-F"]
    for word in PREFILTER:
        argv += ["-e", word]
    argv += ["--", *specs]
    p = subprocess.run(argv, capture_output=True)
    if p.returncode not in (0, 1):
        raise RuntimeError(p.stderr.decode(errors="replace"))
    return sorted(rel for rel in p.stdout.decode().split("\0") if rel and in_scope(rel, paths))


def scan(root: Path, paths: dict) -> dict[tuple[str, str], list[int]]:
    found: dict[tuple[str, str], list[int]] = {}
    for rel in candidate_files(root, paths):
        path = root / rel
        if path.is_symlink() or not path.is_file():
            continue
        try:
            text = path.read_text()
        except (UnicodeDecodeError, OSError):
            continue
        for name, lines in matches(text, rel).items():
            found[(rel, name)] = lines
    return found


# ---- the ratchet -------------------------------------------------------------------------------------------
HOW = ("NEXT code adds no call to classic Cloud (/api/vm, /api/runs, a cmux.com or cmux-staging.vercel.app API base): "
       "build it on cmux-platform's API instead. A call NEXT still makes is an entry in "
       "tests/classic-cloud-route-allowlist.json, and that list only shrinks")


def entries(allow: dict) -> dict[tuple[str, str], dict]:
    return {(e.get("file", ""), e.get("pattern", "")): e for e in allow.get("entries", [])}


def problems(found: dict[tuple[str, str], list[int]], allow: dict) -> list[str]:
    out = []
    listed = entries(allow)
    if len(listed) != len(allow.get("entries", [])):
        out.append("allowlist: an entry (file, pattern) appears twice")
    for key, lines in sorted(found.items()):
        rel, name = key
        n, entry = len(lines), listed.get(key)
        shown = ", ".join(f"L{line}" for line in lines[:8]) + (" ..." if n > 8 else "")
        if entry is None:
            out.append(f"{rel}: {n} new {name} match(es) at {shown}")
        elif n > entry.get("count", 0):
            out.append(f"{rel}: {n} {name} matches, allowlist says {entry.get('count')}: a new call at {shown}")
        elif n < entry.get("count", 0):
            out.append(f"{rel}: {n} {name} matches, allowlist says {entry['count']}: lower the count "
                       f"(the list only shrinks)")
    for key, entry in sorted(listed.items()):
        rel, name = key
        count = entry.get("count")
        if name not in PATTERNS:
            out.append(f"{rel}: unknown pattern {name!r} (one of {', '.join(PATTERNS)})")
        if type(count) is not int or count < 1:
            out.append(f"{rel}: {name}: count must be a positive integer, not {count!r}")
        if key not in found:
            out.append(f"{rel}: {name} is allowlisted but no longer matches; remove its entry")
        if not REASON.match(str(entry.get("reason", ""))):
            out.append(f"{rel}: {name}: give a one-line reason starting \"debt: \" or \"keep: \"")
    return out


def grown(base: dict, allow: dict) -> list[str]:
    """Entries added or raised since the base, and scanned paths that shrank."""
    out = []
    old = entries(base)
    for key, entry in sorted(entries(allow).items()):
        was = old.get(key, {}).get("count", 0)
        if entry.get("count", 0) > was and not str(entry.get("reason", "")).startswith("keep: "):
            out.append(f"{key[0]}: {key[1]} allowlist {was} -> {entry.get('count')} since the base: NEXT code "
                       f"may not add classic Cloud calls (use cmux-platform's API; a reviewed exception, such as a "
                       f"move from Swift to Rust, gives a reason starting \"keep: \")")
    before, after = config(base), config(allow)
    for prefix in before.get("include", []):
        if prefix not in after.get("include", []):
            out.append(f"paths.include: {prefix} was dropped since the base; the scanned paths only grow")
    for x in after.get("exclude", []):
        if x not in before.get("exclude", []):
            out.append(f"paths.exclude: {x} was added since the base; the scanned paths only grow")
    return out


def base_allowlist(root: Path = ROOT) -> dict | None:
    base = (os.environ.get("CLASSIC_CLOUD_ROUTES_BASE") or os.environ.get("CMUX_GUARDS_BASE_SHA") or "").strip()
    if not base or set(base) == {"0"}:
        return None
    if subprocess.run(["git", "-C", str(root), "cat-file", "-e", f"{base}^{{commit}}"], capture_output=True).returncode:
        return None
    p = subprocess.run(["git", "-C", str(root), "show", f"{base}:{ALLOWLIST.relative_to(ROOT).as_posix()}"],
                       capture_output=True, text=True)
    return json.loads(p.stdout) if p.returncode == 0 else None


class ClassicCloudRoutes(unittest.TestCase):
    def test_next_adds_no_classic_cloud_calls(self):
        allow = json.loads(ALLOWLIST.read_text())
        bad = problems(scan(ROOT, config(allow)), allow)
        base = base_allowlist()
        if base is not None:
            bad += grown(base, allow)
        self.assertEqual(bad, [], f"classic Cloud route guard ({HOW}):\n  " + "\n  ".join(bad))

    def test_paths_are_declared(self):
        paths = config(json.loads(ALLOWLIST.read_text()))
        self.assertTrue(paths.get("include"))
        for prefix in paths["include"]:
            with self.subTest(prefix=prefix):
                hits = subprocess.run(["git", "-C", str(ROOT), "ls-files", "--", prefix + "*"],
                                      capture_output=True, text=True).stdout
                self.assertTrue(hits.strip(), f"{prefix} matches no tracked file")


class Matcher(unittest.TestCase):
    def count(self, source: str, rel: str = "Packages/macOS/CmuxNext/Sources/CmuxNextCloud/X.swift") -> dict:
        return {k: len(v) for k, v in matches(source, rel).items()}

    def test_classic_routes_and_bases_are_flagged(self):
        self.assertEqual(self.count('try await send("GET", "/api/vm/\\(id)", as: M.self)'), {"route:/api/vm": 1})
        self.assertEqual(self.count('let u = `${base}/api/runs/${id}/events`;', "webviews/src/a/runApi.ts"),
                         {"route:/api/runs": 1})
        self.assertEqual(self.count('path = "/api/vm"; other = "/api/vm/domains"', "cmux-tui/x/relay.mjs"),
                         {"route:/api/vm": 2})
        self.assertEqual(self.count('static let productionOrigin = URL(string: "https://cmux.com")'),
                         {"base:cmux.com": 1})
        self.assertEqual(self.count("const API = 'https://www.cmux.com/';", "webviews/src/a/api.ts"),
                         {"base:cmux.com": 1})
        self.assertEqual(self.count('let s = URL(string: "https://cmux-staging.vercel.app/api/auth")'),
                         {"base:cmux-staging": 1})

    def test_comments_and_other_cmux_urls_are_not_flagged(self):
        clean_cases = [
            '/// `GET /api/vm`: the machines\nlet x = 1',
            '// calls https://cmux.com\nlet x = 1',
            '/* POST /api/runs */ let x = 1',
            'let docs = "https://cmux.com/docs/cloud"',
            'let pair = "https://cmux.com/pair?c=\\(code)"',
            'let files = URL(string: "https://files.cmux.com/cmux-tui")',
            'let hang = "https://cmux.com/api/hang-reports"',
            'return host == "cmux.com" || host.hasSuffix(".cmux.com")',
            'let vms = "/api/vms-report"',
            'guard let probe = URL(string: "https://cmux.com") else { return nil }',
            '"client_uri": "https://cmux.com",',
            '("cmux.com", "https://cmux.com", "globe"),',
            'let platform = "/v1/machines"',
        ]
        for source in clean_cases:
            with self.subTest(source=source):
                self.assertEqual(self.count(source), {})

    def test_rust_cfg_test_modules_are_skipped(self):
        source = ('const A: &str = "/api/vm";\n#[cfg(test)]\nmod tests {\n    const B: &str = "/api/vm/{x}";\n'
                  '    fn f() { let _ = "}"; }\n}\nconst C: &str = "/api/runs";\n')
        self.assertEqual(matches(source, "cmux-tui/crates/x/src/lib.rs"), {"route:/api/vm": [1], "route:/api/runs": [7]})

    def test_test_and_mock_files_are_out_of_scope(self):
        paths = {"include": ["Packages/macOS/CmuxNext/", "webviews/src/"]}
        self.assertTrue(in_scope("Packages/macOS/CmuxNext/Sources/CmuxNextCloud/API/CloudAPIClient.swift", paths))
        for rel in ("Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/CloudAPIClientRunTests.swift",
                    "webviews/src/agent-session/acpmux/run-board/runApi.test.ts",
                    "webviews/src/agent-session/acpmux/mockFixture.ts",
                    "webviews/src/pages/x/Foo.gallery.ts",
                    "cmux-tui/crates/x/src/lib.rs"):
            with self.subTest(rel=rel):
                self.assertFalse(in_scope(rel, paths))

    def test_the_list_only_shrinks(self):
        allow = {"entries": [{"file": "a.swift", "pattern": "route:/api/vm", "count": 2, "reason": "debt: x"}]}
        self.assertEqual(problems({("a.swift", "route:/api/vm"): [1, 2]}, allow), [])
        self.assertTrue(any("a new call" in p for p in problems({("a.swift", "route:/api/vm"): [1, 2, 3]}, allow)))
        self.assertTrue(any("lower the count" in p for p in problems({("a.swift", "route:/api/vm"): [1]}, allow)))
        self.assertTrue(any("no longer matches" in p for p in problems({}, allow)))
        self.assertTrue(any("new route:/api/runs" in p for p in problems(
            {("a.swift", "route:/api/vm"): [1, 2], ("a.swift", "route:/api/runs"): [4]}, allow)))
        no_reason = {"entries": [{"file": "a.swift", "pattern": "route:/api/vm", "count": 2, "reason": ""}]}
        self.assertTrue(any("one-line reason" in p for p in problems({("a.swift", "route:/api/vm"): [1, 2]}, no_reason)))
        no_reason["entries"][0]["reason"] = "because"
        self.assertTrue(any("one-line reason" in p for p in problems({("a.swift", "route:/api/vm"): [1, 2]}, no_reason)))

    def test_base_ratchet_refuses_growth(self):
        base = {"paths": {"include": ["webviews/src/"]},
                "entries": [{"file": "a.ts", "pattern": "route:/api/runs", "count": 1, "reason": "debt: x"}]}
        same = json.loads(json.dumps(base))
        self.assertEqual(grown(base, same), [])
        raised = json.loads(json.dumps(base))
        raised["entries"][0]["count"] = 2
        self.assertEqual(len(grown(base, raised)), 1)
        added = json.loads(json.dumps(base))
        added["entries"].append({"file": "b.ts", "pattern": "route:/api/vm", "count": 1, "reason": "debt: y"})
        self.assertEqual(len(grown(base, added)), 1)
        added["entries"][-1]["reason"] = "keep: moved from a.ts to Rust; a.ts drops it in the next step"
        self.assertEqual(grown(base, added), [])
        dropped = json.loads(json.dumps(base))
        dropped["paths"]["include"] = []
        self.assertEqual(len(grown(base, dropped)), 1)


def print_matches() -> None:
    allow = json.loads(ALLOWLIST.read_text())
    for (rel, name), lines in sorted(scan(ROOT, config(allow)).items()):
        print(f"{rel}\t{name}\t{len(lines)}\t{','.join(map(str, lines))}")


if __name__ == "__main__":
    if sys.argv[1:] == ["--print"]:
        print_matches()
    else:
        unittest.main()
