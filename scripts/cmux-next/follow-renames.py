#!/usr/bin/env python3
"""Keep path-keyed baselines and every other mention of a CmuxNext source path in step with renames.

About 700 entries in checker baselines, allowlists, route tables and docs name CmuxNext source files by
path (plans/cmux-next/chrome-parity/p11-codebase.md section 2). A `git mv` that leaves one of them behind
either drops an allowance (the checker fails at the new path) or keeps a dead one (the baseline lies).

  follow-renames.py --map moves.json            rewrite every mention of each old path (a JSON list of
                                                [old, new] repository paths, files) in the worktree
  follow-renames.py --from-git A..B             the same for the renames git finds between A and B
  follow-renames.py --check [--rev R] [--base B]...
                                                list the baseline entries (REGISTRY) that name no tracked
                                                file at R; with --base, only those B does not already have.
                                                Exit 1 when there is one, and only then: any other failure (an
                                                unknown revision, a missing object) exits 2.

Path forms it reads and writes, on a path-character boundary: `Packages/macOS/CmuxNext/Sources/T/x`,
`Sources/T/x`, `Tests/TTests/x`, `${sources}/T/x` (after any interpolation), and the bare `T/x` (rewrite only). A whole moved directory is rewritten
as a prefix, so globs under it follow. A glob whose literal folder did not move follows only when every
file it matched moved to one folder; a glob that would split is reported, never guessed. The godfile
ratchet keys Swift types as `Module/Type`: a row follows the file that declares the type.
Generated files (scripts/ci/generated-files.json, the settings schema, docs/mdm, CHANGELOG.md) are never
edited: their generator rewrites them, and the run names them.
"""
from __future__ import annotations

import argparse
import fnmatch
import functools
import json
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

PKG = "Packages/macOS/CmuxNext/"

# Files that key entries by a CmuxNext source path; --check reads these. Add a baseline here when a checker
# starts keying by path.
REGISTRY = (
    "scripts/cmux-next/crash-allowlist.json",
    "scripts/cmux-next/main-actor-work-baseline.json",
    "scripts/localization-debt-baseline.json",
    "scripts/cmux-next/no-swiftui-allowlist.txt",
    "scripts/lint-namespace-types-ratchet.txt",
    "scripts/cmux-next/swift-type-scale-baseline.tsv",
    "scripts/cmux-next/check-menu-actions-baseline.txt",
    "scripts/cmux-next/state-roots-baseline.tsv",
    "scripts/cmux-next/process-scan-baseline.tsv",
    "scripts/cmux-next/env-write-allowlist.json",
    "scripts/cmux-next/invariant-allowlist.json",
    "scripts/cmux-next/godfile-baseline.tsv",
    "scripts/cmux-next/perf-hot-benches.json",
    "scripts/ci/generated-files.json",
    "plans/cmux-next/OWNERS.md",
    "scripts/cmux-next/autofix-areas.sh",
    "scripts/ci/cmux_next_route.py",
    ".github/workflows/cmux-next-motion-golden.yml",
    "scripts/cmux-next/check-crash-safety.sh",
    "scripts/cmux-next/check-no-bench-hooks.sh",
    "scripts/cmux-next/check-ime-input.py",
    "webviews/scripts/pages/gen-strings.mjs",
)
GODFILE = "scripts/cmux-next/godfile-baseline.tsv"
# Never hand-edited (CLAUDE.md): a generator or the release tooling owns them.
GENERATED_NAMED = ("CHANGELOG.md", "settings-schema.json", "settings-schema.sources.sha256")
GENERATED_PREFIXES = ("docs/mdm/",)
GENERATED_JSON = "scripts/ci/generated-files.json"

