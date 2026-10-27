#!/usr/bin/env python3
"""Crash signatures: one stable id per bug, from any crash, panic, sanitizer or hang report.

Usage: crash_signature.py [--ignore FILE] [--include-test] [--process NAME] PATH...

Reads each report and prints one JSON line per signature:
{kind, process, exception, frames, hash12, source, ...}. Kinds:

  crash        macOS .ips crash report (crashed thread)
  nsexception  .ips with an uncaught NSException (lastExceptionBacktrace)
  rust-panic   cmux-panic-log JSONL lines (cmux-tui/crates/cmux-panic-log)
  asan, tsan, ubsan, lsan
               sanitizer reports in any text output (one per report)
  hang         `sample` or spindump text (heaviest stack of the main thread)

The signature is ClusterFuzz's crash state (google/clusterfuzz
src/clusterfuzz/stacktraces/__init__.py, constants.py): drop the frames that
match signature-ignore.txt (runtime, libc, allocators, assertion and panic
helpers, sanitizer runtime, Rust std source files), normalize the rest (no
offsets, addresses, generic arguments, closure numbers, Rust symbol hashes,
compiler thunks or outlining and LTO suffixes such as `.cold.1` and
`.llvm.123`), and keep the top 3. A Rust panic starts below its panic entry
point (`rust_begin_unwind`, `core::panicking::*`), and an inlined Rust frame's
bare name is qualified by its source file. hash12 is the first 12 hex digits of sha256 over kind, exception
and those frames, so the same bug from two builds gets the same id. A frame
with no symbol is its image plus offset, which buckets one build's
unsymbolicated crashes together. When every frame is ignored, the top 3
normalized frames are used, so such crashes still differ by their stack.

Exit status: 0 when every path parsed (even with no signature), 1 when a path
could not be read, 2 on bad arguments.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path

TOP_FRAMES = 3
HASH_DIGITS = 12
DEFAULT_IGNORE = Path(__file__).resolve().with_name("signature-ignore.txt")
MESSAGE_LIMIT = 300


@dataclass(frozen=True)
class Frame:
    """One stack frame: a function name (may be empty), its image, the offset in that image and its source file."""

    function: str
    image: str = ""
    offset: int | None = None
    file: str = ""


@dataclass
class Signature:
    kind: str
    process: str
    exception: str
    frames: list[str]
    hash12: str
    source: str = ""
    message: str = ""
    extra: dict = field(default_factory=dict)

    def to_json(self) -> dict:
        record = asdict(self)
        extra = record.pop("extra")
        record.update(extra)
        return record


class IgnoreList:
    """signature-ignore.txt: function regexes, `image:` regexes for whole binaries, `file:` regexes for source files."""

    def __init__(self, function_patterns: list[str], image_patterns: list[str], file_patterns: list[str] = ()):
        self.functions = [re.compile(pattern) for pattern in function_patterns]
        self.images = [re.compile(pattern) for pattern in image_patterns]
        self.files = [re.compile(pattern) for pattern in file_patterns]

    @classmethod
    def parse(cls, text: str) -> IgnoreList:
        functions: list[str] = []
        images: list[str] = []
        files: list[str] = []
        for raw in text.splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("image:"):
                images.append(line[len("image:"):].strip())
            elif line.startswith("file:"):
                files.append(line[len("file:"):].strip())
            else:
                functions.append(line)
        return cls(functions, images, files)

    @classmethod
    def load(cls, path: Path = DEFAULT_IGNORE) -> IgnoreList:
        return cls.parse(path.read_text(encoding="utf-8"))

    def ignores(self, function: str, image: str, file: str = "") -> bool:
        if image and any(pattern.search(image) for pattern in self.images):
            return True
        if file and any(pattern.search(file) for pattern in self.files):
            return True
        return bool(function) and any(pattern.search(function) for pattern in self.functions)


# ---------------------------------------------------------------- normalization

_RUST_HASH = re.compile(r"::h[0-9a-f]{16}$")
# Compiler outlining, partial inlining and ThinLTO suffixes: `foo.cold.1`, `bar.part.0`, `baz::h<hash>.llvm.123`.
_OUTLINED_SUFFIX = re.compile(r"(?:\.(?:cold|part|isra|constprop|llvm)\.\d+)+$")
_RUST_CLOSURE = re.compile(r"\{\{closure\}\}|\{closure#\d+\}")
_OBJC_BLOCK = re.compile(r"^__\d+(?=[-+]\[)")
_OBJC_BLOCK_SUFFIX = re.compile(r"(_block_invoke)(?:[._]\d+)+$")
_CLOSURE = re.compile(r"\b(implicit closure|closure)(?: #\d+)?(?: [@(][^#]*?)? in ")
_ASYNC_RESUME = re.compile(r"^\(\d+\) (?:await|suspend) resume partial function for ")
_SPECIALIZATION = re.compile(r"^(?:generic|function signature|generic partial) specialization\s*")
_WITNESS = re.compile(r"^protocol witness for (.+?) in conformance ([^\s:]+)")
_PREFIXES = (
    "specialized ",
    "partial apply for ",
    "merged ",
    "dispatch thunk of ",
    "@objc ",
    "@nonobjc ",
    "async function pointer to ",
    "key path getter for ",
    "key path setter for ",
    "lazy protocol witness table accessor for ",
)
# Mangled Swift: closure numbers and specialization or thunk suffixes.
_MANGLED_CLOSURE = re.compile(r"f([Uu])\d*_")
_MANGLED_SUFFIX = re.compile(r"(?:Tf\d\w*|Tg5|TG5|TA|Tm)+$")
_ACCESSOR_TYPE = re.compile(r"\.(getter|setter|modify|read|didset|willset|unsafeMutableAddressor|unsafeAddressor) : .*$")
_SPACES = re.compile(r"\s+")


def _strip_generics(text: str) -> str:
    """Drop generic arguments (`Array<Int>` -> `Array`); keep Rust `<X as Trait>` paths, generics removed inside."""
    out: list[str] = []
    i = 0
    n = len(text)
    while i < n:
        char = text[i]
        if char != "<" or _is_operator(text, i):
            out.append(char)
            i += 1
            continue
        end = _matching(text, i, "<", ">")
        if end < 0:
            out.append(text[i:])
            break
        inner = text[i + 1:end]
        if text[max(0, i - 2):i] == "::":
            # Rust turbofish `load::<cmux::Config>`: generic arguments, dropped with their `::`.
            del out[-2:]
        elif i == 0 or text[i - 1] in " (":
            qualified = _split_top_level(inner, " as ")
            if qualified is not None:
                out.append(f"<{_strip_generics(qualified[0])} as {_strip_generics(qualified[1])}>")
            elif inner.startswith("impl "):
                out.append(f"<{_strip_generics(inner)}>")
            else:
                out.append(_strip_generics(inner))
        i = end + 1
    return "".join(out)


def _is_operator(text: str, i: int) -> bool:
    return text[max(0, i - 8):i].endswith("operator") or text[i + 1:i + 2] in ("<", "=") or text[i - 1:i] == "-"


def _matching(text: str, start: int, opening: str, closing: str) -> int:
    depth = 0
    for index in range(start, len(text)):
        if text[index] == opening:
            depth += 1
        elif text[index] == closing and text[index - 1:index] != "-":
            depth -= 1
            if depth == 0:
                return index
    return -1


def _split_top_level(text: str, separator: str) -> tuple[str, str] | None:
    depth = 0
    for index in range(len(text)):
        char = text[index]
        if char in "<([":
            depth += 1
        elif char in ">)]":
            depth -= 1
        elif depth == 0 and text.startswith(separator, index):
            return text[:index], text[index + len(separator):]
    return None


def _strip_signature_types(text: str) -> str:
    """`foo(_: Swift.Int, bar: Swift.String) -> Swift.Bool` -> `foo(_:bar:)` (the simplified Swift form)."""
    open_at = text.find("(")
    if open_at <= 0:
        return text
    close_at = _matching(text, open_at, "(", ")")
    if close_at < 0:
        return text
    params = text[open_at + 1:close_at]
    rest = text[close_at + 1:]
    if re.match(r"^\s*(?:async\s*)?(?:throws(?:\([^)]*\))?\s*|rethrows\s*)?->", rest):
        rest = ""
    if params.strip() and (": " in params or "." in params):
        labels = []
        for part in _split_all_top_level(params, ","):
            label = part.split(": ", 1)[0].strip() if ": " in part else "_"
            labels.append(f"{label}:")
        params = "".join(labels)
    return f"{text[:open_at]}({params}){rest}"


def _split_all_top_level(text: str, separator: str) -> list[str]:
    parts: list[str] = []
    depth = 0
    start = 0
    for index, char in enumerate(text):
        if char in "<([":
            depth += 1
        elif char in ">)]":
            depth -= 1
        elif depth == 0 and char == separator:
            parts.append(text[start:index])
            start = index + 1
    parts.append(text[start:])
    return parts


def _strip_specialization(text: str) -> str:
    """`generic specialization <Swift.Array<Swift.Int>> of Foo.bar()` -> `Foo.bar()`, any nesting in the brackets."""
    match = _SPECIALIZATION.match(text)
    if not match:
        return text
    rest = text[match.end():]
    if rest.startswith("<"):
        end = _matching(rest, 0, "<", ">")
        if end < 0:
            return text
        rest = rest[end + 1:].lstrip()
    return rest.removeprefix("of ") if rest.startswith("of ") else text


def _witness(text: str) -> str:
    """`protocol witness for P.load() in conformance Model` -> `Model.load()`, the implementation it calls."""
    match = _WITNESS.match(text)
    if not match:
        return text
    requirement, conformer = match.group(1), match.group(2)
    paren = requirement.find("(")
    head = requirement if paren < 0 else requirement[:paren]
    tail = "" if paren < 0 else requirement[paren:]
    member = head.rsplit(".", 1)[-1]
    return f"{conformer}.{member}{tail}"


def normalize_function(name: str) -> str:
    """One function name with no build-specific parts: offsets, hashes, generics, closure numbers, thunk prefixes."""
    text = _SPACES.sub(" ", name.strip())
    if not text:
        return ""
    text = re.sub(r"\s*\+\s*(?:0x[0-9a-fA-F]+|\d+)$", "", text)
    text = _OUTLINED_SUFFIX.sub("", text)
    if text.startswith(("$s", "_$s", "$S", "_$S")):
        text = _MANGLED_CLOSURE.sub(r"f\1_", text)
        return _MANGLED_SUFFIX.sub("", text)
    text = _RUST_HASH.sub("", text)
    text = _RUST_CLOSURE.sub("{closure}", text)
    text = _OBJC_BLOCK.sub("", text)
    text = _OBJC_BLOCK_SUFFIX.sub(r"\1", text)
    changed = True
    while changed:
        changed = False
        before = text
        text = _ASYNC_RESUME.sub("", text)
        text = _strip_specialization(text)
        for prefix in _PREFIXES:
            text = text.removeprefix(prefix)
        changed = text != before
    text = _CLOSURE.sub(lambda match: f"{match.group(1)} in ", text)
    text = _witness(text)
    text = _strip_generics(text)
    text = _ACCESSOR_TYPE.sub(r".\1", text)
    if not text.startswith(("-[", "+[")) and "::" not in text:
        text = _strip_signature_types(text)
    return _SPACES.sub(" ", text).strip()


# An inlined Rust frame's bare name (`sorted`, `{closure}`): no path, no Swift or ObjC name, no signature.
_BARE_NAME = re.compile(r"[A-Za-z_{][\w{}]*")


def frame_label(frame: Frame) -> str:
    """The normalized function, or `image+0xoffset` for an unsymbolicated frame.

    An inlined Rust frame is a bare name (`sorted`, `{closure}`); its source file qualifies it, so two functions of
    one name in different modules stay apart: `sorted (acpmux/src/server/sessions.rs)`.
    """
    function = normalize_function(frame.function)
    if function and function not in ("???", "<unknown>", "<null>"):
        if frame.file.endswith(".rs") and _BARE_NAME.fullmatch(function):
            return f"{function} ({_crate_relative(frame.file)})"
        return function
    image = frame.image or "?"
    return f"{image}+0x{frame.offset:x}" if frame.offset is not None else image


def crash_state(frames: list[Frame], ignore: IgnoreList) -> list[str]:
    """Top TOP_FRAMES labels after the ignore list, consecutive duplicates collapsed (inlined thunks)."""
    kept: list[str] = []
    every: list[str] = []
    for frame in frames:
        label = frame_label(frame)
        if not label:
            continue
        if not every or every[-1] != label:
            every.append(label)
        if ignore.ignores(normalize_function(frame.function), frame.image, frame.file):
            continue
        if kept and kept[-1] == label:
            continue
        kept.append(label)
        if len(kept) == TOP_FRAMES:
            break
    return kept or every[:TOP_FRAMES]


def _crate_relative(path: str) -> str:
    """`/Users/me/cmux/cmux-tui/crates/acpmux/src/lib.rs` -> `acpmux/src/lib.rs`: no checkout path in the label."""
    path = path.replace("\\", "/")
    src = path.rfind("/src/")
    if src < 0:
        return os.path.basename(path)
    return path[path.rfind("/", 0, src) + 1:]


def signature_hash(kind: str, exception: str, frames: list[str]) -> str:
    material = "\n".join([kind, exception, *frames])
    return hashlib.sha256(material.encode("utf-8")).hexdigest()[:HASH_DIGITS]


def make_signature(kind: str, process: str, exception: str, frames: list[Frame], ignore: IgnoreList,
                   source: str = "", message: str = "", **extra) -> Signature:
    state = crash_state(frames, ignore)
    return Signature(kind=kind, process=process, exception=exception, frames=state,
                     hash12=signature_hash(kind, exception, state), source=source,
                     message=message[:MESSAGE_LIMIT], extra={key: value for key, value in extra.items() if value})


# ---------------------------------------------------------------- .ips

_TRAP_TYPES = ("EXC_BREAKPOINT", "EXC_BAD_INSTRUCTION")


def parse_ips(text: str, ignore: IgnoreList, source: str = "") -> list[Signature]:
    """A macOS .ips crash report (header JSON line, then the body JSON)."""
    header_text, _, body_text = text.partition("\n")
    try:
        header = json.loads(header_text or "{}")
        body = json.loads(body_text or "{}")
    except json.JSONDecodeError:
        return []
    if not isinstance(body, dict) or not body.get("threads"):
        return []
    images = body.get("usedImages") or []
    process = body.get("procName") or header.get("app_name") or header.get("name") or ""
    exception_info = body.get("exception") or {}
    message = _ips_message(body)
    main_uuid = _main_image_uuid(header, body, images)
    version = header.get("app_version") or header.get("build_version") or ""

    last_exception = body.get("lastExceptionBacktrace")
    name = _nsexception_name(body)
    if last_exception and name:
        frames = [_ips_frame(frame, images) for frame in last_exception]
        return [make_signature("nsexception", process, name, frames, ignore, source, message,
                               build_uuid=main_uuid, version=version)]

    threads = body.get("threads") or []
    crashed = next((thread for thread in threads if thread.get("triggered")), None)
    faulting = body.get("faultingThread")
    if crashed is None and isinstance(faulting, int) and 0 <= faulting < len(threads):
        crashed = threads[faulting]
    if crashed is None:
        return []
    frames = [_ips_frame(frame, images) for frame in crashed.get("frames") or []]
    exception_type = " ".join(
        part for part in (
            exception_info.get("type"),
            exception_info.get("signal"),
            re.sub(r"\s+at\s+0x[0-9a-fA-F]+.*$", "", exception_info.get("subtype") or "").strip(),
        ) if part
    ) or "unknown"
    # A Swift trap is EXC_BREAKPOINT on arm64 and EXC_BAD_INSTRUCTION on x86_64: one bug, one signature.
    exception = "trap" if exception_info.get("type") in _TRAP_TYPES else exception_type
    return [make_signature("crash", process, exception, frames, ignore, source, message,
                           build_uuid=main_uuid, version=version, queue=crashed.get("queue", ""),
                           exception_type=exception_type)]


def _main_image_uuid(header: dict, body: dict, images: list) -> str:
    """The app's own build UUID: the header's slice_uuid, else the image at procPath (usedImages has no fixed order)."""
    if header.get("slice_uuid"):
        return str(header["slice_uuid"])
    proc_path = body.get("procPath")
    main = next((image for image in images if isinstance(image, dict) and proc_path
                 and image.get("path") == proc_path), None)
    return str(main.get("uuid") or "") if main else ""


def _ips_frame(frame: dict, images: list) -> Frame:
    index = frame.get("imageIndex")
    image = ""
    if isinstance(index, int) and 0 <= index < len(images) and isinstance(images[index], dict):
        image = images[index].get("name") or os.path.basename(images[index].get("path") or "")
    offset = frame.get("imageOffset")
    return Frame(function=frame.get("symbol") or "", image=image, offset=offset if isinstance(offset, int) else None)


def _ips_message(body: dict) -> str:
    asi = body.get("asi") or {}
    lines = [line for values in asi.values() if isinstance(values, list) for line in values if isinstance(line, str)]
    return " | ".join(lines)


def _nsexception_name(body: dict) -> str:
    """The uncaught exception's name, from the report's ObjC exception info or CoreFoundation's message."""
    for key in ("exceptionReason", "nsException"):
        info = body.get(key)
        if isinstance(info, dict) and info.get("name"):
            return str(info["name"])
    match = re.search(r"uncaught exception '([^']+)'", _ips_message(body))
    if match:
        return match.group(1)
    return "NSException" if body.get("lastExceptionBacktrace") else ""


