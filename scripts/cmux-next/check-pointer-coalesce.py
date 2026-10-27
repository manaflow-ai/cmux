#!/usr/bin/env python3
"""MQ-pointer-per-event closing check (plans/cmux-next/chrome-parity/p04-input.md, queue MQ-pointer-per-event).

Lists every `mouseMoved` / `mouseDragged` / `rightMouseDragged` / `otherMouseDragged` override under
Packages/macOS/CmuxNext/Sources whose per-event work is not frame-aligned. Chromium delivers continuous
mouse input once per frame (`third_party/blink/renderer/platform/widget/input/main_thread_event_queue.cc`,
`IsRafAlignedEvent`); cmux's equivalent is the window's FrameInputCoalescer. A hit passes when:

  coalesced  its body, or a function of its target it calls (two levels deep), posts to the coalescer:
             a property of a coalescer type (`PointerFrameConsumer`, `PointerFrameHover`, `PointerFrameDrag`,
             `FrameInputCoalescer`, or a type of the target that holds one of those) with `.post(`, `.moved(`,
             `.crossed(` or `.dragged(`; a consumer or coalescer made in place (`.consumer(owner:`,
             `.coalescer(for:`); or a keyed post (`.post(.pointerMove|.drag|.scroll`). A closure property it
             calls (`onMove?(event)`) counts when every `.onMove = { ... }` of its target posts.
  native     the override carries `// input-coalesce: native (<why>)`, on its line or in the comment
             block right above it: a forward into an engine that coalesces itself (WebKit, Chromium's
             renderer, AppKit's dragging session) or work with nothing per event to coalesce. The reason
             is required.
  empty      its body is empty (it only swallows the event)

Comment lines (doc examples) are not overrides. Exit 1 and one line per open hit when any hit passes
none of these; `--list` prints every hit with how it passed.

  python3 scripts/cmux-next/check-pointer-coalesce.py [--root REPO] [--list]
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

SOURCES = "Packages/macOS/CmuxNext/Sources"

POINTER_EVENTS = r"(mouseMoved|mouseDragged|rightMouseDragged|otherMouseDragged)"
OVERRIDE = re.compile(
    r"override\s+(?:(?:public|open|package)\s+)?func\s+" + POINTER_EVENTS + r"\("
    r"|(?:public|open|package)\s+override\s+func\s+" + POINTER_EVENTS + r"\("
)
NATIVE = re.compile(r"//\s*input-coalesce:\s*native\b(.*)")
COALESCER_TYPES = frozenset({"PointerFrameConsumer", "PointerFrameHover", "PointerFrameDrag", "FrameInputCoalescer"})
IN_PLACE = re.compile(r"\.consumer\(\s*owner:|\.coalescer\(\s*for:|\.post\(\s*\.(?:pointerMove|drag|scroll)\b")
# A call of a function or of a closure property: `route(event)`, `self.route(event)`, `onMove?(event)`.
CALL = re.compile(r"(?<![.\w])(?:self\??\.)?([a-z_]\w*)\s*\??\s*\(")
# A closure stored into a property: `row.onMove = { [weak self] event in ... }`.
CLOSURE_SET = re.compile(r"\.([a-z_]\w*)\s*=\s*\{")
FUNC = re.compile(r"\bfunc\s+(\w+)\s*(?:<[^>]*>)?\s*\(")
TYPE_DECL = re.compile(r"\b(?:class|struct|actor|enum)\s+(\w+)")
# Between a declaration's name and its body no other declaration starts (a protocol requirement has none).
NO_BODY = re.compile(r"\n\s*(?:func|var|let|case|init|deinit|subscript|@|}|#)")
# The text of a line before a type name that declares a property of it: `var drag: ` or `let hover = `.
DECLARED = re.compile(r"\b(?:var|let)\s+(\w+)\s*(?::\s*\[?\s*|=\s*)$")
LITERAL = re.compile(r'//[^\n]*|/\*.*?\*/|"""(?:.|\n)*?"""|"(?:\\.|[^"\\\n])*"', re.DOTALL)
KEYWORDS = frozenset({"if", "guard", "switch", "for", "while", "return", "super", "self", "let", "var", "case",
                      "in", "defer", "do", "catch", "try", "await", "print", "max", "min", "abs", "assert",
                      "precondition"})


@dataclass
class Hit:
    path: str
    line: int
    name: str
    verdict: str  # "coalesced", "native", "empty" or "" (open)
    why: str = ""


def strip_code(text: str) -> str:
    """`text` with comments and string literals blanked (same length, newlines kept), so brace
    matching and call scans see only code."""
    return LITERAL.sub(lambda m: re.sub(r"[^\n]", " ", m.group(0)), text)


class Source:
    """One file's code, its braces matched once."""

    def __init__(self, rel: str, text: str) -> None:
        self.rel = rel
        self.text = text
        self.code = strip_code(text)
        self.close: dict[int, int] = {}
        self.types: list[tuple[int, int, str]] | None = None
        stack: list[int] = []
        for m in re.finditer(r"[{}]", self.code):
            if m.group(0) == "{":
                stack.append(m.start())
            elif stack:
                self.close[stack.pop()] = m.start()

    def body_at(self, start: int) -> str | None:
        """The code between the first `{` after `start` and its `}`; None when another declaration
        starts first or the brace never closes."""
        open_at = self.code.find("{", start)
        if open_at < 0 or NO_BODY.search(self.code, start, open_at) or open_at not in self.close:
            return None
        return self.code[open_at + 1:self.close[open_at]]

    def declarations(self, types: set[str] | frozenset[str]) -> list[tuple[int, str]]:
        """Each `var NAME: T` / `let NAME = T(` of a type in `types`: its offset and NAME. Finds the type
        names first (a plain text search) and reads the declaration back from there."""
        found = []
        for m in re.finditer(r"\b(?:" + alternation(types) + r")\b", self.code):
            line_start = self.code.rfind("\n", 0, m.start()) + 1
            decl = DECLARED.search(self.code[line_start:m.start()])
            if decl:
                found.append((line_start + decl.start(), decl.group(1)))
        return found

    def type_at(self, offset: int) -> str | None:
        """The innermost type declared around `offset` (its spans are found on the first call)."""
        if self.types is None:
            self.types = []
            for m in TYPE_DECL.finditer(self.code):
                open_at = self.code.find("{", m.end())
                if open_at >= 0 and open_at in self.close and not NO_BODY.search(self.code, m.end(), open_at):
                    self.types.append((open_at, self.close[open_at], m.group(1)))
        inner = None
        for start, end, name in self.types:
            if start < offset < end and (inner is None or start > inner[0]):
                inner = (start, name)
        return inner[1] if inner else None


