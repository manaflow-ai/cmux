#!/usr/bin/env python3
"""crash_signature.py: one stable signature per bug from .ips, Rust panic JSONL, sanitizer and hang reports."""

from __future__ import annotations

import importlib.util
import io
import json
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPTS = HERE.parent
FIXTURES = HERE / "fixtures" / "signature"
spec = importlib.util.spec_from_file_location("crash_signature", SCRIPTS / "crash_signature.py")
cs = importlib.util.module_from_spec(spec)
sys.modules["crash_signature"] = cs
spec.loader.exec_module(cs)

IGNORE = cs.IgnoreList.load()


def one(name: str) -> cs.Signature:
    signatures = cs.signatures_from_path(FIXTURES / name, IGNORE)
    assert len(signatures) == 1, signatures
    return signatures[0]


class SixKindsTests(unittest.TestCase):
    def test_ips_trap(self):
        sig = one("trap-build-a.ips")
        self.assertEqual(sig.kind, "crash")
        self.assertEqual(sig.process, "cmux NEXT")
        self.assertEqual(sig.exception, "trap")
        self.assertEqual(sig.extra["exception_type"], "EXC_BREAKPOINT SIGTRAP")
        self.assertEqual(sig.extra["build_uuid"], "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa")
        self.assertEqual(sig.frames, ["SessionModel.pane(at:)", "SessionModel.focusedPane()",
                                      "closure in WorkspaceStore.refresh(reason:)"])
        self.assertRegex(sig.hash12, r"^[0-9a-f]{12}$")

    def test_nsexception_uses_the_throwing_stack(self):
        sig = one("nsexception.ips")
        self.assertEqual(sig.kind, "nsexception")
        self.assertEqual(sig.exception, "NSRangeException")
        self.assertEqual(sig.frames, ["-[__NSArrayM objectAtIndexedSubscript:]", "TabStripController.selectTab(at:)",
                                      "TabStripController.mouseDown(with:)"])
        self.assertIn("beyond bounds", sig.message)

    def test_rust_panic(self):
        signatures = cs.signatures_from_path(FIXTURES / "rust-panics.jsonl", IGNORE)
        self.assertEqual([sig.kind for sig in signatures], ["rust-panic"] * 3)
        first = signatures[0]
        self.assertEqual(first.process, "acpmux")
        self.assertEqual(first.exception, "panic: index-out-of-bounds")
        self.assertEqual(first.frames, ["acpmux::server::sessions::SessionTable::sorted",
                                        "acpmux::server::sessions::SessionTable::list::{closure}",
                                        "acpmux::server::handle_request::{closure}"])
        self.assertEqual(first.extra["location"], "crates/acpmux/src/server/sessions.rs:214:23")

    def test_rust_panic_skips_test_lines_unless_asked(self):
        with_test = cs.signatures_from_path(FIXTURES / "rust-panics.jsonl", IGNORE, include_test=True)
        self.assertEqual(len(with_test), 4)
        self.assertEqual(with_test[2].frames, ["acpmux::daemon::panic_for_test"])

    def test_stripped_rust_panic_buckets_by_source_file(self):
        stripped = cs.signatures_from_path(FIXTURES / "rust-panics.jsonl", IGNORE)[2]
        self.assertEqual(stripped.process, "cmux-tui-owner")
        self.assertEqual(stripped.exception, "panic: unwrap-none")
        self.assertEqual(stripped.frames, ["crates/cmux-tui-core/src/layout.rs"])

    def test_tsan_race(self):
        sig = one("tsan-race.txt")
        self.assertEqual(sig.kind, "tsan")
        self.assertEqual(sig.exception, "data race")
        # The first stack only; the TSan block-invoke and libdispatch frames are dropped.
        self.assertEqual(sig.frames, ["TerminalRegistry.register(_:)", "closure in TerminalHost.start()"])

    def test_asan_use_after_free(self):
        sig = one("asan-uaf.txt")
        self.assertEqual(sig.kind, "asan")
        self.assertEqual(sig.exception, "heap-use-after-free READ")
        self.assertEqual(sig.frames, ["cmux_pty::reader::Reader::drain", "cmux_pty::reader::Reader::poll::{closure}"])

    def test_ubsan_and_lsan_in_one_log(self):
        signatures = cs.signatures_from_path(FIXTURES / "ubsan-lsan.txt", IGNORE)
        self.assertEqual([sig.kind for sig in signatures], ["ubsan", "lsan"])
        ubsan, lsan = signatures
        self.assertEqual(ubsan.exception, "signed integer overflow")
        self.assertEqual(ubsan.frames, ["vt_parser_csi_param", "vt_parser_feed", "ghostty_vt::parser::Parser::advance"])
        # The direct leak only; the allocator frames are dropped.
        self.assertEqual(lsan.exception, "direct-leak")
        self.assertEqual(lsan.frames, ["cmux_holder::session::Session::spawn_reader",
                                       "cmux_holder::session::Session::start"])

    def test_hang_sample_takes_the_heaviest_main_thread_stack(self):
        sig = one("hang-sample.txt")
        self.assertEqual(sig.kind, "hang")
        self.assertEqual(sig.process, "cmux NEXT")
        self.assertEqual(sig.frames, ["FileManager.contentsOfDirectory(atPath:)", "SessionModel.snapshot()",
                                      "closure in WorkspaceStore.refresh(reason:)"])
        self.assertEqual(sig.extra["samples"], 4123)

    def test_spindump_hang_matches_the_sample_signature(self):
        spindump = (
            "Process:          cmux NEXT [4242]\n"
            "  Thread 0x8a3b    DispatchQueue \"com.apple.main-thread\"(1)    1001 samples (1-1001)\n"
            "  1001  start + 6076 (dyld + 26748) [0x18e9a2b98]\n"
            "    1001  main + 64 (cmux NEXT + 16448) [0x100004040]\n"
            "      1001  closure #2 in WorkspaceStore.refresh(reason:) + 80 (cmux NEXT + 1250000) [0x1001312d0]\n"
            "        990  SessionModel.snapshot() + 400 (cmux NEXT + 1262000) [0x1001400a0]\n"
            "          990  FileManager.contentsOfDirectory(atPath:) + 120 (Foundation + 9000) [0x18fa00000]\n"
            "            990  __getdirentries64 + 8 (libsystem_kernel.dylib + 4000) [0x18ed00000]\n"
            "             *990  hndl_unix_scall64 + 22 (kernel + 1000) [0xffffff8000200000]\n"
            "        11  SessionModel.diff(_:) + 40 (cmux NEXT + 1270000) [0x100141000]\n"
            "  Thread 0x8a3c    1001 samples (1-1001)\n"
            "  1001  start_wqthread + 8 (libsystem_pthread.dylib + 7000) [0x18ee00000]\n"
        )
        signatures = cs.signatures_from_text(spindump, "cmux.spindump.txt", IGNORE)
        self.assertEqual(len(signatures), 1)
        self.assertEqual(signatures[0].kind, "hang")
        self.assertEqual(signatures[0].hash12, one("hang-sample.txt").hash12)

    def test_unsymbolicated_frames_bucket_by_image_and_offset(self):
        sig = one("unsymbolicated.ips")
        self.assertEqual(sig.exception, "EXC_BAD_ACCESS SIGSEGV KERN_INVALID_ADDRESS")
        self.assertEqual(sig.frames, ["cmux NEXT+0xbdc00", "cmux NEXT+0xbdf10", "cmux NEXT+0xc0df0"])