# ---------------------------------------------------------------- Rust panic JSONL

_RUST_FRAME = re.compile(r"^\s*\d+:\s+(?:0x[0-9a-f]+ - )?(.+?)\s*$")
_RUST_AT = re.compile(r"^\s*at\s+(?P<file>.+?)(?::\d+){1,2}\s*$")
# The frame std or core calls the panic hook from. Every frame above it is the hook and panic machinery, as
# ClusterFuzz skips everything above the sanitizer's or the runtime's report entry. `rust_begin_unwind` is
# `__rustc::rust_begin_unwind` since Rust 1.88; `std::panicking::begin_panic` is `panic!` with a non-format payload.
_RUST_PANIC_ENTRY = re.compile(
    r"^(?:__rustc::)?rust_begin_unwind$|^core::panicking::|^std::panicking::begin_panic$|^std::panic::panic_any$"
)
_PANIC_CLASSES = (
    (re.compile(r"called `Option::unwrap\(\)` on a `None` value"), "unwrap-none"),
    (re.compile(r"called `Result::unwrap\(\)` on an `Err` value"), "unwrap-err"),
    (re.compile(r"index out of bounds"), "index-out-of-bounds"),
    (re.compile(r"byte index .* is (?:not a char boundary|out of bounds)"), "str-index"),
    (re.compile(r"attempt to \w+ with overflow"), "arithmetic-overflow"),
    (re.compile(r"attempt to divide by zero"), "divide-by-zero"),
    (re.compile(r"already (?:mutably )?borrowed"), "refcell-borrow"),
    (re.compile(r"slice index starts at|range end index|range start index"), "slice-range"),
)


