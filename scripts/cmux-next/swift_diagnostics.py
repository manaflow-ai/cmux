#!/usr/bin/env python3
"""Every Swift compiler diagnostic of a package build as JSON lines, with its group and fix-its.

Usage (a build runs only as a fleet step; see swift-diagnostics.sh):
  cmux-ci run --class isolated --ref SHA --script scripts/cmux-next/swift-diagnostics.sh -- --summary
  swift-diagnostics.sh [--package Packages/macOS/CmuxNext] [--scratch-path DIR [--no-build]] [--read-log FILE]
                       [--out FILE] [--fixits-out FILE] [--group NAME]... [--summary] [--ref SHA]

Modes (each row records its mode):
- clean (default): `swift build -Xswiftc -print-diagnostic-groups` into a new, empty --scratch-path, so no file is
  skipped as up to date and no warning is lost (an incremental build prints only the files it recompiles).
- persisted: --scratch-path DIR is an existing build folder. The build there is incremental, then every persisted
  `.dia` file is read, so files the build did not recompile still count. --no-build only reads (any host).
- log: --read-log FILE parses a saved build log (any host). The log has no fix-it offsets.

Rows come from the serialized diagnostics (`.dia`, the LLVM bitstream format of
clang/include/clang/Frontend/SerializedDiagnostics.h that swiftc writes per source file), which carry the group
and machine-applicable fix-its; the build log adds what has no `.dia` (driver and manifest diagnostics). Groups:
Swift 6.2 writes the category record as `Group@documentation-url` and prints `message [#Group]`; a category or
suffix without the URL (older and later compilers) is read the same way.

Row: {mode, source, target, file, line, column, severity, group, message, fixits, notes}. A fix-it is
{file, line, column, offset, end_line, end_column, end_offset, text}: replace the bytes [offset, end_offset) of
file with text. --fixits-out writes one line per row fix-it (the diagnostic's own fix-its, not its notes'
alternatives), the input of the strict-memory-safety pass (p10-stability-211).

Exit status: 0 the build succeeded; 1 the build failed (its diagnostics are still written); 2 bad arguments or a
host that may not build; 3 no verdict (no toolchain, or no diagnostics could be read).
"""

from __future__ import annotations

import argparse
import dataclasses
import importlib.util
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path
from typing import Callable, Iterable, Iterator, Mapping

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
DEFAULT_PACKAGE = "Packages/macOS/CmuxNext"
DEFAULT_OUT = Path(".build/swift-diagnostics/diagnostics.jsonl")
FLEET_COMMAND = ("cmux-ci run --class isolated --ref SHA --script scripts/cmux-next/swift-diagnostics.sh"
                 " -- --summary")
SEVERITIES = {0: "ignored", 1: "note", 2: "warning", 3: "error", 4: "fatal", 5: "remark"}
COUNTED = ("warning", "error", "fatal", "remark")

# clang/Frontend/SerializedDiagnostics.h
DIA_MAGIC = b"DIAG"
BLOCK_INFO = 0
BLOCK_META = 8
BLOCK_DIAG = 9
RECORD_VERSION, RECORD_DIAG, RECORD_SOURCE_RANGE, RECORD_DIAG_FLAG, RECORD_CATEGORY, RECORD_FILENAME, \
    RECORD_FIXIT = range(1, 8)
SETBID = 1
CHAR6 = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._"

# path:line:col: severity: message [#Group], the first line of each diagnostic in both the LLVM and the
# swift-syntax console styles. Snippet lines (` 7 |   |- warning: ...`) start with a space and never match.
LOG_HEADER = re.compile(r"^(?P<file>[^\s:][^:]*):(?P<line>\d+):(?P<column>\d+): "
                        r"(?P<severity>error|warning|note|remark): (?P<message>.*)$")
GROUP_SUFFIX = re.compile(r"\s+\[#(?P<group>[A-Za-z][A-Za-z0-9_-]*)\]\s*$")
TARGET_FOLDER = re.compile(r"^(?:Sources|Tests|Plugins)/(?P<target>[^/]+)/")


