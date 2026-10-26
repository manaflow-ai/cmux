#!/usr/bin/env python3
"""swift_diagnostics.py: fleet-only build, .dia and log parsing (real Swift 6.2.4 and 6.3.3 output), freshness of
persisted .dia files against the checkout, modes, outputs.

Real compiler output, made on the Linux VM from the package in Package.swift.txt (sources A.swift.txt, T.swift.txt,
both with .strictMemorySafety()) at /work/tmp/swiftdiag-p10-036/pkg:
- swift-6.2.4-A.dia, swift-6.2.4-build.log: Swift 6.2.4, `swift build -Xswiftc -print-diagnostic-groups`, A.swift.
- swift-6.3.3-A.dia, swift-6.3.3-T.dia, swift-6.3.3-build.log: Swift 6.3.3, the same with `--build-tests`.
- swift-6.3.3-release-Demo.dia: Swift 6.3.3 `-c release`, the whole-module .dia of target Demo.
synthetic_dia writes other shapes (unabbreviated category record, nested notes, an error) with a small bitstream
writer, and a .dia for any source path; it is not a compiler's output.
"""

from __future__ import annotations

import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPTS = HERE.parent
FIXTURES = HERE / "fixtures" / "swift-diagnostics"
spec = importlib.util.spec_from_file_location("swift_diagnostics", SCRIPTS / "swift_diagnostics.py")
sd = importlib.util.module_from_spec(spec)
sys.modules["swift_diagnostics"] = sd
spec.loader.exec_module(sd)

FLEET = {"CMUX_CI_STEP_KEY": "step-1", "PATH": "/usr/bin:/bin"}
REAL_DIA = (FIXTURES / "swift-6.2.4-A.dia").read_bytes()
REAL_LOG = (FIXTURES / "swift-6.2.4-build.log").read_text()
REAL_SOURCE = (FIXTURES / "A.swift.txt").read_bytes()
DIA_6_3 = (FIXTURES / "swift-6.3.3-A.dia").read_bytes()
TEST_DIA_6_3 = (FIXTURES / "swift-6.3.3-T.dia").read_bytes()
RELEASE_DIA_6_3 = (FIXTURES / "swift-6.3.3-release-Demo.dia").read_bytes()
LOG_6_3 = (FIXTURES / "swift-6.3.3-build.log").read_text()
TEST_SOURCE = (FIXTURES / "T.swift.txt").read_bytes()
REAL_PACKAGE = "/work/tmp/swiftdiag-p10-036/pkg"
REAL_FILE = REAL_PACKAGE + "/Sources/Demo/A.swift"


class BitWriter:
    """The writer side of llvm/Bitstream/BitstreamWriter.h, enough to build .dia files."""

    def __init__(self):
        self.bits: list[int] = []

    def fixed(self, value: int, width: int) -> None:
        self.bits.extend((value >> i) & 1 for i in range(width))

    def vbr(self, value: int, width: int) -> None:
        continuation = 1 << (width - 1)
        while value >= continuation:
            self.fixed((value & (continuation - 1)) | continuation, width)
            value >>= width - 1
        self.fixed(value, width)

    def align32(self) -> None:
        self.bits.extend([0] * (-len(self.bits) % 32))

    def raw(self, data: bytes) -> None:
        for byte in data:
            self.fixed(byte, 8)

    def data(self) -> bytes:
        self.align32()
        return bytes(sum(self.bits[i + j] << j for j in range(8)) for i in range(0, len(self.bits), 8))


class DiaWriter:
    """Blocks, abbreviations (BLOCKINFO and local) and records as clang's SerializedDiagnosticPrinter writes them."""

    def __init__(self):
        self.out = BitWriter()
        self.out.raw(sd.DIA_MAGIC)
        self.widths = [2]

    def enter(self, block_id: int, width: int = 4) -> None:
        self.out.fixed(1, self.widths[-1])
        self.out.vbr(block_id, 8)
        self.out.vbr(width, 4)
        self.out.align32()
        self.out.fixed(0, 32)  # length in words; the reader does not need it
        self.widths.append(width)

    def end(self) -> None:
        self.out.fixed(0, self.widths.pop())
        self.out.align32()

    def define(self, ops: list[tuple[str, int]]) -> None:
        self.out.fixed(2, self.widths[-1])
        self.out.vbr(len(ops), 5)
        codes = {"fixed": 1, "vbr": 2, "array": 3, "char6": 4, "blob": 5}
        for kind, value in ops:
            if kind == "literal":
                self.out.fixed(1, 1)
                self.out.vbr(value, 8)
            else:
                self.out.fixed(0, 1)
                self.out.fixed(codes[kind], 3)
                if kind in ("fixed", "vbr"):
                    self.out.vbr(value, 5)

    def unabbreviated(self, code: int, values: list[int]) -> None:
        self.out.fixed(3, self.widths[-1])
        self.out.vbr(code, 6)
        self.out.vbr(len(values), 6)
        for value in values:
            self.out.vbr(value, 6)

    def abbreviated(self, abbrev_id: int, ops: list[tuple[str, int]], values: list[int], blob: bytes = b"") -> None:
        self.out.fixed(abbrev_id, self.widths[-1])
        operands = iter(values)
        for kind, width in ops:
            if kind == "literal":
                continue
            if kind == "fixed":
                self.out.fixed(next(operands), width)
            elif kind == "vbr":
                self.out.vbr(next(operands), width)
            elif kind == "blob":
                self.out.vbr(len(blob), 6)
                self.out.align32()
                self.out.raw(blob)
                self.out.align32()

    def data(self) -> bytes:
        return self.out.data()


