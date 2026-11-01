#!/usr/bin/env python3
"""Fails when the cmux-next app references a daemon capability no same-tree daemon can serve.

check-daemon-capabilities.sh starts the bundled cmux-tui and checks that it
serves every capability in DaemonCapability.required and .optional
(plans/cmux-next/daemon-capabilities.json). That export is generated from the
Swift lists (and the base autofix can rewrite it), so a capability the app gates
on through another constant (`Foo.capability`,
`"session-journal-v1"` in a `supports(...)` call) was never checked: when the
daemon dropped or renamed it, the feature went dark with no red build. This
check closes that gap from the source, with no build. check-daemon-capabilities.sh
runs it first (every non-Release app bundle phase, the cmux-next package job,
nightly and release); the cmux-next lanes' push guard runs it too.

It reads every Swift file under Packages/macOS/CmuxNext/Sources and collects the
capability references:
  gate sites      `supports(X)`, `require(X)`, `requires: X` and every
                  `let <name>Capability = "..."` / `let capability = "..."`
                  constant (the app turns a feature on or off with them)
  refusal sites   `needsDaemonCapability(X)` (an action bound unavailable or
                  refused with "not available in this version" or "restart to
                  update")
  the list        every case of `enum DaemonCapability` (DaemonEndpoint.swift), read with
                  check-daemon-capabilities-fresh.py's parser, which also gives the lists
X resolves when it is a string literal, `DaemonCapability.NAME.rawValue` (or
`DaemonCapability.NAME`), `Self.NAME`, `Type.NAME` or a bare constant of the
enclosing type; other expressions forward a value from elsewhere and are not
references. Named gaps: values passed through variables, tuples or arrays
(`supports(docks)`), `capabilities.contains(...)`, and constants initialized
from another constant are not followed; the DaemonCapability lists plus the
identify probe still cover those that use a DaemonCapability case.

It reads every Rust file of cmux-tui-core (the crate whose `identify`
advertises the daemon's capabilities) and of the cmux-tui crates it depends on
directly, and collects the capability strings it
defines: `const|static *CAPABILIT*: &str = "..."` and the string literals in
server/capabilities.rs.

Rules (each violation names the file and line):
  1. A capability the daemon source defines that the app references must be in
     DaemonCapability.required or .optional, so check-daemon-capabilities.sh
     proves the bundled binary serves it (and RefusalStrings says "restart to
     update" for an older daemon). CONDITIONAL lists the few the daemon serves
     only beside a sidecar binary.
  2. A capability the daemon source does not define may appear only at a
     refusal site (a feature not built yet, shown as "not available in this
     version"), in DaemonCapability.unservedByBundledDaemon, in PEERS (a
     capability of another server, not cmux-tui), or in the bundled acpmux's own
     capability list (ACPMUX_LIST: the ids its `initialize` advertises in
     `_meta.acpmux.capabilities`, read from the same tree, so a gate on a name
     acpmux does not define still fails). At a gate site it is the
     error class P10 forbids: the feature waits for a capability the bundled
     daemon never serves.
  3. An unservedByBundledDaemon entry the daemon source now defines moves to
     optional.
  4. A capability is a case of DaemonCapability: a static of the catalog type (in
     DaemonEndpoint.swift or an extension in any file) that is or may be a String
     (stored or computed, typed String or untyped, or a func returning one) is in
     no list, so the export, check-daemon-capabilities.sh and DaemonCompatibility
     never see it, and the gate APIs take any String, so it compiles at a gate.
     check-daemon-capabilities-fresh.py's catalog_strays finds them for both checks.
     A stopgap with known gaps (a static in a type nested in an extension, a
     `typealias` of String, a brace in a string literal of the catalog body, a
     two-part name such as `DaemonCapability.More.orphan` at a gate): the fix is
     typed gates (architecture-refactor-DESIGN.md slice B6), which deletes this
     rule and catalog_strays.

Usage: check-app-capability-references.py [--repo ROOT] [--list]
  --list prints every reference (capability, kind, file:line) and exits 0.
"""
from __future__ import annotations

import argparse
import importlib.util
import re
import sys
from dataclasses import dataclass
from pathlib import Path

# The catalog parser shared with the export's freshness check (one way to read the lists).
_FRESH = importlib.util.spec_from_file_location(
    "check_daemon_capabilities_fresh", Path(__file__).resolve().parent / "check-daemon-capabilities-fresh.py")