def parse_rust_panic_jsonl(text: str, ignore: IgnoreList, source: str = "",
                           include_test: bool = False) -> list[Signature]:
    """cmux-panic-log lines: message, location, thread, backtrace, plus the process's own fields."""
    signatures = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(record, dict) or "message" not in record:
            continue
        if record.get("test") and not include_test:
            continue
        frames = _rust_frames(str(record.get("backtrace") or ""))
        location = str(record.get("location") or "")
        if all(ignore.ignores(normalize_function(frame.function), "", frame.file) for frame in frames):
            file_only = re.sub(r":\d+(?::\d+)?$", "", location)
            if file_only:
                frames.append(Frame(function=file_only))
        message = str(record.get("message") or "")
        process = str(record.get("process") or ("cmux-tui-owner" if "session" in record else "") or "rust")
        signatures.append(make_signature("rust-panic", process, _panic_class(message), frames, ignore, source,
                                         message, location=location, thread=record.get("thread", ""),
                                         version=record.get("version", "")))
    return signatures


def _rust_frames(backtrace: str) -> list[Frame]:
    """std's `Backtrace` text as frames with their `at` file, starting below the panic entry point."""
    frames: list[Frame] = []
    for line in backtrace.splitlines():
        at = _RUST_AT.match(line)
        if at:
            if frames and not frames[-1].file:
                frames[-1] = Frame(function=frames[-1].function, file=at.group("file").replace("\\", "/"))
            continue
        match = _RUST_FRAME.match(line)
        if match and match.group(1) != "<unknown>":
            frames.append(Frame(function=match.group(1)))
    entry = max((index for index, frame in enumerate(frames)
                 if _RUST_PANIC_ENTRY.search(normalize_function(frame.function))), default=-1)
    return frames[entry + 1:]