LOCATION = [("fixed", 10), ("fixed", 32), ("fixed", 32), ("fixed", 32)]
DIAG_OPS = [("literal", sd.RECORD_DIAG), ("fixed", 3), *LOCATION, ("fixed", 16), ("fixed", 10), ("fixed", 16),
            ("blob", 0)]
FIXIT_OPS = [("literal", sd.RECORD_FIXIT), *LOCATION, *LOCATION, ("fixed", 16), ("blob", 0)]
FILENAME_OPS = [("literal", sd.RECORD_FILENAME), ("fixed", 10), ("fixed", 32), ("fixed", 32), ("fixed", 16),
                ("blob", 0)]


def synthetic_dia(source: str, category: str, message: str, line: int = 12, column: int = 5,
                  offset: int = 300) -> bytes:
    """A .dia of a warning in `source` with an `unsafe ` fix-it at offset and a nested note, then an error: the
    category in an unabbreviated record, the group possibly also in the message."""
    writer = DiaWriter()
    writer.enter(sd.BLOCK_INFO, 2)
    writer.unabbreviated(sd.SETBID, [sd.BLOCK_DIAG])
    writer.define(DIAG_OPS)  # abbreviation 4 of every BLOCK_DIAG
    writer.end()
    writer.enter(sd.BLOCK_META, 3)
    writer.unabbreviated(sd.RECORD_VERSION, [2])
    writer.end()
    writer.enter(sd.BLOCK_DIAG)
    writer.define(FILENAME_OPS)  # local abbreviation 5
    writer.define(FIXIT_OPS)  # local abbreviation 6
    name = source.encode()
    writer.abbreviated(5, FILENAME_OPS, [1, 0, 0, len(name)], name)
    writer.unabbreviated(sd.RECORD_CATEGORY, [7, len(category), *category.encode()])
    text = message.encode()
    writer.abbreviated(4, DIAG_OPS, [2, 1, line, column, offset, 7, 0, len(text)], text)
    writer.abbreviated(6, FIXIT_OPS, [1, line, column, offset, 1, line, column, offset, 7], b"unsafe ")
    writer.enter(sd.BLOCK_DIAG)
    note = b"reference to var 'buffer' involves unsafe type 'UnsafeMutableRawPointer'"
    writer.abbreviated(4, DIAG_OPS, [1, 1, line, column, offset, 0, 0, len(note)], note)
    writer.end()
    writer.end()
    writer.enter(sd.BLOCK_DIAG)
    error = b"cannot find 'x' in scope"
    writer.abbreviated(4, DIAG_OPS, [3, 1, line + 8, 9, offset + 212, 0, 0, len(error)], error)
    writer.end()
    return writer.data()


def run_main(argv, environ=None, system="Darwin", build=None, resolve=None, root=None):
    stdout, stderr = io.StringIO(), io.StringIO()
    kwargs = {"environ": FLEET if environ is None else environ, "system": system,
              "resolve": resolve or (lambda root, env: (dict(env), "Apple Swift version 6.3.3"))}
    if build is not None:
        kwargs["build"] = build
    if root is not None:
        kwargs["root"] = root
    with redirect_stdout(stdout), redirect_stderr(stderr):
        status = sd.main(argv, **kwargs)
    return status, stdout.getvalue(), stderr.getvalue()


def read_jsonl(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines()]


def target_folder(scratch: Path, target: str = "Demo", configuration: str = "debug") -> Path:
    return scratch / "arm64-apple-macosx" / configuration / f"{target}.build"


def place_dia(scratch: Path, data: bytes, target: str = "Demo", name: str = "A.dia", configuration: str = "debug",
              mtime: int | None = None) -> Path:
    folder = target_folder(scratch, target, configuration)
    folder.mkdir(parents=True, exist_ok=True)
    (folder / name).write_bytes(data)
    if mtime is not None:
        set_mtime(folder / name, mtime)
    return folder / name