class UsageError(Exception):
    """Bad arguments or a host that may not build (exit 2)."""


class NoVerdict(Exception):
    """No toolchain or no readable diagnostics (exit 3)."""


class DiaError(Exception):
    """A .dia file that is not a well-formed serialized diagnostics bitstream."""


# ---------------------------------------------------------------- LLVM bitstream (llvm/Bitstream/BitstreamReader.h)

class BitReader:
    """Fields are read low bit first from the byte stream, as LLVM reads them from little-endian words."""

    def __init__(self, data: bytes, position: int = 0):
        self.data = data
        self.position = position  # in bits

    def at_end(self) -> bool:
        return self.position >= len(self.data) * 8

    def fixed(self, width: int) -> int:
        if self.position + width > len(self.data) * 8:
            raise DiaError(f"truncated at bit {self.position}")
        value = shift = 0
        while width:
            byte, offset = divmod(self.position, 8)
            take = min(8 - offset, width)
            value |= ((self.data[byte] >> offset) & ((1 << take) - 1)) << shift
            shift += take
            width -= take
            self.position += take
        return value

    def vbr(self, width: int) -> int:
        if width == 0:
            return 0
        continuation = 1 << (width - 1)
        value = shift = 0
        while True:
            piece = self.fixed(width)
            value |= (piece & (continuation - 1)) << shift
            if not piece & continuation:
                return value
            shift += width - 1
            if shift > 64:
                raise DiaError(f"VBR value over 64 bits at bit {self.position}")

    def align32(self) -> None:
        self.position = (self.position + 31) & ~31

    def blob(self, length: int) -> bytes:
        self.align32()
        start = self.position // 8
        if start + length > len(self.data):
            raise DiaError(f"blob of {length} bytes runs past the end")
        self.position += length * 8
        self.align32()
        return self.data[start:start + length]


Abbrev = tuple[tuple[str, int], ...]
ENCODINGS = {1: "fixed", 2: "vbr", 3: "array", 4: "char6", 5: "blob"}


def _read_abbrev(reader: BitReader) -> Abbrev:
    ops = []
    for _ in range(reader.vbr(5)):
        if reader.fixed(1):
            ops.append(("literal", reader.vbr(8)))
            continue
        encoding = ENCODINGS.get(reader.fixed(3))
        if encoding is None:
            raise DiaError(f"unknown abbreviation encoding at bit {reader.position}")
        ops.append((encoding, reader.vbr(5) if encoding in ("fixed", "vbr") else 0))
    return tuple(ops)


def _scalar(reader: BitReader, encoding: str, width: int) -> int:
    if encoding == "literal":
        return width
    if encoding == "fixed":
        return reader.fixed(width)
    if encoding == "vbr":
        return reader.vbr(width)
    if encoding == "char6":
        return ord(CHAR6[reader.fixed(6)])
    raise DiaError(f"{encoding} cannot be an array element or a scalar")


def _read_abbreviated(reader: BitReader, abbrev: Abbrev) -> tuple[int, list[int], bytes | None]:
    values: list[int] = []
    blob = None
    index = 0
    while index < len(abbrev):
        encoding, width = abbrev[index]
        if encoding == "array":
            if index + 1 >= len(abbrev):
                raise DiaError("array abbreviation without an element type")
            element, element_width = abbrev[index + 1]
            values.extend(_scalar(reader, element, element_width) for _ in range(reader.vbr(6)))
            index += 2
            continue
        if encoding == "blob":
            blob = reader.blob(reader.vbr(6))
        else:
            values.append(_scalar(reader, encoding, width))
        index += 1
    if not values:
        raise DiaError("abbreviated record without a code")
    return values[0], values[1:], blob


@dataclasses.dataclass
class _Block:
    block_id: int | None
    width: int
    abbrevs: list[Abbrev]