fresh = importlib.util.module_from_spec(_FRESH)
_FRESH.loader.exec_module(fresh)
CATALOG = "DaemonCapability"

SWIFT_ROOT = "Packages/macOS/CmuxNext/Sources"
RUST_ROOT = "cmux-tui/crates/cmux-tui-core/src"
# identify's list: its string literals are capabilities too ("attach-identity-v1").
RUST_LIST = "cmux-tui/crates/cmux-tui-core/src/server/capabilities.rs"
ENDPOINT = "Packages/macOS/CmuxNext/Sources/CmuxNextDaemon/Connection/DaemonEndpoint.swift"
# The bundled acpmux's capability list: the `id: "..."` of each entry, which its `initialize` advertises.
ACPMUX_LIST = "cmux-tui/crates/acpmux/src/capabilities.rs"

# Served by cmux-tui only under a host condition (a sidecar binary beside it,
# or a cmux Cloud host), so the isolated identify probe of
# check-daemon-capabilities.sh cannot require it.
CONDITIONAL = {
    "apps-v1": "only with cmux-app-host beside the binary (cmux-tui-core apps.rs advertised())",
    "fs-v1": "only on a cmux Cloud host: a root-owned image stamp and the model plane identity (cmux-tui link/cloud_fs.rs)",
    "agent-session-start-owner-cloud-v1": "only on a cmux Cloud VM with no team evidence (cmux-tui-core server/capabilities.rs serves_owner_cloud_start)",
}

# Capabilities of other servers that the app gates on with the same helpers.
PEERS = {
    "serve.owner-pid": "the computer-use helper's manifest (CuaHelperManifestReader)",
    "serve.motion": "the computer-use helper's manifest (CuaHelperManifestReader)",
    "optchat-chief-brain": "the cloud pairing server (CloudPairingSource)",
    "daemon_lane.v1": "the iOS client's mobile host info (MobileCompatHostInfo)",
}

GATE, REFUSAL, LISTED = "gate", "refusal", "listed"
TYPE_DECL = re.compile(r"\b(?:struct|enum|class|actor|extension|protocol)\s+(?!(?:func|var|let|subscript|init)\b)([A-Za-z_][\w.]*)[^{;]*\{")
CONSTANT = re.compile(r'\blet\s+([A-Za-z_]\w*)\s*(?::\s*String\s*)?=\s*"([^"\\]*)"')
CALLS = (
    (re.compile(r"\bsupports\(\s*([^()]*?)\s*\)"), GATE),
    (re.compile(r"\brequire\(\s*([^(),]*?)\s*[,)]"), GATE),
    (re.compile(r"\brequires:\s*([^,()\[\]]+?)\s*[,)]"), GATE),
    (re.compile(r"\bneedsDaemonCapability\(\s*([^()]*?)\s*\)"), REFUSAL),
)
CALL_NAMES = {pattern: re.match(r"\\b(\w+)", pattern.pattern).group(1) for pattern, _ in CALLS}
RUST_CONST = re.compile(r'\b(?:const|static)\s+([A-Z0-9_]*CAPABILIT[A-Z0-9_]*)\s*:\s*&(?:\'static\s+)?str\s*=\s*"([^"]+)"')


@dataclass(frozen=True)
class Ref:
    capability: str
    kind: str
    where: str


_MASK_NEXT = re.compile(r'//|/\*|"|#{1,7}"')
_NOT_NL = re.compile(r"[^\n]")
_STRING_STOPS: dict[tuple[int, bool], re.Pattern] = {}