PATH_CHARS = r"A-Za-z0-9_.\-/$}"
GLOB_CHARS = "*?["
# A path token: on a boundary, the package form or a Sources/Tests form, then path and glob characters.
TOKEN = re.compile(r"(?<![" + PATH_CHARS + r"])((?:" + re.escape(PKG) + r")?(?:Sources|Tests)/(?:[A-Za-z0-9_+\-./*?\[\]]|\\\.)+)")
END = r"(?![A-Za-z0-9_+\-*?\[\\]|\.[A-Za-z0-9])"
# A module-qualified path after an interpolated Sources or Tests folder: `${sources}/CmuxNextApp/x`,
# f"{SOURCES}/CmuxNextBrowser/x" (webviews/scripts/pages/gen-strings.mjs, check-single-omnibar.py).
BRACED = re.compile(r"(?<=\}/)(CmuxNext[A-Za-z0-9_]*/(?:[A-Za-z0-9_+\-./*?\[\]])+)")
# Where a path starts: after a non-path character, an interpolation (`${sources}/`), or a doc's short alias for a
# Sources or Tests folder (`S/CmuxNextApp/x`, `T/CmuxNextAppTests/x`, `APP/`, `SRC/`: one to four capitals).
ALIAS = "|".join(r"(?<=(?<![" + PATH_CHARS + r"])[A-Z]{" + str(n) + r"}/)" for n in range(1, 5))
START = r"(?:(?<![" + PATH_CHARS + r"])|(?<=\}/)|" + ALIAS + r")"
SWIFT_DECL = re.compile(
    r"^(?:(?:@[A-Za-z_]+(?:\([^)]*\))?|public|internal|package|fileprivate|private|final|nonisolated|indirect|open)\s+)*"
    r"(?:class|struct|enum|actor|protocol)\s+([A-Za-z_][A-Za-z0-9_]*)")


class FollowError(Exception):
    """A failure that is not a finding (a git error, a missing object): main() exits 2, never 1."""


def git(repo: Path, *args: str, check: bool = True) -> str:
    done = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
    if check and done.returncode != 0:
        raise FollowError(f"git {' '.join(args)} failed: {done.stderr.strip()}")
    return done.stdout


def strip_token(token: str) -> str:
    """A token without its sentence's full stop and with a regex's escaped dots read as dots."""
    return token.replace("\\.", ".").rstrip(".")


def package_path(token: str) -> str:
    """The repository path a token names (the Sources/Tests forms are relative to the CmuxNext package)."""
    token = strip_token(token)
    return token if token.startswith(PKG) else PKG + token


def is_glob(path: str) -> bool:
    return any(c in path for c in GLOB_CHARS)


def glob_regex(pattern: str) -> re.Pattern:
    """`**` crosses folders, `*` and `?` stay in one, `[...]` is a class (fnmatch's)."""
    out, i = "", 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out += r"(?:[^/]+/)*"
            i += 3
        elif pattern.startswith("**", i):
            out += r".*"
            i += 2
        elif pattern[i] == "*":
            out += r"[^/]*"
            i += 1
        elif pattern[i] == "?":
            out += r"[^/]"
            i += 1
        elif pattern[i] == "[":
            end = pattern.find("]", i + 1)
            if end < 0:
                out += re.escape("[")
                i += 1
            else:
                out += fnmatch.translate(pattern[i:end + 1])[4:-3]
                i = end + 1
        else:
            out += re.escape(pattern[i])
            i += 1
    return re.compile(out + r"/?\Z")


def literal_folder(pattern: str) -> str:
    """The folder part of a glob before its first glob character, with its trailing slash."""
    first = min(pattern.find(c) for c in GLOB_CHARS if c in pattern)
    return pattern[:pattern.rfind("/", 0, first) + 1]


def matches(path: str, files: list[str], folders: set[str]) -> list[str]:
    """The tracked files PATH names: itself, the files under it as a folder, or a glob's matches."""
    if is_glob(path):
        rx = glob_regex(path)
        return [f for f in files if rx.match(f)]
    path = path.rstrip("/")
    if path in folders:
        prefix = path + "/"
        return [f for f in files if f.startswith(prefix)]
    return [path] if path in set(files) else []


def folders_of(files: list[str]) -> set[str]:
    out: set[str] = set()
    for f in files:
        parts = f.split("/")[:-1]
        for i in range(1, len(parts) + 1):
            out.add("/".join(parts[:i]))
    return out


# ---------------------------------------------------------------------------------------------- --check


