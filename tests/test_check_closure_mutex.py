"""check-closure-mutex.py: no `withLock` on a lock whose value is a closure (#40144).

`withLock` hands its body the value `inout` at the generic abstraction; for a closure (an
optional one, or a tuple holding one) Swift wraps the stored closure in two more thunks per
call and writes it back. The watchdog's `onStall` grew 74,661 frames deep that way and
overflowed the main thread's stack. A struct or an array holding the closure is not converted.
"""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cmux-next/check-closure-mutex.py"

# The shape that crashed (MainThreadWatchdog before the fix).
WATCHDOG = """import CmuxNextCompat

public final class Watchdog: Sendable {
    public var onStall: (@Sendable (Int) -> Void)? {
        get { stallSink.withLock { $0 } }
        set { stallSink.withLock { $0 = newValue } }
    }
    private let stallSink = Mutex<(@Sendable (Int) -> Void)?>(nil)
}
"""
FIXED = WATCHDOG.replace("stallSink.withLock { $0 }", "stallSink.load()").replace(
    "stallSink.withLock { $0 = newValue }", "stallSink.store(newValue)")
TUPLE = """import CmuxNextCompat

final class CancelBox: Sendable {
    private let state = Mutex<(fired: Bool, action: (@Sendable () -> Void)?)>((false, nil))
    func fire() { state.withLock { $0.action }?() }
}
"""
STRUCT = """import CmuxNextCompat

final class CancelBox: Sendable {
    private struct State: Sendable { var fired = false; var action: (@Sendable () -> Void)? }
    private let state = Mutex(State())
    func fire() { state.withLock { $0.action }?() }
}
"""
ALIAS = """import os

typealias Handler = @Sendable (String) -> Void

final class Relay: Sendable {
    private let handler = OSAllocatedUnfairLock<Handler?>(initialState: nil)
    func send(_ text: String) { handler.withLock { $0 }?(text) }
}
"""
# `Answer` is a function typealias in one file and a struct in another: the struct's file is fine.
ALIAS_ELSEWHERE = "typealias Answer = (Int) -> Bool\n"
NOMINAL_SAME_NAME = """import CmuxNextCompat

final class Switch: Sendable {
    struct Answer: Sendable { var enabled: Bool }
    private let state = Mutex<Answer?>(nil)
    var current: Answer? { state.withLock { $0 } }
}
"""
ARRAY = """import CmuxNextCompat

final class Hooks: Sendable {
    private let hooks = Mutex<[@Sendable () -> Void]>([])
    func run() { for hook in hooks.withLock({ $0 }) { hook() } }
}
"""
ALLOWED = """import CmuxNextCompat

final class Once: Sendable {
    private let action = Mutex<(@Sendable () -> Void)?>(nil)
    func take() -> (@Sendable () -> Void)? {
        // closure-mutex-allow: one take per instance, the thunk never accumulates.
        action.withLock { value in defer { value = nil }; return value }
    }
}
"""


def run(files):
    with tempfile.TemporaryDirectory() as tmp:
        for name, text in files.items():
            path = Path(tmp) / "Pkg" / "Sources" / "Mod" / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        result = subprocess.run([sys.executable, "-I", str(SCRIPT), tmp], capture_output=True, text=True)
        return result.returncode, result.stdout


class CheckClosureMutexTests(unittest.TestCase):
    def test_flags_the_watchdog_shape_that_crashed(self):
        code, out = run({"Watchdog.swift": WATCHDOG})
        self.assertEqual(code, 1, out)
        self.assertIn("Watchdog.swift:5:", out)
        self.assertIn("Watchdog.swift:6:", out)

    def test_load_and_store_pass(self):
        code, out = run({"Watchdog.swift": FIXED})
        self.assertEqual(code, 0, out)

    def test_flags_a_tuple_holding_a_closure(self):
        code, out = run({"CancelBox.swift": TUPLE})
        self.assertEqual(code, 1, out)
        self.assertIn("CancelBox.swift:5:", out)

    def test_a_struct_or_array_holding_a_closure_passes(self):
        code, out = run({"CancelBox.swift": STRUCT, "Hooks.swift": ARRAY})
        self.assertEqual(code, 0, out)

    def test_flags_a_function_typealias_in_an_unfair_lock(self):
        code, out = run({"Relay.swift": ALIAS})
        self.assertEqual(code, 1, out)
        self.assertIn("Relay.swift:7:", out)

    def test_a_struct_named_like_a_function_alias_elsewhere_passes(self):
        code, out = run({"Alias.swift": ALIAS_ELSEWHERE, "Switch.swift": NOMINAL_SAME_NAME})
        self.assertEqual(code, 0, out)

    def test_a_reviewed_exception_passes(self):
        code, out = run({"Once.swift": ALLOWED})
        self.assertEqual(code, 0, out)


if __name__ == "__main__":
    unittest.main()
