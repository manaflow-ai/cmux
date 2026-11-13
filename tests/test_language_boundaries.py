#!/usr/bin/env python3
"""The language-boundaries check keeps each area in its language and fails #37777's diff without Leo's approval."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "language_boundaries.py"
MANIFEST = ROOT / ".github" / "language-boundaries.toml"
WORKFLOW = ROOT / ".github" / "workflows" / "language-boundaries.yml"
FIXTURE = ROOT / "tests" / "fixtures" / "language-boundaries" / "pr-37777-name-status.tsv"

spec = importlib.util.spec_from_file_location("language_boundaries", SCRIPT)
assert spec and spec.loader
lb = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = lb
spec.loader.exec_module(lb)

AREAS = lb.load(MANIFEST)
PORT = lb.load_react_port(MANIFEST)
HOME = "Packages/macOS/CmuxNext/Sources/CmuxNextHome"
CLOUD = "Packages/macOS/CmuxNext/Sources/CmuxNextCloud"
PANE = "webviews/src/agent-session"
ACPMUX = "cmux-tui/crates/acpmux/src"

LABEL_EVENT = {"event": "labeled", "label": "leo-approved-port", "actor": "teamleaderleo", "type": "User",
               "app": None}
LEO_NOTE = {"user": "teamleaderleo", "type": "User", "body": "leo-approved-port: yes, move the transcript to React",
            "app": None, "source": "comment"}


def cli(args: list[str]) -> int:
    with contextlib.redirect_stdout(io.StringIO()):
        return lb.main(args)


def records(text: str) -> list:
    return lb.parse_records(text)


def run(text: str, labels=(), events=(), notes=()) -> tuple[int, list[str]]:
    return lb.check(AREAS, records(text), list(labels), list(events), list(notes), port=PORT)


class ManifestTests(unittest.TestCase):
    def test_manifest_names_every_area_leo_asked_for(self) -> None:
        by_name = {a.name: a for a in AREAS}
        self.assertEqual(by_name["imessage-home"].language, "swift")
        self.assertEqual(by_name["chief-transcript-panel-and-conversation-tabs"].language, "swift")
        self.assertEqual(by_name["chat-ui"].language, "web")
        self.assertEqual(by_name["acpmux"].language, "rust")
        self.assertEqual(by_name["cmux-tui"].language, "rust")
        self.assertEqual(by_name["cloud-core-rust"].language, "rust")
        self.assertEqual(by_name["cloud-core-swift-minimal"].policy, "minimal")

    def test_every_area_glob_matches_a_file_in_the_tree_or_a_file_37777_deleted(self) -> None:
        tracked = [str(p.relative_to(ROOT)) for p in (ROOT / "Packages").rglob("*") if p.is_file()]
        tracked += [str(p.relative_to(ROOT)) for d in ("webviews/src", "cmux-tui/crates")
                    for p in (ROOT / d).rglob("*.*") if p.is_file() and "node_modules" not in p.parts]
        tracked += [r.old or r.path for r in records(FIXTURE.read_text())]
        for area in AREAS:
            for glob, rx in zip(area.paths, area.regexes):
                if glob in {"Packages/macOS/CmuxNext/Sources/CmuxNextApp/TopPages/TopHomePageView*.swift",
                            "Packages/macOS/CmuxNext/Sources/CmuxNextAgentLanes/HomeFilterPlaygroundSection.swift",
                            "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Control/CaptureSceneRegistry+Home*.swift"}:
                    continue  # deleted by #37736, which Lawrence is reverting
                self.assertTrue(any(rx.match(p) for p in tracked), f"{area.name}: {glob} matches nothing")

    def test_malformed_manifest_raises(self) -> None:
        good = '[[area]]\nname = "a"\nlanguage = "swift"\npolicy = "keep"\npaths = ["x/**"]\n'
        self.assertEqual(len(lb.parse(good)), 1)
        for bad in (good.replace('"swift"', '"kotlin"'), good.replace('"keep"', '"frozen"'),
                    good.replace('paths = ["x/**"]', "paths = []"), good.replace('name = "a"\n', ""),
                    good + 'extra = 1\n', "", good + good):
            with self.assertRaises(ValueError, msg=bad):
                lb.parse(bad)


class PR37777Tests(unittest.TestCase):
    """#37777 deleted the native Swift Chief transcript and HomeHostView for the React Messages page."""

    def test_37777_fails(self) -> None:
        code, lines = run(FIXTURE.read_text())
        self.assertEqual(code, 1)
        text = "\n".join(lines)
        self.assertIn("imessage-home: loses", text)
        self.assertIn("chief-transcript-panel-and-conversation-tabs: loses", text)
        self.assertIn("HomeHostView.swift", text)
        self.assertIn("leo-approved-port", lines[-2])
        self.assertTrue(lines[-1].startswith("next: "))

    def test_37777_fails_with_the_label_from_an_agent_footer_comment(self) -> None:
        agent = {"user": "teamleaderleo", "type": "User", "app": None, "source": "comment",
                 "body": "leo-approved-port: ported\n\n"
                 "Agent session: [agent session](https://cmux.com/deeplink/agent?id=aid-1)"}
        code, lines = run(FIXTURE.read_text(), ["leo-approved-port"], [LABEL_EVENT], [agent])
        self.assertEqual(code, 1)
        self.assertIn("no comment by", lines[-2])

    def test_37777_passes_with_leos_approval_and_react_port_ok(self) -> None:
        # #37777 is a Swift-to-React port too: Leo's leo-approved-port opens the keep areas, react-port-ok the port.
        code, lines = run(FIXTURE.read_text(), ["leo-approved-port"], [LABEL_EVENT], [LEO_NOTE])
        self.assertEqual(code, 1)
        self.assertIn("Refused a Swift-to-React port", lines[0])
        code, lines = run(FIXTURE.read_text(), ["leo-approved-port", "react-port-ok"],
                          [LABEL_EVENT, PORT_EVENT], [LEO_NOTE])
        self.assertEqual(code, 0)
        self.assertIn("React port approved", lines[0])
        self.assertTrue(all("Leo approved" in line for line in lines[1:]))