def stale_tokens(text: str, files: list[str], folders: set[str], fileset: set[str]) -> list[str]:
    found = []
    for m in TOKEN.finditer(text):
        token = strip_token(m.group(1))
        rel = token[len(PKG):] if token.startswith(PKG) else token
        if rel.count("/") < 1 or rel.split("/")[1] == "":
            continue  # `Sources/` alone names no target
        path = package_path(token)
        if is_glob(path):
            if not matches(path, files, folders):
                found.append(token)
        elif path.rstrip("/") not in fileset and path.rstrip("/") not in folders:
            found.append(token)
    for m in BRACED.finditer(text):
        token = strip_token(m.group(1))
        module = token.split("/", 1)[0]
        path = PKG + ("Tests/" if module.endswith("Tests") else "Sources/") + token
        if not matches(path, files, folders):
            found.append(token)
    return found


def stale_godfile(text: str, swift_types: dict[str, set[str]]) -> list[str]:
    found = []
    for line in text.splitlines():
        cols = line.split("\t")
        if len(cols) >= 2 and cols[0] == "swift-type":
            module, _, name = cols[1].partition("/")
            if name not in swift_types.get(module, set()):
                found.append(cols[1])
    return found


def tree_swift_types(repo: Path, rev: str | None, files: list[str]) -> dict[str, set[str]]:
    """Module -> top-level types declared in CmuxNext Sources (the godfile ratchet's swift-type keys)."""
    sources = [f for f in files if f.startswith(PKG + "Sources/") and f.endswith(".swift")]
    out: dict[str, set[str]] = {}
    for f, text in read_many(repo, rev, sources).items():
        module = f[len(PKG + "Sources/"):].split("/", 1)[0]
        out.setdefault(module, set()).update(declared_types(text))
    return out


def declared_types(text: str) -> set[str]:
    return {m.group(1) for line in text.splitlines() if (m := SWIFT_DECL.match(line))}


def read_many(repo: Path, rev: str | None, paths: list[str]) -> dict[str, str]:
    """PATHS' text at REV (the worktree when None); a missing path is left out."""
    if rev is None:
        out = {}
        for p in paths:
            try:
                out[p] = (repo / p).read_text(encoding="utf-8", errors="replace")
            except OSError:
                pass
        return out
    batch = "".join(f"{rev}:{p}\n" for p in paths).encode()
    done = subprocess.run(["git", "-C", str(repo), "cat-file", "--batch"], input=batch, capture_output=True)
    if done.returncode != 0:
        raise FollowError(f"git cat-file --batch at {rev} failed: {done.stderr.decode(errors='replace').strip()}")
    raw = done.stdout
    out, i = {}, 0
    for p in paths:
        nl = raw.find(b"\n", i)
        header = raw[i:nl].split()
        i = nl + 1
        if len(header) < 3 or header[1] != b"blob":
            continue
        size = int(header[2])
        out[p] = raw[i:i + size].decode("utf-8", errors="replace")
        i += size + 1
    return out


def tracked(repo: Path, rev: str | None) -> list[str]:
    if rev is None:
        return [p for p in git(repo, "ls-files", "-z").split("\0") if p and (repo / p).exists()]
    return [p for p in git(repo, "ls-tree", "-r", "-z", "--name-only", rev).split("\0") if p]


def stale_at(repo: Path, rev: str | None) -> dict[str, list[str]]:
    """Registry file -> its entries that name nothing tracked at REV."""
    files = tracked(repo, rev)
    fileset, folders = set(files), folders_of(files)
    texts = read_many(repo, rev, [p for p in REGISTRY if p in fileset])
    out: dict[str, list[str]] = {}
    for path, text in texts.items():
        if path == GODFILE:
            found = stale_godfile(text, tree_swift_types(repo, rev, files))
        else:
            found = stale_tokens(text, files, folders, fileset)
        if found:
            out[path] = sorted(set(found))
    return out


# The first line --check prints before its findings; prepush-gate.py refuses only on exit 1 with this line.
STALE_HEADER = "follow-renames: these baseline entries name no tracked file"


