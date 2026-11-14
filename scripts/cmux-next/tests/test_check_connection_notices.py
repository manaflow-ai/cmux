#!/usr/bin/env python3
"""scripts/cmux-next/check-connection-notices.py on small trees written for each case.

The noisy shapes come from cmux NEXT itself: the agent pane's "Retrying (2/5) after a connection error" drawn the
moment a retry is scheduled (AutoResumeNotice.tsx), the remote placeholder's "Reconnecting to %@…" with no hold
(RemoteTerminalPlaceholderView, error-states audit 2026-11-12), and an iPhone "Connecting…" line. Each fails, and the
fixed shape (held for the shared bound, or carrying one action) passes. Then the allowlist: a listed offender passes,
a stale row fails, a row the base lacks fails, a moved unit keeps its row; and every copy of the bound must say the
schema's value.

    python3 -I scripts/cmux-next/tests/test_check_connection_notices.py
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("check_connection_notices",
                                              ROOT / "scripts/cmux-next/check-connection-notices.py")
ccn = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = ccn  # dataclasses read the module
SPEC.loader.exec_module(ccn)

ALLOWLIST = ccn.ALLOWLIST

STRINGS = {
    "sourceLanguage": "en",
    "strings": {
        "retry.waiting.transport": {"localizations": {"en": {"stringUnit": {
            "state": "translated", "value": "Retrying ({attempt}/{of}) after a connection error"}}}},
        "page.disconnected": {"localizations": {"en": {"stringUnit": {
            "state": "translated", "value": "Not connected to cmux."}}}},
        "page.retry": {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "Retry"}}}},
        "workspaceVerbs.refusal.machineNotConnected": {"localizations": {"en": {"stringUnit": {
            "state": "translated", "value": "That machine isn't connected."}}}},
    },
}

# The agent pane's retry line before conn-quiet: the label helper, and the notice that draws it at once.
RETRY_LABEL = """\
    import type { Translate } from "./i18n";
    export function retryLabel(t: Translate, attempt: number, of: number): string {
      return t("retry.waiting.transport", { attempt, of });
    }
"""
NOISY_NOTICE = """\
    import { retryLabel } from "./retryState";
    export function AutoResumeNotice({ retry, t }: Props) {
      return <output className="notice">{retry ? retryLabel(t, retry.attempt, retry.of) : null}</output>;
    }
"""
HELD_NOTICE = """\
    import { useConnectionQuiet } from "../../ui/lasting";
    import { retryLabel } from "./retryState";
    export function AutoResumeNotice({ retry, t }: Props) {
      const lasting = useConnectionQuiet(retry !== undefined);
      return <output className="notice">{lasting && retry ? retryLabel(t, retry.attempt, retry.of) : null}</output>;
    }
"""
ACTION_NOTICE = """\
    import { retryLabel } from "./retryState";
    export function AutoResumeNotice({ retry, t, onRetry }: Props) {
      return (
        <output className="notice">
          {retry ? retryLabel(t, retry.attempt, retry.of) : null}
          <button type="button" onClick={onRetry}>{t("page.retry")}</button>
        </output>
      );
    }
"""
SHORT_GRACE_NOTICE = """\
    import { useLasting } from "../../ui/lasting";
    import { retryLabel } from "./retryState";
    export function AutoResumeNotice({ retry, t }: Props) {
      const lasting = useLasting(retry !== undefined, 500);
      return <output className="notice">{lasting && retry ? retryLabel(t, retry.attempt, retry.of) : null}</output>;
    }
"""
# An editor page's strings map and a page that says the disconnected key through it.
PAGE_STRINGS = """\
    export const L = {
      title: "page.title",
      disconnected: "page.disconnected",
      retry: "page.retry",
    };
"""
QUIET_PAGE_OLD = """\
    import { L } from "./strings";
    export function EditorPage({ state, t }: Props) {
      if (state.phase === "disconnected") return <p role="alert">{t(L.disconnected)}</p>;
      return <main>{t(L.title)}</main>;
    }