def bitstream_records(data: bytes) -> Iterator[tuple[str, int, int, list[int], bytes | None]]:
    """("enter" | "record" | "end", block id, record code, operands, blob) for each event of a .dia file."""
    if data[:4] != DIA_MAGIC:
        raise DiaError("not a serialized diagnostics file (no DIAG magic)")
    reader = BitReader(data, 32)
    block_info: dict[int, list[Abbrev]] = {}
    info_target: int | None = None
    stack = [_Block(None, 2, [])]
    while True:
        block = stack[-1]
        if len(stack) == 1 and len(data) * 8 - reader.position < block.width:
            return
        abbrev_id = reader.fixed(block.width)
        if abbrev_id == 0:  # END_BLOCK
            if len(stack) == 1:
                raise DiaError("END_BLOCK outside a block")
            reader.align32()
            stack.pop()
            if block.block_id != BLOCK_INFO:
                yield "end", block.block_id, 0, [], None
            continue
        if abbrev_id == 1:  # ENTER_SUBBLOCK
            block_id, width = reader.vbr(8), reader.vbr(4)
            reader.align32()
            reader.fixed(32)  # the block's length in words
            stack.append(_Block(block_id, width, list(block_info.get(block_id, []))))
            if block_id != BLOCK_INFO:
                yield "enter", block_id, 0, [], None
            continue
        if abbrev_id == 2:  # DEFINE_ABBREV
            abbrev = _read_abbrev(reader)
            if block.block_id == BLOCK_INFO:
                if info_target is None:
                    raise DiaError("BLOCKINFO abbreviation before SETBID")
                block_info.setdefault(info_target, []).append(abbrev)
            else:
                block.abbrevs.append(abbrev)
            continue
        if abbrev_id == 3:  # UNABBREV_RECORD
            code, count = reader.vbr(6), reader.vbr(6)
            values, blob = [reader.vbr(6) for _ in range(count)], None
        elif abbrev_id - 4 < len(block.abbrevs):
            code, values, blob = _read_abbreviated(reader, block.abbrevs[abbrev_id - 4])
        else:
            raise DiaError(f"undefined abbreviation {abbrev_id} in block {block.block_id}")
        if block.block_id == BLOCK_INFO:
            if code == SETBID and values:
                info_target = values[0]
            continue
        yield "record", block.block_id, code, values, blob


def _text(values: list[int], length_index: int, blob: bytes | None) -> str:
    """The string field of a record: a blob in clang's and swiftc's abbreviations, else trailing characters."""
    raw = blob if blob is not None else bytes(v & 0xFF for v in values[length_index + 1:])
    if length_index < len(values):
        raw = raw[:values[length_index]]
    return raw.decode("utf-8", "replace")


@dataclasses.dataclass
class DiaDiagnostic:
    severity: str
    file_id: int
    line: int
    column: int
    category_id: int
    message: str
    fixits: list[tuple[int, int, int, int, int, int, int, int, str]] = dataclasses.field(default_factory=list)
    notes: list["DiaDiagnostic"] = dataclasses.field(default_factory=list)


@dataclasses.dataclass
class DiaFile:
    version: int
    files: dict[int, str]
    categories: dict[int, str]
    diagnostics: list[DiaDiagnostic]


def parse_dia(data: bytes) -> DiaFile:
    result = DiaFile(0, {}, {}, [])
    open_diags: list[DiaDiagnostic | None] = []
    for event, block_id, code, values, blob in bitstream_records(data):
        if block_id != BLOCK_DIAG and not (block_id == BLOCK_META and code == RECORD_VERSION):
            continue
        if event == "enter":
            open_diags.append(None)
            continue
        if event == "end":
            if not open_diags:
                raise DiaError("unbalanced diagnostic block")
            open_diags.pop()
            continue
        if code == RECORD_VERSION:
            result.version = values[0] if values else 0
        elif code == RECORD_FILENAME and len(values) >= 4:
            result.files[values[0]] = _text(values, 3, blob)
        elif code == RECORD_CATEGORY and len(values) >= 2:
            result.categories[values[0]] = _text(values, 1, blob)
        elif code == RECORD_DIAG and len(values) >= 8:
            if not open_diags:
                raise DiaError("diagnostic record outside a diagnostic block")
            diagnostic = DiaDiagnostic(SEVERITIES.get(values[0], "unknown"), values[1], values[2], values[3],
                                       values[5], _text(values, 7, blob))
            parent = next((d for d in reversed(open_diags[:-1]) if d is not None), None)
            (parent.notes if parent else result.diagnostics).append(diagnostic)
            open_diags[-1] = diagnostic
        elif code == RECORD_FIXIT and len(values) >= 9 and open_diags and open_diags[-1] is not None:
            open_diags[-1].fixits.append((*values[:8], _text(values, 8, blob)))
    return result


