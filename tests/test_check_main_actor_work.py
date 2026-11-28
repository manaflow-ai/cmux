"""check-main-actor-work.py: which lines count as main-actor code, and the blocking-call rules.

plans/cmux-next/main-thread-guarantee-DESIGN.md, layer 1. Each scope case here was a wrong answer of the lexical
tracker on feat-cmux-next (2026-11-15): a `nonisolated` function with a default closure argument
(TerminalLaunchFrames.writeOne) gave its isolation to that closure, so its body counted as main-actor code.
Run: python3 -I tests/test_check_main_actor_work.py
"""
import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("check_main_actor_work", ROOT / "scripts/cmux-next/check-main-actor-work.py")
check = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(check)


def hits(source: str, default_main: bool = True) -> list[tuple[int, str]]:
    with tempfile.TemporaryDirectory() as folder:
        path = Path(folder) / "Fixture.swift"
        path.write_text(source, encoding="utf-8")
        return [(line, rule) for line, rule, _ in check.scan_file(str(path), default_main)]


WRITE = "synchronous file write or file-system change"


class ScopeTests(unittest.TestCase):
    def test_nonisolated_function_with_default_closure_argument_is_off_main(self):
        source = """final class Frames {
    nonisolated static func writeOne(_ data: Data, to url: URL,
                                     stillWanted: () -> Bool = { true }) {
        try? data.write(to: url)
    }
    func onMain(_ data: Data, _ url: URL) {
        try? data.write(to: url)
    }
}
"""
        self.assertEqual(hits(source), [(7, WRITE)])

    def test_detached_closure_in_parentheses_is_off_main_and_the_await_after_it_is_main(self):
        source = """func load(path: String) async {
    guard let data = await Task.detached(operation: { try? Data(contentsOf: URL(filePath: path)) }).value,
          let object = try? JSONSerialization.jsonObject(with: data) else { return }
    _ = object
}
"""
        self.assertEqual(hits(source), [(3, "JSON / property-list decode")])

    def test_background_work_lane_closure_is_off_main(self):
        source = """func save(_ data: Data, _ url: URL) async throws {
    try await work.run(.userBlocking, mayBlock: .files) { try data.blockingWrite(to: url, options: .atomic) }
    work.post(.utility, mayBlock: .files) {
        try? FileManager.default.removeItem(at: url)
    }
    try data.blockingWrite(to: url)
}
"""
        self.assertEqual(hits(source), [(6, WRITE)])

    def test_nonisolated_property_with_closure_in_parentheses_ends_at_its_line(self):
        # DaemonRecovery.swift's shape: the property's `{` is in its parentheses, and it has no body.
        source = """final class C {
    private nonisolated let m = Mutex<@Sendable () -> Bool>({ true })
    func f() {
        let d = try JSONDecoder().decode(T.self, from: data)
    }
}
"""
        self.assertEqual(hits(source), [(4, "JSON / property-list decode")])

    def test_main_actor_closure_in_parentheses_inside_nonisolated_code_is_main(self):
        source = """nonisolated func f(_ d: Data, _ u: URL) {
    run(handler: { @MainActor in
        try? d.write(to: u)
    })
}
"""
        self.assertEqual(hits(source), [(3, WRITE)])

    def test_nonisolated_target_default_is_off_main(self):
        self.assertEqual(hits("func f(_ d: Data, _ u: URL) { try? d.write(to: u) }\n", default_main=False), [])


class BlockingRuleTests(unittest.TestCase):
    def test_each_blocking_system_call_is_flagged_on_main(self):
        calls = {
            "SecItemCopyMatching(query as CFDictionary, &result)": "keychain call (securityd IPC; can wait on a prompt)",
            "SecTrustEvaluateWithError(trust, &error)": "trust evaluation (can fetch revocation over the network)",
            "AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)":
                "Accessibility IPC (waits up to 6 s on an app that does not answer)",
            "CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)": "window-server list query (CGWindowList*)",
            "getaddrinfo(host, nil, &hints, &info)": "DNS lookup",
            "waitpid(pid, &status, 0)": "child wait (waitpid blocks until the child exits)",
            "fsync(fd)": "fsync (waits for the disk)",
            "_ = Darwin.fsync(fd)": "fsync (waits for the disk)",
            "Darwin.waitpid(pid, &status, 0)": "child wait (waitpid blocks until the child exits)",
            "sqlite3_step(statement)": "SQLite statement",
            "try FileManager.default.removeItem(at: url)": WRITE,
            "try string.write(toFile: path, atomically: true, encoding: .utf8)": WRITE,
        }
        for call, rule in calls.items():
            with self.subTest(call=call):
                self.assertEqual(hits(f"func f() {{\n    {call}\n}}\n"), [(2, rule)])

    def test_menu_remove_item_is_not_a_file_change(self):
        self.assertEqual(hits("func f(menu: NSMenu, item: NSMenuItem) {\n    menu.removeItem(item)\n    menu.removeItem(at: 0)\n}\n"), [])

    def test_untyped_exception_silences_the_call_but_is_its_own_hit(self):
        # Lawrence, 2026-11-27: "The comment should have to name the UI type it touches, not how small the data is".
        source = """func f() {
    // main-actor-ok: a one-line pid file in the app's own container, written once at launch.
    try? Data().write(to: url)
}
"""
        self.assertEqual(hits(source), [(2, check.UNTYPED_RULE)])

    def test_exception_naming_an_appkit_or_core_animation_type_passes(self):
        for marker in ("main-actor-ok(NSView): walks the view tree on the picking move",
                       "main-actor-ok(CATransaction): the commit's completion block"):
            with self.subTest(marker=marker):
                source = f"""func f() {{
    // {marker}
    let p = Process()
}}
"""
                self.assertEqual(hits(source), [])

    def test_exception_naming_a_data_type_is_untyped(self):
        for marker in ("main-actor-ok(NSData): a few bytes", "main-actor-ok(String): two keys",
                       "main-actor-ok(): small"):
            with self.subTest(marker=marker):
                source = f"func f() {{\n    let p = Process() // {marker}\n}}\n"
                self.assertEqual(hits(source), [(2, check.UNTYPED_RULE)])

    def test_untyped_exception_counts_off_main_too(self):
        source = "nonisolated func f() {\n    // main-actor-ok: why\n    fsync(fd)\n}\n"
        self.assertEqual(hits(source), [(2, check.UNTYPED_RULE)])

    def test_same_calls_off_main_are_not_flagged(self):
        source = """nonisolated func f() {
    waitpid(pid, &status, 0)
    fsync(fd)
}
"""
        self.assertEqual(hits(source), [])


if __name__ == "__main__":
    unittest.main()
