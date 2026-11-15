#!/usr/bin/env python3
"""No new error, notice or recovery string in cmux NEXT that is jargon, a paragraph, filler or a dead end.

Leo, 2026-11-11, on a friend who started a chat without Claude Code or Codex installed and met an error with no
way out: "When we hit errors, there can never be [nonsense]. You can never write [nonsense] to the end user."
Where the person truly has to act, the product shows one short true sentence and one working button.

What it reads (and nothing else):

* the agent chat's string catalog, webviews/src/agent-session/acpmux/Localizable.xcstrings: every key whose name
  or English value reads as an error, notice or recovery (TRIGGER: error, failed, unavailable, offline, missing,
  not installed, sign in, retry, reload, couldn't, unable, timed out, lost, not sent, unexpected, unknown);
* hard-coded rendered strings in webviews/src/agent-session/acpmux/**/*.tsx (galleries and tests left out) that
  contain a TRIGGER word or FILLER: JSX text between tags, and the literal of a `title`, `message`, `label`, `hint`,
  `detail`, `placeholder`, `aria-label` or `alt` prop;
* the message of every NSAlert (`messageText`, `informativeText`) and SwiftUI `.alert(` under
  Packages/macOS/CmuxNext/Sources: a string literal, or a `Type.member` whose `static var|let|func member`
  line's last string literal is its English default (one level, the `*Strings.swift` helpers' shape).

The rules, each a finding:

* jargon: the text names ACP, acpmux, daemon, socket, hub, FFI, JSON, RPC, JSON-RPC, stderr, stdout, exit code,
  errno, ENOENT, EPIPE, undefined, null or NaN.
* raw-error: a .tsx line takes a caught error's own words (`X.message`, `String(X)`, `errorMessage(X)`, for X one
  of e, err, error, cause, caught, failure, nativeError*) and that line or one of the two before it hands them to
  the person: JSX `{X.message}`, a template `${...}`, a state setter `setFoo(`, `notices.*(`, `.notice(`,
  `toast*(`, or a `t("key", ...)`/`translate("key", ...)` call. A line that logs (console, acpWire, log*, debug*,
  trace*) is not counted. This is a line regex, not data flow: an error stored in one place and drawn in another
  file is caught where it is stored.
* sentences: more than one sentence (more than one `.`, `!` or `?` that ends a sentence; an ellipsis, a
  decimal or a file extension is not an end).
* filler: "something went wrong", "an error occurred", "unexpected error", "please try again later",
  "try again later".
* no-action: an error surface draws no action. The surfaces are COMPONENTS (each by file and exported function)
  and every `<Notice ... tier="error">` (or a tier expression that can be "error") in a non-gallery .tsx of
  acpmux/. A component passes when its props type has a member named action, actions, onRetry or onInstall,
  or its body draws a button (`<button`, `<…Button`, a `retry={` or `actions={` prop). A Notice passes when
  its children draw a button the same way or hand a child an `on…={` handler or an `action=`/`actions=`/
  `retry=` prop. Children the check cannot read (a lone `{variable}`) count as no action: inline the element,
  so the action can be seen.

Shrink-only (cmuxterm-hq docs/handbook/allowlist-grows-past-its-ratchet.md): today's offenders are listed in
scripts/user_facing_strings_baseline.json by rule, place (a catalog key, or a file and its text, never a line
number, so unrelated edits do not move it) and text. The check fails on any offender not listed, on a listed
entry that is no longer an offender (delete it), and, with a base (BASE_REF in the environment, as ci-web's
Check webviews step sets it, or --base), on a listed entry the base's baseline does not have: the list only
shrinks. `--write-baseline` rewrites it from the tree (for removing fixed entries; the base check still refuses
growth). Exits 1 with one line per finding, 0 when clean.

  python3 scripts/cmux-next/check-user-facing-strings.py [--root DIR] [--base REF] [--counts]
  python3 scripts/cmux-next/check-user-facing-strings.py --write-baseline
  python3 scripts/cmux-next/check-user-facing-strings.py --self-test
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
CATALOG = "webviews/src/agent-session/acpmux/Localizable.xcstrings"
TSX_TREE = "webviews/src/agent-session/acpmux"
SWIFT_TREE = "Packages/macOS/CmuxNext/Sources"
BASELINE = "scripts/user_facing_strings_baseline.json"
# What this check reads. scripts/web_lint_prepush.py runs it alone when a push touches one (declared_inputs()).
INPUTS = (CATALOG, f"{TSX_TREE}/**/*.tsx", f"{SWIFT_TREE}/**/*.swift", BASELINE)

TRIGGER = re.compile(r"\berror|\bfail|unavailable|offline|missing|not installed|sign.?in|\bretry|\breload|"
                     r"couldn[’']t|could not|unable|timed out|\blost\b|not sent|unexpected|unknown", re.I)
JARGON = [
    ("ACP", re.compile(r"\bACP\b")),
    ("acpmux", re.compile(r"acpmux", re.I)),
    ("daemon", re.compile(r"\bdaemons?\b", re.I)),
    ("socket", re.compile(r"\bsockets?\b", re.I)),
    ("hub", re.compile(r"\bhubs?\b", re.I)),
    ("FFI", re.compile(r"\bFFI\b")),
    ("JSON-RPC", re.compile(r"\bJSON-RPC\b", re.I)),
    ("JSON", re.compile(r"\bJSON\b(?!-RPC)", re.I)),
    ("RPC", re.compile(r"(?<!-)\bRPC\b", re.I)),
    ("stderr", re.compile(r"\bstderr\b", re.I)),
    ("stdout", re.compile(r"\bstdout\b", re.I)),
    ("exit code", re.compile(r"\bexit(?:ed with)? (?:code|status)\b", re.I)),
    ("errno", re.compile(r"\berrno\b", re.I)),
    ("ENOENT", re.compile(r"\bENOENT\b")),
    ("EPIPE", re.compile(r"\bEPIPE\b")),
    ("undefined", re.compile(r"\bundefined\b")),
    ("null", re.compile(r"\bnull\b")),
    ("NaN", re.compile(r"\bNaN\b")),
]
FILLER = re.compile(r"something went wrong|an error occurred|an error has occurred|unexpected error|"
                    r"(?:please )?try again later", re.I)
CAUGHT = r"(?:e|err|error|cause|caught|failure|nativeError\w*)"
# A caught error's own words: its message, its String(), the errorMessage() helper of it, a NativeError's message.
RAW_SOURCE = re.compile(r"\b" + CAUGHT + r"\??\.message\b|\bString\(\s*" + CAUGHT + r"\s*\)|\berrorMessage\(\s*"
                        + CAUGHT + r"\s*\)")
# Where it reaches the person: JSX `{...}`, a template, a state setter, a notice or toast, a t()/translate() value.
SINK = re.compile(r"\{\s*(?:" + CAUGHT + r"\??\.message|String\(\s*" + CAUGHT + r"\s*\))\s*\}|\$\{|\bset[A-Z]\w*\(|"
                  r"\bnotices?\.\w+\(|\.notice\(|\btoast\w*\(|\b(?:t|translate)\(\s*[\"']")
# Not the person's: logs and wire traces.
LOG = re.compile(r"\bconsole\.\w+\(|\bacpWire\.|\blog\w*\(|\bdebug\w*\(|\btrace\w*\(", re.I)
# Error surfaces by file (under TSX_TREE) and exported function.
COMPONENTS = (
    ("HostError.tsx", "HostError"),
    ("HostError.tsx", "HostUnavailableLine"),
    ("ChatUnavailableState.tsx", "ChatUnavailableState"),
    ("HarnessHealthNotice.tsx", "HarnessHealthNotice"),
    ("PermissionCard.tsx", "PermissionCard"),
    ("MissingChat.tsx", "MissingChat"),
)
ACTION_MEMBERS = {"action", "actions", "onRetry", "onInstall"}
DRAWS_BUTTON = re.compile(r"<button\b|<\w*Button\b|\bretry=\{|\bactions=\{")
HANDS_ACTION = re.compile(r"\bon[A-Z]\w*=\{|\baction=|\bactions=|\bretry=")
PROP_STRING = re.compile(r"\b(?:title|message|label|hint|detail|placeholder|aria-label|alt)="
                         r"(?:\"([^\"\n]*)\"|\{\"([^\"\n]*)\"\}|\{'([^'\n]*)'\})")
JSX_TEXT = re.compile(r">([^<>{}`]*[A-Za-z][^<>{}`]*)<")
CODEY = re.compile(r"[;=()&|]|=>|\bconst\b|\breturn\b")


def sentence_count(text: str) -> int:
    """How many sentences: ends are `.`, `!`, `?` before a space or the end; an ellipsis, a decimal and a dotted
    name (a file extension, e.g.) are not ends."""
    body = text.replace("…", " ").replace("...", " ")
    body = re.sub(r"\{\w+\}", "x", body)  # a placeholder is a word
    ends = re.findall(r"(?<![.\s])[.!?]+(?=\s|$)", body.strip())
    return max(1, len(ends))


def string_rules(text: str) -> list[tuple[str, str]]:
    """(rule, what) for a user-facing string."""
    out = []
    for name, pattern in JARGON:
        if pattern.search(text):
            out.append(("jargon", name))
    if FILLER.search(text):
        out.append(("filler", FILLER.search(text).group(0).lower()))
    if sentence_count(text) > 1:
        out.append(("sentences", f"{sentence_count(text)} sentences"))
    return out


def line_of(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def strip_comments(source: str) -> str:
    """Comments blanked to spaces (newlines kept, so offsets and lines hold)."""
    def blank(match: re.Match) -> str:
        return re.sub(r"[^\n]", " ", match.group(0))
    # Strings first so a `//` inside one survives.
    pattern = re.compile(r"\"(?:\\.|[^\"\\\n])*\"|'(?:\\.|[^'\\\n])*'|`(?:\\.|[^`\\])*`|//[^\n]*|/\*.*?\*/", re.S)
    return pattern.sub(lambda m: m.group(0) if m.group(0)[0] in "\"'`" else blank(m), source)


class Finding:
    def __init__(self, rule: str, where: str, text: str, path: str, line: int, why: str):
        self.rule, self.where, self.text, self.path, self.line, self.why = rule, where, text, path, line, why

    def key(self) -> tuple[str, str, str]:
        return (self.rule, self.where, self.text)

    def shown(self) -> str:
        return f"{self.path}:{self.line}: {self.rule} ({self.why}): {self.where}: {json.dumps(self.text)[:160]}"


def catalog_findings(root: Path) -> list[Finding]:
    path = root / CATALOG
    if not path.is_file():
        return []
    raw = path.read_text(encoding="utf-8")
    strings = json.loads(raw).get("strings", {})
    out = []
    for key, entry in strings.items():
        unit = entry.get("localizations", {}).get("en", {})
        values = []
        if "stringUnit" in unit:
            values.append(unit["stringUnit"].get("value", ""))
        for forms in unit.get("variations", {}).values():
            for form in forms.values():
                values.append(form.get("stringUnit", {}).get("value", ""))
        values = [v for v in values if v] or [key]
        if not (TRIGGER.search(key) or any(TRIGGER.search(v) or FILLER.search(v) for v in values)):
            continue
        at = raw.find(json.dumps(key) + " :")
        if at < 0:
            at = raw.find(json.dumps(key))
        line = line_of(raw, max(at, 0))
        seen = set()
        for value in values:
            for rule, why in string_rules(value):
                if (rule, why) in seen:
                    continue
                seen.add((rule, why))
                out.append(Finding(rule, f"catalog:{key}", why if rule != "sentences" else "", CATALOG, line,
                                   f"{why}; English: {value[:100]}"))
    return out


def tsx_files(root: Path) -> list[Path]:
    base = root / TSX_TREE
    if not base.is_dir():
        return []
    return sorted(p for p in base.rglob("*.tsx")
                  if not p.name.endswith((".gallery.tsx", ".test.tsx")) and "/test/" not in p.as_posix())


def tsx_findings(root: Path) -> list[Finding]:
    out = []
    for path in tsx_files(root):
        rel = path.relative_to(root).as_posix()
        source = strip_comments(path.read_text(encoding="utf-8"))
        texts = []
        for match in JSX_TEXT.finditer(source):
            text = " ".join(match.group(1).split())
            if text and not CODEY.search(text):
                texts.append((match.start(1), text))
        for match in PROP_STRING.finditer(source):
            text = next(g for g in match.groups() if g is not None)
            texts.append((match.start(), text))
        for offset, text in texts:
            if not (TRIGGER.search(text) or FILLER.search(text)):
                continue
            for rule, why in string_rules(text):
                out.append(Finding(rule, rel, text, rel, line_of(source, offset), why))
        lines = source.splitlines()
        for number, line in enumerate(lines, 1):
            match = RAW_SOURCE.search(line)
            if not match or LOG.search(line):
                continue
            # The sink on the line itself, or on one of the two before it (a multi-line object or call).
            window = lines[max(0, number - 3):number]
            if any(SINK.search(text) and not LOG.search(text) for text in window):
                out.append(Finding("raw-error", rel, match.group(0).strip(), rel, number,
                                   "a caught error's own words reach the person"))
        out.extend(notice_findings(rel, source))
    return out


def notice_findings(rel: str, source: str) -> list[Finding]:
    out = []
    for match in re.finditer(r"<Notice\b(?P<attrs>(?:[^>{]|\{(?:[^{}]|\{[^{}]*\})*\})*)>(?P<body>.*?)</Notice>",
                             source, re.S):
        attrs, body = match.group("attrs"), match.group("body")
        tier = re.search(r"\btier=(?:\"(\w+)\"|\{(.*?)\}\s)", attrs + " ", re.S)
        if not tier or "error" not in (tier.group(1) or tier.group(2) or ""):
            continue
        ident = re.search(r"\bid=\"([^\"]+)\"", attrs)
        name = f"Notice {ident.group(1) if ident else '?'}"
        if DRAWS_BUTTON.search(body) or HANDS_ACTION.search(body):
            continue
        lone = re.fullmatch(r"\s*\{\s*[\w.?]+\s*\}\s*", body)
        why = "its children are a variable the check cannot read" if lone else "draws no button and hands no action"
        out.append(Finding("no-action", rel, name, rel, line_of(source, match.start()), why))
    return out


def component_findings(root: Path) -> list[Finding]:
    out = []
    for file, name in COMPONENTS:
        rel = f"{TSX_TREE}/{file}"
        path = root / rel
        if not path.is_file():
            out.append(Finding("no-action", rel, name, rel, 1, "an error surface the check lists is gone; "
                               "update COMPONENTS in scripts/cmux-next/check-user-facing-strings.py"))
            continue
        source = strip_comments(path.read_text(encoding="utf-8"))
        start = re.search(rf"^export function {name}\b", source, re.M)
        if not start:
            out.append(Finding("no-action", rel, name, rel, 1, "the listed export is gone; update COMPONENTS"))
            continue
        rest = source[start.start():]
        end = re.search(r"^(?:export )?(?:function|const|class) ", rest[1:], re.M)
        body = rest[: end.start() + 1] if end else rest
        props = re.search(r"\}\s*:\s*\{(.*?)\n\}\)", body, re.S)
        members = set(re.findall(r"^\s*(\w+)\??\s*[:(]", props.group(1), re.M)) if props else set()
        if members & ACTION_MEMBERS or DRAWS_BUTTON.search(body):
            continue
        out.append(Finding("no-action", rel, name, rel, line_of(source, start.start()),
                           "no action/actions/onRetry/onInstall prop and no button drawn"))
    return out


def swift_index(files: list[Path]) -> dict[tuple[str, str], str]:
    index = {}
    for path in files:
        if not path.name.endswith("Strings.swift") and "Strings" not in path.name:
            continue
        owner = ""
        for line in path.read_text(encoding="utf-8").splitlines():
            decl = re.match(r"\s*(?:public |internal |private |fileprivate )*(?:enum|struct|extension|class)\s+(\w+)",
                            line)
            if decl:
                owner = decl.group(1)
            member = re.search(r"\bstatic (?:var|let|func) (\w+)", line)
            literals = re.findall(r"\"((?:\\.|[^\"\\])*)\"", line)
            if member and literals:
                index[(owner, member.group(1))] = literals[-1]
    return index


def swift_findings(root: Path) -> list[Finding]:
    base = root / SWIFT_TREE
    if not base.is_dir():
        return []
    files = sorted(base.rglob("*.swift"))
    index = swift_index(files)
    out = []
    for path in files:
        rel = path.relative_to(root).as_posix()
        text = path.read_text(encoding="utf-8")
        if "NSAlert" not in text and ".alert(" not in text:
            continue
        for number, line in enumerate(text.splitlines(), 1):
            match = re.search(r"\.(?:messageText|informativeText)\s*=\s*(.+)$", line) or \
                re.search(r"\.alert\(\s*(\"(?:\\.|[^\"\\])*\"|[A-Z]\w*\.\w+)", line)
            if not match:
                continue
            rhs = match.group(1)
            values = re.findall(r"\"((?:\\.|[^\"\\])*)\"", rhs)
            for owner, member in re.findall(r"\b([A-Z]\w*)\.(\w+)", rhs):
                if (owner, member) in index:
                    values.append(index[(owner, member)])
            for value in values:
                for rule, why in string_rules(value):
                    out.append(Finding(rule, rel, value, rel, number, why))
    return out


def all_findings(root: Path) -> list[Finding]:
    return catalog_findings(root) + tsx_findings(root) + component_findings(root) + swift_findings(root)


def entry(finding: Finding) -> dict:
    return {"rule": finding.rule, "where": finding.where, "text": finding.text}


def entry_key(item: dict) -> tuple[str, str, str]:
    return (item["rule"], item["where"], item["text"])


def read_baseline(text: str | None) -> Counter:
    if not text:
        return Counter()
    return Counter(entry_key(item) for item in json.loads(text).get("offenders", []))


def write_baseline(root: Path, findings: list[Finding]) -> None:
    items = sorted((entry(f) for f in findings), key=entry_key)
    data = {
        "comment": "Shrink-only: today's user-facing string offenders (scripts/cmux-next/check-user-facing-strings.py). "
                   "Fix one and delete its entry; never add one.",
        "offenders": items,
    }
    (root / BASELINE).write_text(json.dumps(data, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")


def base_baseline(root: Path, base: str) -> str | None:
    result = subprocess.run(["git", "-C", str(root), "show", f"{base}:{BASELINE}"], capture_output=True, text=True)
    return result.stdout if result.returncode == 0 else None


def check(root: Path, base: str = "", counts: bool = False) -> int:
    findings = all_findings(root)
    path = root / BASELINE
    baseline = read_baseline(path.read_text(encoding="utf-8") if path.is_file() else None)
    have = Counter(f.key() for f in findings)
    problems = []
    budget = Counter(baseline)
    for finding in findings:
        if budget[finding.key()] > 0:
            budget[finding.key()] -= 1
            continue
        problems.append(f"{finding.shown()} — new; fix the string or the surface (one short true sentence, "
                        "one working action, plain words)")
    for key, count in sorted((baseline - have).items()):
        problems.append(f"{BASELINE}: stale entry ×{count} {json.dumps(list(key))}: no longer an offender; "
                        "delete it")
    if base:
        before = base_baseline(root, base)
        if before is not None:
            for key, count in sorted((baseline - read_baseline(before)).items()):
                problems.append(f"{BASELINE}: grew ×{count} {json.dumps(list(key))}: the base {base[:12]} does "
                                "not list it; the baseline only shrinks, fix the offender instead")
    if counts:
        by_rule = Counter(f.rule for f in findings)
        print("user-facing strings: " + ", ".join(f"{rule} {n}" for rule, n in sorted(by_rule.items()))
              + f", total {sum(by_rule.values())}")
    for problem in problems:
        print(problem)
    if problems:
        print(f"user-facing strings: {len(problems)} problem(s); see cmuxterm-hq "
              "docs/handbook/user-facing-state-contradicts-or-dead-ends.md", file=sys.stderr)
        return 1
    return 0


def self_test() -> int:
    failures = []

    def expect(name: str, got, want) -> None:
        if got != want:
            failures.append(f"{name}: got {got!r}, want {want!r}")

    expect("one sentence", sentence_count("Claude Code isn't installed."), 1)
    expect("ellipsis", sentence_count("Installing… Retry when it ends."), 1)
    expect("two", sentence_count("The chat could not start. Try again."), 2)
    expect("question then sentence", sentence_count("Lost the link? Reconnect to keep going."), 2)
    expect("file extension", sentence_count("Could not read AGENTS.md."), 1)
    expect("placeholder", sentence_count("{name} is not installed."), 1)
    expect("jargon socket", [r for r, _ in string_rules("The socket is closed.")], ["jargon"])
    expect("GitHub is not hub", string_rules("Sign in to GitHub."), [])
    expect("acpmux", [w for _, w in string_rules("acpmux failed")], ["acpmux"])
    expect("JSON-RPC once", [w for _, w in string_rules("JSON-RPC error")], ["JSON-RPC"])
    expect("filler", [r for r, _ in string_rules("Something went wrong")], ["filler"])
    expect("clean", string_rules("Codex isn't installed."), [])

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        acp = root / TSX_TREE
        acp.mkdir(parents=True)
        (root / "scripts").mkdir()
        catalog = {"sourceLanguage": "en", "strings": {
            "host.failed": {"localizations": {"en": {"stringUnit": {"state": "translated",
                                                                    "value": "The daemon failed. Try again."}}}},
            "chat.title": {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "Chat"}}}},
            "harness.missing": {"localizations": {"en": {"stringUnit": {"state": "translated",
                                                                        "value": "Codex isn't installed."}}}},
        }}
        (acp / "Localizable.xcstrings").write_text(json.dumps(catalog, indent=2))
        (acp / "Bad.tsx").write_text(
            'export function Bad({ error }: { error: Error }) {\n'
            '  // Something went wrong in a comment is fine.\n'
            '  return (\n'
            '    <div title="Unable to reach the socket">\n'
            '      <p>Something went wrong</p>\n'
            '      <p>{error.message}</p>\n'
            '      {console.error(String(error))}\n'
            '      <Notice id="dead" tier="error" when={error}>\n'
            '        <p>Failed</p>\n'
            '      </Notice>\n'
            '      <Notice id="alive" tier="error" when={error}>\n'
            '        <Line onRetry={() => undefined} />\n'
            '      </Notice>\n'
            '      <Notice id="hint" tier="hint" when>\n'
            '        <p>Tip</p>\n'
            '      </Notice>\n'
            '      <Notice id="opaque" tier={x ? "status" : "error"} when>\n'
            '        {card}\n'
            '      </Notice>\n'
            '    </div>\n'
            '  );\n'
            '}\n')
        (acp / "Store.tsx").write_text(
            'export function save(failure: unknown, setState: (s: object) => void) {\n'
            '  console.warn("save failed", failure.message);\n'
            '  setState({\n'
            '    kind: "failed",\n'
            '    reason: failure.message,\n'
            '  });\n'
            '}\n')
        (acp / "Bad.gallery.tsx").write_text('export const x = <p>Something went wrong</p>;\n')
        (acp / "MissingChat.tsx").write_text(
            'export function MissingChat({ onClose }: {\n  onClose(): void;\n}) {\n'
            '  return <button onClick={onClose}>Close</button>;\n}\n')
        (acp / "HostError.tsx").write_text(
            'export function HostError({ message }: {\n  message: string;\n}) {\n  return <p>{message}</p>;\n}\n'
            'export function HostUnavailableLine({ onRetry }: {\n  onRetry(): void;\n}) {\n  return null;\n}\n')
        swift = root / SWIFT_TREE / "Mod"
        swift.mkdir(parents=True)
        (swift / "ModStrings.swift").write_text(
            'enum ModStrings {\n    static var failed: String { t("mod.failed", "The FFI call failed.") }\n}\n')
        (swift / "Mod.swift").write_text(
            'import AppKit\nfunc f() {\n    let alert = NSAlert()\n    alert.messageText = ModStrings.failed\n'
            '    alert.informativeText = "An error occurred. Please try again later."\n}\n')
        got = Counter((f.rule, f.where, f.text) for f in all_findings(root))
        tsx = f"{TSX_TREE}/Bad.tsx"
        sw = f"{SWIFT_TREE}/Mod/Mod.swift"
        want = Counter({
            ("jargon", "catalog:host.failed", "daemon"): 1,
            ("sentences", "catalog:host.failed", ""): 1,
            ("jargon", tsx, "Unable to reach the socket"): 1,
            ("filler", tsx, "Something went wrong"): 1,
            ("raw-error", tsx, "error.message"): 1,
            ("raw-error", f"{TSX_TREE}/Store.tsx", "failure.message"): 1,
            ("no-action", tsx, "Notice dead"): 1,
            ("no-action", tsx, "Notice opaque"): 1,
            ("no-action", f"{TSX_TREE}/HostError.tsx", "HostError"): 1,
            ("no-action", f"{TSX_TREE}/ChatUnavailableState.tsx", "ChatUnavailableState"): 1,
            ("no-action", f"{TSX_TREE}/HarnessHealthNotice.tsx", "HarnessHealthNotice"): 1,
            ("no-action", f"{TSX_TREE}/PermissionCard.tsx", "PermissionCard"): 1,
            ("jargon", sw, "The FFI call failed."): 1,
            ("filler", sw, "An error occurred. Please try again later."): 1,
            ("sentences", sw, "An error occurred. Please try again later."): 1,
        })
        expect("fixture findings", sorted(got.items()), sorted(want.items()))

        # The ratchet: a fresh baseline passes; a new offender fails; a fixed but listed one fails.
        write_baseline(root, all_findings(root))
        expect("baseline passes", check(root), 0)
        (acp / "New.tsx").write_text('export const y = <p>Something went wrong</p>;\n')
        expect("new offender fails", check(root), 1)
        (acp / "New.tsx").unlink()
        (acp / "Bad.tsx").write_text((acp / "Bad.tsx").read_text().replace("<p>{error.message}</p>", "<p />"))
        expect("stale entry fails", check(root), 1)
        write_baseline(root, all_findings(root))
        expect("shrunk baseline passes", check(root), 0)
        # Growth against a base: the base's baseline lacks an entry the head lists.
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        subprocess.run(["git", "-C", str(root), "add", "-A"], check=True)
        subprocess.run(["git", "-C", str(root), "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "b"],
                       check=True)
        expect("same as base passes", check(root, base="HEAD"), 0)
        (acp / "New.tsx").write_text('export const y = <p>Something went wrong</p>;\n')
        write_baseline(root, all_findings(root))
        expect("grown baseline fails against base", check(root, base="HEAD"), 1)
        expect("grown baseline passes without base", check(root), 0)

    for failure in failures:
        print(f"self-test: {failure}")
    print(f"self-test: {'FAILED' if failures else 'ok'}")
    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=REPO)
    parser.add_argument("--base", default=os.environ.get("BASE_REF", ""),
                        help="refuse baseline entries this ref's baseline lacks (default: $BASE_REF)")
    parser.add_argument("--counts", action="store_true", help="print the offender count by rule")
    parser.add_argument("--write-baseline", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    root = Path(args.root).resolve()
    if args.write_baseline:
        write_baseline(root, all_findings(root))
        return 0
    return check(root, args.base, args.counts)


if __name__ == "__main__":
    sys.exit(main())
