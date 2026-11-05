#!/usr/bin/env python3
"""Send-path cap guard: no new hard-coded size or count cap where a message, prompt or file travels.

The rule: nothing in the send path caps how big a message, prompt or attachment is, or how many files a
send takes. Attachments take arbitrarily large files of any type. A cap the audit is still removing is
listed as debt; a new one fails here.

tests/send-path-cap-allowlist.json is the one place that says what the send path is ("paths": "include"
prefixes, "include_named" prefixes whose file names must match a pattern, and "exclude" substrings) and
which files may still hold caps ("files": {path: {"count": N, "reason": "..."}}). A match is:

  decl     a cap-like name given a value: MAX_PROMPT_BYTES = ..., let maxBytes = ..., max_message_size:
           Some(1 << 20), maxFileSize: 10_000_000. A cap-like name has a cap word (max, maximum, limit, cap)
           and a size or count word (bytes, size, len, length, chars, kib, mib, attachments, files, uploads,
           images, body, payload, prompt). CHUNK/BUF/PAGE names without a cap word never match, so a
           64 KiB read chunk is fine; MAX_CHUNK_BYTES does match.
  literal  a comparison against a byte-size literal: len > 64 * 1024, size <= 1 << 20, n < 65536, 0x10000,
           1_048_576, 10 * MiB.
  schema   .max(N), maxLength(N) or maxItems(N) on a zod or Effect schema (a number() range is not a cap).
  layer    a body-limit layer or call: DefaultBodyLimit::max(...), bodyLimit(...),
           RequestBodyLimitLayer::new(...).

Comments, strings, test files, Rust #[cfg(test)] modules, fixtures and generated files are not scanned.

The test fails when a file not listed matches, when a file has more matches than its entry (a new cap),
when it has fewer (lower the count, so the list only shrinks), when an entry is stale, and when an entry's
reason does not start with "debt: ", "safe: " or "platform: ". Reasons:

  debt:      a cap the send-path limits audit is removing.
  platform:  a real platform limit the code is designed around; name it (Cloudflare's 100 MB request
             body, a Durable Object value, a Workers WebSocket message, the OS ARG_MAX ...).
  safe:      a bound that never refuses a user's message or file (a DoS guard on unauthenticated input,
             a derived preview budget, a transfer chunk a loop splits at).

In CI, CMUX_GUARDS_BASE_SHA (or SEND_PATH_CAPS_BASE) names the base commit. An entry added or raised since
that commit's allowlist fails unless its reason starts with "safe:" or "platform:", so a PR cannot allowlist
its own new cap as debt; and the send path may not shrink (an include dropped, an exclude added).
"""

from __future__ import annotations

import ast
import functools
import json
import os
import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ALLOWLIST = Path(__file__).resolve().parent / "send-path-cap-allowlist.json"
SOURCE_SUFFIXES = (".rs", ".ts", ".tsx", ".js", ".mjs", ".cjs", ".swift")
REASON = re.compile(r"(debt|safe|platform): \S")
GROWABLE = ("safe:", "platform:")

# A test, fixture or generated file is never the send path.
TEST_PART = re.compile(r"^(tests?|__tests__|__mocks__|fixtures?|__fixtures__|testdata|test-support|generated|gallery|"
                       r"lint-fixtures|e2e|mocks?|[A-Za-z0-9]+Tests|[A-Za-z0-9]+TestSupport)$")
TEST_NAME = re.compile(r"((?:^|[._-])[Mm]ocks?[._-]|^mock[A-Z]|(?:^|[._-])fixtures?[._-]|^tests?\.rs$|_tests?\.rs$|\.test\.|\.spec\.|\.stories\.|\.gallery\.|\.fixture\.|Tests?\.swift$|"
                       r"\.d\.ts$|\.generated\.|_generated\.|_wasm\.js$|\.wasm\.js$)")

