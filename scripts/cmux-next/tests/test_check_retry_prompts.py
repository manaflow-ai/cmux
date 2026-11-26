#!/usr/bin/env python3
"""scripts/cmux-next/check-retry-prompts.py on small trees written for each case.

The shapes come from cmux NEXT itself: the held-messages row's "Couldn't read the held messages. Try again"
(Leo, 2026-11-22), a web `t("project.retry")` whose English is "Try again", an iPhone `Button("Try Again")` and an
acpmux CLI error ending "; try again". Each new one fails; a marked one passes; a counted one passes until fixed,
then it asks for its row to come down.

    python3 -I scripts/cmux-next/tests/test_check_retry_prompts.py
"""
from __future__ import annotations

import importlib.util
import io
import json
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("check_retry_prompts", ROOT / "scripts/cmux-next/check-retry-prompts.py")
crp = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = crp
SPEC.loader.exec_module(crp)

STRINGS = {
    "sourceLanguage": "en",
    "strings": {
        "project.retry": {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "Try again"}}}},
        "project.open": {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "Open"}}}},
    },
}


class RetryPrompts(unittest.TestCase):
    def setUp(self) -> None:
        self._dir = tempfile.TemporaryDirectory()
        self.root = Path(self._dir.name)
        self.write("webviews/src/agent-session/acpmux/Localizable.xcstrings", json.dumps(STRINGS))

    def tearDown(self) -> None:
        self._dir.cleanup()

    def write(self, path: str, text: str) -> None:
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(textwrap.dedent(text), encoding="utf-8")

    def run_check(self, **kw) -> tuple[int, str]:
        out = io.StringIO()
        return crp.check(self.root, out=out, **kw), out.getvalue()

    def test_held_messages_try_again_fails(self) -> None:
        self.write("webviews/src/agent-session/acpmux/SurgeHoldRow.tsx", """\
            export function SurgeHoldRow() {
              return <p>Couldn't read the held messages. Try again</p>;
            }
        """)
        code, out = self.run_check()
        self.assertEqual(code, 1, out)
        self.assertIn("SurgeHoldRow.tsx", out)

    def test_string_table_key_fails(self) -> None:
        self.write("webviews/src/pages/Add.tsx", 'export const Add = () => <button>{t("project.retry")}</button>;\n')
        self.assertEqual(self.run_check()[0], 1)

    def test_swift_button_and_rust_error_fail(self) -> None:
        self.write("cmux-next-ios/Kit/Sources/Chat/Screen.swift", 'Button("Try Again") { reload() }\n')
        self.write("cmux-tui/crates/acpmux/src/cli/chats.rs",
                   'out.push_str("the chat index is still scanning; try again in a moment\\n");\n')
        code, out = self.run_check()
        self.assertEqual(code, 1)
        self.assertIn("Screen.swift", out)
        self.assertIn("chats.rs", out)

    def test_marked_prompt_passes(self) -> None:
        self.write("webviews/src/pages/Send.tsx", """\
            export function Send() {
              // retry-prompt-ok: re-sends a paid model request; the person chooses to spend it
              return <button>Retry</button>;
            }
        """)
        self.assertEqual(self.run_check()[0], 0)

    def test_not_prompts_pass(self) -> None:
        self.write("webviews/src/pages/Quiet.tsx", """\
            // Try again is gone from here: it retries on its own.
            const icon = "action.retry";
            const open = t("project.open");
            console.warn("Try again later");
            export const Quiet = () => <p>Reconnecting…</p>;
        """)
        self.write("cmux-tui/crates/x/src/lib.rs", """\
            fn f() { tracing::warn!("reconnect failed; try again"); let k = "hook retry max_attempts"; }
            #[cfg(test)]
            mod tests { fn t() { assert_eq!(e, "Try again"); } }
        """)
        self.write("webviews/src/pages/Row.gallery.tsx", "export const g = <p>Try again</p>;\n")
        self.write("webviews/src/pages/Row.test.tsx", 'expect(text).toBe("Try again");\n')
        code, out = self.run_check()
        self.assertEqual(code, 0, out)

    def test_chat_simulator_inputs_are_not_shipped_copy(self) -> None:
        self.write("webviews/src/agent-session/acpmux/sim/layoutCases.ts", """
            const REPLY = "Mixed: retry three times then stop.";
        """)
        self.write("webviews/src/agent-session/acpmux/sim/scenarios.ts", """
            export const failed = () => sim("failed", "Try again.");
        """)
        self.assertEqual(self.run_check()[0], 0)

    def test_neighboring_simulation_path_is_still_scanned(self) -> None:
        self.write("webviews/src/agent-session/acpmux/simulation/ProductCopy.tsx", """
            export const ProductCopy = () => <button>Try again</button>;
        """)
        code, out = self.run_check()
        self.assertEqual(code, 1, out)
        self.assertIn("ProductCopy.tsx", out)

    def test_baseline_counts_only_go_down(self) -> None:
        self.write("cmux-next-ios/Kit/Sources/Chat/Screen.swift", 'Button("Try Again") { a() }\nButton("Retry") { b() }\n')
        self.write(crp.BASELINE, crp.BASELINE_HEADER + "cmux-next-ios/Kit/Sources/Chat/Screen.swift\t2\n")
        self.assertEqual(self.run_check()[0], 0)
        self.write("cmux-next-ios/Kit/Sources/Chat/Screen.swift", 'Button("Try Again") { a() }\n')
        code, out = self.run_check()
        self.assertEqual(code, 0)  # a fix never turns the base red
        self.assertIn("lower it", out)
        self.assertEqual(self.run_check(update=True)[0], 0)
        self.assertIn("Screen.swift\t1", (self.root / crp.BASELINE).read_text())
        self.write("cmux-next-ios/Kit/Sources/Chat/Screen.swift", 'Button("Try Again") { a() }\nButton("Retry") { b() }\n')
        self.assertEqual(self.run_check(update=True)[0], 1)  # never raised
        self.assertIn("Screen.swift\t1", (self.root / crp.BASELINE).read_text())


if __name__ == "__main__":
    unittest.main()