def place_map(scratch: Path, sources: dict[str, str], target: str = "Demo", configuration: str = "debug",
              whole_module_object: str = "") -> None:
    """output-file-map.json as SwiftPM writes it: {source: {..., diagnostics}} and the module's "" entry."""
    folder = target_folder(scratch, target, configuration)
    folder.mkdir(parents=True, exist_ok=True)
    entries = {"": {"swift-dependencies": str(folder / "primary.swiftdeps")}}
    if whole_module_object:
        entries[""]["object"] = str(folder / whole_module_object)
    for source, dia in sources.items():
        entries[source] = {"object": str(folder / (Path(source).name + ".o")), "diagnostics": str(folder / dia)}
    (folder / "output-file-map.json").write_text(json.dumps(entries))


def place_plan(scratch: Path, mtime: int, configuration: str = "debug") -> None:
    plan = scratch / f"{configuration}.yaml"
    plan.parent.mkdir(parents=True, exist_ok=True)
    plan.write_text("client: {}\n")
    set_mtime(plan, mtime)


def set_mtime(path: Path, seconds: int) -> None:
    os.utime(path, ns=(seconds * 10**9, seconds * 10**9))


def dia_files(scratch: Path, configuration: str = "debug") -> list[Path]:
    return [p for p in sd.configuration_files(scratch, configuration) if p.suffix == ".dia"]


def read_folder(scratch: Path, package_dir: Path, configuration: str = "debug") -> tuple[list[dict], dict]:
    meta = {"unreadable_dia": [], "orphan_dia": [], "missing_dia": [], "unbuilt_targets": []}
    rows, _ = sd.read_build_folder(scratch, configuration, "persisted", package_dir, meta, sd.MtimeCache())
    return rows, meta


# Times of the freshness tests: the plan, then the source, then the .dia; EDITED is after all of them.
PLANNED, WRITTEN, COMPILED, EDITED = 1_700_000_000, 1_700_000_100, 1_700_000_200, 1_700_000_300
FUTURE = 4_000_000_000