"""
QUIET_PAGE_FIXED = """\
    import { useLasting } from "../../ui/lasting";
    import { L } from "./strings";
    export function EditorPage({ state, t }: Props) {
      const downLasting = useLasting(state.phase === "disconnected");
      if (downLasting) return <p role="alert">{t(L.disconnected)}</p>;
      return <main>{t(L.title)}</main>;
    }
"""
# Not a connection state a person reads: a state tag, a log line, a refusal answering their own click.
NOT_TEXT = """\
    import { L } from "./strings";
    export function PhaseBadge({ phase, t }: Props) {
      if (phase === "disconnected") console.warn("Reconnecting to the page host");
      return <span data-phase={phase}>{t(L.title)}</span>;
    }
"""
SWIFT_REFUSAL = """\
    enum WorkspaceVerbStrings {
        static var machineNotConnected: String { String(localized: "workspaceVerbs.refusal.machineNotConnected", defaultValue: "That machine isn't connected.") }
    }
"""
# The remote placeholder before conn-quiet: a strings type and the view that draws its line at once.
SWIFT_STRINGS = """\
    enum RemoteStrings {
        static func placeholderReconnecting(_ machine: String) -> String { String(format: String(localized: "remote.terminal.reconnecting", defaultValue: "Reconnecting to %@…"), machine) }
        static func placeholderTitle(_ machine: String) -> String { machine }
    }
"""
SWIFT_VIEW_OLD = """\
    import AppKit

    final class RemoteTerminalPlaceholderView: NSView {
        func show(machine: String) {
            label.stringValue = RemoteStrings.placeholderReconnecting(machine)
        }
    }
"""
SWIFT_VIEW_FIXED = """\
    import AppKit
    import CmuxNextDesignTokens

    final class RemoteTerminalPlaceholderView: NSView {
        func show(machine: String) {
            reveal(after: NoticeTiming.connectionQuiet) { [label] in
                label.stringValue = RemoteStrings.placeholderReconnecting(machine)
            }
        }
    }
"""
SWIFT_TITLE_ONLY = """\
    import AppKit

    final class RemoteTerminalTitleView: NSView {
        func show(machine: String) { label.stringValue = RemoteStrings.placeholderTitle(machine) }
    }
"""
IOS_OLD = """\
    import SwiftUI

    struct TerminalStatusLine: View {
        let connecting: Bool
        var body: some View {
            if connecting { Text("Connecting…").font(.footnote) }
        }
    }
"""
IOS_FIXED = """\
    import SwiftUI

    struct TerminalStatusLine: View {
        let connecting: Bool
        @State private var gate = QuietStatusGate()
        var body: some View {
            if gate.isShown { Text("Connecting…").font(.footnote) }
        }
    }