# ---------------------------------------------------------------- rows

def split_group(message: str, category: str = "") -> tuple[str, str]:
    """(message without a ` [#Group]` suffix, group): the suffix, else the category's name before `@url`."""
    match = GROUP_SUFFIX.search(message)
    if match:
        return message[:match.start()], match.group("group")
    return message, category.split("@", 1)[0].strip()


def target_of(file: str, package_dir: Path) -> str:
    try:
        relative = Path(file).resolve().relative_to(package_dir.resolve()).as_posix()
    except (ValueError, OSError):
        return ""
    match = TARGET_FOLDER.match(relative)
    return match.group("target") if match else ""


def _fixit(raw: tuple, files: Mapping[int, str]) -> dict:
    file_id, line, column, offset, _end_file, end_line, end_column, end_offset, text = raw
    return {"file": files.get(file_id, ""), "line": line, "column": column, "offset": offset,
            "end_line": end_line, "end_column": end_column, "end_offset": end_offset, "text": text}


def _note(diagnostic: DiaDiagnostic, files: Mapping[int, str]) -> dict:
    return {"file": files.get(diagnostic.file_id, ""), "line": diagnostic.line, "column": diagnostic.column,
            "message": diagnostic.message, "fixits": [_fixit(f, files) for f in diagnostic.fixits]}


def dia_rows(path: Path, mode: str, package_dir: Path) -> list[dict]:
    """The rows of one .dia; SwiftPM writes a target's files to <target>.build/<file>.dia."""
    folder = path.parent.name
    return dia_rows_from_bytes(path.read_bytes(), mode, package_dir,
                               folder[:-len(".build")] if folder.endswith(".build") else "")


def dia_rows_from_bytes(data: bytes, mode: str, package_dir: Path, dia_target: str) -> list[dict]:
    parsed = parse_dia(data)
    rows = []
    for diagnostic in parsed.diagnostics:
        file = parsed.files.get(diagnostic.file_id, "")
        message, group = split_group(diagnostic.message, parsed.categories.get(diagnostic.category_id, ""))
        rows.append({"mode": mode, "source": "dia", "target": dia_target or target_of(file, package_dir),
                     "file": file, "line": diagnostic.line, "column": diagnostic.column,
                     "severity": diagnostic.severity, "group": group, "message": message,
                     "fixits": [_fixit(f, parsed.files) for f in diagnostic.fixits],
                     "notes": [_note(n, parsed.files) for n in diagnostic.notes]})
    return rows


def log_rows(text: str, mode: str, package_dir: Path) -> list[dict]:
    rows: list[dict] = []
    for line in text.splitlines():
        match = LOG_HEADER.match(line.rstrip())
        if not match:
            continue
        message, group = split_group(match["message"])
        if match["severity"] == "note":
            if rows and rows[-1]["file"] == match["file"]:
                rows[-1]["notes"].append({"file": match["file"], "line": int(match["line"]),
                                          "column": int(match["column"]), "message": message, "fixits": []})
            continue
        rows.append({"mode": mode, "source": "log", "target": target_of(match["file"], package_dir),
                     "file": match["file"], "line": int(match["line"]), "column": int(match["column"]),
                     "severity": match["severity"], "group": group, "message": message, "fixits": [],
                     "notes": []})
    return rows


def _key(row: Mapping) -> tuple:
    return row["file"], row["line"], row["column"], row["severity"], row["message"]