# ---- names -------------------------------------------------------------------------------------------------
CAP_WORDS = {"max", "maximum", "limit", "cap"}
SIZE_WORDS = {"bytes", "byte", "size", "len", "length", "chars", "characters", "kib", "mib", "kb", "mb",
              "body", "payload", "prompt"}
COUNT_WORDS = {"attachment", "attachments", "files", "uploads", "images"}
# A cap on an identifier, a label or a derived preview never refuses a user's message or file.
METADATA_WORDS = {"name", "names", "id", "ids", "title", "key", "keys", "token", "tokens", "secret", "url", "urls",
                  "uri", "label", "labels", "emoji", "stamp", "header", "headers", "error", "errors", "query",
                  "hostname", "host", "display", "avatar", "icon", "cursor", "slug", "branch", "email", "password",
                  "ticket", "path", "paths", "field", "reason", "summary", "preview", "poster", "thumbnail", "pixel",
                  "dimension", "width", "height", "warm", "cache", "log", "logs", "stderr", "stdout", "excerpt",
                  "snippet", "chunk", "buf", "buffer", "page", "disk", "memory"}
# A literal value below this is a field length (a name, an id), not a message, prompt or file cap; count caps
# (MAX_ATTACHMENTS = 10) are caps whatever their value.
SMALL = 4096


def words(name: str) -> list[str]:
    spaced = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1 \2", name))
    return [w.lower() for w in re.split(r"[\s_$]+", spaced) if w]


@functools.lru_cache(maxsize=None)
def cap_kind(name: str) -> str:
    """"size", "count" or "" for a name."""
    ws = set(words(name))
    if not ws & CAP_WORDS or ws & METADATA_WORDS:
        return ""
    if ws & COUNT_WORDS:
        return "count"
    return "size" if ws & SIZE_WORDS else ""


def cap_like(name: str) -> bool:
    return bool(cap_kind(name))


# ---- literals ----------------------------------------------------------------------------------------------
NUM = r"(?:0x[0-9A-Fa-f_]+|\d[\d_]*)"
UNIT = r"(?:1024|1_024|KiB|MiB|GiB|KB|MB|GB|KIB|MIB|GIB)"
UNITS = {"kib": 1024, "kb": 1024, "mib": 1 << 20, "mb": 1 << 20, "gib": 1 << 30, "gb": 1 << 30}
BYTE_LIT = (rf"(?:{NUM}\s*\*\s*{UNIT}(?:\s*\*\s*{UNIT})*|{NUM}\s*<<\s*(?:10|20|30)\b|"
            r"0x10000\b|65_?536\b|1_?048_?576\b|10_?485_?760\b|104_?857_?600\b)")
NUMERIC = rf"\(?\s*{NUM}(?:\s*(?:\*|<<|\+)\s*(?:{NUM}|{UNIT}))*\s*\)?"
NUMERIC_VALUE = re.compile(rf"\{{?\s*(?:Some\(\s*)?({NUMERIC})\s*\)?\s*\}}?\s*(?:[,;\n}})\]]|$)")
CAP_WORD = re.compile(r"[Mm]ax|MAX|[Ll]imit|LIMIT|[Cc]ap|CAP")
WORD_CHAR = re.compile(r"[\w$]")
ASSIGN = re.compile(r"\s*(?::[^=;\n{}()<>]*?)?\s*=(?![=>])\s*")
KEY = re.compile(r"\s*:\s*")
CALL = re.compile(r"\s*\(\s*")
LITERAL_HINT = re.compile(r"1_?024|<<\s*[123]0\b|0x10000|65_?536|048_?576|485_?760|857_?600|[KMG]i?B\b")
BYTE_LITERAL = re.compile(rf"(?<![\w.]){BYTE_LIT}")
# A port number or a memory size in MiB is not a payload.
NOT_BYTES = re.compile(r"(?i)port|memory|_mb\b|Mb\b")
COMPARED_BEFORE = re.compile(r"(?<![<>=\-!])[<>]=?\s*\(?\s*$")
COMPARED_AFTER = re.compile(r"\s*\)?\s*[<>]=?(?![<>=])")
SCHEMA = re.compile(rf"(?<!Math)(?<![\w$])\.max\(\s*({NUM})\s*\)|\b(?:is)?[Mm]axItems\(\s*({NUM})")
COUNTED = re.compile(r"(?i)attach|upload|file|image")
LAYER = re.compile(r"\bDefaultBodyLimit::max\b|(?<![\w$.])bodyLimit\s*\(|\bRequestBodyLimitLayer::new\b")
NUMBER_SCHEMA = re.compile(r"\b(?:number|int|bigint|positive|nonnegative|finite|safe)\s*\(|\bSchema\.(?:Number|Int|BigInt|NonNegative|Positive)")