class BitstreamTests(unittest.TestCase):
    def test_real_swift_6_2_dia(self):
        parsed = sd.parse_dia(REAL_DIA)
        self.assertEqual(parsed.version, 2)
        self.assertEqual([d.severity for d in parsed.diagnostics], ["warning"] * 4)
        self.assertEqual([parsed.categories.get(d.category_id, "") for d in parsed.diagnostics],
                         ["DeprecatedDeclaration", "no-usage", "StrictMemorySafety", "StrictMemorySafety"])
        last = parsed.diagnostics[-1]
        self.assertEqual((last.line, last.column), (8, 3))
        self.assertEqual(len(last.notes), 2)
        self.assertEqual(last.fixits[0][-1], "unsafe ")

    def test_real_swift_6_3_dia(self):
        parsed = sd.parse_dia(DIA_6_3)
        self.assertEqual(parsed.version, 2)
        self.assertEqual([parsed.categories.get(d.category_id, "") for d in parsed.diagnostics],
                         ["DeprecatedDeclaration", "no-usage", "StrictMemorySafety", "StrictMemorySafety"])
        self.assertEqual([(d.line, d.column) for d in parsed.diagnostics], [(4, 3), (5, 7), (7, 3), (8, 3)])
        tests = sd.parse_dia(TEST_DIA_6_3)
        self.assertEqual([(d.line, tests.categories.get(d.category_id)) for d in tests.diagnostics],
                         [(4, "StrictMemorySafety")])
        self.assertEqual(tests.files, {1: "/work/tmp/swiftdiag-p10-036/pkg/Tests/DemoTests/T.swift"})

    def test_category_length_is_the_group_and_the_flag_record_is_the_url(self):
        """6.2.4 and 6.3.3 write `Group@url` bytes but a length that covers `Group`; the URL is DIAG_FLAG's."""
        for data in (REAL_DIA, DIA_6_3):
            records = [(code, values, blob) for event, block, code, values, blob in sd.bitstream_records(data)
                       if event == "record" and block == sd.BLOCK_DIAG]
            category = next(r for r in records if r[0] == sd.RECORD_CATEGORY and r[2].startswith(b"Strict"))
            self.assertTrue(category[2].startswith(b"StrictMemorySafety@https://"))
            self.assertEqual(sd._text(category[1], 1, category[2]), "StrictMemorySafety")
            flag = next(r for r in records if r[0] == sd.RECORD_DIAG_FLAG and b"strict" in r[2])
            self.assertEqual(sd._text(flag[1], 1, flag[2]),
                             "https://docs.swift.org/compiler/documentation/diagnostics/strict-memory-safety")

    def test_writer_round_trip_with_char6_and_vbr_arrays(self):
        writer = DiaWriter()
        writer.enter(sd.BLOCK_DIAG)
        ops = [("literal", sd.RECORD_CATEGORY), ("vbr", 6), ("array", 0), ("char6", 0)]
        writer.define(ops)
        writer.out.fixed(4, 4)
        writer.out.vbr(9, 6)
        writer.out.vbr(len("Group_a.9"), 6)
        for char in "Group_a.9":
            writer.out.fixed(sd.CHAR6.index(char), 6)
        writer.end()
        events = list(sd.bitstream_records(writer.data()))
        self.assertEqual(events[1][:3], ("record", sd.BLOCK_DIAG, sd.RECORD_CATEGORY))
        self.assertEqual(sd._text(events[1][3], 0, events[1][4]), "Group_a.9")

    def test_malformed_files_raise_dia_error(self):
        with self.assertRaises(sd.DiaError):
            sd.parse_dia(b"BC\xc0\xde" + REAL_DIA[4:])
        with self.assertRaises(sd.DiaError):
            sd.parse_dia(REAL_DIA[:len(REAL_DIA) // 2])

    def test_synthetic_dia_shapes(self):
        message = "expression uses unsafe constructs but is not marked with 'unsafe' [#StrictMemorySafety]"
        rows = sd.dia_rows_from_bytes(synthetic_dia("/src/Sources/Net/B.swift", "", message), "clean",
                                      Path("/src"), "Net")
        self.assertEqual([(r["severity"], r["group"]) for r in rows], [("warning", "StrictMemorySafety"),
                                                                       ("error", "")])
        self.assertEqual(rows[0]["message"], "expression uses unsafe constructs but is not marked with 'unsafe'")
        self.assertEqual(rows[0]["fixits"][0]["text"], "unsafe ")
        self.assertEqual(rows[0]["notes"][0]["line"], 12)
        bare = sd.dia_rows_from_bytes(synthetic_dia("/src/Sources/Net/B.swift", "StrictMemorySafety", "m"),
                                      "clean", Path("/src"), "")
        self.assertEqual((bare[0]["group"], bare[0]["target"]), ("StrictMemorySafety", "Net"))


class RowTests(unittest.TestCase):
    def test_split_group(self):
        self.assertEqual(sd.split_group("m [#StrictMemorySafety]"), ("m", "StrictMemorySafety"))
        self.assertEqual(sd.split_group("m [#no-usage]"), ("m", "no-usage"))
        self.assertEqual(sd.split_group("m", "DeprecatedDeclaration"), ("m", "DeprecatedDeclaration"))
        self.assertEqual(sd.split_group("cannot convert '[Int]'"), ("cannot convert '[Int]'", ""))

    def test_real_dia_fixits_apply_to_the_source(self):
        for data in (REAL_DIA, DIA_6_3, RELEASE_DIA_6_3):
            with tempfile.TemporaryDirectory() as directory:
                place_dia(Path(directory), data)
                rows = sd.dia_rows(dia_files(Path(directory))[0], "persisted", Path(REAL_PACKAGE))
            self.assertEqual({r["target"] for r in rows}, {"Demo"})
            source = bytearray(REAL_SOURCE)
            fixits = [f for f in sd.fixit_lines(rows) if f["group"] == "StrictMemorySafety"]
            for fixit in sorted(fixits, key=lambda f: -f["offset"]):
                source[fixit["offset"]:fixit["end_offset"]] = fixit["text"].encode()
            self.assertIn(b"  unsafe p.pointee = 3\n  unsafe p.deallocate()\n", bytes(source))

    def test_real_6_3_test_target_dia_fixit_applies(self):
        with tempfile.TemporaryDirectory() as directory:
            place_dia(Path(directory), TEST_DIA_6_3, target="DemoTests", name="T.dia")
            rows = sd.dia_rows(dia_files(Path(directory))[0], "persisted", Path(REAL_PACKAGE))
        self.assertEqual([(r["target"], r["group"]) for r in rows], [("DemoTests", "StrictMemorySafety")])
        source = bytearray(TEST_SOURCE)
        fixit = rows[0]["fixits"][0]
        source[fixit["offset"]:fixit["end_offset"]] = fixit["text"].encode()
        self.assertIn(b"  unsafe q.deallocate()\n", bytes(source))

    def test_real_6_3_log_includes_the_test_target(self):
        rows = sd.log_rows(LOG_6_3, "log", Path(REAL_PACKAGE))
        self.assertEqual([(r["target"], r["line"], r["group"]) for r in rows],
                         [("Demo", 4, "DeprecatedDeclaration"), ("Demo", 5, "no-usage"),
                          ("Demo", 7, "StrictMemorySafety"), ("Demo", 8, "StrictMemorySafety"),
                          ("DemoTests", 4, "StrictMemorySafety")])

    def test_real_log_swift_syntax_style(self):
        rows = sd.log_rows(REAL_LOG, "log", Path(REAL_PACKAGE))
        self.assertEqual([(r["line"], r["group"]) for r in rows],
                         [(4, "DeprecatedDeclaration"), (5, "no-usage"), (7, "StrictMemorySafety"),
                          (8, "StrictMemorySafety")])
        self.assertEqual({r["target"] for r in rows}, {"Demo"})

    def test_llvm_style_log_attaches_notes(self):
        log = (f"{REAL_FILE}:7:3: warning: expression uses unsafe constructs [#StrictMemorySafety]\n"
               f"{REAL_FILE}:7:3: note: reference to let 'p' involves unsafe type\n"
               "    p.pointee = 3\n    ^\n")
        rows = sd.log_rows(log, "log", Path(REAL_PACKAGE))
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["notes"][0]["message"], "reference to let 'p' involves unsafe type")

    def test_merge_keeps_one_row_per_diagnostic_and_log_only_rows(self):
        with tempfile.TemporaryDirectory() as directory:
            place_dia(Path(directory), REAL_DIA)
            place_dia(Path(directory), REAL_DIA, name="Demo.emit-module.dia")
            dia = [r for p in dia_files(Path(directory))
                   for r in sd.dia_rows(p, "clean", Path(REAL_PACKAGE))]
        manifest = "/work/tmp/swiftdiag-p10-036/pkg/Package.swift:3:1: warning: manifest thing\n"
        rows = sd.merge_rows(dia, sd.log_rows(REAL_LOG + manifest, "clean", Path(REAL_PACKAGE)))
        self.assertEqual(len(rows), 5)
        self.assertEqual(sorted(r["source"] for r in rows), ["dia"] * 4 + ["log"])

    def test_configuration_files_reads_one_configuration_once(self):
        with tempfile.TemporaryDirectory() as directory:
            scratch = Path(directory)
            place_dia(scratch, REAL_DIA)
            place_dia(scratch, REAL_DIA, configuration="release")
            (scratch / "debug").symlink_to(scratch / "arm64-apple-macosx" / "debug")
            found = dia_files(scratch)
        self.assertEqual([p.relative_to(scratch).as_posix() for p in found],
                         ["arm64-apple-macosx/debug/Demo.build/A.dia"])


class FreshnessTests(unittest.TestCase):
    """A persisted .dia counts only while it matches the checkout: its sources are not newer and its target still
    compiles them."""

    def setUp(self):
        self.directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.directory, ignore_errors=True)
        self.package = self.directory / "pkg"
        self.scratch = self.directory / "scratch"
        self.source = self.package / "Sources" / "Demo" / "A.swift"
        self.source.parent.mkdir(parents=True)
        self.source.write_bytes(REAL_SOURCE)
        set_mtime(self.source, WRITTEN)

    def dia(self, source: Path, name: str, target: str = "Demo", mtime: int = COMPILED) -> Path:
        return place_dia(self.scratch, synthetic_dia(str(source), "StrictMemorySafety", "m", 7, 3, 166),
                         target=target, name=name, mtime=mtime)

    def sibling(self, name: str, mtime: int = WRITTEN) -> Path:
        path = self.source.with_name(name)
        path.write_text("func b() {}\n")
        set_mtime(path, mtime)
        return path

    def test_fresh_dia_counts(self):
        place_map(self.scratch, {str(self.source): "A.dia"})
        self.dia(self.source, "A.dia")
        rows, meta = read_folder(self.scratch, self.package)
        self.assertEqual(len(rows), 2)
        self.assertEqual((meta["stale_sources"], meta["orphan_dia"], meta["missing_dia"]), ([], [], []))

    def test_source_edited_after_its_dia_is_stale(self):
        place_map(self.scratch, {str(self.source): "A.dia"})
        self.dia(self.source, "A.dia")
        self.source.write_bytes(b"// a new first line\n" + REAL_SOURCE)
        set_mtime(self.source, EDITED)
        rows, meta = read_folder(self.scratch, self.package)
        self.assertEqual(rows, [])
        self.assertEqual(meta["stale_sources"], [str(self.source)])

    def test_edited_source_without_rows_stales_its_dia(self):
        """An edit can add warnings to a file whose old .dia had none; that .dia is stale with no rows."""
        empty = DiaWriter()
        empty.enter(sd.BLOCK_META, 3)
        empty.unabbreviated(sd.RECORD_VERSION, [2])
        empty.end()
        place_map(self.scratch, {str(self.source): "A.dia"})
        place_dia(self.scratch, empty.data(), mtime=COMPILED)
        set_mtime(self.source, EDITED)
        _, meta = read_folder(self.scratch, self.package)
        self.assertEqual(meta["stale_sources"], [str(self.source)])

    def test_row_in_a_file_newer_than_the_dia_is_stale_without_a_map(self):
        self.dia(self.source, "A.dia")
        set_mtime(self.source, EDITED)
        rows, meta = read_folder(self.scratch, self.package)
        self.assertEqual(rows, [])
        self.assertEqual(meta["stale_sources"], [str(self.source)])

    def test_module_dia_is_stale_when_any_source_of_its_target_is_newer(self):
        other = self.sibling("B.swift", EDITED)
        place_map(self.scratch, {str(self.source): "A.dia", str(other): "B.dia"})
        self.dia(self.source, "A.dia")
        self.dia(self.source, "Demo.emit-module.dia")
        place_dia(self.scratch, b"", name="B.dia", mtime=COMPILED)
        rows, meta = read_folder(self.scratch, self.package)
        self.assertEqual(len(rows), 2, "A.dia is fresh; the module's .dia covers B.swift too")
        self.assertEqual(meta["stale_sources"], [str(other)])

    def test_dia_of_a_source_that_left_the_target_is_an_orphan(self):
        excluded = self.sibling("B.swift")
        place_map(self.scratch, {str(self.source): "A.dia"})
        self.dia(self.source, "A.dia")
        orphan = self.dia(excluded, "B.dia")
        rows, meta = read_folder(self.scratch, self.package)
        self.assertEqual({r["file"] for r in rows}, {str(self.source)})
        self.assertEqual(meta["orphan_dia"], [str(orphan)])

    def test_release_whole_module_dia_covers_the_target(self):
        """Swift 6.3.3 -c release: the map names A.dia, the driver writes only `<object stem>.dia`. Its rows name
        the fixture's build path, which may exist on this host, so the .dia is dated after any such file."""
        place_map(self.scratch, {str(self.source): "A.dia"}, whole_module_object="Demo.o")
        place_dia(self.scratch, RELEASE_DIA_6_3, name="Demo.dia", mtime=FUTURE)
        rows, meta = read_folder(self.scratch, self.package)
        self.assertEqual(len(rows), 4)
        self.assertEqual((meta["orphan_dia"], meta["missing_dia"]), ([], []))
        set_mtime(self.source, FUTURE + 1)
        rows, meta = read_folder(self.scratch, self.package)
        self.assertEqual((rows, meta["stale_sources"]), ([], [str(self.source)]))

    def test_missing_and_unbuilt(self):
        other = self.sibling("B.swift")
        place_map(self.scratch, {str(self.source): "A.dia", str(other): "B.dia"})
        self.dia(self.source, "A.dia")
        place_map(self.scratch, {str(self.package / "Tests" / "T.swift"): "T.dia"}, target="DemoTests")
        _, meta = read_folder(self.scratch, self.package)
        self.assertEqual(meta["missing_dia"], [str(other)])
        self.assertEqual(meta["unbuilt_targets"], ["DemoTests.build"])

    def test_changed_since_build(self):
        manifest = self.package / "Package.swift"
        manifest.write_text("// manifest\n")
        set_mtime(manifest, WRITTEN)
        place_plan(self.scratch, PLANNED)
        listed = {os.path.realpath(self.source)}
        self.assertEqual(sd.changed_since_build(self.package, self.scratch, "debug", listed), [str(manifest)])
        set_mtime(manifest, PLANNED - 1)
        self.assertEqual(sd.changed_since_build(self.package, self.scratch, "debug", listed), [],
                         "a listed source newer than the plan is the stale check's, not this one's")
        new = self.sibling("New.swift", EDITED)
        self.assertEqual(sd.changed_since_build(self.package, self.scratch, "debug", listed), [str(new)])
        self.assertIn("no build plan",
                      sd.changed_since_build(self.package, self.directory / "x", "debug", listed)[0])