def check(repo: Path, rev: str | None, bases: list[str] | None = None) -> int:
    """Exit status 1 when a registry entry names nothing at REV and at none of BASES (base debt passes)."""
    now = stale_at(repo, rev)
    for base in bases or []:
        before = stale_at(repo, base)
        now = {p: [t for t in tokens if t not in set(before.get(p, []))] for p, tokens in now.items()}
    now = {p: tokens for p, tokens in now.items() if tokens}
    if not now:
        print("follow-renames: every path-keyed baseline entry names a tracked file")
        return 0
    print(STALE_HEADER + " (a rename left them behind; run "
          "scripts/cmux-next/follow-renames.py --from-git <base>..HEAD, or delete the dead entry):")
    for path, tokens in sorted(now.items()):
        for token in tokens:
            print(f"  {path}: {token}")
    return 1


# --------------------------------------------------------------------------------------------- rewrite


@dataclass
class Renames:
    """Old -> new repository paths, files and the folders that moved whole.

    A folder that moved whole into a new folder is in FOLDERS: its spelling is a prefix, so a folder or glob entry
    under it follows. One that moved whole into a folder that already held files is in MERGED instead: there only
    the file entries follow, because the same folder or glob entry at the destination would also cover the files
    that were there before; rewrite_text reports such an entry (Report.widened)."""
    files: dict[str, str]
    before: list[str]  # tracked files before the renames
    folders: dict[str, str] = field(default_factory=dict)
    merged: dict[str, str] = field(default_factory=dict)

    def __post_init__(self) -> None:
        moved = set(self.files)
        candidates: dict[str, str] = {}
        for old, new in self.files.items():
            o, n = old.split("/"), new.split("/")
            # Shared trailing segments give the folder pair this file implies.
            k = 0
            while k < min(len(o), len(n)) - 1 and o[-1 - k] == n[-1 - k]:
                k += 1
            for j in range(1, k + 1):
                fo, fn = "/".join(o[:-j]), "/".join(n[:-j])
                if fo.startswith(PKG) and fo.count("/") >= PKG.count("/") + 1:
                    candidates.setdefault(fo, fn)
                    if candidates[fo] != fn:
                        candidates[fo] = ""
        for fo, fn in candidates.items():
            under = [f for f in self.before if f.startswith(fo + "/")]
            if fn and under and all(f in moved and self.files[f] == fn + f[len(fo):] for f in under):
                there = any(f.startswith(fn + "/") and f not in moved for f in self.before)
                (self.merged if there else self.folders)[fo] = fn

    @functools.cached_property
    def before_folders(self) -> set[str]:
        return folders_of(self.before)

    @functools.cached_property
    def patterns(self) -> tuple[re.Pattern | None, dict[str, str]]:
        return rewrite_pattern(self.pairs())

    @functools.cached_property
    def merged_pattern(self) -> re.Pattern | None:
        merged = [(o, n) for o, n in sorted(self.merged.items(), key=lambda kv: -len(kv[0]))
                  if not any(o.startswith(fo + "/") for fo in self.folders)]
        return rewrite_pattern(merged)[0]

    @functools.cache
    def glob_hits(self, path: str) -> tuple[str, ...]:
        return tuple(matches(path, self.before, self.before_folders))

    def __hash__(self) -> int:
        return id(self)

    def pairs(self) -> list[tuple[str, str]]:
        """Every old path (files and whole folders) with its new path, longest first."""
        both = {**self.folders, **self.files}
        return sorted(both.items(), key=lambda kv: -len(kv[0]))

    def map_path(self, path: str) -> tuple[str | None, str]:
        """(PATH after the renames, how): PATH a file, folder or glob as a package path. how is "moved" (the new
        path), "none" (nothing it names moved), "split" (only some of what it names moved, or to several folders) or
        "widened" (all of it moved, into a folder that already held files the new spelling would cover too)."""
        if path in self.files:
            return self.files[path], "moved"
        for fo, fn in sorted(self.folders.items(), key=lambda kv: -len(kv[0])):
            if path.rstrip("/") == fo or path.startswith(fo + "/"):
                return fn + path[len(fo):], "moved"
        hits = self.glob_hits(path)
        moved = [h for h in hits if h in self.files]
        if not moved:
            return None, "none"
        lit = literal_folder(path) if is_glob(path) else path.rstrip("/") + "/"
        targets = {self.files[h][:len(self.files[h]) - (len(h) - len(lit))] for h in moved
                   if self.files[h].endswith(h[len(lit):])}
        if len(moved) != len(hits) or len(targets) != 1:
            return None, "split"
        new = targets.pop() + path[len(lit):]
        if not is_glob(path) and not path.endswith("/"):
            new = new.rstrip("/")
        if matches(new, self.before, self.before_folders):  # BEFORE holds no moved file's new path
            return None, "widened"
        return new, "moved"


