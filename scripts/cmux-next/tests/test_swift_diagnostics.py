#!/usr/bin/env python3
"""swift_diagnostics.py: fleet-only build, .dia and log parsing (Swift 6.2 output and later shapes), modes, outputs.

The swift-6.2.4 fixtures are a real `swift build -Xswiftc -print-diagnostic-groups` of a one-file package with
.strictMemorySafety() (Swift 6.2.4, Linux). The later-format files are written here with a small bitstream writer.
"""

from __future__ import annotations

import importlib.util
import io
import json
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


def later_format_dia(source: str, category: str, message: str) -> bytes:
    """A .dia in the shapes a later compiler may write: the category is the bare group name (no `@url`) in an
    unabbreviated record, the group may also be in the message, a fix-it, and a note nested in its warning."""
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
    writer.abbreviated(4, DIAG_OPS, [2, 1, 12, 5, 300, 7, 0, len(text)], text)
    writer.abbreviated(6, FIXIT_OPS, [1, 12, 5, 300, 1, 12, 5, 300, 7], b"unsafe ")
    writer.enter(sd.BLOCK_DIAG)
    note = b"reference to var 'buffer' involves unsafe type 'UnsafeMutableRawPointer'"
    writer.abbreviated(4, DIAG_OPS, [1, 1, 12, 5, 300, 0, 0, len(note)], note)
    writer.end()
    writer.end()
    writer.enter(sd.BLOCK_DIAG)
    error = b"cannot find 'x' in scope"
    writer.abbreviated(4, DIAG_OPS, [3, 1, 20, 9, 512, 0, 0, len(error)], error)
    writer.end()
    return writer.data()


def run_main(argv, environ=None, system="Darwin", build=None, resolve=None, root=None):
    stdout, stderr = io.StringIO(), io.StringIO()
    kwargs = {"environ": FLEET if environ is None else environ, "system": system,
              "resolve": resolve or (lambda root, env: (dict(env), "Apple Swift version 6.2.4"))}
    if build is not None:
        kwargs["build"] = build
    if root is not None:
        kwargs["root"] = root
    with redirect_stdout(stdout), redirect_stderr(stderr):
        status = sd.main(argv, **kwargs)
    return status, stdout.getvalue(), stderr.getvalue()


def read_jsonl(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines()]


def place_dia(scratch: Path, data: bytes, target: str = "Demo", name: str = "A.dia", configuration: str = "debug"):
    folder = scratch / "arm64-apple-macosx" / configuration / f"{target}.build"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / name).write_bytes(data)


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

    def test_later_format_dia(self):
        message = "expression uses unsafe constructs but is not marked with 'unsafe' [#StrictMemorySafety]"
        rows = sd.dia_rows_from_bytes(later_format_dia("/src/Sources/Net/B.swift", "", message), "clean",
                                      Path("/src"), "Net")
        self.assertEqual([(r["severity"], r["group"]) for r in rows], [("warning", "StrictMemorySafety"),
                                                                       ("error", "")])
        self.assertEqual(rows[0]["message"], "expression uses unsafe constructs but is not marked with 'unsafe'")
        self.assertEqual(rows[0]["fixits"][0]["text"], "unsafe ")
        self.assertEqual(rows[0]["notes"][0]["line"], 12)
        bare = sd.dia_rows_from_bytes(later_format_dia("/src/Sources/Net/B.swift", "StrictMemorySafety", "m"),
                                      "clean", Path("/src"), "")
        self.assertEqual((bare[0]["group"], bare[0]["target"]), ("StrictMemorySafety", "Net"))