class KeepTests(unittest.TestCase):
    def test_modifying_files_passes(self) -> None:
        self.assertEqual(run(f"M\t{HOME}/A.swift\nM\t{PANE}/x.tsx\nM\t{ACPMUX}/lib.rs\n")[0], 0)

    def test_deleting_a_swift_home_file_fails(self) -> None:
        code, lines = run(f"D\t{HOME}/Messages/HomeComposerIntake.swift\n")
        self.assertEqual(code, 1)
        self.assertIn("imessage-home: loses 1 swift", lines[0])

    def test_copying_a_foreign_file_into_a_swift_area_fails(self) -> None:
        self.assertEqual(run(f"C100\twebviews/src/x.tsx\t{HOME}/x.tsx\n")[0], 1)

    def test_split_or_rename_within_the_area_passes(self) -> None:
        self.assertEqual(run(f"R090\t{HOME}/A.swift\t{HOME}/Sub/A.swift\n")[0], 0)
        self.assertEqual(run(f"D\t{HOME}/Big.swift\nA\t{HOME}/Big+One.swift\n")[0], 0)

    def test_renaming_out_of_the_area_fails(self) -> None:
        code, lines = run(f"R100\t{HOME}/A.swift\tPackages/macOS/CmuxNext/Sources/CmuxNextPages/A.swift\n")
        self.assertEqual(code, 1)
        self.assertIn("->", lines[0])

    def test_rest_status_format_is_read_the_same(self) -> None:
        self.assertEqual(run(f"removed\t{HOME}/A.swift\n")[0], 1)
        self.assertEqual(run(f"renamed\t{HOME}/Sub/A.swift\t{HOME}/A.swift\n")[0], 0)
        self.assertEqual(run(f"added\t{HOME}/page.tsx\n")[0], 1)

    def test_foreign_language_added_to_a_swift_area_fails(self) -> None:
        for path in (f"{HOME}/page.tsx", f"{HOME}/styles.css", f"{HOME}/core.rs"):
            code, lines = run(f"A\t{path}\n")
            self.assertEqual(code, 1, path)
            self.assertIn("in a swift area", lines[0])

    def test_renaming_swift_to_typescript_fails_twice(self) -> None:
        code, lines = run(f"R050\t{HOME}/A.swift\t{HOME}/A.ts\n")
        self.assertEqual(code, 1)
        self.assertTrue(any("loses 1 swift" in line for line in lines))
        self.assertTrue(any("adds" in line and "A.ts" in line for line in lines))

    def test_non_code_files_never_count(self) -> None:
        self.assertEqual(run(f"D\t{HOME}/Localizable.xcstrings\nA\t{HOME}/notes.md\nA\t{PANE}/data.json\n")[0], 0)

    def test_swift_in_the_chat_ui_fails(self) -> None:
        code, lines = run(f"A\t{PANE}/Pane.swift\n")
        self.assertEqual(code, 1)
        self.assertIn("chat-ui", lines[0])

    def test_deleting_react_chat_ui_fails(self) -> None:
        self.assertEqual(run(f"D\t{PANE}/acpmux/toastAvoidance.ts\n")[0], 1)

    def test_rust_areas_refuse_swift_but_not_their_typescript_runtimes(self) -> None:
        self.assertEqual(run(f"A\t{ACPMUX}/bridge.swift\n")[0], 1)
        self.assertEqual(run("A\tcmux-tui/crates/cmux-tui-hooks/assets/agent-hooks/x.ts\n")[0], 0)
        self.assertEqual(run(f"D\t{ACPMUX}/old.rs\n")[0], 1)
        self.assertEqual(run("D\tcmux-tui/crates/cmux-cloud-wire/src/a.rs\n")[0], 1)

    def test_paths_outside_every_area_pass(self) -> None:
        self.assertEqual(run("D\tPackages/macOS/CmuxNext/Sources/CmuxNextPages/X.swift\nA\twebviews/src/x.swift\n")[0], 0)