def forms(path: str) -> list[str]:
    """The relative spellings of a package path: `Sources/T/x` and the bare `T/x` (the package form is the
    first with the package prefix, which the pattern allows in front of it)."""
    rel = path[len(PKG):]
    bare = rel.split("/", 1)[1] if "/" in rel else ""
    return [rel] + ([bare] if "/" in bare else [])


def rewrite_pattern(pairs: list[tuple[str, str]]) -> tuple[re.Pattern | None, dict[str, str]]:
    table: dict[str, str] = {}
    for old, new in pairs:
        if not old.startswith(PKG) or not new.startswith(PKG):
            continue
        olds, news = forms(old), forms(new)
        if len(olds) != len(news):
            olds, news = olds[:1], news[:1]
        for o, n in zip(olds, news):
            table.setdefault(o, n)
            # The same path inside a regex (autofix-areas.sh): dots escaped.
            table.setdefault(o.replace(".", "\\."), n.replace(".", "\\."))
    if not table:
        return None, table
    alternation = "|".join(re.escape(k) for k in sorted(table, key=len, reverse=True))
    # Group 3: the rest of the path after a moved folder, so a made-up path under it is left alone.
    rx = re.compile(START + r"(" + re.escape(PKG) + r")?(" + alternation + r")" + END + r"((?:/" + REST + r")?)")
    return rx, table


# The rest of a path: path and glob characters, `${x}` or `{x}` interpolations and `{a,b}` brace lists.
REST = r"(?:[A-Za-z0-9_+\-./*?\[\]$\\]|\{[^{}\s\"'`]*\})*"
# Code that builds a path: `{SRC}`, `{i}`, `${name}`, `$name` (an interpolation has no comma; a brace list does).
INTERPOLATED = re.compile(r"\{[^{},]*\}|\$")
# A path with one `{a,b,...}` brace list, in any spelling the rewrite reads (package, Sources/Tests, bare `T/x`).
BRACE_LIST = re.compile(START + r"((?:" + re.escape(PKG) + r")?(?:(?:Sources|Tests)/)?CmuxNext[A-Za-z0-9_]*/"
                        r"[A-Za-z0-9_+\-./*?]*\{[^{}\s,\"'`]*(?:,[^{}\s,\"'`]*)+\}[A-Za-z0-9_+\-./*?]*)(?!\{)")


def synthesized(rest: str) -> bool:
    """Whether REST (the path after a moved folder) is built by code: a test's `{SRC}/CmuxNextApp/Handlers/Moved{i}.swift`
    names a fixture file, not the folder's, and keeps its spelling. A literal path under a moved folder follows it,
    a planned file in a spec too, and so does a brace list (`Handlers/{A,B}.swift`): the whole folder moved."""
    return bool(INTERPOLATED.search(rest))


@dataclass
class Report:
    edited: dict[str, int] = field(default_factory=dict)  # file -> replacements
    split_globs: list[str] = field(default_factory=list)
    generated: list[str] = field(default_factory=list)
    godfile_rows: list[str] = field(default_factory=list)
    widened: list[str] = field(default_factory=list)  # folder or glob entries a merge into a held folder would widen

    def as_dict(self) -> dict:
        return {"edited": self.edited, "split_globs": self.split_globs, "generated": self.generated,
                "godfile_rows": self.godfile_rows, "widened": self.widened}

    def note(self, kind: list[str], line: str) -> None:
        if line not in kind:
            kind.append(line)


def spelled_like(token: str, path: str) -> str:
    """Package path PATH in TOKEN's spelling: the package form, `Sources/T/x`, or the bare `T/x`."""
    if token.startswith(PKG):
        return path
    rel = path[len(PKG):]
    return rel if token.startswith(("Sources/", "Tests/")) else rel.split("/", 1)[1]


