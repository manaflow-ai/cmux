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
# tests/git_fixture_env.py builds a fixture repository's git env: no inherited GIT_DIR or config, no maintenance.
_GIT_FIXTURE = importlib.util.spec_from_file_location("git_fixture_env", ROOT / "tests/git_fixture_env.py")
git_fixture_env = importlib.util.module_from_spec(_GIT_FIXTURE)
_GIT_FIXTURE.loader.exec_module(git_fixture_env)

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
# A strings member whose words sit under a local (`let state`) inside it, and the button that draws it (cmux#53574's
# Live tooltip: "Click to go offline" read as a state on the strings type, and every kit run on base went red).
SWIFT_STRINGS_LOCAL = """\
    extension Strings {
        static func liveTooltip(isLive: Bool) -> String {
            let state = isLive
                ? String(localized: "sidebar.live.on", defaultValue: "Live is on. Click to go offline.")
                : String(localized: "sidebar.live.off", defaultValue: "Live is off. Click to go live.")
            return state
        }
    }
"""
SWIFT_LIVE_BUTTON = """\
    import AppKit

    extension SidebarView {
        func applyLive() { liveButton.toolTip = Strings.liveTooltip(isLive: live.isLive) }
        func liveMenu() -> NSMenu {
            let item = NSMenuItem(title: "", action: #selector(SidebarLiveMenuTarget.pick(_:)), keyEquivalent: "")
            return NSMenu()
        }
    }
"""
SWIFT_LIVE_LABEL = """\
    import AppKit

    final class LiveLabel: NSView {
        func show(isLive: Bool) { label.stringValue = Strings.liveTooltip(isLive: isLive) }
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
        env = git_fixture_env.without_auto_maintenance(git_fixture_env.write_env())
        env.update(GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com",
                   GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.com")
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

    def test_a_view_drawing_its_own_button_component_carries_the_action(self):
        tree = Tree(self)
        tree.write(f"{WEB}/retryState.ts", RETRY_LABEL)
        tree.write(f"{WEB}/AutoResumeNotice.tsx", """\
    import { retryLabel } from "./retryState";
    function RetryButton({ onRetry }: { onRetry: () => void }) {
      return <button type="button" onClick={onRetry}>Retry</button>;
    }
    export function AutoResumeNotice({ retry, t, onRetry }: Props) {
      return <output className="notice">{retry ? retryLabel(t, retry.attempt, retry.of) : null}<RetryButton onRetry={onRetry} /></output>;
    }
""")
        code, out = tree.check()
        self.assertEqual(code, 0, out)

    def test_a_view_drawing_an_imported_button_component_carries_the_action(self):
        tree = Tree(self)
        tree.write(f"{WEB}/retryState.ts", RETRY_LABEL)
        tree.write(f"{WEB}/RetryButton.tsx", """\
    export function RetryButton({ onRetry }: { onRetry: () => void }) {
      return <button type="button" onClick={onRetry}>Retry</button>;
    }
""")
        tree.write(f"{WEB}/AutoResumeNotice.tsx", """\
    import { retryLabel } from "./retryState";
    import { RetryButton } from "./RetryButton";
    export function AutoResumeNotice({ retry, t, onRetry }: Props) {
      return <output className="notice">{retry ? retryLabel(t, retry.attempt, retry.of) : null}<RetryButton onRetry={onRetry} /></output>;
    }
""")
        code, out = tree.check()
        self.assertEqual(code, 0, out)

    def test_a_drawn_component_without_an_action_is_no_action(self):
        tree = Tree(self)
        tree.write(f"{WEB}/retryState.ts", RETRY_LABEL)
        tree.write(f"{WEB}/AutoResumeNotice.tsx", """\
    import { retryLabel } from "./retryState";
    function MarkButton() {
      return <span className="mark" />;
    }
    export function AutoResumeNotice({ retry, t }: Props) {
      return <output className="notice"><MarkButton />{retry ? retryLabel(t, retry.attempt, retry.of) : null}</output>;
    }
