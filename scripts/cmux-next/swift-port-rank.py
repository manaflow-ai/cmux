#!/usr/bin/env python3
"""Swift port rank: which Swift to move to Rust next, and how much of the mirror count a generated binding deletes.

swift-logic-lines.py (method v3) says how many Swift logic and mirror lines are left; this says where they are, ranked,
so the next port batch is picked by the number and not by feel (goal swift-share-falls: 498,729 at 086838234b6 against
a target of 415,007). It is a report: it never blocks anything and always exits 0 unless it cannot read the count.

  python3 -I scripts/cmux-next/swift-port-rank.py --rev SHA              both tables, as Markdown
  python3 -I scripts/cmux-next/swift-port-rank.py --rev SHA --json       one JSON object
  ... --top N (default 20)   --days D (churn window, default 30)   --include-ios (rank iOS-shared Swift too)

iOS-shared: a file in a package that an iOS app compiles (IOS_APPS: ios/CmuxiOS's Package.swift and xcodeproj,
cmux-next-ios's project.yml and CmuxMobileKit, followed through each `.package(path:)` transitively) is marked with the
apps; ios/CmuxiOS links no Rust, so porting such a file breaks that app or counts 0. The (a) tables rank mac-only
files and types by default and the header gives the iOS-shared pure logic and mirror totals.

(a) Port batch. Each counted swift_logic_lines declaration (swift-logic-lines' `--sites swift_logic_lines`: LOGIC and
MIXED rows' logic share, and unlisted declarations) is "pure" when its own lines name no platform API (PLATFORM_TOKENS:
AppKit and SwiftUI types, Core Animation, WebKit, Metal, ScreenCaptureKit, accessibility, CGEvent and CGWindow calls);
a file is pure when it also imports no platform module (PLATFORM_IMPORTS). Pure logic has nothing in it that needs the
Mac, so it can move to Rust whole. The rank is pure logic lines times the file's commits in the last D days at REV (a
file nobody touches costs little to keep; a hot one costs every PR that touches it), then lines. Both a per-file and a
per-type table (a type's extensions in other files fold into it; its churn is the sum of its files', so a commit
that touches two of them counts twice) are printed.

(b) Mirror coverage. Each counted mirror_lines declaration falls in one bucket, by its name (the last component of a
dotted extension name, with a Swift suffix such as Snapshot, Request or Payload also tried without it):
  generated-now   the SDK schema (cmux-tui/spec/sdk-schema.json) has the type, a command or event of that name, or the
                  swift_app bindings (cmux-tui/bindings/codegen/swift_app/bindings.json) name it: the existing
                  generator (DaemonWireTypesPlugin, swift_app/generate.py) can write it, so deleting the hand copy is
                  codegen work only
  schema-first    no schema entry, but a Rust struct or enum of that name exists at REV: add it to the schema, then
                  generate it
  port            a MIRROR or MIXED declaration with neither: a Swift-held copy of state (stores, feeds, caches), which
                  only a port of its owner deletes
The split of a MIXED row is its mirror share, as swift-logic-lines counts it. Name matching is a heuristic (two types
of one name in different crates match); the bucket totals are the planning number, the table's rows say which.

Tests: scripts/cmux-next/tests/test_swift_port_rank.py.
"""

from __future__ import annotations