def _panic_class(message: str) -> str:
    for pattern, name in _PANIC_CLASSES:
        if pattern.search(message):
            return f"panic: {name}"
    return "panic"


# ---------------------------------------------------------------- sanitizers

_SAN_FRAME = re.compile(r"^\s*#(\d+)\s+(.*)$")
_SAN_MODULE = re.compile(r"\s*\((?P<image>[^()]+?)(?::[A-Za-z0-9_]+)?\+0x(?P<offset>[0-9a-fA-F]+)\)\s*$")
# `%L`/`%S`: `FILE:LINE[:COL]`, or `<null>` and `<compiler-generated>` for no file. An absolute
# path may hold spaces (`/Users/me/My Projects/...`); a function name never holds ` /`.
_SAN_LOCATION = re.compile(r"\s+(?:(?P<file>/.*?|\S+?):\d+(?::\d+)?|<null>|<compiler-generated>)$")
# A file with no line (a unit without line tables): `asan_interceptors.cpp`, `test.73e075bfb260dd19-cgu.01`.
_SAN_BARE_FILE = re.compile(r"\s+(?P<file>[^\s<>():]+\.[\w-]+)$")
# `%L` and `%M` add the binary's BuildId after an unsymbolized frame's module; it changes per build.
_SAN_BUILD_ID = re.compile(r"\s*\(BuildId: [0-9a-fA-F]+\)\s*$")
_ASAN_ERROR = re.compile(r"==\d+==ERROR: AddressSanitizer: (?P<type>.+)$")
# Headers whose words are not one type token, named as in the report's SUMMARY line (compiler-rt asan_errors.cpp).
_ASAN_HEADER_TYPES = (
    ("attempting double-free", "double-free"),
    ("attempting free on address which was not malloc()-ed", "bad-free"),
    ("requested allocation size", "allocation-size-too-big"),
    ("calloc parameters overflow", "calloc-overflow"),
    ("reallocarray parameters overflow", "reallocarray-overflow"),
    ("out of memory", "out-of-memory"),
    ("invalid alignment requested", "invalid-allocation-alignment"),
    ("invalid allocation alignment", "invalid-allocation-alignment"),
)
_ASAN_TYPE_END = re.compile(r" on | \(|:| at pc ")
_ASAN_ACCESS = re.compile(r"^(?P<access>READ|WRITE) of size \d+")
_LSAN_ERROR = re.compile(r"==\d+==ERROR: LeakSanitizer: detected memory leaks")
_LSAN_LEAK = re.compile(r"^(?P<which>Direct|Indirect) leak of \d+ byte")
_TSAN_WARNING = re.compile(r"WARNING: ThreadSanitizer: (?P<type>.+?)(?: \(pid=\d+\))?\s*$")
_UBSAN_ERROR = re.compile(r"^(?P<loc>\S+?):\d+(?::\d+)?: runtime error: (?P<msg>.+)$")
_PID = re.compile(r"\(pid=\d+\)|==\d+==")