NO_CAP = re.compile(r"(?:nil|null|undefined|None|Infinity|Number\.(?:MAX|POSITIVE)\w*|\.max\b|Int\.max|"
                    r"[iu](?:8|16|32|64|128|size)::MAX|\.greatestFiniteMagnitude|CGSize|NSSize|CGRect|\.init\(width|"
                    r"\.zero\b)")


def value(expression: str) -> int | None:
    """Bounded integer arithmetic on a literal (1 << 20, 64 * 1024, 10 * MiB), never names or calls."""
    text = expression.replace("_", "")
    while text.count(")") > text.count("("):
        text = text[:text.rindex(")")] + text[text.rindex(")") + 1:]
    while text.count("(") > text.count(")"):
        text = text.replace("(", "", 1)
    text = re.sub(r"(?i)\b(kib|kb|mib|mb|gib|gb)\b", lambda m: str(UNITS[m.group(1).lower()]), text)
    if len(text) > 80 or not re.fullmatch(r"[0-9a-fA-Fx\s()*+<]+", text):
        return None
    try:
        tree = ast.parse(text.strip(), mode="eval").body
    except SyntaxError:
        return None

    def ev(node: ast.AST) -> int:
        if isinstance(node, ast.Constant) and type(node.value) is int:
            return node.value
        if isinstance(node, ast.BinOp):
            left, right = ev(node.left), ev(node.right)
            if isinstance(node.op, ast.Mult):
                return left * right
            if isinstance(node.op, ast.Add):
                return left + right
            if isinstance(node.op, ast.LShift) and 0 <= right <= 63:
                return left << right
        raise ValueError(text)

    try:
        return ev(tree)
    except (ValueError, RecursionError):
        return None


def small(expression: str) -> bool:
    n = value(expression)
    return n is not None and n < SMALL


def cap_names(code: str):
    """(start, end, name) of every identifier holding a cap word, found from the word outwards."""
    seen = -1
    for m in CAP_WORD.finditer(code):
        if m.start() < seen:
            continue
        start, end = m.start(), m.end()
        while start > 0 and WORD_CHAR.match(code, start - 1):
            start -= 1
        while end < len(code) and WORD_CHAR.match(code, end):
            end += 1
        seen = end
        yield start, end, code[start:end]


def name_hit(code: str, start: int, end: int, name: str) -> bool:
    """A cap-like name given a value: assigned, keyed or passed a literal."""
    kind = cap_kind(name)
    if not kind or name[0].isdigit():
        return False
    rest = code[end:end + 240]
    for form, literal_only in ((ASSIGN, False), (KEY, True), (CALL, True)):
        f = form.match(rest)
        if not f:
            continue
        v = NUMERIC_VALUE.match(rest, f.end())
        if v is None:
            if literal_only:
                continue
            assigned = rest[f.end():]
            # No cap (nil, MAX), a geometry, or a parameter stored under its own name (self.maxBytes = maxBytes).
            if NO_CAP.match(assigned) or re.match(rf"{re.escape(name)}\s*(?:[;,\n)}}]|$)", assigned):
                return False
            return True
        if kind == "count" or not small(v.group(1)):
            return True
        return form is CALL and bool(COUNTED.search(schema_chain(code, start)))
    return False