import argparse
import collections
import importlib.util
import json
import posixpath
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCHEMA = "cmux-tui/spec/sdk-schema.json"
BINDINGS = "cmux-tui/bindings/codegen/swift_app/bindings.json"
PLATFORM_IMPORTS = frozenset({
    "AppKit", "SwiftUI", "Cocoa", "WebKit", "QuartzCore", "Metal", "MetalKit", "CoreText", "CoreImage", "AVFoundation",
    "AVKit", "ScreenCaptureKit", "Carbon", "IOKit", "UserNotifications", "ServiceManagement", "CoreVideo", "CoreMedia",
    "ApplicationServices", "Quartz", "QuickLookUI", "SafariServices", "StoreKit", "LocalAuthentication",
})
PLATFORM_TOKENS = re.compile(
    r"\bNS(?:App|Application|View|Window|Event|Color|Image|Font|Screen|Pasteboard|Workspace|Menu|Cursor|Responder"
    r"|Text(?:View|Field|Storage|Container)|Panel|Alert|Button|BezierPath|Graphics|Animation|Hosting|Layout"
    r"|TrackingArea|Status|Sound|Accessibility|Appearance|Touch|Dragging|Toolbar|Split|Scroll|Table|Outline"
    r"|Collection|Popover|Gesture|Visual|Control|Draggable|Running|Open|Save)\w*"
    r"|\b(?:CA[A-Z][a-z]\w*|WK[A-Z]\w+|MTL\w+|SC(?:Stream|Shareable|Content)\w*|AX[A-Z]\w+|CV[A-Z]\w+"
    r"|CGEvent\w*|CGWindow\w*|CGDisplay\w*)"
    r"|\bsome View\b|@Environment\b|@State\b|@Binding\b|\bBinding<|@FocusState\b|\bGeometryReader\b")
SUFFIXES = ("Snapshot", "Request", "Response", "Result", "Payload", "Params", "Reply", "Body", "Wire", "Record",
            "Event", "DTO", "Info")
# The iOS apps and the manifests their local packages are read from: a package any of them reaches (`.package(path:)`,
# transitively) is iOS-shared, and a port of its Swift must keep the iOS build (ios/CmuxiOS links no Rust).
IOS_APPS = {
    "CmuxiOS": ("ios/CmuxiOS/Package.swift", "ios/cmux-ios.xcodeproj/project.pbxproj"),
    "cmux-next-ios": ("cmux-next-ios/project.yml", "cmux-next-ios/CmuxMobileKit/Package.swift"),
}
_PKG_PATH = re.compile(r'\.package\(\s*(?:name:\s*"[^"]*",\s*)?path:\s*"([^"]+)"')
_PBX_PATH = re.compile(r"relativePath = \"?([^;\"]+)\"?;")
_LABEL = re.compile(r"^(\w+) (\S+) #(\d+): (\d+) of (\d+) lines \((\w+)")
_IMPORT = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*import\s+(?:(?:class|struct|enum|protocol|func|var|let|typealias)\s+)?"
                     r"(\w+)", re.M)
_RUST_TYPE = re.compile(r"\b(?:struct|enum)\s+([A-Z]\w*)")