def token_path(token: str) -> str:
    """The package path of a token in any spelling (a bare `TTests/x` is under Tests/)."""
    if token.startswith((PKG, "Sources/", "Tests/")):
        return package_path(token)
    module = token.split("/", 1)[0]
    return PKG + ("Tests/" if module.endswith("Tests") else "Sources/") + strip_token(token)


def follow_globs(text: str, renames: Renames, source: str, report: Report) -> str:
    """Globs whose literal folder did not move whole: follow only when all their matches moved to one folder that
    held none of them before. A glob mostly about the moved files (at least half of its matches) that would split is
    reported; a broader one (`CmuxNextApp/**`) keeps naming what stays, and the moved files leave it as they leave
    the App. A glob whose new spelling would also cover files already at the destination is reported (widened)."""
    out, last = [], 0
    for m in TOKEN.finditer(text):
        token = strip_token(m.group(1))
        path = package_path(token)
        if not is_glob(path):
            continue
        lit = literal_folder(path)
        if any(lit.startswith(fo + "/") for fo in renames.folders):
            continue  # the literal pass rewrites the folder
        new, how = renames.map_path(path)
        if how == "moved" and new:
            out.append(text[last:m.start(1)] + spelled_like(token, new))
            last = m.start(1) + len(token)
            report.edited[source] = report.edited.get(source, 0) + 1
        elif how == "widened":
            report.note(report.widened, f"{source}: {token}")
        elif how == "split":
            hits = renames.glob_hits(path)
            moved = [h for h in hits if h in renames.files]
            if len(moved) * 2 >= len(hits):
                report.note(report.split_globs, f"{source}: {token} (matched {len(hits)}, {len(moved)} moved)")
    out.append(text[last:])
    return "".join(out)


def follow_brace_lists(text: str, renames: Renames, source: str, report: Report) -> str:
    """`T/{A,B}/` and `T/X/{A*,B}.swift` entries (WORK.tsv, specs): each expansion is mapped like a path or glob. They
    follow when every expansion moved under one new prefix; when only some moved, the entry is reported (split)."""
    out, last = [], 0
    for m in BRACE_LIST.finditer(text):
        token = m.group(1)
        open_, close = token.index("{"), token.index("}")
        prefix, alts, suffix = token[:open_], token[open_ + 1:close].split(","), token[close + 1:]
        mapped = [renames.map_path(token_path(prefix + alt + suffix)) for alt in alts]
        hows = {how for _, how in mapped}
        if hows == {"none"}:
            continue
        if hows == {"moved"}:
            # The new prefix, when every expansion is it + the same alternative + the same suffix.
            heads = {new[:len(new) - len(alt + suffix)] if new and new.endswith(alt + suffix) else None
                     for (new, _), alt in zip(mapped, alts)}
            head = heads.pop() if len(heads) == 1 else None
            if head:
                out.append(text[last:m.start(1)] + spelled_like(token, head) + token[open_:])
                last = m.end(1)
                report.edited[source] = report.edited.get(source, 0) + 1
                continue
        # Some alternatives stay or went apart: a split, for review. All moved, but one would widen at the destination:
        # widened.
        kind = report.widened if "widened" in hows and hows <= {"moved", "widened"} else report.split_globs
        report.note(kind, f"{source}: {token} ({sum(how != 'none' for _, how in mapped)} of {len(alts)} moved)")
    out.append(text[last:])
    return "".join(out)


def rewrite_text(text: str, renames: Renames, source: str, report: Report) -> str:
    text = follow_brace_lists(text, renames, source, report)
    text = follow_globs(text, renames, source, report)
    rx, table = renames.patterns
    count = 0

    def sub(m: re.Match) -> str:
        nonlocal count
        old, rest = m.group(2), m.group(3)
        if rest and synthesized(rest):
            return m.group(0)
        count += 1
        return (m.group(1) or "") + table[old] + rest

    out = rx.sub(sub, text) if rx is not None else text
    if count:
        report.edited[source] = report.edited.get(source, 0) + count
    if renames.merged_pattern is not None:
        # A folder that merged into a held one: its own spelling stays, for review (its files followed above).
        for m in renames.merged_pattern.finditer(out):
            if not (m.group(3) and synthesized(m.group(3))):
                report.note(report.widened, f"{source}: {m.group(0)}")
    return out


