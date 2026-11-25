#!/usr/bin/env python3
"""bench_hover_preload.py --stalls: one bad stall record never costs the sweep, and atos reads the right binary.

1. stall_frames read every debug.hangs record with no guard, inside sweep() before the sweep's result was written:
   one record with a null duration or offset raised, and the arm lost its sweep, click and grace numbers.
2. Atos mapped an image NAME to the first file of that name os.walk met in the bundle (setdefault). A bundle has
   more than one file of one name (the app's cmux in Contents/MacOS, the CLI's in Contents/Resources/bin), and the
   walk order is the file system's, so a frame could be named from the wrong binary. Each frame carries its image's
   LC_UUID (`image_uuid`, HangLog.swift): the binary is the bundle file with that UUID.
No app, no Mac: bench_memory/bench_power are stubbed (they load macOS libraries), the bundle holds synthetic
Mach-O headers, and atos is a mock. Run: python3 -I scripts/cmux-next/tests/test_bench_hover_preload_stalls.py"""
import importlib.util, io, os, shutil, struct, sys, tempfile, types, unittest, uuid
from contextlib import redirect_stdout
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
_stubs = {name: types.ModuleType(name) for name in ("bench_memory", "bench_power")}
with mock.patch.dict(sys.modules, _stubs):
    spec = importlib.util.spec_from_file_location("bench_hover_preload", os.path.join(HERE, "..", "bench_hover_preload.py"))
    hover = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(hover)

ARM64 = 0x0100000C
X86_64 = 0x01000007


def thin(cputype, image_uuid):
    """A 64-bit Mach-O header with one LC_UUID load command."""
    header = struct.pack("<IiiIIIII", 0xFEEDFACF, cputype, 0, 2, 1, 24, 0, 0)
    return header + struct.pack("<II", 0x1B, 24) + image_uuid.bytes


def fat(*slices):
    """A universal binary of (cputype, uuid) slices."""
    head = struct.pack(">II", 0xCAFEBABE, len(slices))
    offset, bodies, table = 4096, [], b""
    for cputype, image_uuid in slices:
        body = thin(cputype, image_uuid)
        table += struct.pack(">iiIII", cputype, 0, offset, len(body), 12)
        bodies.append((offset, body))
        offset += 4096
    data = bytearray(head + table)
    for at, body in bodies:
        data += b"\0" * (at - len(data)) + body
    return bytes(data)


class FakeBench:
    def __init__(self, records):
        self.records = records

    def rpc(self, method, params=None, timeout=30):
        if method == "debug.hangs":
            return {"records": self.records, "threshold_ms": 8, "installed": True}
        raise AssertionError(method)


def frame(image, image_uuid, offset):
    return {"image": image, "image_uuid": str(image_uuid).upper(), "image_offset": float(offset), "symbol": None}


class AtosRecorder:
    """subprocess.run for `xcrun atos`: answers each address with a name that says which file was read."""
    def __init__(self):
        self.calls = []

    def __call__(self, argv, **kwargs):
        self.calls.append(argv)
        path = argv[argv.index("-o") + 1]
        load = int(argv[argv.index("-l") + 1], 16)
        addresses = [a for a in argv[argv.index("-l") + 2:]]
        lines = [f"fn_{int(a, 16) - load:x} (in {os.path.relpath(path, self.bundle)})" for a in addresses]
        return types.SimpleNamespace(stdout="\n".join(lines) + "\n", returncode=0)