# ---- source cleanup ----------------------------------------------------------------------------------------
STRIP_COMMON = r'"""[\s\S]*?"""|//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\\n])*"'
STRIP = {
    ".rs": re.compile(STRIP_COMMON + r"|'(?:\\.|[^'\\\n])'"),  # a char literal, never a lifetime
    ".swift": re.compile(STRIP_COMMON),
}
STRIP_JS = re.compile(STRIP_COMMON + r"|'(?:\\.|[^'\\\n])*'|`(?:\\.|[^`\\])*`")
CFG_TEST = re.compile(r"#\[cfg\(test\)\]\s*(?:#\[[^\]]*\]\s*)*(?:pub(?:\([^)]*\))?\s+)?mod\s+\w+\s*\{")


def blank(match: re.Match[str]) -> str:
    """A comment or string becomes spaces, keeping its newlines so line numbers hold."""
    text = match.group(0)
    return " " * len(text) if "\n" not in text else "\n".join(" " * len(part) for part in text.split("\n"))


def strip_tests(text: str) -> str:
    """Blank Rust #[cfg(test)] modules (on already-stripped text, so braces in strings do not count)."""
    out = text
    for m in reversed(list(CFG_TEST.finditer(text))):
        depth, i = 0, m.end() - 1
        while i < len(text):
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        out = out[:m.start()] + re.sub(r"[^\n]", " ", out[m.start():i + 1]) + out[i + 1:]
    return out


def clean(text: str, suffix: str) -> str:
    text = STRIP.get(suffix, STRIP_JS).sub(blank, text)
    return strip_tests(text) if suffix == ".rs" else text


def schema_chain(code: str, at: int) -> str:
    start = max(code.rfind(";", 0, at), code.rfind("\n\n", 0, at), code.rfind("=", 0, at), at - 160, 0)
    return code[start:at]


def matches(text: str, rel: str) -> list[tuple[int, str]]:
    """(line, kind: snippet) for every cap in one file's source."""
    suffix = Path(rel).suffix
    code = clean(text, suffix)
    hits: dict[int, str] = {}
    for start, end, name in cap_names(code):
        if name_hit(code, start, end, name):
            hits.setdefault(start, "decl")
    for m in BYTE_LITERAL.finditer(code) if LITERAL_HINT.search(code) else ():
        before = code[max(0, m.start() - 12):m.start()]
        if NOT_BYTES.search(code, max(0, m.start() - 32), m.start()):
            continue
        if (COMPARED_BEFORE.search(before) or COMPARED_AFTER.match(code, m.end())) and not small(m.group(0)):
            hits.setdefault(m.start(), "literal")
    if suffix not in (".rs", ".swift"):
        for m in SCHEMA.finditer(code) if (".max(" in code or "axItems(" in code) else ():
            chain = schema_chain(code, m.start())
            if NUMBER_SCHEMA.search(chain):
                continue
            if COUNTED.search(chain) or not small(m.group(1) or m.group(2)):
                hits.setdefault(m.start(), "schema")
    for m in LAYER.finditer(code) if "odyLimit" in code else ():
        hits.setdefault(m.start(), "layer")
    lines = text.split("\n")
    out = []
    for at, kind in sorted(hits.items()):
        line = code.count("\n", 0, at) + 1
        out.append((line, f"{kind}: {lines[line - 1].strip()[:140]}"))
    return out


# ---- the send path -----------------------------------------------------------------------------------------
def config(allow: dict) -> dict:
    return allow.get("paths", {})


def in_send_path(rel: str, paths: dict) -> bool:
    if not rel.endswith(SOURCE_SUFFIXES):
        return False
    parts = rel.split("/")
    if any(TEST_PART.match(p) for p in parts[:-1]) or TEST_NAME.search(parts[-1]):
        return False
    if any(x in rel for x in paths.get("exclude", [])):
        return False
    if any(rel.startswith(p) for p in paths.get("include", [])):
        return True
    for prefix, pattern in paths.get("include_named", {}).items():
        if rel.startswith(prefix) and re.search(pattern, parts[-1]):
            return True
    return False