""")
        code, out = tree.check()
        self.assertEqual(code, 1, out)

    def test_inline_copy_is_judged_at_each_row_that_draws_it(self):
        tree = Tree(self)
        tree.write(f"{WEB}/strings.ts", PAGE_STRINGS)
        tree.write(f"{WEB}/StateWord.tsx", """
            import { L } from "./strings";
            export function StateWord({ t }) { return <span>{t(L.disconnected)}</span>; }
        """)
        tree.write(f"{WEB}/Rows.tsx", """
            import { StateWord as Badge } from "./StateWord";
            function LocalWord() { return <Badge />; }
            export function PairedRow({ connect }) {
              const pill = <LocalWord />;
              return <Card pill={pill} action={<button onClick={connect}>Connect</button>} />;
            }
            export function BareRow() { return <section><LocalWord /></section>; }
        """)
        code, out = tree.check()
        self.assertEqual(code, 1, out)
        self.assertIn("BareRow shows a connection state", out)
        self.assertNotIn("PairedRow shows", out)
        self.assertNotIn("StateWord shows", out)
        self.assertNotIn("LocalWord shows", out)

    def test_unresolved_or_unmounted_inline_copy_stays_a_finding(self):
        for extra in ["", "export const registry = [StateWord];",
                      'export { StateWord } from "./StateWord";',
                      'export const load = () => import("./StateWord");',
                      'export const load = () => require("./StateWord");',
                      'export function Nested() { return <StateWord.Other />; }',
                      'export const example = "<StateWord />";']:
            with self.subTest(extra=extra):
                tree = Tree(self)
                tree.write(f"{WEB}/StateWord.tsx", """
                    export function StateWord() { return <span>Offline</span>; }
                """)
                if extra:
                    tree.write(f"{WEB}/Use.tsx", f"""
                        import {{ StateWord }} from "./StateWord";
                        export function ActionRow() {{ return <button onClick={{connect}}><StateWord /></button>; }}
                        {extra}
                    """)
                code, out = tree.check()
                self.assertEqual(code, 1, out)
                self.assertIn("StateWord shows a connection state", out)

    def test_relative_action_does_not_cover_unresolved_alias_consumer(self):
        for declaration, tag in [
            ('import { StateWord as Badge } from "@/other/component";', "Badge"),
            ('import Badge from "@/other/StateWord";', "Badge"),
            ('import * as labels from "@/other/StateWord";', "labels.StateWord"),
        ]:
            with self.subTest(declaration=declaration):
                tree = Tree(self)
                tree.write(f"{WEB}/StateWord.tsx", """
                    export function StateWord() { return <span>Offline</span>; }
                """)
                tree.write(f"{WEB}/ActionRow.tsx", """
                    import { StateWord } from "./StateWord";
                    export function ActionRow() { return <button onClick={connect}><StateWord /></button>; }
                """)
                tree.write(f"{WEB}/BareRow.tsx", declaration + f"\nexport function BareRow() {{ return <{tag} />; }}")
                code, out = tree.check()
                self.assertEqual(code, 1, out)
                self.assertIn("StateWord shows a connection state", out)

    def test_live_region_keeps_its_own_finding(self):
        tree = Tree(self)
        tree.write(f"{WEB}/Notice.tsx", """
            function Notice() { return <span role="status">Offline</span>; }
            export function Page() { return <section><Notice /><button onClick={save}>Save</button></section>; }
        """)
        code, out = tree.check()
        self.assertEqual(code, 1, out)
        self.assertIn("Notice shows a connection state", out)

    def test_recursive_presenter_keeps_a_finding(self):
        tree = Tree(self)
        tree.write(f"{WEB}/Cycle.tsx", """
            function Word() { return <span>Offline</span>; }
            function Left() { return <Right><Word /></Right>; }
            function Right() { return <Left />; }
        """)
        code, out = tree.check()
        self.assertEqual(code, 1, out)
        self.assertIn("shows a connection state", out)

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

    def test_words_under_a_local_belong_to_the_member_around_it(self):
        """The hit's member is the strings function, not the `let` inside it: the words move to the unit that calls
        the function. A button with its own action passes; a label with none fails at the label."""
        tree = Tree(self)
        tree.write(f"{MAC}/Strings+Live.swift", SWIFT_STRINGS_LOCAL)
        tree.write(f"{MAC}/SidebarView+Live.swift", SWIFT_LIVE_BUTTON)
        code, out = tree.check()
        self.assertEqual(code, 0, out)
        tree.write(f"{MAC}/LiveLabel.swift", SWIFT_LIVE_LABEL)
        code, out = tree.check()
        self.assertEqual(code, 1, out)
        self.assertIn(f"{MAC}/LiveLabel.swift:4: LiveLabel shows a connection state", out)
        self.assertNotIn("Strings+Live.swift:", out)

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

    def test_a_quiet_hold_at_the_bound_passes_and_a_short_one_does_not(self):
        """cmux#43311 added QuietHold (CmuxNextWakeups): a hold for the bound is a gate; a shorter literal is not."""
        view = ("struct RemoteTerminalPlaceholderView: View {{\n"
                "    var reconnectHold = QuietHold(owner: \"remote-terminal-reconnect\", delay: {delay})\n"
                "    var body: some View {{ Text(\"Reconnecting…\") }}\n}}\n")
        tree = Tree(self)
        tree.write(f"{MAC}/RemoteTerminalPlaceholderView.swift", view.format(delay=".seconds(10)"))
        code, out = tree.check()
        self.assertEqual(code, 0, out)
        tree.write(f"{MAC}/RemoteTerminalPlaceholderView.swift", view.format(delay=".milliseconds(1_500)"))
        code, out = tree.check()
        self.assertEqual(code, 1, out)
        self.assertIn("a literal grace under the bound (QuietHold(", out)

    def test_a_mac_connection_chip_is_a_gate(self):
        """CmuxNextDesign's connectionChip / connectionLasting hold the state for NoticeTiming.connectionQuiet."""
        view = ("struct RemotePathBadgeView: View {\n"
                "    var body: some View { Color.clear.connectionChip(down ? \"Reconnecting\" : nil) }\n}\n")
        tree = Tree(self)
        tree.write(f"{MAC}/RemotePathBadgeView.swift", view)
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

    def test_ios_reattaching_pill_is_a_connection_state(self):
        """The iOS terminal pill's "Reattaching…" (Leo's gray-out report) is read like "Reconnecting…"."""
        old = ("struct TerminalTabPill {\n"
               "    func subtitle(down: Bool) -> String? { down ? \"Reattaching…\" : nil }\n}\n")
        held = ("struct TerminalTabPill {\n"
                "    let gate = QuietStatusGate()\n"
                "    func subtitle(down: Bool) -> String? { gate.isShown(down) ? \"Reattaching…\" : nil }\n}\n")
        tree = Tree(self)
        tree.write(f"{IOS}/TerminalTabPill.swift", old)
        code, out = tree.check()
        self.assertEqual(code, 1, out)
        self.assertIn("TerminalTabPill shows a connection state ('Reattaching…')", out)
        tree.write(f"{IOS}/TerminalTabPill.swift", held)
        code, out = tree.check()
        self.assertEqual(code, 0, out)

    def test_a_swiftui_trailing_closure_button_is_an_action(self):
        """`Button { ... } label: { ... }` is a person action like `Button("Retry")` (iOS ConnectionChip)."""
        chip = ("struct ConnectionChip: View {\n"
                "    let retry: (() -> Void)?\n"
                "    var body: some View {\n"
                "        Button { retry?() } label: { Text(\"Connecting\") }\n    }\n}\n")
        tree = Tree(self)
        tree.write(f"{IOS}/ConnectionChip.swift", chip)
        code, out = tree.check()
        self.assertEqual(code, 0, out)

    def test_a_model_that_names_its_action_type_is_an_action_and_a_text_field_is_not(self):
        """A row model's `var action: Action?` (Mac Home chief connections) carries the person's action; a field
        that only holds words (`var action: String?`, a subagent's description) does not."""
        acted = ("struct HomeChiefConnection {\n"
                 "    var status: String { \"Not connected\" }\n"
                 "    public var action: Action? { .connect }\n"
                 "    enum Action { case connect }\n}\n")
        worded = ("struct AgentSubagent {\n"
                  "    var status: String { \"Disconnected\" }\n"
                  "    public var action: String?\n}\n")
        tree = Tree(self)
        tree.write(f"{IOS}/HomeChiefConnection.swift", acted)
        code, out = tree.check()
        self.assertEqual(code, 0, out)
        tree.write(f"{IOS}/AgentSubagent.swift", worded)
        code, out = tree.check()
        self.assertEqual(code, 1, out)
        self.assertIn("AgentSubagent shows a connection state ('Disconnected')", out)

    def test_a_sidebar_section_that_activates_its_rows_is_an_action(self):
        """A sidebar section whose rows click through `activate(_ id: LayoutItemID)` (Mac HostsSidebar: a
        Connecting row opens the workspace once connected) carries the person's action; a section without it does not."""
        clicked = ("final class HostsSidebar {\n"
                   "    static func caption() -> String { \"Connecting\u2026\" }\n"
                   "    public func activate(_ id: LayoutItemID) -> Bool { true }\n}\n")
        unclicked = ("final class PeersSidebar {\n"
                     "    static func caption() -> String { \"Connecting\u2026\" }\n}\n")
        tree = Tree(self)
        tree.write(f"{MAC}/HostsSidebar.swift", clicked)
        code, out = tree.check()
        self.assertEqual(code, 0, out)
        tree.write(f"{MAC}/PeersSidebar.swift", unclicked)
        code, out = tree.check()
        self.assertEqual(code, 1, out)
        self.assertIn("PeersSidebar shows a connection state", out)

    def test_a_web_list_row_with_a_run_handler_is_an_action(self):
        """A picker row the person clicks through `run:` (the GitHub source row in SourcePicker: "GitHub offline"
        with a Retry row) carries the person's action; a row list without one does not."""
        clicked = ('export function GitHubRows() {\n'
                   '  return [{ id: "github", status: "Offline", run: () => goTo("github") },\n'
                   '          { id: "retry", label: "Retry", run: github.onRetry }];\n}\n')
        unclicked = ('export function GitHubStatus() {\n'
                     '  return [{ id: "github", status: "Offline" }, { id: "resume", run: (agent) => resume(agent) }];\n}\n')
        tree = Tree(self)
        tree.write(f"{WEB}/GitHubRows.tsx", clicked)
        code, out = tree.check()
        self.assertEqual(code, 0, out)
        tree.write(f"{WEB}/GitHubStatus.tsx", unclicked)
        code, out = tree.check()
        self.assertEqual(code, 1, out)
        self.assertIn("GitHubStatus shows a connection state", out)

    def test_a_web_button_component_is_an_action(self):
        """The Connect GitHub card ("GitHub isn't connected for this repo") draws its own `<ConnectButton>` with the
        tap handler inside it (GitHubConnectCard.tsx); the same line with no button component does not pass."""
        button = ('export function ConnectCard() {\n'
                  '  return <div>Reconnecting to GitHub<ConnectButton onConnect={go} /></div>;\n}\n')
        bare = ('export function ConnectLine() {\n'
                '  return <div>Reconnecting to GitHub<ConnectIcon /></div>;\n}\n')
        tree = Tree(self)
        tree.write(f"{WEB}/ConnectCard.tsx", button)
        code, out = tree.check()
        self.assertEqual(code, 0, out)
        tree.write(f"{WEB}/ConnectLine.tsx", bare)
        code, out = tree.check()
        self.assertEqual(code, 1, out)
        self.assertIn("ConnectLine shows a connection state", out)

    def test_a_scheduler_signature_is_not_a_run_action(self):
        """`run: () => void` is a timer's parameter type, not a row the person clicks."""
        tree = Tree(self)
        tree.write(f"{WEB}/Retrying.tsx", ('export function Retrying() {\n'
                                           '  const timeout = (run: () => void, ms: number) => setTimeout(run, ms);\n'
                                           '  return <p>Reconnecting\u2026</p>;\n}\n'))
        code, out = tree.check()
        self.assertEqual(code, 1, out)
        self.assertIn("Retrying shows a connection state", out)

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

    def test_a_tracked_file_missing_on_disk_is_not_judged(self):
        # A review sandbox without some tracked files read 19 listed rows as stale (BLOCK at dec7b89e9efc): their
        # units were only unseen. A tree missing tracked files gets no verdict, not a red.
        tree = self.noisy()
        tree.allow(self.NOTICE)
        tree.commit("base: the notice is listed")
        tree.remove(f"{WEB}/AutoResumeNotice.tsx")
        code, out = tree.check()
        self.assertEqual(code, 2, out)
        self.assertIn("cannot judge this tree", out)
        self.assertNotIn("stale row", out)

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

    def test_a_row_moved_onto_a_new_unit_while_the_old_one_still_offends_fails(self):
        """Review of the first head: removing a.tsx::X's row and adding b.tsx::X for a new unit passed."""
        tree = self.noisy()
        tree.allow(self.NOTICE)
        tree.commit("base")
        tree.write(f"{WEB}/notices/AutoResumeNotice.tsx", NOISY_NOTICE.replace("./retryState", "../retryState"))
        tree.allow(f"{WEB}/notices/AutoResumeNotice.tsx::AutoResumeNotice")
        tree.commit("head: a second unit of the same name takes the row")
        code, out = tree.check(base="HEAD^1")
        self.assertEqual(code, 1, out)
        self.assertIn(f"new row {WEB}/notices/AutoResumeNotice.tsx::AutoResumeNotice", out)
        self.assertIn(f"{WEB}/AutoResumeNotice.tsx:3: AutoResumeNotice shows a connection state", out,
                      "the unit whose row was removed is judged though its file is untouched")

    def test_a_listed_unit_fixed_from_another_file_fails_as_stale(self):
        """Second review: a page's row stayed when only its strings map changed, and a later run paid for it."""
        tree = Tree(self)
        tree.write(f"{PAGE}/strings.ts", PAGE_STRINGS)
        tree.write(f"{PAGE}/EditorPage.tsx", QUIET_PAGE_OLD)
        tree.allow(f"{PAGE}/EditorPage.tsx::EditorPage")
        tree.commit("base")
        tree.write(f"{PAGE}/strings.ts", PAGE_STRINGS.replace('"page.disconnected"', '"page.retry"'))
        tree.commit("head: the map no longer says it")
        code, out = tree.check(base="HEAD^1")
        self.assertEqual(code, 1, out)
        self.assertIn(f"stale row {PAGE}/EditorPage.tsx::EditorPage", out)

    def test_a_unit_fixed_in_place_does_not_free_its_row_for_a_namesake(self):
        """Second review: fixing a.tsx::X where it is let b.tsx::X take its row."""
        tree = self.noisy()
        tree.allow(self.NOTICE)
        tree.commit("base")
        tree.write(f"{WEB}/AutoResumeNotice.tsx", HELD_NOTICE)
        tree.write(f"{WEB}/other/AutoResumeNotice.tsx", NOISY_NOTICE.replace("./retryState", "../retryState"))
        tree.allow(f"{WEB}/other/AutoResumeNotice.tsx::AutoResumeNotice")
        tree.commit("head")
        code, out = tree.check(base="HEAD^1")
        self.assertEqual(code, 1, out)
        self.assertIn(f"new row {WEB}/other/AutoResumeNotice.tsx::AutoResumeNotice", out)

    def test_a_string_table_change_judges_every_unit(self):
        """Review of the first head: a key whose English became "Reconnecting…" was not judged."""
        tree = Tree(self)
        tree.write(f"{PAGE}/strings.ts", PAGE_STRINGS)
        tree.write(f"{PAGE}/EditorPage.tsx", QUIET_PAGE_OLD.replace("L.disconnected", "L.retry"))
        tree.commit("base")
        table = json.loads(json.dumps(STRINGS))
        table["strings"]["page.retry"]["localizations"]["en"]["stringUnit"]["value"] = "Reconnecting…"
        tree.write(f"{WEB}/Localizable.xcstrings", json.dumps(table))
        tree.commit("head: only the table changes")
        code, out = tree.check(base="HEAD^1")
        self.assertEqual(code, 1, out)
        self.assertIn("EditorPage shows a connection state", out)

    def test_an_offender_made_by_a_change_elsewhere_is_judged_with_a_base(self):
        """Third review: deleting a strings type's last gated user in its module spilled its words to a view in
        another module; neither file changed, so --base passed and the next full run failed."""
        kit = "Packages/iOS/Kit/Sources"
        tree = Tree(self)
        tree.write(f"{kit}/ModA/ModAStrings.swift", 'struct ModAStrings {\n    static let offline = "Offline"\n}\n')
        tree.write(f"{kit}/ModA/GatedView.swift",
                   "struct GatedView: View {\n    @State var gate = QuietStatusGate()\n"
                   "    var body: some View { Text(ModAStrings.offline) }\n}\n")
        tree.write(f"{kit}/ModB/OtherView.swift",
                   "struct OtherView: View {\n    var body: some View { Text(ModAStrings.offline) }\n}\n")
        code, out = tree.check()
        self.assertEqual(code, 0, out)
        tree.commit("base")
        tree.remove(f"{kit}/ModA/GatedView.swift")
        tree.commit("head: the gated user goes")
        code, out = tree.check(base="HEAD^1")
        self.assertEqual(code, 1, out)
        self.assertIn("OtherView shows a connection state", out)

    def test_a_new_rows_surface_text_does_not_make_a_move(self):
        """Third review: a row copying a deleted row's surface text took it for a unit on another surface."""
        tree = self.noisy()
        tree.allow(self.NOTICE)
        tree.commit("base")
        tree.remove(f"{WEB}/AutoResumeNotice.tsx")
        tree.write(f"{IOS}/AutoResumeNotice.swift",
                   'struct AutoResumeNotice: View {\n    var body: some View { Text("Reconnecting…") }\n}\n')
        tree.allow(f"{IOS}/AutoResumeNotice.swift::AutoResumeNotice")  # same "web:test" surface text
        tree.commit("head")
        code, out = tree.check(base="HEAD^1")
        self.assertEqual(code, 1, out)
        self.assertIn(f"new row {IOS}/AutoResumeNotice.swift::AutoResumeNotice", out)

    def test_a_base_that_does_not_resolve_refuses(self):
        tree = self.noisy()
        tree.allow(self.NOTICE)
        tree.commit("only commit")
        code, out = tree.check(base="no-such-rev")
        self.assertEqual(code, 2, out)
        self.assertIn("--base no-such-rev does not resolve", out)

    def test_malformed_string_tables_are_skipped(self):
        tree = self.noisy()
        tree.allow(self.NOTICE)
        tree.write(f"{PAGE}/Localizable.xcstrings", "[1, 2]")
        tree.write(f"{IOS}/Localizable.xcstrings",
                   json.dumps({"strings": {"a.b": {"localizations": {"en": {"stringUnit": {"value": 3}}}}}}))
        tree.write(f"{MAC}/Localizable.xcstrings", "{not json")
        code, out = tree.check()
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