def _sanitizer_frame(text: str) -> Frame:
    """`#N PC in FUNCTION LOCATION`: the function, its module and offset, and its source file.

    The file is kept so the `file:` ignore rules drop std's frames (`/rustc/...`) and inlined bare names are
    qualified by their file, as for a Rust backtrace.
    """
    rest = text.strip()
    rest = re.sub(r"^0x[0-9a-fA-F]+\s*", "", rest)
    rest = rest.removeprefix("in ")
    rest = _SAN_BUILD_ID.sub("", rest)
    image = ""
    offset = None
    file = ""
    module = _SAN_MODULE.search(rest)
    if module:
        image = os.path.basename(module.group("image").strip())
        offset = int(module.group("offset"), 16)
        rest = rest[:module.start()]
    rest = rest.strip()
    location = _SAN_LOCATION.search(rest) or (None if module else _SAN_BARE_FILE.search(rest))
    if location:
        file = (location.group("file") or "").replace("\\", "/")
        rest = rest[:location.start()]
    if rest in ("<null>", "") or rest.startswith(("(", "<unknown")):
        rest = ""
    rest = re.sub(r"\+0x[0-9a-fA-F]+$", "", rest)
    return Frame(function=rest, image=image, offset=offset, file=file)


def _asan_type(header: str) -> str:
    """`heap-use-after-free on address 0x...` -> `heap-use-after-free`; multi-word headers map to their summary type."""
    for prefix, name in _ASAN_HEADER_TYPES:
        if header.startswith(prefix):
            return name
    head = _ASAN_TYPE_END.split(header, 1)[0]
    head = re.sub(r"0x[0-9a-fA-F]+|\bT\d+\b", "", head)
    return _SPACES.sub(" ", head).strip() or "unknown-crash"