class SelfTests(unittest.TestCase):
    def test_changing_the_check_needs_leos_approval(self) -> None:
        for path in lb.SELF_PATHS:
            code, lines = run(f"M\t{path}\n")
            self.assertEqual(code, 1, path)
            self.assertIn("check itself", lines[0])
            self.assertEqual(run(f"M\t{path}\n", ["leo-approved-port"], [LABEL_EVENT], [LEO_NOTE])[0], 0)


class MinimalTests(unittest.TestCase):
    def test_new_swift_in_cloud_core_fails(self) -> None:
        code, lines = run(f"A\t{CLOUD}/CloudNewThing.swift\n")
        self.assertEqual(code, 1)
        self.assertIn("cloud-core-swift-minimal: adds Swift file", lines[0])

    def test_changing_or_deleting_cloud_swift_passes(self) -> None:
        self.assertEqual(run(f"M\t{CLOUD}/CloudAPIClient.swift\nD\t{CLOUD}/Old.swift\n")[0], 0)
        self.assertEqual(run(f"R100\t{CLOUD}/A.swift\t{CLOUD}/Sub/A.swift\n")[0], 0)

    def test_quoted_and_tab_paths_are_caught(self) -> None:
        # git quotes a path with a quote, tab, newline or backslash; -z and REST JSON carry it as it is.
        for name in ('Cloud"New.swift', "Cloud\tNew.swift", "Cloud\nNew.swift", "Cloud\\New.swift"):
            path = f"{HOME}/{name}"
            z = lb.parse_records_z(f"D\0{path}\0".encode())
            self.assertEqual(z, [lb.Record("removed", path)])
            self.assertEqual(lb.check(AREAS, z, [], [], [])[0], 1, name)
            js = lb.parse_records_json(json.dumps({"status": "removed", "path": path, "old": ""}) + "\n")
            self.assertEqual(lb.check(AREAS, js, [], [], [])[0], 1, name)
            added = lb.parse_records_z(f"A\0{CLOUD}/{name}\0".encode())
            self.assertEqual(lb.check(AREAS, added, [], [], [])[0], 1, name)
        moved = lb.parse_records_z(f"R100\0{HOME}/A\tB.swift\0Packages/Elsewhere/A\tB.swift\0M\0x.md\0".encode())
        self.assertEqual([r.status for r in moved], ["renamed", "modified"])
        self.assertEqual(lb.check(AREAS, moved, [], [], [])[0], 1)

    def test_tsv_refuses_a_git_quoted_path(self) -> None:
        with self.assertRaises(ValueError):
            records(f'D\t"{HOME}/Cloud\\"New.swift"\n')
        with self.assertRaises(ValueError):
            records(f'R100\t"{HOME}/A\\tB.swift"\tPackages/Elsewhere/AB.swift\n')

    def test_z_and_json_fail_closed_on_bad_input(self) -> None:
        for data in (b"D\0", b"R100\0only-old\0", b"X\0path\0", b"removed\0path\0"):
            with self.assertRaises(ValueError, msg=data):
                lb.parse_records_z(data)
        for line in ('{"status": "gone", "path": "a"}', '{"status": "renamed", "path": "a", "old": ""}', "[1]"):
            with self.assertRaises(ValueError, msg=line):
                lb.parse_records_json(line)

    def test_non_ascii_paths_are_matched(self) -> None:
        self.assertEqual(run(f"D\t{HOME}/Ünïcode.swift\n")[0], 1)

    def test_swift_moved_or_copied_into_cloud_core_fails(self) -> None:
        self.assertEqual(run(f"R100\tPackages/macOS/CmuxNext/Sources/CmuxNextApp/A.swift\t{CLOUD}/A.swift\n")[0], 1)
        self.assertEqual(run(f"C100\tPackages/macOS/CmuxNext/Sources/CmuxNextApp/A.swift\t{CLOUD}/A.swift\n")[0], 1)
        self.assertEqual(run(f"R050\t{CLOUD}/a.txt\t{CLOUD}/A.swift\n")[0], 1)