def mask(source: str) -> str:
    """Comments and string contents blanked (same length, line breaks kept), for scope and call matching.

    Handles raw strings (`#"..."#`), multi-line strings and quotes nested in
    `\\( ... )` interpolations, so braces inside strings never shift a scope.
    Each scan jumps to the next character that can start or end a token, so a
    file costs regex time, not one Python step per character.
    """
    out: list[str] = []
    n, i, kept = len(source), 0, 0

    def blank(a: int, b: int) -> None:
        nonlocal kept
        b = min(b, n)
        if b <= a:
            return
        out.append(source[kept:a])
        out.append(_NOT_NL.sub(" ", source[a:b]))
        kept = b

    def string_end(i: int) -> int:
        """Index just past the string literal that starts at i (at `#` or `"`)."""
        hashes = 0
        while i + hashes < n and source[i + hashes] == "#":
            hashes += 1
        j = i + hashes
        multi = source.startswith('"""', j)
        close = ('"""' if multi else '"') + "#" * hashes
        j += 3 if multi else 1
        escape = "\\" + "#" * hashes
        stops = _STRING_STOPS.get((hashes, multi))
        if stops is None:
            alts = [re.escape(escape), re.escape(close)] + ([] if multi else ["\n"])
            stops = _STRING_STOPS[(hashes, multi)] = re.compile("|".join(alts))
        while j < n:
            m = stops.search(source, j)
            if not m:
                return n
            j = m.start()
            if source.startswith(escape + "(", j):
                j += len(escape) + 1
                depth = 1
                while j < n and depth:
                    if source[j] == '"' or (source[j] == "#" and source.startswith('"', j + 1)):
                        j = string_end(j)
                        continue
                    depth += {"(": 1, ")": -1}.get(source[j], 0)
                    j += 1
                continue
            if source.startswith(escape, j):
                j += len(escape) + 1
                continue
            if source.startswith(close, j):
                return j + len(close)
            if source[j] == "\n" and not multi:
                return j
            j += 1
        return n

    while i < n:
        m = _MASK_NEXT.search(source, i)
        if not m:
            break
        i = m.start()
        if source.startswith("//", i):
            j = source.find("\n", i)
            j = n if j < 0 else j
            blank(i, j)
            i = j
        elif source.startswith("/*", i):
            j = source.find("*/", i + 2)
            j = n if j < 0 else j + 2
            blank(i, j)
            i = j
        else:
            j = string_end(i)
            q = source.index('"', i)
            blank(q + 1, j - 1)
            i = j
    out.append(source[kept:])
    return "".join(out)


def brace_ends(masked: str) -> dict[int, int]:
    """{index of a `{`: index just past its matching `}`, or len(masked) when it has none}."""
    ends, stack = {}, []
    for m in re.finditer(r"[{}]", masked):
        if m.group() == "{":
            stack.append(m.start())
        elif stack:
            ends[stack.pop()] = m.start() + 1
    for p in stack:
        ends[p] = len(masked)
    return ends


class SwiftFile:
    def __init__(self, path: Path, rel: str):
        self.rel = rel
        self.text = path.read_text(encoding="utf-8")
        self.masked = mask(self.text)
        self.scopes = []  # (start, end, type name)
        ends = brace_ends(self.masked)
        for match in TYPE_DECL.finditer(self.masked):
            self.scopes.append((match.end(), ends[match.end() - 1], match.group(1).split(".")[-1]))
        # Constants: masked text locates them outside comments, the raw text gives the value.
        self.constants = []  # (pos, name, value, type)
        for match in CONSTANT.finditer(self.masked):
            raw = CONSTANT.match(self.text, match.start())
            if raw:
                self.constants.append((match.start(), raw.group(1), raw.group(2), self.type_at(match.start())))

    def type_at(self, pos: int) -> str | None:
        inner = [s for s in self.scopes if s[0] <= pos < s[1]]
        return min(inner, key=lambda s: s[1] - s[0])[2] if inner else None

    def line(self, pos: int) -> int:
        return self.text.count("\n", 0, pos) + 1


def collect(repo: Path):
    files = [SwiftFile(p, str(p.relative_to(repo))) for p in sorted((repo / SWIFT_ROOT).rglob("*.swift"))]
    by_type: dict[tuple[str, str], str] = {}
    for f in files:
        for _, name, value, owner in f.constants:
            if owner:
                by_type.setdefault((owner, name), value)
    endpoint = next((f for f in files if f.rel == ENDPOINT), None)
    if endpoint is None:
        sys.exit(f"check-app-capability-references: {ENDPOINT} is missing")
    cases, lists = fresh.swift_catalog(endpoint.text)
    lists = {name: lists[name] for name in ("required", "optional", "unservedByBundledDaemon")}

    refs: list[Ref] = []
    for name, value in cases.items():
        by_type.setdefault((CATALOG, name), value)
        found = re.search(r"\bcase\s+" + re.escape(name) + r"\b", endpoint.masked)
        refs.append(Ref(value, LISTED, f"{ENDPOINT}:{endpoint.line(found.start()) if found else 1}"))
    strays: list[str] = []
    for f in files:
        if CATALOG in f.text:
            strays += fresh.catalog_strays(f.text, f.rel)
        for pos, name, value, owner in f.constants:
            if owner != CATALOG and (name == "capability" or name.endswith("Capability")):
                refs.append(Ref(value, GATE, f"{f.rel}:{f.line(pos)}"))
        for pattern, kind in CALLS:
            # Every call pattern starts with its literal name: a file without
            # it has no match (a substring test is much cheaper than the regex).
            if CALL_NAMES[pattern] not in f.masked:
                continue
            for match in pattern.finditer(f.masked):
                expr_start = match.start(1)
                expr = f.text[expr_start:match.end(1)].strip()
                value = resolve(expr, f.type_at(expr_start), by_type)
                if value is not None:
                    refs.append(Ref(value, kind, f"{f.rel}:{f.line(expr_start)}"))
    return refs, lists, rust_capabilities(repo), strays


