#!/usr/bin/env python3
"""Switching away and back makes no fetch (plans/cmux-next/shared-projections.md).

A tab's agent page stays alive and hidden while another tab or workspace shows, so a switch is
`visibilitychange` (and the window's `focus` as the page takes focus again). A view that reads its
data again on either, or that reads it again each time it mounts, makes every switch or remount
reload: rows empty and refill, entrances replay. Views read a shared projection instead and ask
their source only when it pushed a change. In the agent page (every .ts/.tsx file under
webviews/src/agent-session/acpmux, galleries and tests excluded) this refuses:

  listener  a `visibilitychange`, `resume` or `pageshow` listener, or a `focus` listener on the
            window or document (`window`, `document`, `globalThis`, `doc`, `view`, `defaultView`),
            in a file and for an event that `ALLOWED_LISTENERS` does not list with its reason. An
            element's own `focus` listener is not a switch. The page lifecycle
            (webviews/src/pages/shared/pageLifecycle.ts) counts as a `visibilitychange` listener:
            `onPageLifecycleChange(`, `usePageLifecycle(`, `pageLifecycleFor(`,
            `new PageLifecycle(` and an interval's `catchUpOnShow` (unless `: false`).
  mount     a `useEffect` / `useLayoutEffect` whose dependencies are `[]`, or only stable read
            functions (`callNative`, `fetchPage`, `load...`, `reload`, `refresh...`), whose body
            reads data (`callNative(`, `.request(`, `fetch(`, `fetchPage(`, a `load...(` call) or
            that is itself a named read (`useEffect(loadRows, [])`), unless the line above it carries
            `// mount-read: <reason>` or `ALLOWED_MOUNT_READS` lists the file.

Comments and string contents are masked before matching, so a comment that names a pattern does
not trip it. Exits 1 with one line per hit, 0 when clean.

  python3 scripts/cmux-next/check-switch-fetches.py [--root DIR] [--self-test]
"""
from __future__ import annotations

import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
ACPMUX = "webviews/src/agent-session/acpmux"

# (file, event): why this file listens. Each is a review decision; the exit plan is in
# shared-projections.md section 6.
ALLOWED_LISTENERS = {
    (f"{ACPMUX}/direct.ts", "visibilitychange"): "tells acpmux the chat is shown or hidden "
    "(`_acpmux/view`) so a turn ending while hidden stays unread; a state write, not a read",
    (f"{ACPMUX}/App.tsx", "visibilitychange"): "harness health re-reads only after a Log In ran "
    "in a terminal (`healthStale`)",
    (f"{ACPMUX}/App.tsx", "focus"): "harness health, as above",
    (f"{ACPMUX}/composerFocus.ts", "focus"): "focus claim when the window is focused (the composer "
    "focus lane); reads no data",
    (f"{ACPMUX}/newtab/NewTabScreen.tsx", "focus"): "the field takes the keyboard back when the "
    "page is focused with nothing in it focused (#22456), as composerFocus.ts does; reads no data",
    (f"{ACPMUX}/threadMinimap/scrollMotion.ts", "visibilitychange"): "cancels the wheel's own "
    "motion when the page hides; reads no data",
    (f"{ACPMUX}/newtab/listMotion.ts", "visibilitychange"): "cancels the list's own motion when "
    "the page hides; reads no data",
    (f"{ACPMUX}/avatars/AnimatedAvatar.tsx", "visibilitychange"): "stops the avatar's own CSS "
    "frame animation while the page hides; reads no data",
    (f"{ACPMUX}/pageKey.ts", "focus"): "marks the page key or not for the caret; reads no data",
    (f"{ACPMUX}/clock.ts", "visibilitychange"): "the shared minute clock stops its timer while the page "
    "is hidden and reads the minute once on show (p13-webui-035); reads no data",
    (f"{ACPMUX}/chips/referenceExistence.ts", "visibilitychange"): "its retry waits count only shown time "
    "(startPageTimeout) and a hidden page's first round waits once (p13-webui-069); no read on show itself",
    (f"{ACPMUX}/Composer.tsx", "visibilitychange"): "flushes a new chat's waiting unsent draft to the host "
    "when the page hides (unsentDraftThrottle.ts); a write, reads no data",
    (f"{ACPMUX}/MarkdownField.tsx", "focus"): "puts back the prompt's selection, which WebKit moves "
    "to the start while the web view is away (#22798); reads no data",
    (f"{ACPMUX}/pageKey.ts", "visibilitychange"): "the same, on hide and show",
    (f"{ACPMUX}/composer/keptAttachments.ts", "visibilitychange"): "sends a resting write of the "
    "chat's unsent attachments before the page can go away (#23139); a write, not a read",
    (f"{ACPMUX}/chips/ReplyMedia.tsx", "visibilitychange"): "stops a muted hover preview when the "
    "agent page hides; it only cancels local media and reads no data",
    (f"{ACPMUX}/clock.ts", "visibilitychange"): "the shared minute clock rests while the page is "
    "hidden (p13-webui-035) and on show reads the minute once; reads no data",
    (f"{ACPMUX}/chips/referenceExistence.ts", "visibilitychange"): "a bare #N's pull request rounds rest "
    "while the page is hidden (p13-webui-069): the lifecycle only picks the first wait, and a show "
    "waits a period (`onResume: \"wait\"`), so a switch reads nothing",
    (f"{ACPMUX}/harnesses/HarnessesScreen.tsx", "focus"): "follow-up: re-reads harness health on "
    "every focus to catch a Sign In run in a terminal; should re-read only once one ran, as App.tsx "
    "`healthStale` does",
}