class ApprovalTests(unittest.TestCase):
    BAD = f"D\t{HOME}/A.swift\n"

    def test_label_alone_is_not_enough(self) -> None:
        code, lines = run(self.BAD, ["leo-approved-port"], [LABEL_EVENT], [])
        self.assertEqual(code, 1)

    def test_label_added_by_someone_else_fails(self) -> None:
        other = dict(LABEL_EVENT, actor="lawrencecchen")
        code, lines = run(self.BAD, ["leo-approved-port"], [other], [LEO_NOTE])
        self.assertEqual(code, 1)
        self.assertIn("'lawrencecchen'", lines[-2])

    def test_label_added_through_an_app_fails(self) -> None:
        code, _ = run(self.BAD, ["leo-approved-port"], [dict(LABEL_EVENT, app="cmux-bot")], [LEO_NOTE])
        self.assertEqual(code, 1)

    def test_the_latest_labeled_event_decides(self) -> None:
        events = [LABEL_EVENT, {"event": "unlabeled", "label": "leo-approved-port", "actor": "teamleaderleo"},
                  dict(LABEL_EVENT, actor="some-bot")]
        self.assertEqual(run(self.BAD, ["leo-approved-port"], events, [LEO_NOTE])[0], 1)

    def test_events_without_the_label_on_the_pr_fail(self) -> None:
        self.assertEqual(run(self.BAD, [], [LABEL_EVENT], [LEO_NOTE])[0], 1)

    def test_approval_line_from_another_user_or_quoted_or_empty_fails(self) -> None:
        for note in (dict(LEO_NOTE, user="lawrencecchen"), dict(LEO_NOTE, body="> leo-approved-port: yes"),
                     dict(LEO_NOTE, body="leo-approved-port:"), dict(LEO_NOTE, app="some-app"),
                     dict(LEO_NOTE, body=LEO_NOTE["body"] + "\n\n\U0001f916 Generated with [Claude Code](x)"),
                     dict(LEO_NOTE, body=LEO_NOTE["body"] + "\n\nCo-authored-by: Claude <noreply@anthropic.com>")):
            self.assertEqual(run(self.BAD, ["leo-approved-port"], [LABEL_EVENT], [note])[0], 1, note)

    def test_approval_in_a_review_never_passes(self) -> None:
        # GitHub reports no app for a review, so a review an app submitted on Leo's behalf looks like his own.
        review = dict(LEO_NOTE, body="Looks right.\nleo-approved-port: the port is mine", source="review")
        code, lines = run(self.BAD, ["leo-approved-port"], [LABEL_EVENT], [review])
        self.assertEqual(code, 1)
        self.assertIn("a review never counts", lines[-2])
        self.assertEqual(run(self.BAD, ["leo-approved-port"], [LABEL_EVENT], [review, LEO_NOTE])[0], 0)

    def test_app_or_bot_submitted_approval_fails(self) -> None:
        for note in (dict(LEO_NOTE, app="cmux-agent"), dict(LEO_NOTE, type="Bot"), dict(LEO_NOTE, type=None),
                     dict(LEO_NOTE, user="teamleaderleo[bot]"), dict(LEO_NOTE, app="cmux-agent", source="review")):
            self.assertEqual(run(self.BAD, ["leo-approved-port"], [LABEL_EVENT], [note])[0], 1, note)

    def test_label_added_by_a_bot_typed_actor_fails(self) -> None:
        for event in (dict(LABEL_EVENT, type="Bot"), {k: v for k, v in LABEL_EVENT.items() if k != "type"}):
            code, lines = run(self.BAD, ["leo-approved-port"], [event], [LEO_NOTE])
            self.assertEqual(code, 1, event)
            self.assertIn("as a bot", lines[-2])