class InputBlockedWhileConnecting(unittest.TestCase):
    """--input-block: Leo, 2026-11-24, back in the iOS app after minutes away: "the entire thing is somehow grayed out
    and I can't interact with anything at all". Each place input is taken away or a view grayed out on a link
    condition is reported; a show-or-hide toggle, an account's connect button and a callback named onConnect are
    not. A report: it exits 0 whatever it finds."""

    def found(self, tree: Tree) -> list[tuple[str, str, str]]:
        return [(f.surface, f.unit, f.kind) for f in ccn.input_blocks(ccn.Tree(tree.root))]

    def test_ios_controls_disabled_or_dimmed_on_the_link(self):
        tree = Tree(self)
        tree.write(f"{IOS}/TerminalPage.swift", """\
            struct TerminalPage: View {
                var body: some View {
                    VStack {
                        Composer().disabled(!model.connectionState.isAttached)
                        Grid().opacity(link == .reconnecting ? 0.45 : 1)
                        Rows().allowsHitTesting(hub.isReady)
                        Chip().opacity(shown ? 1 : 0)
                        Send().disabled(text.isEmpty)
                    }
                }
            }
        """)
        self.assertEqual(self.found(tree), [("ios", "TerminalPage", "disabled"), ("ios", "TerminalPage", "opacity"),
                                            ("ios", "TerminalPage", "allowsHitTesting")])

    def test_a_derived_flag_and_a_labelled_argument(self):
        tree = Tree(self)
        tree.write(f"{IOS}/TabActions.swift", """\
            final class TabActions {
                var inputBlocked: Bool { linkState != .live }
                let model = TerminalModel(connection: connection)
                func actions() -> [Action] {
                    [Action(title: "Send Text", isEnabled: !inputBlocked),
                     Action(title: "Clear", isEnabled: model.canClear),
                     Action(title: "Paste", isEnabled: model.connectionState.isAttached)]
                }
            }
        """)
        self.assertEqual(self.found(tree), [("ios", "TabActions", "isEnabled"), ("ios", "TabActions", "isEnabled")])

    def test_web_disabled_while_disconnected_but_not_an_account_connect(self):
        tree = Tree(self)
        tree.write(f"{WEB}/KeysPage.tsx", """\
            export function KeysPage({ snap, github, onConnect }: Props) {
              const disconnected = snap.connection === "disconnected";
              return (
                <div>
                  <button disabled={disconnected}>Save</button>
                  <button disabled={state.connection !== "live"}>Attach</button>
                  <button disabled={!github.canConnect}>Connect GitHub</button>
                  <button disabled={!onConnect}>Pick</button>
                </div>
              );
            }
        """)
        self.assertEqual(self.found(tree), [("web", "KeysPage", "disabled"), ("web", "KeysPage", "disabled")])

    def test_the_report_exits_zero(self):
        tree = Tree(self)
        tree.write(f"{IOS}/Page.swift", "struct Page: View { var body: some View { Text(\"x\").disabled(offline) } }\n")
        out = io.StringIO()
        self.assertEqual(ccn.report_input_blocks(tree.root, out=out), 0)
        self.assertIn("input blocked while connecting: 1 place(s) (ios 1)", out.getvalue())
        out = io.StringIO()
        self.assertEqual(ccn.report_input_blocks(tree.root, as_json=True, out=out), 0)
        self.assertEqual(json.loads(out.getvalue())["findings"][0]["unit"], "Page")


if __name__ == "__main__":
    unittest.main()