_CARGO_TEST_HASH = re.compile(r"-[0-9a-f]{16}$")


def _report_process(frames: list[Frame], ignore: IgnoreList) -> str:
    """The image of the report's first frame outside the runtime: the binary the bug is in."""
    for frame in frames:
        if frame.image and not ignore.ignores(normalize_function(frame.function), frame.image):
            return _CARGO_TEST_HASH.sub("", frame.image)
    return ""


def _ubsan_kind(message: str) -> str:
    text = message.split(":", 1)[0]
    text = re.sub(r"0x[0-9a-fA-F]+", "", text)
    text = re.sub(r"'[^']*'", "", text)
    text = re.sub(r"-?\d+", "", text)
    return _SPACES.sub(" ", text).strip(" ,") or "undefined-behavior"


def parse_sanitizer(text: str, ignore: IgnoreList, source: str = "", process: str = "") -> list[Signature]:
    """Every ASan, LSan, TSan and UBSan report in `text`, each from its first stack.

    A report's process is the image of its first frame outside the runtime, else `process` (the binary the lane
    ran; a symbolized frame names no image).
    """
    signatures: list[Signature] = []
    current: dict | None = None
    lines = text.splitlines()

    def finish():
        nonlocal current
        if current is not None and (current["frames"] or current.get("fallback")):
            frames = current["frames"] or [Frame(function=current["fallback"])]
            signatures.append(make_signature(current["kind"], _report_process(frames, ignore) or process,
                                             current["exception"], frames, ignore, source, current.get("message", "")))
        current = None

    for line in lines:
        asan = _ASAN_ERROR.search(line)
        tsan = _TSAN_WARNING.search(line)
        ubsan = _UBSAN_ERROR.match(line.strip())
        lsan_leak = _LSAN_LEAK.match(line.strip())
        if _LSAN_ERROR.search(line):
            finish()
            continue
        if asan:
            finish()
            current = {"kind": "asan", "exception": _asan_type(asan.group("type")), "frames": [], "state": "header",
                       "message": _PID.sub("", line).strip()}
            continue
        if tsan:
            finish()
            current = {"kind": "tsan", "exception": tsan.group("type").strip(), "frames": [], "state": "header",
                       "message": _PID.sub("", line).strip()}
            continue
        if ubsan:
            finish()
            location = os.path.basename(ubsan.group("loc"))
            current = {"kind": "ubsan", "exception": _ubsan_kind(ubsan.group("msg")), "frames": [],
                       "state": "header", "fallback": location, "message": ubsan.group("msg")[:MESSAGE_LIMIT]}
            continue
        if lsan_leak:
            finish()
            current = {"kind": "lsan", "exception": f"{lsan_leak.group('which').lower()}-leak", "frames": [],
                       "state": "header", "message": line.strip()}
            continue
        if current is None:
            continue
        access = _ASAN_ACCESS.match(line.strip())
        if access and current["kind"] == "asan" and current["state"] == "header":
            current["exception"] = f"{current['exception']} {access.group('access')}"
            continue
        frame = _SAN_FRAME.match(line)
        if frame and current["state"] in ("header", "stack"):
            if frame.group(1) == "0" and current["state"] == "stack":
                current["state"] = "done"
                continue
            current["state"] = "stack"
            current["frames"].append(_sanitizer_frame(frame.group(2)))
            continue
        if current["state"] == "stack":
            current["state"] = "done"
    finish()
    return _drop_indirect_leaks(signatures)