PORT_EVENT = {"event": "labeled", "label": "react-port-ok", "actor": "lawrencecchen", "type": "User", "app": None}
PAGES = "Packages/macOS/CmuxNext/Sources/CmuxNextPages"
SWIFT_TO_TSX = f"D\t{PAGES}/SettingsPage.swift\nA\twebviews/src/settings/SettingsPage.tsx\n"


class ReactPortTests(unittest.TestCase):
    """Lawrence, relayed by Leo (2026-11-11): "also let's not move stuff to react anymore unless we talk about it /
    swift->rust is usually fine though"."""

    def test_manifest_names_the_label_and_who_adds_it(self) -> None:
        self.assertEqual(PORT.label, "react-port-ok")
        self.assertEqual(PORT.approvers, ["lawrencecchen", "teamleaderleo"])
        self.assertTrue(PORT.covers("webviews/src/x.tsx"))

    def test_swift_to_tsx_outside_every_area_is_refused(self) -> None:
        code, lines = run(SWIFT_TO_TSX)
        self.assertEqual(code, 1)
        self.assertIn("Refused a Swift-to-React port", lines[0])
        self.assertIn("SettingsPage.swift", lines[0])
        self.assertIn("Talk to Lawrence or Leo, then they add react-port-ok", lines[0])
        self.assertIn("swift->rust is usually fine though", lines[1])
        self.assertTrue(lines[-1].startswith("next: "))

    def test_rename_from_swift_to_tsx_is_refused(self) -> None:
        self.assertEqual(run(f"R050\t{PAGES}/A.swift\twebviews/src/a/A.tsx\n")[0], 1)

    def test_label_added_by_lawrence_or_leo_passes(self) -> None:
        for who in ("lawrencecchen", "teamleaderleo"):
            code, lines = run(SWIFT_TO_TSX, ["react-port-ok"], [dict(PORT_EVENT, actor=who)])
            self.assertEqual(code, 0, who)
            self.assertIn(f"{who} added `react-port-ok`", lines[0])

    def test_label_added_by_a_bot_or_agent_account_does_not_count(self) -> None:
        for event in (dict(PORT_EVENT, actor="cmux-bot", type="Bot"),
                      dict(PORT_EVENT, actor="manaflow-cmux-ffi-release[bot]", type="User"),
                      dict(PORT_EVENT, app="manaflow-glaeda-route"),
                      dict(PORT_EVENT, actor="teamleaderleo", app="cmux-agent"),
                      dict(PORT_EVENT, actor="austinywang"),
                      {k: v for k, v in PORT_EVENT.items() if k != "type"}):
            self.assertEqual(run(SWIFT_TO_TSX, ["react-port-ok"], [event])[0], 1, event)

    def test_the_latest_labeled_event_decides_and_the_label_must_be_on(self) -> None:
        events = [PORT_EVENT, dict(PORT_EVENT, actor="cmux-bot", type="Bot")]
        self.assertEqual(run(SWIFT_TO_TSX, ["react-port-ok"], events)[0], 1)
        self.assertEqual(run(SWIFT_TO_TSX, [], [PORT_EVENT])[0], 1)

    def test_leo_approved_port_alone_does_not_open_a_react_port(self) -> None:
        self.assertEqual(run(SWIFT_TO_TSX, ["leo-approved-port"], [LABEL_EVENT], [LEO_NOTE])[0], 1)

    def test_swift_to_rust_passes(self) -> None:
        self.assertEqual(run(f"D\t{PAGES}/Sync.swift\nA\tcmux-tui/crates/cmux-sync/src/lib.rs\n")[0], 0)
        self.assertEqual(run(f"R070\t{PAGES}/Sync.swift\tcmux-tui/crates/cmux-sync/src/sync.rs\n")[0], 0)
        # A Rust crate's TypeScript runtime is not React: only the web globs count.
        self.assertEqual(run(f"D\t{PAGES}/Hooks.swift\nA\tcmux-tui/crates/cmux-tui-hooks/assets/x.ts\n")[0], 0)

    def test_new_web_code_that_keeps_swift_passes(self) -> None:
        self.assertEqual(run("A\twebviews/src/settings/New.tsx\n")[0], 0)
        self.assertEqual(run(f"M\t{PAGES}/A.swift\nA\twebviews/src/settings/New.tsx\n")[0], 0)
        # A Swift split (one deleted, two added) loses no Swift on net.
        self.assertEqual(run(f"D\t{PAGES}/A.swift\nA\t{PAGES}/A1.swift\nA\twebviews/src/x.tsx\n")[0], 0)
        # Moving web code around inside the webviews is not a port.
        self.assertEqual(run(f"D\t{PAGES}/A.swift\nR100\twebviews/src/a.tsx\twebviews/src/b/a.tsx\n")[0], 0)

    def test_deleting_swift_alone_passes(self) -> None:
        self.assertEqual(run(f"D\t{PAGES}/Dead.swift\nM\twebviews/src/x.tsx\n")[0], 0)

    def test_malformed_react_port_table_raises(self) -> None:
        area = '[[area]]\nname = "a"\nlanguage = "swift"\npolicy = "keep"\npaths = ["x/**"]\n'
        port = '[[react_port]]\nlabel = "react-port-ok"\napprovers = ["a"]\nweb = ["w/**"]\n'
        self.assertEqual(lb.parse_react_port(area + port).label, "react-port-ok")
        self.assertIsNone(lb.parse_react_port(area))
        for bad in (port.replace('approvers = ["a"]', "approvers = []"), port + "extra = 1\n", port + port,
                    port.replace('label = "react-port-ok"\n', "")):
            with self.assertRaises(ValueError, msg=bad):
                lb.parse(area + bad)