def alternation(names: set[str] | frozenset[str]) -> str:
    return "|".join(re.escape(n) for n in sorted(names))


class Target:
    """One Swift target's coalescer properties and function bodies: an override may post through a
    property or a helper declared in another file of its target."""

    def __init__(self) -> None:
        self.sources: list[Source] = []
        self.coalescers: set[str] = set()
        self.functions: dict[str, list[str]] = {}
        self.closures: dict[str, list[str]] = {}

    def add(self, source: Source) -> None:
        self.sources.append(source)
        for m in FUNC.finditer(source.code):
            body = source.body_at(m.end())
            if body is not None:
                self.functions.setdefault(m.group(1), []).append(body)
        for m in CLOSURE_SET.finditer(source.code):
            open_at = m.end() - 1
            if open_at in source.close:
                self.closures.setdefault(m.group(1), []).append(source.code[open_at + 1:source.close[open_at]])

    def index(self) -> None:
        """Finds the target's coalescer types (the shared ones and a type of its own that holds one, a
        view's consumer wrapper such as TerminalPointerFrames; one level, so a type that only holds a
        wrapper is not one) and the properties declared with them."""
        types = set(COALESCER_TYPES)
        for source in self.sources:
            for offset, _ in source.declarations(COALESCER_TYPES):
                owner = source.type_at(offset)
                if owner is not None:
                    types.add(owner)
        for source in self.sources:
            self.coalescers.update(name for _, name in source.declarations(types))

    def posts(self, body: str, depth: int = 2, seen: set[str] | None = None) -> str:
        """How `body` reaches the coalescer ("" when it does not)."""
        m = IN_PLACE.search(body)
        if m:
            return m.group(0).strip()
        if self.coalescers:
            names = set(self.coalescers)
            # A local bound to one: `if let frames = state.dragFrames, frames.post(event)`.
            names.update(m.group(1) for m in re.finditer(
                r"\blet\s+(\w+)\s*=\s*(?:self\.)?(?:\w+\??\.)*(?:" + alternation(self.coalescers) + r")\b(?!\s*[.(])", body))
            m = re.search(r"\b(" + alternation(names) + r")\s*\??\s*\.\s*(post|moved|crossed|dragged)\s*\(", body)
            if m:
                return f"{m.group(1)}.{m.group(2)}"
        if depth == 0:
            return ""
        seen = set() if seen is None else seen
        for m in CALL.finditer(body):
            name = m.group(1)
            if name in KEYWORDS or name in seen or (name not in self.functions and name not in self.closures):
                continue
            seen.add(name)
            for helper in self.functions.get(name, []):
                via = self.posts(helper, depth - 1, seen)
                if via:
                    return f"{name}() -> {via}"
            # A closure property forwards only when every closure its target stores in it posts.
            closures = self.closures.get(name, [])
            vias = [self.posts(closure, depth - 1, set(seen)) for closure in closures]
            if vias and all(vias):
                return f"{name} closure -> {vias[0]}"
        return ""