def _drop_indirect_leaks(signatures: list[Signature]) -> list[Signature]:
    """Indirect leaks hang off a direct leak; report them only when no direct leak came with them."""
    if any(sig.kind == "lsan" and sig.exception == "direct-leak" for sig in signatures):
        return [sig for sig in signatures if not (sig.kind == "lsan" and sig.exception == "indirect-leak")]
    return signatures


# ---------------------------------------------------------------- hang samples

# `sample`:   "    +   2345 main  (in cmux DEV) + 120  [0x1000abcd]"
_SAMPLE_LINE = re.compile(
    r"^(?P<indent>[\s+!:|]*)(?P<count>\d+)\s+(?P<sym>.+?)\s+\(in (?P<image>[^)]+)\)"
    r"(?:\s+(?:load address 0x[0-9a-f]+ \+ 0x(?P<loadoff>[0-9a-f]+)|\+ (?P<off>\d+)))?.*$"
)
# spindump:  "    1001  main + 64 (cmux DEV + 12345) [0x100abc]"
_SPINDUMP_LINE = re.compile(
    r"^(?P<indent>\s*)(?P<kernel>\*)?(?P<count>\d+)\s+(?P<sym>.+?)\s+\((?P<image>[^()]+?) \+ (?P<off>\d+)\)"
    r"\s+\[0x[0-9a-f]+\]"
)
_SAMPLE_THREAD = re.compile(r"^\s*\d+\s+Thread_\w+")
_SPINDUMP_THREAD = re.compile(r"^\s*Thread 0x[0-9a-f]+")
_HANG_SECTION_ENDS = ("Total number in stack", "Sort by top of stack", "Binary Images")
_SAMPLE_PROCESS = re.compile(r"^Process:\s+(?P<name>.+?)\s+\[\d+\]")


def parse_hang(text: str, ignore: IgnoreList, source: str = "") -> list[Signature]:
    """The main thread's heaviest stack in a `sample` call graph or a spindump, leaf first."""
    process = ""
    for line in text.splitlines():
        match = _SAMPLE_PROCESS.match(line)
        if match:
            process = match.group("name")
            break
    nodes = _main_thread_nodes(text)
    if not nodes:
        return []
    path = _heaviest_path(nodes)
    frames = [Frame(function="" if sym.startswith("???") else re.sub(r"\s+\+\s+\d+$", "", sym), image=image,
                    offset=offset) for sym, image, offset in reversed(path)]
    return [make_signature("hang", process, "main-thread hang", frames, ignore, source,
                           samples=nodes[0][1] if nodes else 0)]