class CliAndWorkflowTests(unittest.TestCase):
    def test_cli_reads_files_events_and_notes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            files, events, notes = (Path(tmp) / n for n in ("f.tsv", "e.jsonl", "n.jsonl"))
            files.write_text(f"removed\t{HOME}/A.swift\t\n")
            events.write_text(json.dumps(LABEL_EVENT) + "\n")
            notes.write_text(json.dumps(LEO_NOTE) + "\n")
            args = ["--files", str(files), "--manifest", str(MANIFEST)]
            self.assertEqual(cli(args), 1)
            approved = args + ["--labels-json", '["leo-approved-port"]', "--events", str(events),
                               "--notes", str(notes)]
            self.assertEqual(cli(approved), 0)
            self.assertEqual(cli(args + ["--expected-files", "2"]), 1)
            quoted = f'{HOME}/Cloud"New.swift'
            zfile, jfile = Path(tmp) / "f.z", Path(tmp) / "f.jsonl"
            zfile.write_bytes(f"D\0{quoted}\0".encode())
            jfile.write_text(json.dumps({"status": "removed", "path": quoted, "old": ""}) + "\n")
            self.assertEqual(cli(["--files", str(zfile), "--format", "git-z", "--manifest", str(MANIFEST)]), 1)
            self.assertEqual(cli(["--files", str(jfile), "--format", "json", "--manifest", str(MANIFEST)]), 1)
            zfile.write_bytes(f"M\0{quoted}\0".encode())
            self.assertEqual(cli(["--files", str(zfile), "--format", "git-z", "--manifest", str(MANIFEST)]), 0)
            files.write_text(SWIFT_TO_TSX)
            self.assertEqual(cli(args), 1)
            events.write_text(json.dumps(PORT_EVENT) + "\n")
            self.assertEqual(cli(args + ["--labels-json", '["react-port-ok"]', "--events", str(events)]), 0)

    def test_cli_fails_closed_on_bad_input(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            files = Path(tmp) / "f.tsv"
            files.write_text("X\tsomething\n")
            self.assertEqual(cli(["--files", str(files), "--manifest", str(MANIFEST)]), 3)
            files.write_text(f"M\t{HOME}/A.swift\n")
            broken = Path(tmp) / "m.toml"
            broken.write_text("[[area]]\nname = 1\n")
            self.assertEqual(cli(["--files", str(files), "--manifest", str(broken)]), 3)

    def test_workflow_runs_the_base_copy_with_a_stable_check_name(self) -> None:
        text = WORKFLOW.read_text()
        self.assertIn("pull_request_target:", text)
        self.assertIn("branches: [main, feat-cmux-next]", text)
        self.assertIn("labeled, unlabeled", text)
        self.assertIn("ref: ${{ github.event.pull_request.base.sha }}", text)
        self.assertIn("    name: language-boundaries\n", text)
        self.assertIn("scripts/ci/language_boundaries.py", text)
        self.assertIn(".github/language-boundaries.toml", text)
        self.assertNotIn("github.event.pull_request.head.sha }}\n          fetch-depth", text)
        # The script reads one JSON object per line; gh's --jq would print an object across many lines.
        self.assertEqual(text.count("| tojson'"), 4)
        # Both listings carry every path byte for byte: REST as JSON, the git fallback NUL-separated.
        self.assertIn("git diff -z --name-status -M", text)
        self.assertIn("path: .filename, old: (.previous_filename // \"\")} | tojson'", text)
        self.assertNotIn("@tsv", text)
        self.assertIn('--format "$format"', text)
        # Every author's type and app are read, and reviews are marked so they never approve.
        self.assertIn("type: (.actor.type // null)", text)
        self.assertEqual(text.count("type: (.user.type // null)"), 2)
        self.assertIn('source: "review"', text)
        self.assertNotIn("app: null", text)
        # react-port-ok reads who added it too.
        self.assertIn("leo-approved-port|react-port-ok", text)


if __name__ == "__main__":
    unittest.main()