class RowTests(unittest.TestCase):
    def test_split_group(self):
        self.assertEqual(sd.split_group("m [#StrictMemorySafety]"), ("m", "StrictMemorySafety"))
        self.assertEqual(sd.split_group("m [#no-usage]"), ("m", "no-usage"))
        self.assertEqual(sd.split_group("m", "DeprecatedDeclaration@https://docs.swift.org/x"),
                         ("m", "DeprecatedDeclaration"))
        self.assertEqual(sd.split_group("cannot convert '[Int]'"), ("cannot convert '[Int]'", ""))

    def test_real_dia_fixits_apply_to_the_source(self):
        with tempfile.TemporaryDirectory() as directory:
            place_dia(Path(directory), REAL_DIA)
            rows = sd.dia_rows(sd.find_dia_files(Path(directory), "debug")[0], "persisted", Path(REAL_PACKAGE))
        self.assertEqual({r["target"] for r in rows}, {"Demo"})
        source = bytearray(REAL_SOURCE)
        fixits = [f for f in sd.fixit_lines(rows) if f["group"] == "StrictMemorySafety"]
        for fixit in sorted(fixits, key=lambda f: -f["offset"]):
            source[fixit["offset"]:fixit["end_offset"]] = fixit["text"].encode()
        self.assertIn(b"  unsafe p.pointee = 3\n  unsafe p.deallocate()\n", bytes(source))

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
            dia = [r for p in sd.find_dia_files(Path(directory), "debug")
                   for r in sd.dia_rows(p, "clean", Path(REAL_PACKAGE))]
        manifest = "/work/tmp/swiftdiag-p10-036/pkg/Package.swift:3:1: warning: manifest thing\n"
        rows = sd.merge_rows(dia, sd.log_rows(REAL_LOG + manifest, "clean", Path(REAL_PACKAGE)))
        self.assertEqual(len(rows), 5)
        self.assertEqual(sorted(r["source"] for r in rows), ["dia"] * 4 + ["log"])

    def test_find_dia_files_reads_one_configuration_once(self):
        with tempfile.TemporaryDirectory() as directory:
            scratch = Path(directory)
            place_dia(scratch, REAL_DIA)
            place_dia(scratch, REAL_DIA, configuration="release")
            (scratch / "debug").symlink_to(scratch / "arm64-apple-macosx" / "debug")
            found = sd.find_dia_files(scratch, "debug")
        self.assertEqual([p.relative_to(scratch).as_posix() for p in found],
                         ["arm64-apple-macosx/debug/Demo.build/A.dia"])


class MainTests(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.directory, ignore_errors=True)
        self.out = self.directory / "out" / "diagnostics.jsonl"

    def fake_build(self, status=0, log=REAL_LOG):
        calls = []

        def build(package_dir, scratch, configuration, env, log_path):
            calls.append((package_dir, scratch, configuration))
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
        self.assertEqual(summary["swift_version"], "Apple Swift version 6.2.4")
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

    def test_no_dia_and_no_rows_is_no_verdict(self):
        def build(package_dir, scratch, configuration, env, log_path):
            log_path.write_text("error: unknown argument\n")
            return 0
        status, _, _ = run_main(["--out", str(self.out)], build=build)
        self.assertEqual(status, 3)

    def test_persisted_no_build_reads_on_any_host_and_drops_deleted_sources(self):
        root = self.directory / "repo"
        source = root / "Sources" / "Net" / "B.swift"
        source.parent.mkdir(parents=True)
        source.write_text("// B\n")
        scratch = self.directory / "scratch"
        message = "expression uses unsafe constructs but is not marked with 'unsafe'"
        place_dia(scratch, later_format_dia(str(source), "StrictMemorySafety", message), target="Net", name="B.dia")
        place_dia(scratch, later_format_dia(str(root / "Sources" / "Net" / "Gone.swift"), "", message),
                  target="Net", name="Gone.dia")
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        status, out, _ = run_main(["--package", ".", "--scratch-path", str(scratch), "--no-build", "--out",
                                   str(self.out)], environ={"PATH": "/usr/bin:/bin"}, system="Linux", root=root)
        self.assertEqual(status, 0)
        rows = read_jsonl(self.out)
        self.assertEqual({(r["mode"], r["file"]) for r in rows}, {("persisted", str(source))})
        self.assertEqual(json.loads((self.out.parent / "summary.json").read_text())["deleted_sources"], 2)

    def test_unreadable_dia_is_reported_not_fatal(self):
        scratch = self.directory / "scratch"
        place_dia(scratch, REAL_DIA)
        place_dia(scratch, REAL_DIA[:40], name="Broken.dia")
        status, _, err = run_main(["--package", REAL_PACKAGE, "--scratch-path", str(scratch), "--no-build", "--out",
                                   str(self.out)], environ={})
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