"""

WEB = "webviews/src/agent-session/acpmux"
PAGE = "webviews/src/pages/editor"
MAC = "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Remote"
IOS = "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileTerminal"


class Tree:
    def __init__(self, test: unittest.TestCase):
        self._dir = tempfile.TemporaryDirectory(prefix="ccn-")
        test.addCleanup(self._dir.cleanup)
        self.root = Path(self._dir.name)
        self.write(f"{WEB}/Localizable.xcstrings", json.dumps(STRINGS))

    def write(self, path: str, text: str) -> None:
        file = self.root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(textwrap.dedent(text), encoding="utf-8")

    def remove(self, path: str) -> None:
        (self.root / path).unlink()

    def allow(self, *units: str) -> None:
        rows = {unit: ("web:test", "conn-quiet-test", "on the base when the check landed") for unit in units}
        ccn.write_allowlist(self.root / ALLOWLIST, rows)

    def check(self, base: str | None = None) -> tuple[int, str]:
        out = io.StringIO()
        code = ccn.check(self.root, base, out=out)
        return code, out.getvalue()

    def git(self, *args: str) -> str:
        env = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
               "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
               "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com"}
        return subprocess.run(["git", "-C", str(self.root), *args], check=True, capture_output=True, text=True,
                              env=env).stdout

    def commit(self, message: str) -> None:
        if not (self.root / ".git").exists():
            self.git("init", "-q", "-b", "main")
            self.git("config", "maintenance.auto", "false")
            self.git("config", "gc.auto", "0")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)


class WebShapes(unittest.TestCase):
    def test_old_retry_line_drawn_at_once_fails_at_its_drawing(self):
        tree = Tree(self)
        tree.write(f"{WEB}/retryState.ts", RETRY_LABEL)
        tree.write(f"{WEB}/AutoResumeNotice.tsx", NOISY_NOTICE)
        code, out = tree.check()
        self.assertEqual(code, 1, out)
        self.assertIn(f"{WEB}/AutoResumeNotice.tsx:3: AutoResumeNotice shows a connection state", out)
        self.assertIn("retryLabel: retry.waiting.transport", out)
        self.assertNotIn("retryState.ts", out, "the label helper only holds the words; the drawing is the offender")

    def test_retry_line_held_for_the_shared_bound_passes(self):
        tree = Tree(self)
        tree.write(f"{WEB}/retryState.ts", RETRY_LABEL)
        tree.write(f"{WEB}/AutoResumeNotice.tsx", HELD_NOTICE)
        self.assertEqual(tree.check(), (0, tree.check()[1]))

    def test_retry_line_with_one_action_passes(self):
        tree = Tree(self)
        tree.write(f"{WEB}/retryState.ts", RETRY_LABEL)
        tree.write(f"{WEB}/AutoResumeNotice.tsx", ACTION_NOTICE)
        code, out = tree.check()
        self.assertEqual(code, 0, out)

    def test_a_literal_grace_under_the_bound_is_no_bound(self):
        tree = Tree(self)
        tree.write("schemas/notice-timing/notice-timing.json", json.dumps({"connectionQuietMs": 10000}))
        tree.write(f"{WEB}/retryState.ts", RETRY_LABEL)
        tree.write(f"{WEB}/AutoResumeNotice.tsx", SHORT_GRACE_NOTICE)
        code, out = tree.check()
        self.assertEqual(code, 1, out)
        self.assertIn("a literal grace under the bound (useLasting(retry !== undefined, 500))", out)

    def test_a_key_said_through_a_pages_strings_map(self):
        tree = Tree(self)
        tree.write(f"{PAGE}/strings.ts", PAGE_STRINGS)
        tree.write(f"{PAGE}/EditorPage.tsx", QUIET_PAGE_OLD)
        code, out = tree.check()
        self.assertEqual(code, 1, out)
        self.assertIn(f"{PAGE}/EditorPage.tsx:3: EditorPage shows a connection state ('L: page.disconnected')", out)
        tree.write(f"{PAGE}/EditorPage.tsx", QUIET_PAGE_FIXED)
        code, out = tree.check()
        self.assertEqual(code, 0, out)

    def test_state_tags_logs_and_other_keys_are_not_text(self):
        tree = Tree(self)
        tree.write(f"{PAGE}/strings.ts", PAGE_STRINGS)
        tree.write(f"{PAGE}/PhaseBadge.tsx", NOT_TEXT)
        code, out = tree.check()
        self.assertEqual(code, 0, out)


class NativeShapes(unittest.TestCase):
    def test_old_remote_placeholder_fails_at_the_view_not_the_strings(self):
        tree = Tree(self)
        tree.write(f"{MAC}/RemoteStrings.swift", SWIFT_STRINGS)
        tree.write(f"{MAC}/RemoteTerminalPlaceholderView.swift", SWIFT_VIEW_OLD)
        tree.write(f"{MAC}/RemoteTerminalTitleView.swift", SWIFT_TITLE_ONLY)
        code, out = tree.check()
        self.assertEqual(code, 1, out)
        self.assertIn(f"{MAC}/RemoteTerminalPlaceholderView.swift:5: RemoteTerminalPlaceholderView shows a connection "
                      "state ('RemoteStrings: Reconnecting to %@…')", out)
        self.assertNotIn("RemoteTerminalTitleView", out, "a view that draws another member of the strings is quiet")
        self.assertNotIn("RemoteStrings.swift", out)

    def test_remote_placeholder_held_for_notice_timing_passes(self):
        tree = Tree(self)
        tree.write(f"{MAC}/RemoteStrings.swift", SWIFT_STRINGS)
        tree.write(f"{MAC}/RemoteTerminalPlaceholderView.swift", SWIFT_VIEW_FIXED)
        code, out = tree.check()
        self.assertEqual(code, 0, out)

    def test_a_refusal_answering_the_persons_own_action_is_not_a_state(self):
        tree = Tree(self)
        tree.write(f"{MAC}/WorkspaceVerbStrings.swift", SWIFT_REFUSAL)
        code, out = tree.check()
        self.assertEqual(code, 0, out)

    def test_ios_connecting_line(self):
        tree = Tree(self)
        tree.write(f"{IOS}/TerminalStatusLine.swift", IOS_OLD)
        code, out = tree.check()
        self.assertEqual(code, 1, out)
        self.assertIn(f"{IOS}/TerminalStatusLine.swift:6: TerminalStatusLine shows a connection state ('Connecting…')",
                      out)
        tree.write(f"{IOS}/TerminalStatusLine.swift", IOS_FIXED)
        code, out = tree.check()
        self.assertEqual(code, 0, out)

    def test_tests_and_galleries_are_not_read(self):
        tree = Tree(self)
        tree.write(f"{IOS}/Tests/TerminalStatusLineTests.swift", IOS_OLD)
        tree.write(f"{WEB}/AutoResumeNotice.gallery.tsx", NOISY_NOTICE)
        tree.write(f"{WEB}/retryState.ts", RETRY_LABEL)
        code, out = tree.check()
        self.assertEqual(code, 1, out)  # the label helper itself, drawn by nothing the check reads
        self.assertIn("retryState.ts:3: retryLabel", out)
        self.assertNotIn("Tests/", out)
        self.assertNotIn(".gallery.", out)


class Allowlist(unittest.TestCase):
    NOTICE = f"{WEB}/AutoResumeNotice.tsx::AutoResumeNotice"

    def noisy(self) -> Tree:
        tree = Tree(self)
        tree.write(f"{WEB}/retryState.ts", RETRY_LABEL)
        tree.write(f"{WEB}/AutoResumeNotice.tsx", NOISY_NOTICE)
        return tree

    def test_a_listed_offender_passes(self):
        tree = self.noisy()
        tree.allow(self.NOTICE)
        code, out = tree.check()
        self.assertEqual(code, 0, out)
        self.assertIn("1 listed: web:test 1", out)

    def test_a_fixed_unit_left_in_the_list_fails_as_stale(self):
        tree = self.noisy()
        tree.allow(self.NOTICE)
        tree.write(f"{WEB}/AutoResumeNotice.tsx", HELD_NOTICE)
        code, out = tree.check()
        self.assertEqual(code, 1, out)
        self.assertIn(f"stale row {self.NOTICE}", out)

    def test_a_deleted_unit_left_in_the_list_fails_as_stale(self):
        tree = self.noisy()
        tree.allow(self.NOTICE)
        tree.remove(f"{WEB}/AutoResumeNotice.tsx")
        code, out = tree.check()
        self.assertEqual(code, 1, out)
        self.assertIn(f"stale row {self.NOTICE}", out)

    def test_a_row_the_base_lacks_fails(self):
        tree = self.noisy()
        tree.allow()
        tree.commit("base: the notice is fixed")
        tree.allow(self.NOTICE)
        tree.commit("head: a new offender, listed")
        code, out = tree.check(base="HEAD^1")
        self.assertEqual(code, 1, out)
        self.assertIn(f"new row {self.NOTICE}: the list only shrinks", out)

    def test_a_row_swapped_for_another_at_the_same_count_fails(self):
        tree = self.noisy()
        tree.write(f"{WEB}/OtherNotice.tsx", NOISY_NOTICE.replace("AutoResumeNotice", "OtherNotice"))
        other = f"{WEB}/OtherNotice.tsx::OtherNotice"
        tree.allow(self.NOTICE)
        tree.write(f"{WEB}/OtherNotice.tsx", HELD_NOTICE.replace("AutoResumeNotice", "OtherNotice"))
        tree.commit("base")
        tree.write(f"{WEB}/AutoResumeNotice.tsx", HELD_NOTICE)
        tree.write(f"{WEB}/OtherNotice.tsx", NOISY_NOTICE.replace("AutoResumeNotice", "OtherNotice"))
        tree.allow(other)
        tree.commit("head: one fixed, another listed")
        code, out = tree.check(base="HEAD^1")
        self.assertEqual(code, 1, out)
        self.assertIn(f"new row {other}", out)

    def test_a_unit_moved_to_another_file_keeps_its_row(self):
        tree = self.noisy()
        tree.allow(self.NOTICE)
        tree.commit("base")
        tree.remove(f"{WEB}/AutoResumeNotice.tsx")
        tree.write(f"{WEB}/notices/AutoResumeNotice.tsx", NOISY_NOTICE.replace("./retryState", "../retryState"))
        tree.allow(f"{WEB}/notices/AutoResumeNotice.tsx::AutoResumeNotice")
        tree.commit("head: moved")
        code, out = tree.check(base="HEAD^1")
        self.assertEqual(code, 0, out)

    def test_the_change_that_adds_the_list_has_no_base_list(self):
        tree = self.noisy()
        tree.commit("base: no list yet")
        tree.allow(self.NOTICE)
        tree.commit("head: the check lands with its list")
        code, out = tree.check(base="HEAD^1")
        self.assertEqual(code, 0, out)

    def test_write_allowlist_drops_fixed_rows_and_adds_none(self):
        tree = self.noisy()
        tree.allow(self.NOTICE, f"{WEB}/Gone.tsx::Gone")
        with contextlib.redirect_stdout(io.StringIO()):
            ccn.main(["--root", str(tree.root), "--write-allowlist"])
        rows = ccn.read_allowlist((tree.root / ALLOWLIST).read_text(encoding="utf-8"))
        self.assertEqual(list(rows), [self.NOTICE])


class SharedBound(unittest.TestCase):
    def tree_with_copies(self, web: str, mac: str, ios: str) -> Tree:
        tree = Tree(self)
        tree.write("schemas/notice-timing/notice-timing.json", json.dumps({"connectionQuietMs": 10000}))
        tree.write("webviews/src/ui/lasting.ts", f"export const CONNECTION_QUIET_MS = {web};\n")
        tree.write("Packages/macOS/CmuxNext/Sources/CmuxNextDesignTokens/NoticeTiming.swift",
                   f"public enum NoticeTiming {{ public static let connectionQuiet: Duration = .milliseconds({mac}) }}\n")
        tree.write("cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileDesign/QuietStatusGate.swift",
                   f"public static let threshold: Duration = .seconds({ios})\n")
        return tree

    def test_every_copy_says_the_schemas_bound(self):
        code, out = self.tree_with_copies("10_000", "10_000", "10").check()
        self.assertEqual(code, 0, out)

    def test_a_copy_that_drifts_fails(self):
        code, out = self.tree_with_copies("1_500", "10_000", "10").check()
        self.assertEqual(code, 1, out)
        self.assertIn("webviews/src/ui/lasting.ts: the connection bound is 1500 ms", out)

    def test_the_repository_copies_agree(self):
        """The real schema and its copies, read from this checkout."""
        tree = ccn.Tree(ROOT)
        if not (ROOT / ccn.NOTICE_TIMING).is_file():
            self.skipTest("no schema in this checkout")
        self.assertEqual(ccn.bound_drift(tree), [])


if __name__ == "__main__":
    unittest.main()
