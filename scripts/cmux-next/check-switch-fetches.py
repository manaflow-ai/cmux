#!/usr/bin/env python3
"""Switching away and back makes no fetch (plans/cmux-next/shared-projections.md).

A tab's agent page stays alive and hidden while another tab or workspace shows, so a switch is
`visibilitychange` (and the window's `focus` as the page takes focus again). A view that reads its
data again on either, or that reads it again each time it mounts, makes every switch or remount
reload: rows empty and refill, entrances replay. Views read a shared projection instead and ask
their source only when it pushed a change. In the agent page's views (VIEWS below) this refuses:

  listener  `addEventListener("visibilitychange" | "focus" | "pageshow", ...)` in a file and for an
            event that `ALLOWED_LISTENERS` does not list with its reason.
  mount     a `useEffect` whose dependencies are `[]`, or only stable read functions (`callNative`,
            `fetchPage`, `load...`), whose body reads data (`callNative(`, `.request(`, `fetch(`,
            `fetchPage(`, a `load...(` call), unless the line above it carries
            `// mount-read: <reason>` or `ALLOWED_MOUNT_READS` lists the file.

Exits 1 with one line per hit, 0 when clean.

  python3 scripts/cmux-next/check-switch-fetches.py [--root DIR] [--self-test]
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
ACPMUX = "webviews/src/agent-session/acpmux"

# The views Leo named (New Tab's recent chats, the composer, the agent pane) and the modules they
# draw from. A directory covers every .ts/.tsx file under it, galleries and tests excluded.
VIEWS = [
    f"{ACPMUX}/App.tsx",
    f"{ACPMUX}/NewTabPage.tsx",
    f"{ACPMUX}/Composer.tsx",
    f"{ACPMUX}/ComposerPickers.tsx",
    f"{ACPMUX}/ComposerContext.tsx",
    f"{ACPMUX}/ComposerQueue.tsx",
    f"{ACPMUX}/composerFocus.ts",
    f"{ACPMUX}/startMode.ts",
    f"{ACPMUX}/direct.ts",
    f"{ACPMUX}/composer",
    f"{ACPMUX}/conversation",
    f"{ACPMUX}/newtab",
]

# (file, event): why this view listens. Each is a review decision; the exit plan is in
# shared-projections.md section 6.
ALLOWED_LISTENERS = {
    (f"{ACPMUX}/direct.ts", "visibilitychange"): "tells acpmux the chat is shown or hidden "
    "(`_acpmux/view`) so a turn ending while hidden stays unread; a state write, not a read",
    (f"{ACPMUX}/App.tsx", "visibilitychange"): "harness health re-reads only after a Log In ran "
    "in a terminal (`healthStale`)",
    (f"{ACPMUX}/App.tsx", "focus"): "harness health, as above",
    (f"{ACPMUX}/startMode.ts", "visibilitychange"): "exception: acpmux does not watch "
    "agents.defaultPermissionMode, so a Settings change is only seen by asking again",
    (f"{ACPMUX}/startMode.ts", "focus"): "exception, as above",
    (f"{ACPMUX}/composerFocus.ts", "focus"): "focus claim when the window is focused (the composer "
    "focus lane); reads no data",
    (f"{ACPMUX}/newtab/listMotion.ts", "visibilitychange"): "cancels the list's own motion when "
    "the page hides; reads no data",
}

# path: why its mount read stays for now. Each names the change that removes it.
ALLOWED_MOUNT_READS = {
    f"{ACPMUX}/newtab/AllChatsList.tsx": "All chats reads its first page on mount; #22115 "
    "(settledCache.ts) draws the last first page and reads only for a pushed change",
}

LISTENER = re.compile(r"addEventListener\??\.?\(\s*[\"'](visibilitychange|focus|pageshow)[\"']")
EFFECT = re.compile(r"\buse(?:Layout)?Effect\(")
READ = re.compile(r"\bcallNative\s*[<(]|\.request\s*[<(]|(?<![\w.])fetch\s*\(|\bfetchPage\s*\(|\bload[A-Z]\w*\s*\(|\bload\s*\(")
STABLE_DEP = re.compile(r"^(?:callNative|fetchPage|load(?:[A-Z]\w*)?|\w+Load\w*)$")
MARK = "mount-read:"


def view_files(root: str) -> list[str]:
    files: list[str] = []
    for entry in VIEWS:
        path = os.path.join(root, entry)
        if os.path.isfile(path):
            files.append(entry)
        elif os.path.isdir(path):
            for directory, _, names in os.walk(path):
                for name in sorted(names):
                    if not name.endswith((".ts", ".tsx")) or ".gallery." in name or ".test." in name:
                        continue
                    files.append(os.path.relpath(os.path.join(directory, name), root))
    return sorted(set(files))


def call_end(text: str, start: int) -> int:
    """Index just past the `)` closing the call whose `(` is at `start`; strings and comments skipped."""
    depth = 0
    index = start
    quote = ""
    while index < len(text):
        char = text[index]
        if quote:
            if char == "\\":
                index += 2
                continue
            if char == quote:
                quote = ""
            index += 1
            continue
        if text.startswith("//", index):
            newline = text.find("\n", index)
            index = len(text) if newline < 0 else newline
            continue
        if text.startswith("/*", index):
            close = text.find("*/", index + 2)
            index = len(text) if close < 0 else close + 2
            continue
        if char in "\"'`":
            quote = char
        elif char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
            if depth == 0:
                return index + 1
        index += 1
    return len(text)


def strip_comments(code: str) -> str:
    """`code` without its // and /* */ comments (strings are left as they are)."""
    return re.sub(r"/\*.*?\*/|//[^\n]*", "", code, flags=re.S)