def _main_thread_nodes(text: str) -> list[tuple[int, int, str, str, int | None]]:
    """(depth, count, symbol, image, offset) lines of the main thread's tree, or of the first thread."""
    threads: list[tuple[bool, list]] = []
    for line in text.splitlines():
        if line.startswith(_HANG_SECTION_ENDS):
            break
        if _SAMPLE_THREAD.match(line) or _SPINDUMP_THREAD.match(line):
            threads.append(("com.apple.main-thread" in line, []))
            continue
        if not threads:
            continue
        spindump = _SPINDUMP_LINE.match(line)
        if spindump:
            if spindump.group("kernel"):
                continue
            threads[-1][1].append((len(spindump.group("indent")), int(spindump.group("count")),
                                   spindump.group("sym").strip(), spindump.group("image").strip(),
                                   int(spindump.group("off"))))
            continue
        sample = _SAMPLE_LINE.match(line)
        if sample:
            offset_text = sample.group("loadoff")
            offset = int(offset_text, 16) if offset_text else (int(sample.group("off")) if sample.group("off") else None)
            threads[-1][1].append((len(sample.group("indent")), int(sample.group("count")),
                                   sample.group("sym").strip(), sample.group("image").strip(), offset))
    chosen = next((nodes for main, nodes in threads if main and nodes), None)
    if chosen is None:
        chosen = next((nodes for _, nodes in threads if nodes), [])
    return chosen


def _heaviest_path(nodes: list[tuple[int, int, str, str, int | None]]) -> list[tuple[str, str, int | None]]:
    """Root to leaf, always into the child with the most samples (the first one on a tie)."""
    path: list[tuple[str, str, int | None]] = []
    parent = -1
    parent_depth = -1
    while True:
        best = None
        child_depth = None
        cursor = parent + 1
        while cursor < len(nodes) and nodes[cursor][0] > parent_depth:
            if child_depth is None:
                child_depth = nodes[cursor][0]
            if nodes[cursor][0] == child_depth and (best is None or nodes[cursor][1] > nodes[best][1]):
                best = cursor
            cursor += 1
        if best is None:
            return path
        _, _, symbol, image, offset = nodes[best]
        path.append((symbol, image, offset))
        parent = best
        parent_depth = nodes[best][0]


# ---------------------------------------------------------------- dispatch

def detect_kind(text: str, name: str = "") -> str:
    """ips, rust-panic, sanitizer, hang or "" for a report this module cannot read."""
    first = text.lstrip()[:1]
    if name.endswith(".ips") or (first == "{" and '"bug_type"' in text.split("\n", 1)[0]):
        return "ips"
    if first == "{" and '"backtrace"' in text and '"message"' in text:
        return "rust-panic"
    if re.search(r"==\d+==ERROR: (?:Address|Leak)Sanitizer|WARNING: ThreadSanitizer:|: runtime error: ", text):
        return "sanitizer"
    if "Call graph:" in text or "Heaviest stack" in text or re.search(r"^\s*Thread 0x[0-9a-f]+", text, re.MULTILINE):
        return "hang"
    return ""


def signatures_from_text(text: str, name: str = "", ignore: IgnoreList | None = None,
                         include_test: bool = False, process: str = "") -> list[Signature]:
    ignore = ignore or IgnoreList.load()
    kind = detect_kind(text, name)
    if kind == "ips":
        return parse_ips(text, ignore, name)
    if kind == "rust-panic":
        return parse_rust_panic_jsonl(text, ignore, name, include_test)
    if kind == "sanitizer":
        return parse_sanitizer(text, ignore, name, process)
    if kind == "hang":
        return parse_hang(text, ignore, name)
    return []


def signatures_from_path(path: Path, ignore: IgnoreList | None = None, include_test: bool = False,
                         process: str = "") -> list[Signature]:
    text = Path(path).read_text(encoding="utf-8", errors="replace")
    return signatures_from_text(text, os.path.basename(str(path)), ignore, include_test, process)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    parser.add_argument("paths", nargs="+", type=Path)
    parser.add_argument("--ignore", type=Path, default=DEFAULT_IGNORE, help="frame ignore list")
    parser.add_argument("--include-test", action="store_true", help="keep panic-log lines marked test")
    parser.add_argument("--process", default="",
                        help="the binary a sanitizer log came from, used when its frames name no image")
    args = parser.parse_args(argv)
    ignore = IgnoreList.load(args.ignore)
    status = 0
    for path in args.paths:
        try:
            signatures = signatures_from_path(path, ignore, args.include_test, args.process)
        except OSError as error:
            print(f"crash_signature: {path}: {error}", file=sys.stderr)
            status = 1
            continue
        for signature in signatures:
            print(json.dumps(signature.to_json(), sort_keys=True))
    return status


if __name__ == "__main__":
    sys.exit(main())