class MainTests(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.directory, ignore_errors=True)
        self.out = self.directory / "out" / "diagnostics.jsonl"

    def fake_build(self, status=0, log=REAL_LOG):
        calls = []

        def build(package_dir, scratch, configuration, env, log_path, build_tests):
            calls.append((package_dir, scratch, configuration, build_tests))
            self.assertEqual(list(scratch.iterdir()), [], "a clean build starts from an empty scratch folder")
            place_dia(scratch, REAL_DIA)
            log_path.write_text(log)
            return status
        return build, calls

    def test_refuses_a_persons_mac_before_building(self):
        build, calls = self.fake_build()
        for environ, system in (({"PATH": "/usr/bin"}, "Darwin"), (FLEET, "Linux")):
            status, _, err = run_main(["--out", str(self.out)], environ=environ, system=system, build=build)
            self.assertEqual(status, 2)
            self.assertEqual(calls, [])
        status, _, err = run_main(["--out", str(self.out)], environ={"PATH": "/usr/bin"}, build=build)
        self.assertIn("runs only on the build fleet", err)
        self.assertIn("cmux-ci run --class isolated", err)
        self.assertFalse(self.out.exists())

    def test_shell_wrapper_refuses_outside_the_fleet(self):
        completed = subprocess.run(["bash", str(SCRIPTS / "swift-diagnostics.sh"), "--summary"],
                                   env={"PATH": "/usr/bin:/bin"}, capture_output=True, text=True)
        self.assertEqual(completed.returncode, 2)
        self.assertIn("runs only on the build fleet", completed.stderr)

    def test_build_command_builds_test_targets_unless_no_tests(self):
        command = sd.build_command(Path("/p"), Path("/s"), "debug", True)
        self.assertIn("--build-tests", command)
        self.assertEqual(command[-2:], ["-Xswiftc", "-print-diagnostic-groups"])
        self.assertNotIn("--build-tests", sd.build_command(Path("/p"), Path("/s"), "debug", False))
        build, calls = self.fake_build()
        run_main(["--package", REAL_PACKAGE, "--out", str(self.out)], build=build)
        run_main(["--package", REAL_PACKAGE, "--out", str(self.out), "--no-tests"], build=build)
        self.assertEqual([call[3] for call in calls], [True, False])
        self.assertFalse(json.loads((self.out.parent / "summary.json").read_text())["build_tests"])

    def test_clean_mode_records_mode_and_removes_scratch(self):
        build, calls = self.fake_build()
        fixits = self.directory / "fixits.jsonl"
        status, out, _ = run_main(["--package", REAL_PACKAGE, "--out", str(self.out), "--fixits-out", str(fixits),
                                   "--summary"], build=build, environ={**FLEET, "RUNNER_TEMP": str(self.directory)})
        self.assertEqual(status, 0)
        rows = read_jsonl(self.out)
        self.assertEqual({(r["mode"], r["source"]) for r in rows}, {("clean", "dia")})
        self.assertEqual(len(rows), 4)
        self.assertEqual(len(read_jsonl(fixits)), 3)
        self.assertFalse(calls[0][1].exists(), "the clean scratch folder is removed")
        summary = json.loads((self.out.parent / "summary.json").read_text())
        self.assertEqual((summary["mode"], summary["by_group"]["StrictMemorySafety"]), ("clean", 2))
        self.assertEqual(summary["swift_version"], "Apple Swift version 6.3.3")
        self.assertIn("StrictMemorySafety: 2", out)

    def test_group_filter(self):
        build, _ = self.fake_build()
        status, out, _ = run_main(["--package", REAL_PACKAGE, "--out", str(self.out), "--summary",
                                   "--group", "StrictMemorySafety", "--group", "Unknown"], build=build)
        self.assertEqual(status, 0)
        self.assertEqual({r["group"] for r in read_jsonl(self.out)}, {"StrictMemorySafety"})
        self.assertIn("  Unknown: 0", out)

    def test_failed_build_still_writes_rows(self):
        build, _ = self.fake_build(status=1)
        status, _, err = run_main(["--package", REAL_PACKAGE, "--out", str(self.out)], build=build)
        self.assertEqual(status, 1)
        self.assertEqual(len(read_jsonl(self.out)), 4)
        self.assertIn("the build failed (exit 1)", err)

    def test_no_dia_after_a_build_is_no_verdict_even_with_log_rows(self):
        for log in ("error: unknown argument\n", REAL_LOG):
            def build(package_dir, scratch, configuration, env, log_path, build_tests):
                log_path.write_text(log)
                return 0
            status, _, err = run_main(["--package", REAL_PACKAGE, "--out", str(self.out)], build=build)
            self.assertEqual(status, 3, log)
            self.assertIn("no .dia file in the build folder", err)

    def persisted_checkout(self) -> tuple[Path, Path, Path]:
        """A checkout with the real A.swift and its fresh .dia in a planned build folder."""
        root = self.directory / "repo"
        source = root / "Sources" / "Demo" / "A.swift"
        source.parent.mkdir(parents=True)
        source.write_bytes(REAL_SOURCE)
        set_mtime(source, WRITTEN)
        scratch = self.directory / "scratch"
        place_plan(scratch, PLANNED)
        place_map(scratch, {str(source): "A.dia"})
        message = "expression uses unsafe constructs but is not marked with 'unsafe'"
        place_dia(scratch, synthetic_dia(str(source), "StrictMemorySafety", message, 7, 3, 166), mtime=COMPILED)
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        return root, source, scratch

    def run_no_build(self, root: Path, scratch: Path, fixits: Path):
        return run_main(["--package", ".", "--scratch-path", str(scratch), "--no-build", "--out", str(self.out),
                         "--fixits-out", str(fixits)], environ={"PATH": "/usr/bin:/bin"}, system="Linux", root=root)

    def test_persisted_no_build_reads_on_any_host_and_drops_deleted_sources(self):
        root, source, scratch = self.persisted_checkout()
        gone = root / "Sources" / "Demo" / "Gone.swift"
        message = "expression uses unsafe constructs but is not marked with 'unsafe'"
        place_dia(scratch, synthetic_dia(str(gone), "", message), name="Gone.dia", mtime=COMPILED)
        place_map(scratch, {str(source): "A.dia", str(gone): "Gone.dia"})
        fixits = self.directory / "fixits.jsonl"
        status, _, err = self.run_no_build(root, scratch, fixits)
        self.assertEqual(status, 0, err)
        rows = read_jsonl(self.out)
        self.assertEqual({(r["mode"], r["file"]) for r in rows}, {("persisted", str(source))})
        self.assertEqual(json.loads((self.out.parent / "summary.json").read_text())["deleted_sources"], 2)
        edited = bytearray(REAL_SOURCE)
        for fixit in read_jsonl(fixits):
            edited[fixit["offset"]:fixit["end_offset"]] = fixit["text"].encode()
        self.assertIn(b"  unsafe p.pointee = 3\n", bytes(edited))

    def test_source_edited_after_its_dia_refuses_rows_and_fixits(self):
        root, source, scratch = self.persisted_checkout()
        source.write_bytes(b"// a new first line\n" + REAL_SOURCE)
        set_mtime(source, EDITED)
        fixits = self.directory / "fixits.jsonl"
        status, _, err = self.run_no_build(root, scratch, fixits)
        self.assertEqual(status, 3)
        self.assertIn("newer than their .dia", err)
        self.assertEqual((read_jsonl(self.out), read_jsonl(fixits)), ([], []))
        summary = json.loads((self.out.parent / "summary.json").read_text())
        self.assertEqual(summary["stale_sources"], [str(source)])

    def test_stale_rows_are_refused_even_when_a_persisted_build_failed(self):
        root, source, scratch = self.persisted_checkout()
        set_mtime(source, EDITED)

        def build(package_dir, scratch_path, configuration, env, log_path, build_tests):
            log_path.write_text("error: a dependency failed\n")
            return 1
        fixits = self.directory / "fixits.jsonl"
        status, _, err = run_main(["--package", ".", "--scratch-path", str(scratch), "--out", str(self.out),
                                   "--fixits-out", str(fixits)], build=build, root=root)
        self.assertEqual(status, 1)
        self.assertIn("newer than their .dia", err)
        self.assertEqual(read_jsonl(fixits), [])

    def test_no_build_after_a_new_source_or_manifest_edit_is_no_verdict(self):
        for changed in ("Sources/Demo/New.swift", "Package.swift"):
            with self.subTest(changed=changed):
                shutil.rmtree(self.directory / "repo", ignore_errors=True)
                shutil.rmtree(self.directory / "scratch", ignore_errors=True)
                root, _, scratch = self.persisted_checkout()
                (root / changed).write_text("// new\n")
                status, _, err = self.run_no_build(root, scratch, self.directory / "fixits.jsonl")
                self.assertEqual(status, 3)
                self.assertIn(f"changed since the last build plan (--no-build): {root / changed}", err)

    def test_truncated_dia_without_a_build_is_no_verdict(self):
        root, _, scratch = self.persisted_checkout()
        place_dia(scratch, REAL_DIA[:40], name="Broken.dia", mtime=COMPILED)
        place_map(scratch, {str(root / "Sources" / "Demo" / "A.swift"): "A.dia",
                            str(root / "Sources" / "Demo" / "Broken.swift"): "Broken.dia"})
        status, _, err = self.run_no_build(root, scratch, self.directory / "fixits.jsonl")
        self.assertEqual(status, 3)
        self.assertIn("unreadable .dia: ", err)
        self.assertIn("Broken.dia", err)
        self.assertEqual(len(read_jsonl(self.out)), 2, "the readable .dia still writes its rows")

    def test_truncated_dia_in_a_clean_build_is_reported_not_fatal(self):
        """The clean build's log has every diagnostic of every file, so its rows are all still there."""
        def build(package_dir, scratch, configuration, env, log_path, build_tests):
            place_dia(scratch, REAL_DIA)
            place_dia(scratch, REAL_DIA[:40], name="Broken.dia")
            log_path.write_text(REAL_LOG)
            return 0
        status, _, err = run_main(["--package", REAL_PACKAGE, "--out", str(self.out)], build=build)
        self.assertEqual(status, 0)
        self.assertEqual(len(read_jsonl(self.out)), 4)
        self.assertIn("Broken.dia", err)

    def test_log_mode(self):
        log = self.directory / "build.log"
        log.write_text(REAL_LOG)
        status, _, _ = run_main(["--package", REAL_PACKAGE, "--read-log", str(log), "--out", str(self.out)],
                                environ={})
        self.assertEqual(status, 0)
        self.assertEqual({r["mode"] for r in read_jsonl(self.out)}, {"log"})

    def test_argument_errors(self):
        for argv in (["--no-build"], ["--read-log", "x", "--scratch-path", "y"], ["--ref", "main"]):
            status, _, _ = run_main(argv)
            self.assertEqual(status, 2, argv)


if __name__ == "__main__":
    unittest.main()