def target_of(rel: str) -> str:
    parts = rel.split("/")
    return parts[4] if len(parts) > 5 else ""


def note_above(lines: list[str], index: int) -> str | None:
    """The `input-coalesce: native` text on line `index` or in the comment and attribute block above it."""
    m = NATIVE.search(lines[index])
    if m:
        return m.group(1).strip()
    i = index - 1
    while i >= 0:
        stripped = lines[i].strip()
        if not (stripped.startswith("//") or stripped.startswith("@")):
            break
        m = NATIVE.search(stripped)
        if m:
            return m.group(1).strip()
        i -= 1
    return None


def scan(root: Path) -> list[Hit]:
    base = root / SOURCES
    texts: dict[str, str] = {}
    for path in sorted(base.rglob("*.swift")):
        texts[path.relative_to(root).as_posix()] = path.read_text(encoding="utf-8", errors="replace")
    # Only targets with a hit are parsed: a cheap match on the raw text finds them.
    hit_targets = {target_of(rel) for rel, text in texts.items() if OVERRIDE.search(text)}
    targets: dict[str, Target] = {name: Target() for name in hit_targets}
    sources: list[Source] = []
    for rel, text in texts.items():
        if target_of(rel) in targets:
            source = Source(rel, text)
            targets[target_of(rel)].add(source)
            sources.append(source)
    for target in targets.values():
        target.index()

    hits: list[Hit] = []
    for source in sources:
        lines = source.text.split("\n")
        for m in OVERRIDE.finditer(source.code):
            index = source.code.count("\n", 0, m.start())
            hit = Hit(source.rel, index + 1, m.group(1) or m.group(2), "")
            reason = note_above(lines, index)
            body = source.body_at(m.end())
            if reason is not None:
                if reason.strip("() "):
                    hit.verdict, hit.why = "native", reason
                else:
                    hit.why = "`input-coalesce: native` needs a reason: `// input-coalesce: native (<why>)`"
            elif body is not None and not body.strip():
                hit.verdict = "empty"
            elif body is not None:
                via = targets[target_of(source.rel)].posts(body)
                if via:
                    hit.verdict, hit.why = "coalesced", via
            hits.append(hit)
    return sorted(hits, key=lambda h: (h.path, h.line))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--list", action="store_true", help="print every hit and how it passed")
    args = parser.parse_args(argv)
    hits = scan(args.root)
    open_hits = [h for h in hits if not h.verdict]
    if args.list:
        for h in hits:
            print(f"{h.verdict or 'OPEN':9} {h.path}:{h.line} {h.name}  {h.why}".rstrip())
    else:
        for h in open_hits:
            detail = h.why or "no coalescer call and no `// input-coalesce: native (<why>)`"
            print(f"{h.path}:{h.line}: {h.name}: {detail}")
    print(f"check-pointer-coalesce: {len(hits)} overrides, {len(open_hits)} not frame-aligned")
    return 1 if open_hits else 0


if __name__ == "__main__":
    sys.exit(main())