# Every match needs one of these in its file: a fixed-string git grep narrows the tracked files first.
PREFILTER = ("max", "limit", "cap", "1024", "1_024", "<<", "65536", "65_536", "0x10000", "048576", "048_576",
             "485760", "485_760", "857600", "857_600", "kib", "mib", "gib")


def candidate_files(root: Path, paths: dict) -> list[str]:
    specs = list(paths.get("include", [])) + list(paths.get("include_named", {}))
    if not specs:
        return []
    argv = ["git", "-C", str(root), "grep", "-I", "-l", "-z", "-F", "-i"]
    for word in PREFILTER:
        argv += ["-e", word]
    argv += ["--", *specs]
    p = subprocess.run(argv, capture_output=True)
    if p.returncode not in (0, 1):
        raise RuntimeError(p.stderr.decode(errors="replace"))
    return sorted(rel for rel in p.stdout.decode().split("\0") if rel and in_send_path(rel, paths))


def scan(root: Path, paths: dict) -> dict[str, list[tuple[int, str]]]:
    found = {}
    for rel in candidate_files(root, paths):
        path = root / rel
        if path.is_symlink() or not path.is_file():
            continue
        try:
            text = path.read_text()
        except (UnicodeDecodeError, OSError):
            continue
        hits = matches(text, rel)
        if hits:
            found[rel] = hits
    return found


# ---- the ratchet -------------------------------------------------------------------------------------------
HOW = ("no size or count cap in the send path: messages, prompts and attachments of any size and number go "
       "through (stream, chunk or hand off by reference instead). A real platform limit or a bound that never "
       "refuses a user's send gets an entry in tests/send-path-cap-allowlist.json with a reason starting "
       "\"platform: \" or \"safe: \" that names it")


def problems(found: dict[str, list[tuple[int, str]]], allow: dict) -> list[str]:
    files = allow.get("files", {})
    out = []
    for rel, hits in sorted(found.items()):
        entry = files.get(rel)
        n = len(hits)
        shown = "; ".join(f"L{line} {what}" for line, what in hits[:6]) + (" ..." if n > 6 else "")
        if entry is None:
            out.append(f"{rel}: {n} new cap(s): {shown}")
        elif n > entry.get("count", 0):
            out.append(f"{rel}: {n} caps, allowlist says {entry.get('count')}: a new one: {shown}")
        elif n < entry.get("count", 0):
            out.append(f"{rel}: {n} caps, allowlist says {entry['count']}: lower the count in "
                       f"tests/send-path-cap-allowlist.json (it only shrinks)")
    for rel, entry in sorted(files.items()):
        count = entry.get("count")
        if type(count) is not int or count < 1:
            out.append(f"{rel}: allowlist count must be a positive integer, not {count!r}")
        if rel not in found:
            out.append(f"{rel}: allowlisted but has no cap now; remove its entry")
        if not REASON.match(str(entry.get("reason", ""))):
            out.append(f"{rel}: allowlist reason must start with \"debt: \", \"safe: \" or \"platform: \" and say why")
    return out


def grown(base: dict, allow: dict, tracked=lambda prefix: True) -> list[str]:
    """Entries added or raised since the base whose reason is debt; and a send path that shrank.

    An include dropped because the code under it was deleted (``tracked`` finds no file) is not a shrink."""
    out = []
    old = base.get("files", {})
    for rel, entry in sorted(allow.get("files", {}).items()):
        was = old.get(rel, {}).get("count", 0)
        if entry.get("count", 0) > was and not str(entry.get("reason", "")).startswith(GROWABLE):
            out.append(f"{rel}: allowlist {was} -> {entry.get('count')} since the base: a new cap is not debt "
                       f"(remove it, or give a reason starting \"platform:\" or \"safe:\" that names why)")
    before, after = config(base), config(allow)
    for prefix in before.get("include", []):
        if prefix not in after.get("include", []) and tracked(prefix):
            out.append(f"paths.include: {prefix} was dropped since the base; the send path only grows")
    for prefix, pattern in before.get("include_named", {}).items():
        if after.get("include_named", {}).get(prefix) != pattern:
            out.append(f"paths.include_named: {prefix} changed since the base; the send path only grows")
    for x in after.get("exclude", []):
        if x not in before.get("exclude", []):
            out.append(f"paths.exclude: {x} was added since the base; the send path only grows")
    return out