def resolve(expr: str, owner: str | None, by_type: dict[tuple[str, str], str]) -> str | None:
    if re.fullmatch(r'"[^"\\]*"', expr):
        return expr[1:-1]
    match = re.fullmatch(CATALOG + r"\.([A-Za-z_]\w*)(?:\.rawValue)?", expr)
    if match:
        return by_type.get((CATALOG, match.group(1)))
    match = re.fullmatch(r"Self\.([A-Za-z_]\w*)\.rawValue", expr)
    if match and owner == CATALOG:
        return by_type.get((CATALOG, match.group(1)))
    match = re.fullmatch(r"(?:Self|([A-Z]\w*))\.([A-Za-z_]\w*)", expr)
    if match:
        return by_type.get((match.group(1) or owner or "", match.group(2)))
    if re.fullmatch(r"[A-Za-z_]\w*", expr) and owner:
        return by_type.get((owner, expr))
    return None


def daemon_source_roots(repo: Path) -> list[Path]:
    """cmux-tui-core's src plus the src of every cmux-tui workspace crate it depends on directly."""
    core = repo / RUST_ROOT
    workspace = (repo / "cmux-tui/Cargo.toml").read_text(encoding="utf-8")
    paths = dict(re.findall(r'^([\w-]+)\s*=\s*\{[^}\n]*\bpath\s*=\s*"([^"]+)"', workspace, re.M))
    manifest = (core.parent / "Cargo.toml").read_text(encoding="utf-8")
    deps = manifest.split("[dependencies]", 1)[-1].split("\n[", 1)[0]
    roots = [core]
    for name in re.findall(r"^([\w-]+)(?:\.workspace\s*=\s*true|\s*=\s*\{[^}\n]*\bworkspace\s*=\s*true)", deps, re.M):
        if name in paths and (repo / "cmux-tui" / paths[name] / "src").is_dir():
            roots.append(repo / "cmux-tui" / paths[name] / "src")
    return roots


def rust_capabilities(repo: Path) -> dict[str, str]:
    found: dict[str, str] = {}
    for root in daemon_source_roots(repo):
        for path in sorted(root.rglob("*.rs")):
            text = path.read_text(encoding="utf-8", errors="replace")
            rel = str(path.relative_to(repo))
            pattern = re.compile(r'"([a-z][a-z0-9.-]*)"') if rel == RUST_LIST else RUST_CONST
            for match in pattern.finditer(text):
                found.setdefault(match.group(match.lastindex), f"{rel}:{text.count(chr(10), 0, match.start()) + 1}")
    if not found:
        sys.exit(f"check-app-capability-references: found no capability constants under {RUST_ROOT}")
    return found


RUST_CHAR = re.compile(r"'(\\.[^']*|[^\\'])'")


def rust_without_comments(text: str) -> str:
    """`text` with every Rust comment (line, block, nested block) blanked to spaces, newlines kept so line
    numbers hold; string and char literals stay as they are, and a comment marker inside one is not one."""
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            i += 1
            while i < n and text[i] != '"':
                i += 2 if text[i] == "\\" else 1
            i += 1
        elif c == "'" and (char := RUST_CHAR.match(text, i)):
            i = char.end()
        elif text.startswith("//", i):
            end = text.find("\n", i)
            end = n if end < 0 else end
            out[i:end] = " " * (end - i)
            i = end
        elif text.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if text.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif text.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            out[i:j] = [ch if ch == "\n" else " " for ch in text[i:j]]
            i = j
        else:
            i += 1
    return "".join(out)