def merge_rows(dia: Iterable[dict], log: Iterable[dict]) -> list[dict]:
    """One row per diagnostic: the .dia row when there is one (swiftc writes a file's diagnostics to its own
    .dia and to the module's emit-module .dia), else the log row."""
    rows: dict[tuple, dict] = {}
    for row in dia:
        rows.setdefault(_key(row), row)
    for row in log:
        rows.setdefault(_key(row), row)
    return sorted(rows.values(), key=lambda r: (r["target"], r["file"], r["line"], r["column"], r["message"]))


def find_dia_files(scratch: Path, configuration: str) -> list[Path]:
    """Every .dia of the configuration's build folders (<scratch>/<triple>/<configuration>/...), symlinks not
    followed, so `<scratch>/debug -> <triple>/debug` is read once."""
    found = []
    for directory, subdirectories, files in os.walk(scratch, followlinks=False):
        parts = Path(directory).relative_to(scratch).parts
        if len(parts) >= 2 and parts[1] != configuration:
            subdirectories.clear()
            continue
        found.extend(Path(directory) / name for name in files if name.endswith(".dia") and len(parts) >= 2)
    return sorted(found)


def drop_deleted_sources(rows: list[dict], root: Path) -> tuple[list[dict], int]:
    """A persisted .dia can outlive its source file; its rows name a file of the checkout that is gone."""
    kept = []
    for row in rows:
        path = Path(row["file"])
        inside = path.is_absolute() and path.resolve().is_relative_to(root.resolve())
        if inside and not path.exists():
            continue
        kept.append(row)
    return kept, len(rows) - len(kept)


# ---------------------------------------------------------------- build

def fleet_host_refusal(environ: Mapping[str, str], system: str) -> str:
    """Why this host may not build, or "" on a fleet step (cmux-ci sets CMUX_CI_STEP_KEY) or a GitHub runner."""
    if not environ.get("CMUX_CI_STEP_KEY") and environ.get("GITHUB_ACTIONS") != "true":
        return ("swift-diagnostics.sh runs only on the build fleet (it builds the whole package from an empty "
                f"scratch folder, never on a person's Mac):\n  {FLEET_COMMAND}\n"
                "--no-build and --read-log only read, on any host.")
    if system != "Darwin":
        return f"swift-diagnostics.sh builds the macOS package and needs a macOS fleet host (this one is {system})"
    return ""


def _load_sanitizer_sweep():
    if "sanitizer_sweep" in sys.modules:
        return sys.modules["sanitizer_sweep"]
    spec = importlib.util.spec_from_file_location("sanitizer_sweep", HERE / "sanitizer_sweep.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules["sanitizer_sweep"] = module
    spec.loader.exec_module(module)
    return module


def resolve_environment(root: Path, environ: Mapping[str, str]) -> tuple[dict[str, str], str]:
    """The lane's Xcode and its macOS SDK (sanitizer_sweep.resolve_toolchain) and `swift --version`."""
    sweep = _load_sanitizer_sweep()
    try:
        toolchain = sweep.resolve_toolchain(root, environ)
    except sweep.SweepError as error:
        raise NoVerdict(str(error)) from error
    env = toolchain.environment(environ)
    completed = subprocess.run(["xcrun", "--sdk", "macosx", "swift", "--version"], env=env, capture_output=True,
                               text=True, stdin=subprocess.DEVNULL)
    if completed.returncode != 0:
        raise NoVerdict(f"swift --version failed in {toolchain.developer_dir}: {completed.stderr.strip()[-2000:]}")
    return env, completed.stdout.strip().splitlines()[0] if completed.stdout.strip() else ""


def run_build(package_dir: Path, scratch: Path, configuration: str, env: Mapping[str, str], log: Path) -> int:
    command = ["xcrun", "--sdk", "macosx", "swift", "build", "--package-path", str(package_dir),
               "--scratch-path", str(scratch), "-c", configuration, "-Xswiftc", "-print-diagnostic-groups"]
    print(f"swift-diagnostics: {' '.join(command)}", flush=True)
    with log.open("w", encoding="utf-8") as handle:
        return subprocess.run(command, env=dict(env), stdout=handle, stderr=subprocess.STDOUT,
                              stdin=subprocess.DEVNULL).returncode


# ---------------------------------------------------------------- outputs

def write_jsonl(path: Path, rows: Iterable[Mapping]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    with temporary.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, sort_keys=True) + "\n")
    temporary.replace(path)