class StabilityTests(unittest.TestCase):
    def test_same_bug_from_two_builds_with_different_inlining_has_one_hash(self):
        a = one("trap-build-a.ips")
        b = one("trap-build-b.ips")
        self.assertNotEqual(a.extra["build_uuid"], b.extra["build_uuid"])
        self.assertEqual(a.frames, b.frames)
        self.assertEqual(a.hash12, b.hash12)

    def test_two_different_force_unwraps_have_different_hashes(self):
        a = one("trap-build-a.ips")
        other = one("trap-other-unwrap.ips")
        self.assertEqual(a.exception, other.exception)
        self.assertNotEqual(a.hash12, other.hash12)

    def test_same_rust_panic_from_two_builds_has_one_hash(self):
        first, second, _ = cs.signatures_from_path(FIXTURES / "rust-panics.jsonl", IGNORE)
        self.assertNotEqual(first.extra["version"], second.extra["version"])
        self.assertEqual(first.hash12, second.hash12)

    def test_every_fixture_gives_the_same_hash_twice(self):
        for path in sorted(FIXTURES.iterdir()):
            first = [sig.hash12 for sig in cs.signatures_from_path(path, IGNORE)]
            again = [sig.hash12 for sig in cs.signatures_from_path(path, IGNORE)]
            self.assertTrue(first, path.name)
            self.assertEqual(first, again, path.name)

    def test_kind_is_part_of_the_hash(self):
        frames = ["A.b()"]
        self.assertNotEqual(cs.signature_hash("crash", "trap", frames), cs.signature_hash("hang", "trap", frames))