def rewrite_godfile(text: str, renames: Renames, repo: Path, report: Report) -> str:
    """`swift-type Module/Type` rows follow the moved file that declares the type."""
    moved_types: dict[tuple[str, str], str] = {}
    for old, new in renames.files.items():
        if not (old.startswith(PKG + "Sources/") and new.startswith(PKG + "Sources/") and new.endswith(".swift")):
            continue
        src_module = old[len(PKG + "Sources/"):].split("/", 1)[0]
        dst_module = new[len(PKG + "Sources/"):].split("/", 1)[0]
        if src_module == dst_module:
            continue
        try:
            body = (repo / new).read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for name in declared_types(body):
            moved_types[(src_module, name)] = dst_module
    lines = text.splitlines(keepends=True)
    for i, line in enumerate(lines):
        cols = line.split("\t")
        if len(cols) >= 2 and cols[0] == "swift-type":
            module, _, name = cols[1].partition("/")
            if (module, name) in moved_types:
                cols[1] = f"{moved_types[(module, name)]}/{name}"
                report.godfile_rows.append(f"{module}/{name} -> {cols[1]}")
                lines[i] = "\t".join(cols)
    if report.godfile_rows:
        report.edited[GODFILE] = report.edited.get(GODFILE, 0) + len(report.godfile_rows)
    return "".join(lines)


def keep_order(old: str, new: str, path: str) -> str:
    """A sorted baseline stays sorted: line files by their data lines, JSON that reproduces with sort_keys."""
    if new == old:
        return new
    if path.endswith((".txt", ".tsv")):
        lines = old.splitlines(keepends=True)
        head = 0
        while head < len(lines) and (lines[head].startswith("#") or not lines[head].strip()):
            head += 1
        data = lines[head:]
        if data and all(not ln.startswith("#") and ln.strip() for ln in data) and data == sorted(data):
            new_lines = new.splitlines(keepends=True)
            if new_lines and not new_lines[-1].endswith("\n"):
                new_lines[-1] += "\n"
            out = new_lines[:head] + sorted(new_lines[head:])
            text = "".join(out)
            return text if new.endswith("\n") else text.rstrip("\n")
        return new
    if path.endswith(".json"):
        try:
            parsed = json.loads(old)
        except ValueError:
            return new
        for indent in (1, 2, 4):
            dumped = json.dumps(parsed, indent=indent, sort_keys=True, ensure_ascii=False)
            if old in (dumped, dumped + "\n"):
                tail = "\n" if old.endswith("\n") else ""
                return json.dumps(json.loads(new), indent=indent, sort_keys=True, ensure_ascii=False) + tail
    return new


def leftovers(repo: Path, renames: Renames, skip: list[str]) -> list[str]:
    """`file:line: text` for each line that still spells a moved path the rewrite follows (SKIP: generated files)."""
    out = []
    for path in mentioning(repo, renames):
        if path in skip or not (repo / path).is_file():
            continue
        text = (repo / path).read_text(encoding="utf-8", errors="surrogateescape")
        lines, probe = text.splitlines(), Report()
        if path == GODFILE or rewrite_text(text, renames, path, probe) == text:
            continue
        for number, line in enumerate(lines, 1):
            if rewrite_text(line, renames, path, Report()) != line:
                out.append(f"{path}:{number}: {line.strip()[:160]}")
    return out


