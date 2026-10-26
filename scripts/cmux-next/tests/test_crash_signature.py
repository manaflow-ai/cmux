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

    def test_build_uuid_is_the_app_image_when_it_is_not_the_first_image(self):
        # macOS lists usedImages in frame reference order, so index 0 is often a system dylib.
        path = FIXTURES / "trap-main-image-not-first.ips"
        sig = one(path.name)
        self.assertEqual(sig.extra["build_uuid"], "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa")
        self.assertEqual(sig.hash12, one("trap-build-a.ips").hash12)
        # With no slice_uuid in the header, the image at procPath names the build.
        header_text, _, body_text = path.read_text().partition("\n")
        header = json.loads(header_text)
        del header["slice_uuid"]
        no_slice = cs.signatures_from_text(json.dumps(header) + "\n" + body_text, path.name, IGNORE)[0]
        self.assertEqual(no_slice.extra["build_uuid"], "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa")

    def test_nsexception_uses_the_throwing_stack(self):
        # The fixture has _CFThrowFormattedException and the outlined `.cold.1` part of the method above it.
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

    def test_rust_1_95_panics_start_below_the_panic_entry_point(self):
        # Captured from rustc 1.95.0 (rust-toolchain.toml) through Backtrace::force_capture, as cmux-panic-log does:
        # five panics in the dev profile (opt-level 1, line-tables-only), then the same five in release.
        signatures = cs.signatures_from_path(FIXTURES / "rust-1.95-panics.jsonl", IGNORE)
        self.assertEqual(len(signatures), 10)
        for sig in signatures:
            for frame in sig.frames:
                self.assertNotIn("rust_begin_unwind", frame)
                self.assertNotIn("cmux-panic-log", frame)
                self.assertNotRegex(frame, r"^(index|unwrap|expect) ", sig.frames)
        dev_index, _, dev_unwrap, _, dev_expect = signatures[:5]
        self.assertEqual(dev_index.frames, ["sorted (acpmux/src/main.rs)", "list (acpmux/src/main.rs)",
                                            "{closure} (acpmux/src/main.rs)"])
        self.assertEqual(dev_unwrap.frames[0], "focused (acpmux/src/main.rs)")
        self.assertEqual(dev_expect.frames[0], "load (acpmux/src/main.rs)")
        self.assertEqual(signatures[5].frames, ["acpmux::sessions::SessionTable::sorted",
                                                "acpmux::sessions::SessionTable::list", "acpmux::main"])
        self.assertEqual(signatures[7].frames[0], "acpmux::sessions::SessionTable::focused")

    def test_two_different_rust_unwraps_have_different_hashes(self):
        signatures = cs.signatures_from_path(FIXTURES / "rust-1.95-panics.jsonl", IGNORE)
        # Dev index, dev unwrap, release index, release unwrap: each pair is one panic kind in two functions.
        for first, second in [(0, 1), (2, 3), (5, 6), (7, 8)]:
            a, b = signatures[first], signatures[second]
            self.assertEqual(a.exception, b.exception)
            self.assertNotEqual(a.hash12, b.hash12, (a.frames, b.frames))

    def test_inlined_rust_names_are_qualified_by_their_file(self):
        def panic(path: str) -> cs.Signature:
            backtrace = ("   0: __rustc::rust_begin_unwind\n"
                         "             at /rustc/0123/library/std/src/panicking.rs:689:5\n"
                         "   1: sorted\n"
                         f"             at /home/ci/cmux/cmux-tui/crates/{path}:12:5\n")
            line = json.dumps({"process": "acpmux", "message": "boom", "backtrace": backtrace})
            return cs.signatures_from_text(line, "panics.jsonl", IGNORE)[0]
        sessions = panic("acpmux/src/server/sessions.rs")
        self.assertEqual(sessions.frames, ["sorted (acpmux/src/server/sessions.rs)"])
        self.assertNotEqual(sessions.hash12, panic("acpmux/src/panes.rs").hash12)

    def test_stripped_rust_panic_buckets_by_source_file(self):
        stripped = cs.signatures_from_path(FIXTURES / "rust-panics.jsonl", IGNORE)[2]
        self.assertEqual(stripped.process, "cmux-tui-owner")
        self.assertEqual(stripped.exception, "panic: unwrap-none")
        self.assertEqual(stripped.frames, ["crates/cmux-tui-core/src/layout.rs"])

    def test_tsan_race(self):
        sig = one("tsan-race.txt")
        self.assertEqual(sig.kind, "tsan")
        self.assertEqual(sig.process, "CmuxNextPackageTests")
        self.assertEqual(sig.exception, "data race")
        # The first stack only; the TSan block-invoke and libdispatch frames are dropped.
        self.assertEqual(sig.frames, ["TerminalRegistry.register(_:)", "closure in TerminalHost.start()"])

    def test_asan_use_after_free(self):
        sig = one("asan-uaf.txt")
        self.assertEqual(sig.kind, "asan")
        self.assertEqual(sig.exception, "heap-use-after-free READ")
        self.assertEqual(sig.frames, ["cmux_pty::reader::Reader::drain", "cmux_pty::reader::Reader::poll::{closure}"])
        # Symbolized frames name no image (the rest are runtime), so the lane's --process names the binary.
        self.assertEqual(sig.process, "")
        named = cs.signatures_from_path(FIXTURES / "asan-uaf.txt", IGNORE, process="cmux_pty-tests")[0]
        self.assertEqual(named.process, "cmux_pty-tests")
        self.assertEqual(named.hash12, sig.hash12)

    def test_asan_process_is_the_first_non_runtime_image(self):
        report = (
            "==7==ERROR: AddressSanitizer: heap-buffer-overflow on address 0x602 at pc 0x55 bp 0x7f sp 0x7e\n"
            "READ of size 4 at 0x602 thread T0\n"
            "    #0 0x7f01 in __asan_memcpy (/usr/lib/llvm-18/lib/linux/libclang_rt.asan-x86_64.so+0xd1000)\n"
            "    #1 0x5501 (/work/target/debug/deps/cmux_pty-0a1b2c3d4e5f6a7b+0x1234)\n"
        )
        sig = cs.signatures_from_text(report, "asan.log", IGNORE, process="used-only-when-no-image-is-named")[0]
        self.assertEqual(sig.process, "cmux_pty")
        self.assertEqual(sig.frames, ["cmux_pty-0a1b2c3d4e5f6a7b+0x1234"])

    def test_sanitizer_frame_keeps_its_file_module_and_offset(self):
        frame = cs._sanitizer_frame
        self.assertEqual(frame("0x5c in <alloc::alloc::Global as core::alloc::Allocator>::allocate "
                               "/rustc/07e5/library/alloc/src/alloc.rs:575:14"),
                         cs.Frame(function="<alloc::alloc::Global as core::alloc::Allocator>::allocate",
                                  file="/rustc/07e5/library/alloc/src/alloc.rs"))
        # `%L` on a frame with no source: module and offset, without the per-build BuildId.
        self.assertEqual(frame("0x5c in __rustc::__rdl_alloc (/w/deps/ws-52c34744ed7e30b6+0x2cca35) (BuildId: c845)"),
                         cs.Frame(function="__rustc::__rdl_alloc", image="ws-52c34744ed7e30b6", offset=0x2cca35))
        self.assertEqual(frame("0x56 (/usr/lib/libz.so.1+0x1f00) (BuildId: 9a9a)"),
                         cs.Frame(function="", image="libz.so.1", offset=0x1f00))
        self.assertEqual(frame("0x5c in __rust_try test.73e075bfb260dd19-cgu.01"),
                         cs.Frame(function="__rust_try", file="test.73e075bfb260dd19-cgu.01"))
        self.assertEqual(frame("0x5c in malloc <null>"), cs.Frame(function="malloc"))
        self.assertEqual(frame("0x5c in ws::tests::a /Users/me/My Projects, x/ws/src/lib.rs:43:26"),
                         cs.Frame(function="ws::tests::a", file="/Users/me/My Projects, x/ws/src/lib.rs"))

    def test_unsymbolized_frames_of_two_libraries_stay_apart(self):
        def report(module: str) -> cs.Signature:
            text = ("==7==ERROR: AddressSanitizer: SEGV on unknown address 0x0 (pc 0x1 bp 0x2 sp 0x3 T0)\n"
                    f"    #0 0x7f01 ({module}+0x1f00) (BuildId: 9a9a)\n")
            return cs.signatures_from_text(text, "asan.log", IGNORE)[0]
        self.assertEqual(report("/usr/lib/libz.so.1").frames, ["libz.so.1+0x1f00"])
        self.assertNotEqual(report("/usr/lib/libz.so.1").hash12, report("/usr/lib/libgit2.so.1").hash12)

    def test_std_inlined_and_libtest_frames_are_dropped_from_sanitizer_stacks(self):
        r = "/rustc/07e526db9df34143c99ec8064acc8ad543f69b30/library"
        text = ("==7==ERROR: LeakSanitizer: detected memory leaks\n\n"
                "Direct leak of 16 byte(s) in 1 object(s) allocated from:\n"
                "    #0 0x1 in malloc (/w/deps/ws-52c34744ed7e30b6+0x16cd04) (BuildId: c845)\n"
                f"    #1 0x2 in alloc_impl_runtime {r}/alloc/src/alloc.rs:335:73\n"
                f"    #2 0x2 in <alloc::vec::Vec<u8>>::with_capacity {r}/alloc/src/vec/mod.rs:519:9\n"
                "    #3 0x2 in sorted /src/cmux-tui/crates/acpmux/src/server/sessions.rs:40:9\n"
                f"    #4 0x3 in <ws::tests::a::{{closure#0}} as core::ops::function::FnOnce<()>>::call_once "
                f"{r}/core/src/ops/function.rs:250:5\n"
                "    #5 0x4 in test::__rust_begin_short_backtrace::<fn()> (/w/deps/ws-52c34744ed7e30b6+0x19c69a)\n"
                "    #6 0x5 in <test::types::RunnableTest>::run (/w/deps/ws-52c34744ed7e30b6+0x1db373)\n")
        [sig] = cs.signatures_from_text(text, "lsan.log", IGNORE, process="ws")
        self.assertEqual(sig.frames, ["sorted (acpmux/src/server/sessions.rs)"])
        self.assertEqual(sig.process, "ws")

    def test_asan_multi_word_error_types_stay_apart(self):
        def report(header: str) -> cs.Signature:
            text = (f"==42==ERROR: AddressSanitizer: {header}\n"
                    "    #0 0x1050d1234 in free+0x98 (libclang_rt.asan_osx_dynamic.dylib:arm64e+0x55234)\n"
                    "    #1 0x104a19000 in cmux_pty::reader::Reader::reset::h3d4e5f6a7b8c9d0e reader.rs:60\n")
            return cs.signatures_from_text(text, "asan.log", IGNORE)[0]
        double_free = report("attempting double-free on 0x602000000010 in thread T0:")
        bad_free = report("attempting free on address which was not malloc()-ed: 0x7ffd4a1c in thread T0")
        self.assertEqual(double_free.exception, "double-free")
        self.assertEqual(bad_free.exception, "bad-free")
        self.assertEqual(double_free.frames, bad_free.frames)
        self.assertNotEqual(double_free.hash12, bad_free.hash12)
        self.assertEqual(report("SEGV on unknown address 0x000000000000 (pc 0x1 bp 0x2 sp 0x3 T0)").exception, "SEGV")
        self.assertEqual(report("alloc-dealloc-mismatch (malloc vs operator delete) on 0x6020").exception,
                         "alloc-dealloc-mismatch")
        self.assertEqual(report("requested allocation size 0xffffffffffffffff (0x0 after adjustments) exceeds "
                                "maximum supported size of 0x10000000000 (thread T0)").exception,
                         "allocation-size-too-big")

    def test_ubsan_and_lsan_in_one_log(self):
        signatures = cs.signatures_from_path(FIXTURES / "ubsan-lsan.txt", IGNORE, process="ghostty-vt-tests")
        self.assertEqual([sig.kind for sig in signatures], ["ubsan", "lsan"])
        ubsan, lsan = signatures
        # No frame outside the runtime names an image, so both take the lane's process.
        self.assertEqual([ubsan.process, lsan.process], ["ghostty-vt-tests", "ghostty-vt-tests"])
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
            "generic specialization <Swift.Int> of Foo.bar<A>(A) -> ()": "Foo.bar(A)",
            "generic specialization <Swift.Array<Swift.Int>> of Foo.bar<A>(A) -> ()": "Foo.bar(A)",
            "function signature specialization <Arg[0] = Owned To Guaranteed> of Foo.bar() -> ()": "Foo.bar()",
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
            "cmux::store::load::<cmux::Config>": "cmux::store::load",
            "cmux::store::load::<alloc::vec::Vec<u8>>": "cmux::store::load",
            "std::sys::backtrace::__rust_end_short_backtrace::<std::panicking::panic_handler::{closure#0}, !>":
                "std::sys::backtrace::__rust_end_short_backtrace",
            "<impl cmux::Foo>::bar": "<impl cmux::Foo>::bar",
            "<alloc::vec::Vec<u8>>::push": "alloc::vec::Vec::push",
            "load<alloc::vec::Vec<u8, alloc::alloc::Global>>": "load",
        }
        for raw, expected in cases.items():
            self.assertEqual(cs.normalize_function(raw), expected, raw)

    def test_outlining_and_lto_suffixes(self):
        cases = {
            "-[__NSArrayM objectAtIndexedSubscript:].cold.1": "-[__NSArrayM objectAtIndexedSubscript:]",
            "cmux_tui::render::Frame::draw::h0123456789abcdef.llvm.4851029314": "cmux_tui::render::Frame::draw",
            "vt_parser_feed.part.0": "vt_parser_feed",
            "vt_parser_feed.isra.0.constprop.1": "vt_parser_feed",
            "SessionModel.pane(at:).cold.2 + 12": "SessionModel.pane(at:)",
            "Weather.cold": "Weather.cold",
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
            ("_CFThrowFormattedException", "CoreFoundation"),
            ("__rustc::rust_begin_unwind", ""),
            ("rust_begin_unwind", ""),
        ]:
            self.assertTrue(IGNORE.ignores(cs.normalize_function(function), image), function)

    def test_rust_std_and_registry_files_are_ignored(self):
        for file in ["/rustc/59807616e1fa/library/core/src/slice/index.rs",
                     "/Users/me/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/tokio-1.47.1/src/task.rs",
                     "/home/ci/cmux/cmux-tui/crates/cmux-panic-log/src/lib.rs"]:
            self.assertTrue(IGNORE.ignores("index", "", file), file)
        self.assertFalse(IGNORE.ignores("sorted", "", "/home/ci/cmux/cmux-tui/crates/acpmux/src/server/sessions.rs"))

    def test_app_frames_are_kept(self):
        for function in ["SessionModel.pane(at:)", "acpmux::server::sessions::SessionTable::sorted",
                         "-[__NSArrayM objectAtIndexedSubscript:]", "vt_parser_feed", "closure in Foo.bar()"]:
            self.assertFalse(IGNORE.ignores(function, "cmux NEXT"), function)

    def test_every_pattern_compiles_and_comments_are_skipped(self):
        parsed = cs.IgnoreList.parse("# comment\n\nimage:^libfoo\nfile:^/rustc/\n^bar$\n")
        self.assertEqual(len(parsed.images), 1)
        self.assertEqual(len(parsed.files), 1)
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

    def test_process_option_names_a_sanitizer_log(self):
        out = io.StringIO()
        with redirect_stdout(out):
            status = cs.main(["--process", "cmux_pty-tests", str(FIXTURES / "asan-uaf.txt")])
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(out.getvalue())["process"], "cmux_pty-tests")

    def test_unknown_text_gives_no_signature(self):
        self.assertEqual(cs.signatures_from_text("hello\nworld\n", "notes.txt", IGNORE), [])


if __name__ == "__main__":
    unittest.main()