def fixit_lines(rows: Iterable[Mapping]) -> list[dict]:
    return [{**fixit, "group": row["group"], "message": row["message"], "target": row["target"]}
            for row in rows for fixit in row["fixits"]]


def summarize(rows: list[dict]) -> dict:
    counted = [r for r in rows if r["severity"] in COUNTED]
    return {"total": len(counted),
            "by_severity": dict(Counter(r["severity"] for r in counted).most_common()),
            "by_group": dict(Counter(r["group"] or "(none)" for r in counted).most_common()),
            "by_target": dict(Counter(r["target"] or "(none)" for r in counted).most_common()),
            "with_fixits": sum(1 for r in counted if r["fixits"])}


def print_summary(summary: Mapping, groups: list[str]) -> None:
    print(f"swift-diagnostics: {summary['total']} diagnostic(s), {summary['with_fixits']} with fix-its; "
          + ", ".join(f"{k} {v}" for k, v in summary["by_severity"].items()))
    by_group = summary["by_group"]
    for group in groups or by_group:
        print(f"  {group}: {by_group.get(group, 0)}")
    if not groups:
        for target, count in list(summary["by_target"].items())[:20]:
            print(f"  target {target}: {count}")


# ---------------------------------------------------------------- main

def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="swift-diagnostics.sh", description=__doc__.split("\n\n", 1)[0])
    parser.add_argument("--package", default=DEFAULT_PACKAGE, help="package folder (default %(default)s)")
    parser.add_argument("--scratch-path", type=Path, help="persisted mode: an existing build folder")
    parser.add_argument("--no-build", action="store_true", help="with --scratch-path: only read its .dia files")
    parser.add_argument("--read-log", type=Path, help="log mode: parse this saved build log, no build")
    parser.add_argument("--configuration", choices=("debug", "release"), default="debug")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="diagnostics JSONL (default %(default)s)")
    parser.add_argument("--fixits-out", type=Path, help="also write each row's fix-its as JSONL")
    parser.add_argument("--group", action="append", default=[], help="only this diagnostic group; repeatable")
    parser.add_argument("--summary", action="store_true", help="print counts by severity, group and target")
    parser.add_argument("--ref", default="", help="refuse unless the checkout is this commit")
    parser.add_argument("--keep-scratch", action="store_true", help="clean mode: keep the scratch folder")
    args = parser.parse_args(argv)
    if args.no_build and not args.scratch_path:
        parser.error("--no-build reads an existing --scratch-path")
    if args.read_log and (args.scratch_path or args.no_build):
        parser.error("--read-log does not take --scratch-path or --no-build")
    if args.ref and not re.fullmatch(r"[0-9a-f]{7,40}", args.ref):
        parser.error("--ref takes a commit sha")
    args.mode = "log" if args.read_log else "persisted" if args.scratch_path else "clean"
    return args


def check_ref(root: Path, ref: str) -> str:
    head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=root, capture_output=True, text=True,
                          stdin=subprocess.DEVNULL).stdout.strip()
    if ref and not head.startswith(ref):
        raise UsageError(f"the checkout is {head or 'not a git checkout'}, not --ref {ref}")
    return head