def base_allowlist(root: Path = ROOT) -> dict | None:
    base = (os.environ.get("SEND_PATH_CAPS_BASE") or os.environ.get("CMUX_GUARDS_BASE_SHA") or "").strip()
    if not base or set(base) == {"0"}:
        return None
    if subprocess.run(["git", "-C", str(root), "cat-file", "-e", f"{base}^{{commit}}"], capture_output=True).returncode:
        return None
    p = subprocess.run(["git", "-C", str(root), "show", f"{base}:{ALLOWLIST.relative_to(ROOT).as_posix()}"],
                       capture_output=True, text=True)
    return json.loads(p.stdout) if p.returncode == 0 else None


class SendPathCaps(unittest.TestCase):
    def test_send_path_has_no_new_caps(self):
        allow = json.loads(ALLOWLIST.read_text())
        found = scan(ROOT, config(allow))
        bad = problems(found, allow)
        base = base_allowlist()
        if base is not None:
            bad += grown(base, allow, tracked=lambda prefix: bool(subprocess.run(
                ["git", "-C", str(ROOT), "ls-files", "--", prefix + "*"], capture_output=True, text=True).stdout.strip()))
        self.assertEqual(bad, [], f"send-path cap guard ({HOW}):\n  " + "\n  ".join(bad))

    def test_paths_are_declared(self):
        paths = config(json.loads(ALLOWLIST.read_text()))
        self.assertTrue(paths.get("include"))
        for prefix in list(paths["include"]) + list(paths.get("include_named", {})):
            with self.subTest(prefix=prefix):
                hits = subprocess.run(["git", "-C", str(ROOT), "ls-files", "--", prefix + "*"],
                                      capture_output=True, text=True).stdout
                self.assertTrue(hits.strip(), f"{prefix} names no tracked file: fix or drop it")