def rust_initializer(text: str, name: str) -> tuple[int, int] | None:
    """The span of `name`'s `&[ ... ]` initializer in comment-free `text` (brackets in strings skipped)."""
    head = re.search(rf"\bconst\s+{name}\s*:[^=]*=\s*&\s*\[", text)
    if not head:
        return None
    depth, i = 1, head.end()
    while i < len(text) and depth:
        c = text[i]
        if c == '"':
            i += 1
            while i < len(text) and text[i] != '"':
                i += 2 if text[i] == "\\" else 1
        elif c == "[":
            depth += 1
        elif c == "]":
            depth -= 1
        i += 1
    return (head.end(), i) if depth == 0 else None


def acpmux_capabilities(repo: Path) -> dict[str, str]:
    """The capabilities the same-tree acpmux advertises, each with its file and line (none without the file):
    the `id`s of its `CAPABILITIES` initializer alone, comments masked, so an id in a comment, a doc or
    another constant never counts."""
    path = repo / ACPMUX_LIST
    if not path.is_file():
        return {}
    text = rust_without_comments(path.read_text(encoding="utf-8", errors="replace"))
    span = rust_initializer(text, "CAPABILITIES")
    if span is None:
        sys.exit(f"check-app-capability-references: found no `CAPABILITIES` initializer in {ACPMUX_LIST}")
    pattern = re.compile(r'\bid:\s*"([a-z][a-z0-9.-]*)"')
    return {m.group(1): f"{ACPMUX_LIST}:{text.count(chr(10), 0, m.start()) + 1}"
            for m in pattern.finditer(text, span[0], span[1])}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--list", action="store_true")
    args = parser.parse_args()
    refs, lists, daemon, strays = collect(args.repo)
    acpmux = acpmux_capabilities(args.repo)
    if args.list:
        for ref in sorted(refs, key=lambda r: (r.capability, r.kind, r.where)):
            served = "daemon" if ref.capability in daemon else "acpmux" if ref.capability in acpmux else "-"
            print(f"{ref.capability}\t{ref.kind}\t{served}\t{ref.where}")
        return 0

    checked = set(lists["required"]) | set(lists["optional"])
    unserved = set(lists["unservedByBundledDaemon"])
    problems: list[str] = []
    for stray in strays:
        problems.append(f"{stray}: a String static of the capability catalog is in no list, so no build checks "
                        f"it; make it a `case` of {CATALOG} in {ENDPOINT} placed in an arm of `tier`, or give it "
                        "a non-String type.")
    stubs: dict[str, list[str]] = {}
    for capability in sorted({r.capability for r in refs}):
        sites = [r for r in refs if r.capability == capability]
        gates = [r.where for r in sites if r.kind == GATE]
        if capability in daemon:
            if capability not in checked and capability not in CONDITIONAL:
                problems.append(
                    f"{capability}: the app references it ({', '.join(r.where for r in sites[:3])}) and the daemon "
                    f"defines it ({daemon[capability]}), but it is not in DaemonCapability.required or .optional, so "
                    "no build proves the bundled daemon serves it. Add it to `optional` in " + ENDPOINT
                    + " (a case in the `.optional` arm of `tier`) and regenerate plans/cmux-next/daemon-capabilities.json.")
            if capability in unserved:
                problems.append(f"{capability}: the daemon defines it ({daemon[capability]}); move it from "
                                "DaemonCapability.unservedByBundledDaemon to optional.")
        elif capability in PEERS or capability in unserved or capability in acpmux:
            continue
        elif gates:
            problems.append(
                f"{capability}: the app gates a feature on it ({', '.join(gates[:3])}), but no cmux-tui crate defines "
                "it, so the bundled daemon never serves it and the feature stays off. Land the daemon half on this "
                "branch (a `*_CAPABILITY` constant that identify advertises, or an entry in " + ACPMUX_LIST
                + " for an acpmux capability), fix the name, or remove the gate.")
        else:
            stubs[capability] = [r.where for r in sites]
    references = len({r.capability for r in refs})
    if stubs:
        print("check-app-capability-references: note: actions not built yet (refused as not available in this "
              "version): " + ", ".join(sorted(stubs)))
    if problems:
        print(f"check-app-capability-references: {len(problems)} problem(s) in {references} referenced capabilities:",
              file=sys.stderr)
        for problem in problems:
            print(f"  error: {problem}", file=sys.stderr)
        return 1
    print(f"check-app-capability-references: PASS: {references} capabilities referenced; every gated one is defined "
          f"by the daemon source ({len(daemon)} defined) and listed for the same-tree identify check "
          f"({len(checked)} listed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