class NormalizeTests(unittest.TestCase):
    def test_swift_names(self):
        cases = {
            "specialized closure #2 in Model.load<A>(_:) + 40": "closure in Model.load(_:)",
            "closure #1 @Sendable () -> () in cmux_DEV.Store.refresh(Swift.Int) -> ()": "closure in cmux_DEV.Store.refresh(_:)",
            "Store.refresh(count: Swift.Int, _: [Swift.String : Swift.Int]) throws -> Swift.Bool": "Store.refresh(count:_:)",
            "protocol witness for P.load() in conformance Model": "Model.load()",
            "Foo.bar.getter : Swift.Int": "Foo.bar.getter",
            "(1) await resume partial function for Store.load()": "Store.load()",
            "partial apply for closure #3 in WorkspaceStore.refresh(reason:)": "closure in WorkspaceStore.refresh(reason:)",
            "@objc TabStripController.mouseDown(with:)": "TabStripController.mouseDown(with:)",
            "$s4main3fooyyFyyXEfU0_TA": "$s4main3fooyyFyyXEfU_",
        }
        for raw, expected in cases.items():
            self.assertEqual(cs.normalize_function(raw), expected, raw)

    def test_rust_and_cpp_names(self):
        cases = {
            "cmux_tui_core::layout::Tree<T>::split::h0123456789abcdef": "cmux_tui_core::layout::Tree::split",
            "<alloc::boxed::Box<F,A> as core::ops::function::Fn<Args>>::call":
                "<alloc::boxed::Box as core::ops::function::Fn>::call",
            "cmux::Foo::bar::{closure#2}": "cmux::Foo::bar::{closure}",
            "cmux::Foo::bar::{{closure}}": "cmux::Foo::bar::{closure}",
            "std::vector<int>::push_back(int const&)": "std::vector::push_back(int const&)",
            "operator<(Foo const&, Foo const&)": "operator<(Foo const&, Foo const&)",
            "__24-[AppDelegate run:]_block_invoke_2": "-[AppDelegate run:]_block_invoke",
        }
        for raw, expected in cases.items():
            self.assertEqual(cs.normalize_function(raw), expected, raw)


class IgnoreListTests(unittest.TestCase):
    def test_runtime_frames_are_ignored(self):
        for function, image in [
            ("Swift._assertionFailure(_:_:file:line:flags:)", "libswiftCore.dylib"),
            ("swift_unexpectedError", ""),
            ("swift_task_switch", ""),
            ("__pthread_kill", "libsystem_kernel.dylib"),
            ("abort", ""),
            ("_dispatch_call_block_and_release", ""),
            ("core::panicking::panic_fmt", ""),
            ("core::option::unwrap_failed", ""),
            ("std::rt::lang_start_internal", ""),
            ("std::panicking::begin_panic_handler::{closure}", ""),
            ("logging::CheckError::~CheckError()", ""),
            ("partition_alloc::internal::OnNoMemoryInternal(unsigned long)", ""),
            ("__asan_report_load8", ""),
            ("__tsan::invoke_and_release_block(void*)", ""),
            ("free", "libclang_rt.asan_osx_dynamic.dylib"),
        ]:
            self.assertTrue(IGNORE.ignores(cs.normalize_function(function), image), function)

    def test_app_frames_are_kept(self):
        for function in ["SessionModel.pane(at:)", "acpmux::server::sessions::SessionTable::sorted",
                         "-[__NSArrayM objectAtIndexedSubscript:]", "vt_parser_feed", "closure in Foo.bar()"]:
            self.assertFalse(IGNORE.ignores(function, "cmux NEXT"), function)

    def test_every_pattern_compiles_and_comments_are_skipped(self):
        parsed = cs.IgnoreList.parse("# comment\n\nimage:^libfoo\n^bar$\n")
        self.assertEqual(len(parsed.images), 1)
        self.assertEqual(len(parsed.functions), 1)
        self.assertGreater(len(IGNORE.functions), 50)

    def test_all_ignored_stack_falls_back_to_its_top_frames(self):
        frames = [cs.Frame("abort"), cs.Frame("__pthread_kill"), cs.Frame("_dispatch_main_queue_drain"),
                  cs.Frame("start")]
        self.assertEqual(cs.crash_state(frames, IGNORE), ["abort", "__pthread_kill", "_dispatch_main_queue_drain"])


class CliTests(unittest.TestCase):
    def test_prints_one_json_line_per_signature(self):
        out = io.StringIO()
        with redirect_stdout(out):
            status = cs.main([str(FIXTURES / "ubsan-lsan.txt"), str(FIXTURES / "trap-build-a.ips")])
        self.assertEqual(status, 0)
        lines = [json.loads(line) for line in out.getvalue().splitlines()]
        self.assertEqual([line["kind"] for line in lines], ["ubsan", "lsan", "crash"])
        self.assertEqual(lines[2]["build_uuid"], "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa")

    def test_unknown_text_gives_no_signature(self):
        self.assertEqual(cs.signatures_from_text("hello\nworld\n", "notes.txt", IGNORE), [])


if __name__ == "__main__":
    unittest.main()