class Matcher(unittest.TestCase):
    def count(self, source: str, rel: str = "cmux-tui/crates/acpmux/src/send.rs") -> int:
        return len(matches(source, rel))

    def test_new_caps_are_flagged(self):
        for rel, source in (
            ("a.rs", "const MAX_PROMPT_BYTES: usize = 64 * 1024;"),
            ("a.rs", "pub const MAX_ATTACHMENTS: usize = 10;"),
            ("a.rs", "let cfg = WebSocketConfig { max_message_size: Some(1 << 20), ..Default::default() };"),
            ("a.rs", "if prompt.len() > 64 * 1024 { return Err(TooLarge); }"),
            ("a.rs", "router.layer(DefaultBodyLimit::max(limit))"),
            ("a.rs", "ws.max_frame_size(Some(16 << 20));"),
            ("a.ts", "const maxBytes = 10 * 1024 * 1024;"),
            ("a.ts", "export const MAX_FILE_SIZE = 25_000_000;"),
            ("a.ts", "const Body = z.object({ prompt: z.string().max(65536) });"),
            ("a.ts", "const Prompt = Schema.String.pipe(Schema.maxLength(100000));"),
            ("a.ts", "app.use(bodyLimit(options));"),
            ("a.ts", "if (text.length >= 0x10000) throw new Error('too big');"),
            ("a.ts", "upload({ maxFileSize: 5_000_000 })"),
            ("a.swift", "static let maximumAttachmentBytes = 100 * 1024 * 1024"),
            ("a.swift", "guard data.count <= 1_048_576 else { return }"),
            ("a.swift", "self.maxPromptLength = limit"),
            ("a.ts", "const Send = z.object({ attachments: z.array(Attachment).max(10) });"),
            ("a.ts", "const Files = Schema.Array(UploadFile).check(Schema.isMaxLength(16));"),
            ("a.tsx", "<textarea maxLength={32000} />"),
            ("a.swift", "func send(maxBytes: Int = 50 << 20) {}"),
        ):
            with self.subTest(source=source):
                self.assertEqual(self.count(source, rel), 1, matches(source, rel))

    def test_unrelated_numbers_are_not_flagged(self):
        for rel, source in (
            ("a.rs", "const READ_CHUNK_SIZE: usize = 64 * 1024;"),
            ("a.rs", "let mut buf = vec![0u8; 65536];"),
            ("a.rs", "const BUF_LEN: usize = 1 << 20;"),
            ("a.rs", "const PAGE_SIZE: usize = 4096;"),
            ("a.rs", "const MAX_RETRIES: u32 = 5;"),
            ("a.rs", "let n = a.max(b);"),
            ("a.rs", "if max_bytes == 0 { return; }"),
            ("a.rs", "fn f<'a>(x: &'a str) -> Vec<u8> { Vec::with_capacity(1 << 20) }"),
            ("a.rs", "let shifted = x << 20;"),
            ("a.rs", "// MAX_PROMPT_BYTES = 64 * 1024 was removed"),
            ("a.rs", 'let msg = "max_bytes = 10 * 1024";'),
            ("a.rs", "#[cfg(test)]\nmod tests {\n    const MAX_BYTES: usize = 64 * 1024;\n}\n"),
            ("a.ts", "const width = Math.max(10, 20);"),
            ("a.ts", "const Retries = z.number().int().max(10);"),
            ("a.ts", "const CHUNK_BYTES = 256 * 1024;"),
            ("a.ts", "if (maxBytes <= 0) return;"),
            ("a.ts", "const f = (a: number) => a >= 2;"),
            ("a.swift", "let pageSize = 64 * 1024"),
            ("a.ts", "const MAX_NAME_CHARS = 64;"),
            ("a.ts", "const Name = Schema.String.pipe(Schema.maxLength(128));"),
            ("a.tsx", "<input maxLength={64} />"),
            ("a.ts", "if (port > 0 && port < 65536) ports.add(port);"),
            ("a.swift", "self.maxBytes = maxBytes"),
            ("a.swift", "generator.maximumSize = CGSize(width: side, height: side)"),
            ("a.rs", "pub max_message_size: Option<usize>,"),
            ("a.rs", "let max_bytes = None;"),
        ):
            with self.subTest(source=source):
                self.assertEqual(self.count(source, rel), 0, matches(source, rel))

    def test_test_and_generated_files_are_outside_the_send_path(self):
        paths = {"include": ["cmux-tui/crates/acpmux/src/", "webviews/src/agent-session/"],
                 "include_named": {"Packages/macOS/CmuxNext/Sources/CmuxNextApp/": r"(Upload|Attachment)"},
                 "exclude": ["/vendor/"]}
        self.assertTrue(in_send_path("cmux-tui/crates/acpmux/src/hub/send.rs", paths))
        self.assertTrue(in_send_path("webviews/src/agent-session/acpmux/composer/Composer.tsx", paths))
        self.assertTrue(in_send_path("Packages/macOS/CmuxNext/Sources/CmuxNextApp/AgentChatUploads.swift", paths))
        for rel in ("cmux-tui/crates/acpmux/src/wire_size_tests.rs", "cmux-tui/crates/acpmux/src/tests.rs",
                    "cmux-tui/crates/acpmux/src/fixtures/a.rs", "webviews/src/agent-session/a.test.ts",
                    "webviews/src/agent-session/x.gallery.tsx", "webviews/src/agent-session/types.d.ts",
                    "webviews/src/agent-session/README.md", "cmux-tui/crates/acpmux/src/vendor/x.rs",
                    "Packages/macOS/CmuxNext/Sources/CmuxNextApp/AppDelegate.swift", "cmux-tui/crates/cmux-remote/src/a.rs"):
            with self.subTest(rel=rel):
                self.assertFalse(in_send_path(rel, paths))

    def test_allowlisted_counts_pass_and_the_list_only_shrinks(self):
        hit = [(1, "decl: const MAX_BYTES = 1")]
        allow = {"files": {"a.rs": {"count": 1, "reason": "platform: Workers WebSocket message is 1 MiB"}}}
        self.assertEqual(problems({"a.rs": hit}, allow), [])
        self.assertEqual(len(problems({"a.rs": hit * 2}, allow)), 1)  # a new cap
        self.assertEqual(len(problems({"b.rs": hit, "a.rs": hit}, allow)), 1)  # an unlisted file
        self.assertEqual(len(problems({"a.rs": hit}, {"files": {"a.rs": {"count": 2, "reason": "debt: x"}}})), 1)
        self.assertEqual(len(problems({}, allow)), 1)  # stale
        self.assertEqual(len(problems({"a.rs": hit}, {"files": {"a.rs": {"count": 1, "reason": "because"}}})), 1)
        self.assertEqual(len(problems({"a.rs": hit}, {"files": {"a.rs": {"count": 1}}})), 1)

    def test_removed_chief_caps_are_in_scope_and_have_no_exemption(self):
        allow = json.loads(ALLOWLIST.read_text())
        for rel, source in (
            ("cmux-tui/crates/cmux-tui/src/cli/chief/backend.rs", "const MAX_ATTACHMENT: u64 = 100_000_000;"),
            ("Native/OptChat/chief-kernel/src/tools.rs", "pub const MAX_SEND_ATTACHMENTS: usize = 10;"),
            ("Native/OptChat/optchat-chief/src/brain/media.rs", "pub const MAX_MEDIA_BYTES: u64 = 50_000_000;"),
            ("backend/apps/api/src/chief-brain-cc/attachments.ts", "export const MAX_FILES = 12"),
        ):
            with self.subTest(path=rel):
                self.assertTrue(in_send_path(rel, config(allow)))
                hits = matches(source, rel)
                self.assertEqual(len(hits), 1, hits)
                self.assertNotIn(rel, allow["files"])
                self.assertTrue(problems({rel: hits}, {"files": {}}))

    def test_base_ratchet_refuses_new_debt(self):
        base = {"paths": {"include": ["a/"], "exclude": []},
                "files": {"a/x.rs": {"count": 2, "reason": "debt: pre-existing"}}}

        def now(files, include=("a/",), exclude=()):
            return {"paths": {"include": list(include), "exclude": list(exclude)}, "files": files}

        self.assertEqual(grown(base, now({"a/x.rs": {"count": 1, "reason": "debt: pre-existing"}})), [])
        self.assertEqual(len(grown(base, now({"a/x.rs": {"count": 3, "reason": "debt: pre-existing"}}))), 1)
        self.assertEqual(len(grown(base, now({"a/y.rs": {"count": 1, "reason": "debt: new"}}))), 1)
        self.assertEqual(grown(base, now({"a/y.rs": {"count": 1, "reason": "safe: DoS guard on unauthenticated input"}})), [])
        self.assertEqual(grown(base, now({"a/y.rs": {"count": 1, "reason": "platform: Cloudflare 100 MB body"}})), [])
        self.assertEqual(len(grown(base, now({}, include=()))), 1)  # the send path shrank
        self.assertEqual(grown(base, now({}, include=()), tracked=lambda prefix: False), [])  # its code was deleted
        self.assertEqual(len(grown(base, now({}, exclude=("a/x",)))), 1)


if __name__ == "__main__":
    unittest.main()