class StallFrames(unittest.TestCase):
    def setUp(self):
        self.bundle = tempfile.mkdtemp(prefix="hover-bundle-") + "/cmux DEV t.app"
        self.app_uuid, self.cli_uuid = uuid.uuid4(), uuid.uuid4()
        self.app_bin = os.path.join(self.bundle, "Contents/MacOS/cmux")
        self.cli_bin = os.path.join(self.bundle, "Contents/Resources/bin/cmux")
        for path, data in ((self.app_bin, fat((X86_64, uuid.uuid4()), (ARM64, self.app_uuid))),
                           (self.cli_bin, thin(ARM64, self.cli_uuid))):
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as handle:
                handle.write(data)

    def tearDown(self):
        shutil.rmtree(os.path.dirname(self.bundle), ignore_errors=True)

    def run_stalls(self, records):
        recorder = AtosRecorder()
        recorder.bundle = self.bundle
        report = {}
        with mock.patch.object(hover.subprocess, "run", recorder), redirect_stdout(io.StringIO()):
            hover.stall_frames(FakeBench(records), self.bundle, report)
        return report, recorder

    def test_each_frame_is_named_from_the_binary_with_its_uuid(self):
        records = [{"kind": "stall", "duration_ms": 20.0, "cpu_ms": 19.0, "frames": ["a", "b"],
                    "frame_details": [frame("cmux", self.app_uuid, 0x100), frame("cmux", self.cli_uuid, 0x201)]}]
        report, recorder = self.run_stalls(records)
        paths = sorted(call[call.index("-o") + 1] for call in recorder.calls)
        self.assertEqual(paths, sorted([self.app_bin, self.cli_bin]))
        names = report["sweep_stalls"]["stalls"][0]["frames"]
        # The second frame is a return address: atos is asked for the call (offset - 1).
        self.assertEqual(names, ["fn_100 (in Contents/MacOS/cmux)", "fn_200 (in Contents/Resources/bin/cmux)"])
        app_call = next(call for call in recorder.calls if call[call.index("-o") + 1] == self.app_bin)
        self.assertEqual(app_call[app_call.index("-arch") + 1], "arm64", "a universal binary needs its slice")

    def test_a_frame_whose_uuid_no_bundle_file_has_stays_unnamed(self):
        records = [{"kind": "stall", "duration_ms": 20.0, "cpu_ms": 19.0, "frames": ["cmux +0x100"],
                    "frame_details": [frame("cmux", uuid.uuid4(), 0x100)]}]
        report, recorder = self.run_stalls(records)
        self.assertEqual(recorder.calls, [])
        self.assertEqual(report["sweep_stalls"]["stalls"][0]["frames"], ["cmux +0x100"])

    def test_one_bad_record_is_skipped_and_the_others_are_kept(self):
        records = [
            {"kind": "stall", "duration_ms": None, "cpu_ms": None, "frames": ["x"],
             "frame_details": [{"image": "cmux", "image_uuid": None, "image_offset": "not a number", "symbol": None}]},
            {"kind": "stall", "duration_ms": 12.5, "cpu_ms": 12.0, "frames": ["AppKit f"],
             "frame_details": [{"image": "AppKit", "image_offset": 5.0, "symbol": "f"}]},
        ]
        report, _ = self.run_stalls(records)
        stalls = report["sweep_stalls"]
        self.assertEqual(stalls["count"], 1)
        self.assertEqual(stalls["stalls"][0]["frames"], ["AppKit f"])
        self.assertEqual(len(stalls["skipped"]), 1)


class Sweep(unittest.TestCase):
    """A stall read that fails keeps the sweep's own numbers (as a profile that fails does)."""

    class Bench:
        pid = 1

        def hibernation(self):
            return {"prewarmed_total": 0, "restored_total": 0}

        def rpc(self, method, params=None, timeout=30):
            if method == "debug.hangs":
                if (params or {}).get("clear"):
                    return {}
                raise RuntimeError("debug.hangs: socket closed")
            if method == "debug.pointer_sweep":
                return {"seconds": 2.0, "move_ms": [1.0, 2.0], "landed": 4, "missing": 0, "late": 0}
            if method == "debug.frames":
                return {"main_ms": [1.0, 3.0], "missed": 0, "refresh_ms": 8.3}
            raise AssertionError(method)

    def test_a_failed_stall_read_keeps_the_sweep(self):
        args = types.SimpleNamespace(crossings=4, hz=120, profile=None, stalls=8, app="/nonexistent.app", label="on")
        report = {}
        with mock.patch.object(hover.time, "sleep", lambda s: None), redirect_stdout(io.StringIO()):
            hover.sweep(self.Bench(), args, report, ["r1", "r2"])
        self.assertEqual(report["sweep"]["crossings"], 4)
        self.assertIn("socket closed", report["sweep_stalls"]["error"])


if __name__ == "__main__":
    unittest.main()