# path: why its mount read stays for now. Each names the change that removes it.
ALLOWED_MOUNT_READS = {
    f"{ACPMUX}/newtab/AllChatsList.tsx": "All chats reads its first page on mount; #22115 "
    "(settledCache.ts) draws the last first page and reads only for a pushed change",
}

LISTENER = re.compile(
    r"(?:([\w$]+)\s*\??\.\s*)?addEventListener\s*\??\.?\(\s*[\"'](visibilitychange|focus|pageshow|resume)[\"']"
)
# The page lifecycle (webviews/src/pages/shared/pageLifecycle.ts) fires on hide, freeze, resume and
# show, so each way to run code on it is a `visibilitychange` listener: `onPageLifecycleChange(`, the
# `usePageLifecycle(` state (an effect keyed on it re-runs on every show), a `PageLifecycle` taken to
# `.observe(` (`pageLifecycleFor(`, `new PageLifecycle(`), and an interval that `catchUpOnShow`s.
LIFECYCLE_LISTENER = re.compile(
    r"(?<![\w$.])(?:onPageLifecycleChange|usePageLifecycle|pageLifecycleFor)\s*\(|"
    r"\bnew\s+PageLifecycle\s*\(|"
    r"(?<![\w$])catchUpOnShow\b(?!\s*:\s*false\b)"
)
PAGE_RECEIVERS = {"window", "document", "globalThis", "doc", "view", "defaultView", "self"}
EFFECT = re.compile(r"\buse(?:Layout)?Effect\(")
READ = re.compile(
    r"\bcallNative\s*[<(]|\.request\s*[<(]|(?<![\w.])fetch\s*\(|\bfetchPage\s*\(|(?<!\.)\bload(?:[A-Z]\w*)?\s*\("
)
STABLE_DEP = re.compile(r"^(?:callNative|fetchPage|load(?:[A-Z]\w*)?|reload|refresh(?:[A-Z]\w*)?)$")
NAMED_READ = re.compile(r"^\s*(?:load[A-Z]\w*|load|fetch[A-Z]\w*|fetchPage|refresh[A-Z]\w*|reload)\s*,")
PUSH = re.compile(r"\bsubscribe\w*\s*\(|\.subscribe\s*\(|\baddEventListener\s*\(")
MARK = "mount-read:"