def _load_counter():
    spec = importlib.util.spec_from_file_location("swift_logic_lines", HERE / "swift-logic-lines.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules["swift_logic_lines"] = mod
    spec.loader.exec_module(mod)
    return mod


def parse_site(path: str, line: int, text: str) -> dict | None:
    m = _LABEL.match(text)
    if not m:
        return None
    kind, name, ordinal, n, span, cls = m.groups()
    module = path.split("/Sources/", 1)[1].split("/", 1)[0] if "/Sources/" in path else "?"
    return {"path": path, "line": line, "kind": kind, "name": name, "ordinal": int(ordinal), "lines": int(n),
            "span": int(span), "class": cls, "module": module}


def type_key(site: dict) -> str:
    """A type and its extensions are one row: `extension Foo.Bar` folds into Foo; file-scope funcs stay per file."""
    if site["kind"] in ("func", "var", "let", "typealias", "main"):
        return f"{site['module']}.{Path(site['path']).name}:{site['name']}"
    return f"{site['module']}.{site['name'].split('.', 1)[0].split('<', 1)[0]}"


def is_pure(text_lines: list[str], site: dict) -> bool:
    body = "\n".join(text_lines[site["line"] - 1: site["line"] - 1 + site["span"]])
    return not PLATFORM_TOKENS.search(body)


def file_imports(text: str) -> set[str]:
    return set(_IMPORT.findall(text))


def pascal(word: str) -> str:
    return "".join(p[:1].upper() + p[1:] for p in re.split(r"[-_.]", word) if p)


def candidates(name: str) -> list[str]:
    last = name.split(".")[-1].split("<", 1)[0]
    out = [last]
    for s in SUFFIXES:
        if last.endswith(s) and len(last) > len(s):
            out.append(last[: -len(s)])
    return out


def schema_names(schema: dict, bindings: dict) -> set[str]:
    names = set(schema.get("types", {}))
    for cmd in schema.get("commands", {}):
        base = pascal(cmd)
        names |= {base, base + "Request", base + "Response", base + "Result", base + "Params"}
    for event in schema.get("events", {}):
        base = pascal(event)
        names |= {base, base + "Event"}
    names |= set(bindings.get("types", {}).values()) | set(bindings.get("types", {}))
    for family in bindings.get("families", {}).values():
        for req in family.get("requests", {}).values():
            if req.get("name"):
                names.add(req["name"])
                names.add(req["name"].removesuffix("Request") + "Response")
        names |= set(family.get("enums", {}))
    return names


def bucket(site: dict, schema: set[str], rust: set[str]) -> str:
    cands = candidates(site["name"])
    if any(c in schema for c in cands):
        return "generated-now"
    if any(c in rust for c in cands):
        return "schema-first"
    return "port"


def manifest_paths(path: str, text: str) -> list[str]:
    """The local package directories one manifest (Package.swift, project.pbxproj, XcodeGen project.yml) names."""
    if path.endswith(".yml"):
        block = re.search(r"^packages:\n((?:[ #].*\n|\n)*)", text, re.M)
        found = re.findall(r"^\s+path:\s*(\S+)", block.group(1), re.M) if block else []
    elif path.endswith(".pbxproj"):
        found = _PBX_PATH.findall(text)
    else:
        found = _PKG_PATH.findall(text)
    base = posixpath.dirname(path)
    if path.endswith(".pbxproj"):  # relative to the folder that holds the .xcodeproj
        base = posixpath.dirname(base)
    return [posixpath.normpath(posixpath.join(base, f)) for f in found]


def ios_packages(repo: "Repo", sha: str) -> dict[str, list[str]]:
    """Each package directory an iOS app compiles, with the apps that reach it (IOS_APPS, followed transitively)."""
    reach = collections.defaultdict(set)
    for app, roots in IOS_APPS.items():
        texts = repo.read(sha, list(roots))
        todo = [d for r in roots if texts.get(r) for d in manifest_paths(r, texts[r])]
        todo += [posixpath.dirname(r) for r in roots if r.endswith("Package.swift") and texts.get(r)]
        seen = set()
        while todo:
            d = todo.pop()
            if d in seen or d.startswith(".."):
                continue
            seen.add(d)
            reach[d].add(app)
            m = f"{d}/Package.swift"
            text = repo.read(sha, [m]).get(m, "")
            todo += manifest_paths(m, text)
    return {d: sorted(a) for d, a in reach.items()}


def ios_of(path: str, packages: dict[str, list[str]]) -> list[str]:
    apps = set()
    for d, a in packages.items():
        if path.startswith(d + "/"):
            apps.update(a)
    return sorted(apps)


class Repo:
    def __init__(self, root: Path):
        self.root = root

    def git(self, *args: str, inp: str | None = None) -> str:
        return subprocess.run(["git", "-C", str(self.root), *args], input=inp, capture_output=True, text=True,
                              check=True).stdout

    def read(self, sha: str, paths: list[str]) -> dict[str, str]:
        """Each PATH's text at SHA, one `git cat-file --batch` for all of them."""
        if not paths:
            return {}
        proc = subprocess.run(["git", "-C", str(self.root), "cat-file", "--batch"],
                              input="".join(f"{sha}:{p}\n" for p in paths).encode(), capture_output=True, check=True)
        out, data, i = {}, proc.stdout, 0
        for p in paths:
            nl = data.index(b"\n", i)
            header = data[i:nl].split()
            if header[-1] == b"missing":
                out[p], i = "", nl + 1
                continue
            size = int(header[2])
            out[p] = data[nl + 1: nl + 1 + size].decode("utf-8", "replace")
            i = nl + 1 + size + 1
        return out

    def churn(self, sha: str, days: int) -> collections.Counter:
        when = self.git("log", "-1", "--format=%ct", sha).strip()
        since = int(when) - days * 86400
        log = self.git("log", f"--since={since}", "--no-renames", "--format=", "--name-only", sha, "--", "*.swift")
        return collections.Counter(p for p in log.splitlines() if p)

    def rust_types(self, sha: str) -> set[str]:
        try:
            out = self.git("grep", "-h", "-o", "-E", r"\b(struct|enum)\s+[A-Z][A-Za-z0-9_]*", sha, "--", "*.rs")
        except subprocess.CalledProcessError:
            return set()
        return set(_RUST_TYPE.findall(out))


def rank(repo: Repo, sha: str, logic_sites, mirror_sites, days: int, top: int, include_ios: bool = False) -> dict:
    logic = [s for s in (parse_site(*x) for x in logic_sites) if s and s["lines"] > 0]
    mirror = [s for s in (parse_site(*x) for x in mirror_sites) if s and s["lines"] > 0]
    paths = sorted({s["path"] for s in logic})
    texts = repo.read(sha, paths)
    churn = repo.churn(sha, days)
    per_file = collections.defaultdict(lambda: {"logic": 0, "pure": 0})
    per_type = collections.defaultdict(lambda: {"logic": 0, "pure": 0, "files": set(), "ios": set()})
    ios_pkgs = ios_packages(repo, sha)
    ios = {p: ios_of(p, ios_pkgs) for p in {s["path"] for s in logic + mirror}}
    platform = {p: sorted(file_imports(texts.get(p, "")) & PLATFORM_IMPORTS) for p in paths}
    for s in logic:
        lines = texts.get(s["path"], "").splitlines()
        pure = not platform[s["path"]] and is_pure(lines, s)
        f, t = per_file[s["path"]], per_type[type_key(s)]
        f["logic"] += s["lines"]
        t["logic"] += s["lines"]
        t["files"].add(s["path"])
        t["ios"].update(ios[s["path"]])
        if pure:
            f["pure"] += s["lines"]
            t["pure"] += s["lines"]
    files = []
    for path, v in per_file.items():
        files.append({"path": path, "logic": v["logic"], "pure": v["pure"], "churn": churn.get(path, 0),
                      "score": v["pure"] * churn.get(path, 0), "platform_imports": platform[path],
                      "ios": ios[path]})
    types = []
    for key, v in per_type.items():
        c = sum(churn.get(p, 0) for p in v["files"])
        types.append({"type": key, "logic": v["logic"], "pure": v["pure"], "churn": c, "score": v["pure"] * c,
                      "files": len(v["files"]), "ios": sorted(v["ios"])})
    order = lambda r: (-r["score"], -r["pure"], r.get("path", r.get("type")))  # noqa: E731
    files.sort(key=order)
    types.sort(key=order)
    ios_pure = sum(f["pure"] for f in files if f["ios"])
    ios_mirror = sum(s["lines"] for s in mirror if ios[s["path"]])
    if not include_ios:
        files = [f for f in files if not f["ios"]]
        types = [t for t in types if not t["ios"]]

    raw = repo.read(sha, [SCHEMA, BINDINGS])
    schema = schema_names(json.loads(raw[SCHEMA] or "{}"), json.loads(raw[BINDINGS] or "{}"))
    rust = repo.rust_types(sha)
    buckets = collections.Counter()
    by_pkg = collections.defaultdict(collections.Counter)
    mirror_rows = []
    for s in mirror:
        b = bucket(s, schema, rust)
        buckets[b] += s["lines"]
        by_pkg[s["module"]][b] += s["lines"]
        mirror_rows.append({**{k: s[k] for k in ("path", "line", "kind", "name", "lines", "class", "module")},
                            "bucket": b, "ios": ios[s["path"]]})
    mirror_rows.sort(key=lambda r: (-r["lines"], r["path"], r["line"]))
    return {
        "method": "swift-port-rank", "sha": sha, "days": days,
        "logic_lines": sum(s["lines"] for s in logic), "mirror_lines": sum(s["lines"] for s in mirror),
        "pure_logic_lines": sum(f["pure"] for f in files) + (0 if include_ios else ios_pure),
        "ios_shared": {"pure_logic_lines": ios_pure, "mirror_lines": ios_mirror,
                       "packages": {d: a for d, a in sorted(ios_pkgs.items())}},
        "ranked_over": "all" if include_ios else "mac-only",
        "files": files[:top], "types": types[:top],
        "mirror": {"buckets": dict(buckets),
                   "packages": {m: dict(c) for m, c in sorted(by_pkg.items(), key=lambda kv: -sum(kv[1].values()))},
                   "top": mirror_rows[:top]},
    }


BUCKETS = ("generated-now", "schema-first", "port")


def markdown(r: dict, top: int) -> str:
    out = [f"swift-port-rank at {r['sha'][:11]} (churn: commits in the {r['days']} days before it)", "",
           f"logic {r['logic_lines']}, of it pure (no platform import or call) {r['pure_logic_lines']}; "
           f"mirror {r['mirror_lines']}", "",
           f"iOS-shared (a package ios/CmuxiOS or cmux-next-ios compiles; a port must keep the iOS build): pure logic "
           f"{r['ios_shared']['pure_logic_lines']}, mirror {r['ios_shared']['mirror_lines']}; ranked over: "
           f"{r['ranked_over']}", "",
           f"(a) top {top} files by pure logic lines x churn", "",
           "| # | file | pure | logic | churn | score | ios |", "|---|---|---|---|---|---|---|"]
    for i, f in enumerate(r["files"], 1):
        out.append(f"| {i} | {f['path'].split('/Sources/')[-1]} | {f['pure']} | {f['logic']} | {f['churn']} | "
                   f"{f['score']} | {', '.join(f['ios']) or 'mac-only'} |")
    out += ["", f"(a) top {top} types (extensions folded) by pure logic lines x churn", "",
            "| # | type | pure | logic | files | churn | score | ios |", "|---|---|---|---|---|---|---|---|"]
    for i, t in enumerate(r["types"], 1):
        out.append(f"| {i} | {t['type']} | {t['pure']} | {t['logic']} | {t['files']} | {t['churn']} | {t['score']} | "
                   f"{', '.join(t['ios']) or 'mac-only'} |")
    b = r["mirror"]["buckets"]
    out += ["", "(b) mirror lines by what deletes them", "",
            "| package | " + " | ".join(BUCKETS) + " | total |", "|---|" + "---|" * (len(BUCKETS) + 1),
            "| **all** | " + " | ".join(str(b.get(k, 0)) for k in BUCKETS) + f" | {sum(b.values())} |"]
    for m, c in list(r["mirror"]["packages"].items())[:top]:
        out.append(f"| {m} | " + " | ".join(str(c.get(k, 0)) for k in BUCKETS) + f" | {sum(c.values())} |")
    out += ["", f"(b) top {top} mirror declarations", "", "| lines | class | bucket | declaration |",
            "|---|---|---|---|"]
    for m in r["mirror"]["top"]:
        out.append(f"| {m['lines']} | {m['class']} | {m['bucket']} | {m['kind']} {m['name']} "
                   f"({m['path'].split('/Sources/')[-1]}:{m['line']}) |")
    return "\n".join(out)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--repo", default=None)
    p.add_argument("--rev", default="HEAD")
    p.add_argument("--top", type=int, default=20)
    p.add_argument("--days", type=int, default=30)
    p.add_argument("--json", action="store_true")
    p.add_argument("--include-ios", action="store_true", help="rank iOS-shared files and types too")
    args = p.parse_args(argv)
    root = Path(args.repo).resolve() if args.repo else Path(subprocess.run(
        ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True).stdout.strip())
    counter = _load_counter()
    found = counter.count(root, args.rev)
    r = rank(Repo(root), found.sha, found.sites["swift_logic_lines"], found.sites["mirror_lines"], args.days, args.top,
             args.include_ios)
    print(json.dumps(r, sort_keys=True) if args.json else markdown(r, args.top))
    return 0


if __name__ == "__main__":
    sys.exit(main())