def generated_globs(repo: Path) -> list[str]:
    try:
        data = json.loads((repo / GENERATED_JSON).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    globs = list(data.get("conventions", []))
    for gen in data.get("generators", []):
        globs += gen.get("outputs", [])
    return globs


def is_generated(path: str, globs: list[str]) -> bool:
    if Path(path).name in GENERATED_NAMED or path.startswith(GENERATED_PREFIXES):
        return True
    return any(glob_regex(g).match(path) for g in globs)


def mentioning(repo: Path, renames: Renames) -> list[str]:
    """Tracked text files that mention any old path in any spelling, a folder that merged into a held one, or a brace
    list (`T/{A,B}`) in a folder an old path is under."""
    needles = set()
    for old in [o for o, _ in renames.pairs()] + list(renames.merged):
        if not old.startswith(PKG):
            continue
        needles.update(forms(old))
        parts = old[len(PKG):].split("/")  # Sources, the module, then its folders
        needles.update("/".join(parts[1:i]) + "/{" for i in range(2, len(parts)))
    if not needles:
        return []
    args = ["grep", "-l", "-I", "-F"]
    for needle in sorted(needles):
        args += ["-e", needle]
    return [p for p in git(repo, *args, check=False).splitlines() if p]


def apply(repo: Path, renames: Renames) -> Report:
    report = Report()
    globs = generated_globs(repo)
    candidates = set(mentioning(repo, renames)) | {p for p in REGISTRY if (repo / p).is_file()}
    for path in sorted(candidates):
        if not (repo / path).is_file():
            continue
        text = (repo / path).read_text(encoding="utf-8", errors="surrogateescape")
        if path == GODFILE:
            new = rewrite_godfile(text, renames, repo, report)
        elif is_generated(path, globs) and path != GENERATED_JSON:
            new = rewrite_text(text, renames, path, Report())
            if new != text:
                report.generated.append(path)
            continue
        else:
            new = keep_order(text, rewrite_text(text, renames, path, report), path)
        if new != text:
            (repo / path).write_text(new, encoding="utf-8", errors="surrogateescape")
    return report


def renames_from_git(repo: Path, span: str) -> dict[str, str]:
    base, _, head = span.partition("..")
    out = git(repo, "diff", "--name-status", "-z", "-M", base, head or "HEAD")
    parts = out.split("\0")
    pairs, i = {}, 0
    while i < len(parts) and parts[i]:
        status = parts[i]
        if status.startswith("R"):
            pairs[parts[i + 1]] = parts[i + 2]
            i += 3
        else:
            i += 2 if not status.startswith("C") else 3
    return pairs


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", type=Path, default=None, help="repository root (default: this checkout)")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="list baseline entries that name no tracked file")
    mode.add_argument("--map", type=Path, help="JSON list of [old, new] repository paths to follow")
    mode.add_argument("--from-git", metavar="A..B", help="follow the renames git finds between A and B")
    mode.add_argument("--list", action="store_true", help="print the path-keyed files --check reads")
    parser.add_argument("--rev", help="--check: the commit to read (default: the worktree)")
    parser.add_argument("--base", action="append", help="--check: report only entries this commit does not already "
                        "have stale (repeatable: a merged upstream head is a base too)")
    parser.add_argument("--json", action="store_true", help="rewrite: print the report as JSON")
    args = parser.parse_args(argv)
    try:
        return run(args)
    except Exception as error:  # exit 1 means stale entries (check()); any failure is 2, so a caller never reads it as one
        print(f"follow-renames: failed ({type(error).__name__}: {error})", file=sys.stderr)
        return 2


def run(args: argparse.Namespace) -> int:
    repo = args.repo or Path(git(Path(__file__).resolve().parent, "rev-parse", "--show-toplevel").strip())
    if args.list:
        print("\n".join(REGISTRY))
        return 0
    if args.check:
        return check(repo, args.rev, args.base)
    if args.map:
        pairs = dict(json.loads(args.map.read_text(encoding="utf-8")))
        base = None
    else:
        pairs = renames_from_git(repo, args.from_git)
        base = args.from_git.partition("..")[0]
    after = tracked(repo, None)
    before = sorted((set(after) - set(pairs.values())) | set(pairs)) if base is None else tracked(repo, base)
    report = apply(repo, Renames(pairs, before))
    if args.json:
        print(json.dumps(report.as_dict(), indent=2, sort_keys=True))
    else:
        print_report(report)
    return 0


def print_report(report: Report) -> None:
    for path, count in sorted(report.edited.items()):
        print(f"follow-renames: {path}: {count} path(s) rewritten")
    for row in report.godfile_rows:
        print(f"follow-renames: godfile row {row}")
    for glob in report.split_globs:
        print(f"follow-renames: WARNING glob only partly moved, edit it by hand: {glob}")
    for entry in report.widened:
        print(f"follow-renames: WARNING the destination folder already holds files, so this entry would cover them "
              f"too; review it by hand: {entry}")
    for path in report.generated:
        print(f"follow-renames: generated, regenerate it (not hand-edited): {path}")


if __name__ == "__main__":
    sys.exit(main())