def view_files(root: str) -> list[str]:
    files: list[str] = []
    for directory, _, names in os.walk(os.path.join(root, ACPMUX)):
        for name in sorted(names):
            if not name.endswith((".ts", ".tsx")) or ".gallery." in name or ".test." in name:
                continue
            files.append(os.path.relpath(os.path.join(directory, name), root))
    return sorted(files)


def mask(text: str) -> str:
    """`text` with comments and string or template contents blanked to spaces (quotes and newlines
    kept), so offsets and line numbers stay and nothing inside them matches or unbalances parens."""
    out = list(text)
    index = 0
    length = len(text)

    def blank(start: int, end: int) -> None:
        for at in range(start, min(end, length)):
            if out[at] != "\n":
                out[at] = " "

    while index < length:
        if text.startswith("//", index):
            end = text.find("\n", index)
            end = length if end < 0 else end
            blank(index, end)
            index = end
        elif text.startswith("/*", index):
            end = text.find("*/", index + 2)
            end = length if end < 0 else end + 2
            blank(index, end)
            index = end
        elif text[index] in "\"'`":
            quote = text[index]
            at = index + 1
            depth = 0
            while at < length:
                char = text[at]
                if char == "\\":
                    at += 2
                    continue
                if quote == "`" and text.startswith("${", at):
                    depth += 1
                elif quote == "`" and char == "}" and depth:
                    depth -= 1
                elif char == quote and not depth:
                    break
                elif char == "\n" and quote != "`":
                    break
                at += 1
            blank(index + 1, at)
            index = at + 1
        else:
            index += 1
    return "".join(out)


def call_end(code: str, start: int) -> int:
    """Index just past the `)` closing the call whose `(` is at `start`, in masked `code`."""
    depth = 0
    for index in range(start, len(code)):
        char = code[index]
        if char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
            if depth == 0:
                return index + 1
    return len(code)


def deps_of(call: str) -> list[str] | None:
    """The effect's dependency list (masked call text), or None when it has none."""
    inner = call[call.index("(") + 1 : -1].rstrip().rstrip(",").rstrip()
    inner = re.sub(r"\s+as\s+const$", "", inner)
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


def listener_hit(path: str, line: int, event: str) -> str:
    return (
        f"{path}:{line}: `{event}` listener in the agent page: a switch away and back must not "
        "re-read (shared-projections.md); read the shared projection, or add the file and event "
        "to ALLOWED_LISTENERS in scripts/cmux-next/check-switch-fetches.py with its reason"
    )


