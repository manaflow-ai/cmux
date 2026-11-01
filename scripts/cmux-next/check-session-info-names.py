#!/usr/bin/env python3
"""Session Info is never called Inspector in its code (Leo, 2026-10-31: "WHY THE FUCK IS IT STILL
CALLED INSPECTOR IN THE CODE STOP CALLING IT THAT").

The agent pane's right-hand panel is Session Info. webviews/test/session-info-name.test.ts keeps
"Inspector" out of what a person reads; this keeps it out of the code: identifiers, file names, CSS
classes and string literals in the panel's own files fail on /inspector/i. Comments are prose and
are not checked (they may name the other inspectors: the event, Memory and Web Inspector).

Scanned: webviews/src/agent-session/acpmux/session-info/ (every file), webviews/test/session-info*
and the Swift files listed in SWIFT (EXEMPT: two tests about the word itself). A file name with "inspector" in it fails too.

Allowed (ALLOW): the names that are saved state or a wire name, which a rename would break:
  agent.inspector                        Debug Settings key (AgentPaneTunables.sessionInfo)
  cmux.agentPane.inspector.*             localStorage keys (sessionInfoState.ts, sectionOrder.ts)
  agentPane.display.inspector.placement  Settings key for Push / Overlay
  agent-pane.chat-inspector, agent-pane.inspector-*   gallery entry ids other tools read
  `inspector` in the App's header state  (AgentPaneHeaderState.json, `pane.tabState`,
                                          setHeaderState / applyHeaderState payloads)
and the event Inspector's own names where Session Info code touches it (`t("inspector.*")`
strings, `toggleInspector`, `.acpmux-inspector`).

  python3 scripts/cmux-next/check-session-info-names.py [--root DIR] [--self-test]

Exits 1 with one `path:line: name` per hit; 0 when clean.
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
TREE = "webviews/src/agent-session/acpmux/session-info"
TESTS = "webviews/test"
TEST_PREFIX = "session-info"
SWIFT = (
    "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AgentPaneHeaderState.swift",
    "Packages/macOS/CmuxNext/Tests/CmuxNextAgentPaneTests/AgentPaneSessionInfoHeaderTests.swift",
)
EXTENSIONS = (".ts", ".tsx", ".css", ".swift")
# Tests whose subject is the word itself: they look for "Inspector" so that nothing shows it, or
# open the event Inspector beside Session Info.
EXEMPT = {
    "webviews/test/session-info-name.test.ts": "fails on Inspector in what a person reads",
    "webviews/test/session-info-palette.test.ts": "drives the event Inspector's palette action beside Session Info",
}

ALLOW = re.compile(
    "|".join(
        [
            r"(?<![\w.])agent\.inspector(?![\w.])",
            r"cmux\.agentPane\.inspector\.\w*",
            r"agentPane\.display\.inspector\.placement",
            r"agent-pane\.(?:chat-)?inspector[\w-]*",
            # The header state's wire name.
            r"(?:set|apply)HeaderState!?\??\.?\(\{[^}]*?\binspector\b",
            r"\"pane\.tabState\":\s*\{[^}]*?\binspector\b",
            r"\"inspector\":\s*\.bool\(",
            r"objectValue\?\[\"inspector\"\]",
            r"raw\.inspector\b",
            r"\binspector\?: unknown",
            # The event Inspector's own names.
            r"t\(\"inspector\.\w+\"",
            r"\btoggleInspector\b",
            r"\.acpmux-inspector\b",
        ]
    )
)
WORD = re.compile(r"inspector", re.I)


def strip_comments(text: str, ext: str) -> str:
    """Blanks comments (keeping line breaks and string literals) so only code is checked."""
    out = []
    i, n = 0, len(text)
    quote = None
    while i < n:
        c = text[i]
        if quote:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == quote or (c == "\n" and quote != "`"):
                quote = None
            i += 1
            continue
        if text.startswith("/*", i):
            end = text.find("*/", i + 2)
            end = n if end < 0 else end + 2
            out.append(re.sub(r"[^\n]", " ", text[i:end]))
            i = end
            continue
        if text.startswith("//", i) and ext != ".css" and (i == 0 or text[i - 1] != ":"):
            end = text.find("\n", i)
            end = n if end < 0 else end
            out.append(" " * (end - i))
            i = end
            continue
        if c in "\"'`":
            quote = c
        out.append(c)
        i += 1
    return "".join(out)


def hits(path: str, text: str):
    ext = os.path.splitext(path)[1]
    if WORD.search(os.path.basename(path)):
        yield (0, os.path.basename(path))
    code = strip_comments(text, ext)
    for number, line in enumerate(code.split("\n"), 1):
        if not WORD.search(line):
            continue
        allowed = [m.span() for m in ALLOW.finditer(line)]
        for m in WORD.finditer(line):
            if any(start <= m.start() and m.end() <= end for start, end in allowed):
                continue
            left = re.search(r"[\w.$-]*$", line[: m.start()]).group(0)
            right = re.match(r"[\w$-]*", line[m.end() :]).group(0)
            yield (number, left + m.group(0) + right)


def files(root: str):
    tree = os.path.join(root, TREE)
    for base, _, names in os.walk(tree):
        for name in sorted(names):
            yield os.path.relpath(os.path.join(base, name), root)
    tests = os.path.join(root, TESTS)
    if os.path.isdir(tests):
        for name in sorted(os.listdir(tests)):
            if name.startswith(TEST_PREFIX):
                yield f"{TESTS}/{name}"
    for path in SWIFT:
        if os.path.exists(os.path.join(root, path)):
            yield path


def check(root: str) -> list[str]:
    found = []
    for path in files(root):
        if path in EXEMPT:
            continue
        if not path.endswith(EXTENSIONS):
            if WORD.search(os.path.basename(path)):
                found.append(f"{path}:0: {os.path.basename(path)}")
            continue
        with open(os.path.join(root, path), encoding="utf-8") as handle:
            text = handle.read()
        found.extend(f"{path}:{number}: {name}" for number, name in hits(path, text))
    return found


def self_test() -> None:
    bad = [
        ("a.tsx", "export function useChatInspector() {}"),
        ("a.css", ".acpmux-chat-inspector-row { color: red; }"),
        ("a.tsx", 'const x = "inspector";'),
        ("a.swift", "public var inspector: Bool"),
        ("inspectorState.ts", "export const x = 1;"),
    ]
    good = [
        ("a.ts", "// the event Inspector covers the chat\nconst x = 1;"),
        ("a.ts", 'const OPEN_KEY = "cmux.agentPane.inspector.open";'),
        ("a.ts", 'setHeaderState({ inspector: true });'),
        ("a.ts", 'const native = { "pane.tabState": { inspector: true } };'),
        ("a.tsx", 'id: "agent-pane.chat-inspector",'),
        ("a.swift", '"inspector": .bool(sessionInfo)'),
        ("a.css", "/* the Inspector */ .acpmux-session-info {}"),
        ("a.ts", "const url = 'https://x/y'; // inspector"),
    ]
    for path, text in bad:
        assert list(hits(path, text)), f"must fail: {path}: {text}"
    for path, text in good:
        assert not list(hits(path, text)), f"must pass: {path}: {text}: {list(hits(path, text))}"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=REPO)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)
    if args.self_test:
        self_test()
        print("check-session-info-names: self-test ok")
        return 0
    found = check(os.path.abspath(args.root))
    for line in found:
        print(line)
    if found:
        print(
            f"\n{len(found)} Inspector name(s) in Session Info's code. It is Session Info (Leo, 2026-10-31);"
            " a saved or wire name goes in ALLOW in scripts/cmux-next/check-session-info-names.py.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