def deps_of(call: str) -> list[str] | None:
    """The effect's dependency list, or None when it has none (runs after every render)."""
    inner = call[call.index("(") + 1 : -1].rstrip().rstrip(",").rstrip()
    if not inner.endswith("]"):
        return None
    depth = 0
    for index in range(len(inner) - 1, -1, -1):
        char = inner[index]
        if char == "]":
            depth += 1
        elif char == "[":
            depth -= 1
            if depth == 0:
                before = inner[:index].rstrip()
                if not before.endswith(","):
                    return None
                body = inner[index + 1 : -1].strip()
                return [part.strip() for part in body.split(",") if part.strip()] if body else []
    return None


def check_text(path: str, text: str) -> list[str]:
    hits: list[str] = []
    lines = text.splitlines()
    for match in LISTENER.finditer(text):
        event = match.group(1)
        if (path, event) in ALLOWED_LISTENERS:
            continue
        line = text.count("\n", 0, match.start()) + 1
        hits.append(
            f"{path}:{line}: `{event}` listener in a view: a switch away and back must not re-read "
            "(shared-projections.md); read the shared projection, or add the file and event to "
            "ALLOWED_LISTENERS in scripts/cmux-next/check-switch-fetches.py with its reason"
        )
    for match in EFFECT.finditer(text):
        open_paren = match.end() - 1
        call = text[match.start() : call_end(text, open_paren)]
        deps = deps_of(call)
        if deps is None or not all(STABLE_DEP.match(dep) for dep in deps):
            continue
        if not READ.search(strip_comments(call)) or path in ALLOWED_MOUNT_READS:
            continue
        line = text.count("\n", 0, match.start()) + 1
        above = lines[line - 2] if line >= 2 else ""
        if MARK in above or MARK in lines[line - 1]:
            continue
        hits.append(
            f"{path}:{line}: an effect that reads data on every mount: a remount must draw the shared "
            "projection and read only for a pushed change (shared-projections.md); or mark it "
            f"`// {MARK} <reason>` on the line above"
        )
    return hits


def check(root: str) -> list[str]:
    hits: list[str] = []
    for path in view_files(root):
        with open(os.path.join(root, path), encoding="utf-8") as handle:
            hits.extend(check_text(path, handle.read()))
    return hits


def self_test() -> None:
    view = f"{ACPMUX}/newtab/Fake.tsx"
    assert check_text(view, 'window.addEventListener("focus", reread);'), "an unlisted focus listener"
    assert not check_text(f"{ACPMUX}/direct.ts", 'document.addEventListener("visibilitychange", x);')
    mount = "useEffect(() => {\n  void callNative('chats.page');\n}, []);"
    assert check_text(view, mount), "a mount read"
    assert check_text(view, "useEffect(() => {\n  fetchPage('', undefined);\n}, [fetchPage]);"), "stable deps"
    assert not check_text(view, "// mount-read: the spare's model is wired only now\n" + mount)
    assert not check_text(view, "useEffect(() => {\n  void callNative('x', { id });\n}, [id]);"), "keyed read"
    assert not check_text(view, "useEffect(() => {\n  void callNative('x');\n});"), "no deps list"
    assert not check_text(view, "useEffect(() => {\n  const f = () => 1; // load(\n}, []);"), "comment"
    print("check-switch-fetches self-test: ok")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", default=REPO)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    hits = check(os.path.abspath(args.root))
    for hit in hits:
        print(hit)
    if hits:
        print(f"check-switch-fetches: {len(hits)} hit(s)", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