def collect(args: argparse.Namespace, root: Path, environ: Mapping[str, str], system: str,
            resolve: Callable[[Path, Mapping[str, str]], tuple[dict[str, str], str]],
            build: Callable[[Path, Path, str, Mapping[str, str], Path], int],
            out_dir: Path) -> tuple[list[dict], dict]:
    package_dir = (root / args.package).resolve()
    meta = {"mode": args.mode, "package": args.package, "configuration": args.configuration,
            "build_status": None, "swift_version": "", "dia_files": 0, "unreadable_dia": [], "deleted_sources": 0}
    if args.mode == "log":
        return log_rows(args.read_log.read_text(encoding="utf-8", errors="replace"), "log", package_dir), meta
    building = not args.no_build
    if building:
        refusal = fleet_host_refusal(environ, system)
        if refusal:
            raise UsageError(refusal)
    if args.mode == "persisted":
        scratch = args.scratch_path.resolve()
        if not scratch.is_dir():
            raise UsageError(f"--scratch-path {scratch} is not a build folder")
    else:
        scratch = Path(tempfile.mkdtemp(prefix="swift-diagnostics-scratch.",
                                        dir=environ.get("RUNNER_TEMP") or None))
    log_text = ""
    try:
        if building:
            env, meta["swift_version"] = resolve(root, environ)
            log = out_dir / "build.log"
            log.parent.mkdir(parents=True, exist_ok=True)
            meta["build_status"] = build(package_dir, scratch, args.configuration, env, log)
            log_text = log.read_text(encoding="utf-8", errors="replace")
            meta["build_log"] = str(log)
        dia_files = find_dia_files(scratch, args.configuration)
        meta["dia_files"] = len(dia_files)
        dia: list[dict] = []
        for path in dia_files:
            try:
                dia.extend(dia_rows(path, args.mode, package_dir))
            except (DiaError, OSError) as error:
                meta["unreadable_dia"].append(f"{path}: {error}")
    finally:
        if args.mode == "clean" and not args.keep_scratch:
            shutil.rmtree(scratch, ignore_errors=True)
    rows = merge_rows(dia, log_rows(log_text, args.mode, package_dir))
    if args.mode == "persisted":
        rows, meta["deleted_sources"] = drop_deleted_sources(rows, root)
    return rows, meta


def main(argv: list[str] | None = None, environ: Mapping[str, str] | None = None, system: str | None = None,
         resolve: Callable[[Path, Mapping[str, str]], tuple[dict[str, str], str]] = resolve_environment,
         build: Callable[[Path, Path, str, Mapping[str, str], Path], int] = run_build, root: Path = ROOT) -> int:
    environ = dict(os.environ if environ is None else environ)
    try:
        args = parse_args(list(sys.argv[1:] if argv is None else argv))
    except SystemExit as error:
        return 2 if error.code else 0
    try:
        head = check_ref(root, args.ref)
        out = args.out if args.out.is_absolute() else root / args.out
        rows, meta = collect(args, root, environ, platform.system() if system is None else system,
                             resolve, build, out.parent)
    except UsageError as error:
        print(f"swift-diagnostics: {error}", file=sys.stderr)
        return 2
    except (NoVerdict, OSError) as error:
        print(f"swift-diagnostics: no verdict: {error}", file=sys.stderr)
        return 3
    if args.group:
        wanted = set(args.group)
        rows = [r for r in rows if r["group"] in wanted]
    summary = summarize(rows)
    write_jsonl(out, rows)
    (out.parent / "summary.json").write_text(
        json.dumps({**meta, "head": head, "groups_filter": args.group, **summary}, indent=2, sort_keys=True) + "\n",
        encoding="utf-8")
    if args.fixits_out:
        write_jsonl(args.fixits_out if args.fixits_out.is_absolute() else root / args.fixits_out, fixit_lines(rows))
    if args.summary:
        print_summary(summary, args.group)
    for problem in meta["unreadable_dia"]:
        print(f"swift-diagnostics: unreadable .dia: {problem}", file=sys.stderr)
    print(f"swift-diagnostics: mode {meta['mode']}; {meta['dia_files']} .dia file(s); {len(rows)} row(s) in {out}"
          + (f"; {meta['swift_version']}" if meta["swift_version"] else ""))
    status = meta["build_status"]
    if status:
        print(f"swift-diagnostics: the build failed (exit {status}); log {meta.get('build_log')}", file=sys.stderr)
        return 1
    if args.mode != "log" and not meta["dia_files"] and not rows:
        print("swift-diagnostics: no verdict: the build left no .dia file and the log no diagnostic",
              file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