def check_text(path: str, text: str) -> list[str]:
    hits: list[str] = []
    lines = text.splitlines()
    code = mask(text)
    for match in LISTENER.finditer(text):
        # A match that starts in a comment (masked to spaces) is prose, not code.
        if code[match.start() : match.start() + 1].isspace() and not text[match.start()].isspace():
            continue
        if "addEventListener" not in code[match.start() : match.end()]:
            continue
        receiver, event = match.group(1), match.group(2)
        if event == "focus" and receiver is not None and receiver not in PAGE_RECEIVERS:
            continue
        if (path, event) in ALLOWED_LISTENERS:
            continue
        line = text.count("\n", 0, match.start()) + 1
        hits.append(listener_hit(path, line, event))
    for match in LIFECYCLE_LISTENER.finditer(code):
        if (path, "visibilitychange") in ALLOWED_LISTENERS:
            continue
        line = code.count("\n", 0, match.start()) + 1
        hits.append(listener_hit(path, line, "visibilitychange"))
    for match in EFFECT.finditer(code):
        open_paren = match.end() - 1
        call = code[match.start() : call_end(code, open_paren)]
        deps = deps_of(call)
        if deps is None or not all(STABLE_DEP.match(dep) for dep in deps):
            continue
        if not (READ.search(call) or NAMED_READ.match(call[call.index("(") + 1 :])) or path in ALLOWED_MOUNT_READS:
            continue
        # An effect that subscribes and reads when its source pushes is the pattern, not a mount read.
        if PUSH.search(call):
            continue
        line = code.count("\n", 0, match.start()) + 1
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
    assert check_text(view, "document.addEventListener('visibilitychange', x, { passive: true });")
    assert not check_text(view, 'input.addEventListener("focus", onFocus);'), "an element's focus"
    assert not check_text(f"{ACPMUX}/direct.ts", 'document.addEventListener("visibilitychange", x);')
    assert check_text(view, "const stop = onPageLifecycleChange(() => void callNative('x'));"), "lifecycle"
    assert check_text(view, 'document.addEventListener("resume", reread);'), "a resume listener"
    assert not check_text(f"{ACPMUX}/direct.ts", "this.stop = onPageLifecycleChange(this.showChanged);")
    assert not check_text(view, "// onPageLifecycleChange(reread) is refused here\nconst a = 1;"), "lifecycle prose"
    keyed = "const state = usePageLifecycle();\nuseEffect(() => {\n  void callNative('chats.page');\n}, [state]);"
    assert check_text(view, keyed), "a read keyed on the lifecycle state"
    assert check_text(view, "pageLifecycleFor().observe(() => void callNative('x'));"), "a lifecycle observer"
    assert check_text(view, "new PageLifecycle(document).observe(reread);"), "a made lifecycle"
    caught_up = "usePageInterval(() => void callNative('x'), 5000, { catchUpOnShow: true });"
    assert check_text(view, caught_up), "a catch-up on show"
    assert check_text(view, "startPageInterval(tick, 1000, { catchUpOnShow });"), "a shorthand catch-up"
    assert not check_text(view, "usePageInterval(tick, 1000, { catchUpOnShow: false });"), "no catch-up"
    assert not check_text(view, "usePageInterval(tick, 1000);"), "a plain interval"
    assert not check_text(view, 'import { pageLifecycleFor } from "../../pages/shared/pageLifecycle";')
    assert not check_text(f"{ACPMUX}/direct.ts", "const s = usePageLifecycle();"), "a listed file"
    assert not check_text(view, '/// unlike window.addEventListener("focus", ...)\nconst a = 1;'), "doc comment"
    mount = "useEffect(() => {\n  void callNative('chats.page');\n}, []);"
    assert check_text(view, mount), "a mount read"
    assert check_text(view, "useEffect(() => {\n  fetchPage('', undefined);\n}, [fetchPage]);"), "stable deps"
    assert check_text(view, "useEffect(loadRows, []);"), "a named read"
    assert check_text(view, "useEffect(() => {\n  void callNative<T>('x');\n}, [/* once */]);"), "commented deps"
    assert not check_text(view, "// mount-read: the spare's model is wired only now\n" + mount)
    assert not check_text(view, "useEffect(() => {\n  void callNative('x', { id });\n}, [id]);"), "keyed read"
    assert not check_text(view, "useEffect(() => {\n  if (!isLoading) void callNative('x');\n}, [isLoading]);")
    assert not check_text(view, "useEffect(() => {\n  void callNative('x');\n});"), "no deps list"
    assert not check_text(
        view, "useEffect(\n  () =>\n    subscribeDeviceChats(() => fetchPage('', undefined)),\n  [fetchPage],\n);"
    ), "a read on each push"
    assert not check_text(view, "useEffect(() => {\n  const f = () => 1; // load(\n}, []);"), "comment"
    assert not check_text(view, "useEffect(() => {\n  setLabel('load(');\n}, []);"), "string"
    assert not check_text(view, "useEffect(() => {\n  audio.load();\n}, []);"), "a media element's load"
    assert not check_text(view, "// never write useEffect(() => load(), []) here\nconst a = 1;"), "prose"
    assert not check_text(view, "useEffect(() => {\n  const s = `a ${f(')')} b`;\n}, []);"), "template"
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
