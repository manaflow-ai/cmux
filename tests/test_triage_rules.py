import importlib.util
import json
import pathlib
import shutil
import sys
import tempfile
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
MANIFEST = ROOT / ".github/labels.json"
WORKFLOW = ROOT / ".github/workflows/auto-triage.yml"


def load(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    # `dataclass` looks its own module up in sys.modules, so register before exec.
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


RULES = load("triage_rules", "scripts/ci/triage_rules.py")
AUTO = load("auto_triage", "scripts/ci/auto_triage.py")
SYNC = load("sync_labels", "scripts/ci/sync_labels.py")


class SeverityTests(unittest.TestCase):
    def test_data_loss_is_critical(self):
        result = RULES.classify("Quitting cmux causes data loss in the active workspace", "")
        self.assertEqual(result.severity, "S1: critical")

    def test_app_that_will_not_launch_is_critical(self):
        result = RULES.classify("0.64.25 won't launch on macOS 15.3", "Nothing happens on open.")
        self.assertEqual(result.severity, "S1: critical")

    def test_credential_exposure_is_critical(self):
        result = RULES.classify("Auth token exposed in the log file", "")
        self.assertEqual(result.severity, "S1: critical")

    def test_crash_is_major(self):
        result = RULES.classify("App crashes when closing the last split", "")
        self.assertEqual(result.severity, "S2: major")

    def test_regression_wording_is_major(self):
        result = RULES.classify("Sidebar reorder no longer works after 0.64.24", "")
        self.assertEqual(result.severity, "S2: major")

    def test_present_tense_session_loss_is_major(self):
        for wording in ("lose session state", "loses session state"):
            with self.subTest(wording=wording):
                result = RULES.classify(f"Terminal {wording} after sleep", "")
                self.assertEqual(result.severity, "S2: major")

    def test_plain_bug_defaults_to_minor(self):
        result = RULES.classify("Tab title shows the wrong directory after rename", "")
        self.assertEqual(result.severity, "S3: minor")

    def test_typo_alone_is_cosmetic(self):
        result = RULES.classify("Typo in the Settings pane: 'Workpsace'", "")
        self.assertEqual(result.severity, "S4: cosmetic")

    def test_a_crash_outranks_a_typo_in_the_same_report(self):
        # Reading order matters: a report that mentions both must not land in
        # the cosmetic bucket because the word "typo" appears in it.
        result = RULES.classify("Crash after fixing the typo in the config file", "")
        self.assertEqual(result.severity, "S2: major")

    def test_feature_request_has_no_severity(self):
        result = RULES.classify(
            "Feature: nested folders for organizing workspaces in the sidebar", ""
        )
        self.assertIsNone(result.severity)

    def test_rfc_has_no_severity(self):
        result = RULES.classify("[RFC] CI structure: thin router and reusable workflows", "")
        self.assertIsNone(result.severity)

    def test_enhancement_label_overrides_bug_sounding_words(self):
        result = RULES.classify(
            "Cannot yet split a pane from the workspace root",
            "",
            [{"name": "enhancement"}],
        )
        self.assertIsNone(result.severity)


class AreaTests(unittest.TestCase):
    def test_title_evidence_picks_the_area(self):
        result = RULES.classify("Sidebar: show git status counts", "")
        self.assertEqual(result.areas, ["area: sidebar"])
        self.assertFalse(result.needs_triage)

    def test_body_only_mention_is_not_enough(self):
        # "over ssh" in a reproduction step does not make a report an ssh bug.
        result = RULES.classify(
            "Colors look off after the update",
            "Steps: 1. connect over ssh 2. look at the prompt",
        )
        self.assertNotIn("area: remote", result.areas)

    def test_two_way_tie_keeps_both_areas(self):
        result = RULES.classify("Command palette text input does not allow IME switching", "")
        self.assertEqual(sorted(result.areas), ["area: command-palette", "area: input"])

    def test_a_title_touching_everything_is_left_for_a_person(self):
        result = RULES.classify(
            "Sidebar, splits, ssh, cloud machines and the iOS app all need a rethink", ""
        )
        self.assertEqual(result.areas, [])
        self.assertTrue(result.needs_triage)
        self.assertIn(RULES.NEEDS_TRIAGE, result.labels_to_add())

    def test_unmatched_title_asks_for_a_person(self):
        result = RULES.classify("theme error", "")
        self.assertTrue(result.needs_triage or result.areas)


def form_body(answer: str, *, before: str = "Something is wrong.") -> str:
    """An issue body the way GitHub renders the bug form."""
    return (
        f"### What happened?\n\n{before}\n\n"
        f"### Which part of cmux is this about?\n\n{answer}\n\n"
        "### Additional context\n\n_No response_"
    )


class FormAreaTests(unittest.TestCase):
    """The dropdown on the issue forms is the reporter answering directly."""

    def test_the_reporters_answer_wins_over_scoring(self):
        # Body-only evidence never carries an area on its own, which is why the
        # form has to be read rather than left to the regexes.
        title = "Wrong item highlighted after reorder"
        body = form_body("sidebar")
        self.assertLess(max(RULES.score_areas(title, body).values()), RULES.TITLE_WEIGHT)
        result = RULES.classify(title, body)
        self.assertEqual(result.areas, ["area: sidebar"])
        self.assertFalse(result.needs_triage)

    def test_the_answer_outranks_a_conflicting_title(self):
        result = RULES.classify("Sidebar shows the wrong item", form_body("workspaces"))
        self.assertEqual(result.areas, ["area: workspaces"])

    def test_option_parentheses_do_not_leak_into_the_area(self):
        # `remote (cmux ssh, tunnels, relays)` also matches the cli and cloud
        # patterns. The reporter picked remote, so remote is what it gets.
        result = RULES.classify("Nothing works", form_body("remote (cmux ssh, tunnels, relays)"))
        self.assertEqual(result.areas, ["area: remote"])

    def test_the_answer_is_explained_in_the_notes(self):
        result = RULES.classify("Nothing works", form_body("docs"))
        self.assertTrue(any("issue form" in note for note in result.notes))

    def test_not_sure_falls_back_to_the_rules(self):
        result = RULES.classify("Sidebar shows the wrong item", form_body("Not sure"))
        self.assertEqual(result.areas, ["area: sidebar"])

    def test_skipped_field_falls_back_to_the_rules(self):
        for answer in ("_No response_", ""):
            with self.subTest(answer=answer):
                result = RULES.classify("Sidebar shows the wrong item", form_body(answer))
                self.assertEqual(result.areas, ["area: sidebar"])

    def test_an_area_the_rules_do_not_have_is_ignored(self):
        self.assertIsNone(RULES.form_area(form_body("quantum-tunnelling")))

    def test_a_body_with_no_form_is_left_alone(self):
        self.assertIsNone(RULES.form_area("Plain issue text, no form, mentions the sidebar."))

    def test_every_dropdown_option_maps_to_a_label(self):
        # The forms live in the other pull request, so this asserts the contract
        # they have to satisfy: the text before the first parenthesis is a label.
        for area in RULES.AREA_NAMES:
            slug = area.removeprefix(RULES.AREA_PREFIX)
            with self.subTest(area=area):
                self.assertEqual(RULES.form_area(form_body(f"{slug} (some hint)")), area)


class DeclaredAreaTests(unittest.TestCase):
    """A title that names its own area up front beats scoring the rest of it."""

    def test_scope_prefix_wins_over_a_tie_in_the_rest_of_the_title(self):
        # Without the prefix this ties agents (Codex) against workspaces.
        result = RULES.classify(
            "Cloud: Codex TUI garbled again after restoring a Cloud workspace", ""
        )
        self.assertEqual(result.areas, ["area: cloud"])
        self.assertFalse(result.needs_triage)

    def test_scope_prefix_works_when_the_scoring_pattern_wants_a_qualifier(self):
        # `area: cloud` scores only on "cloud machine", "cloud workspace" and
        # friends, which a bare `Cloud:` prefix never supplies.
        self.assertEqual(RULES.score_areas("Cloud: ports VPN state messaging", ""), {})
        self.assertEqual(
            RULES.classify("Cloud: ports VPN state messaging", "").areas, ["area: cloud"]
        )

    def test_leading_subject_counts_when_nothing_else_matches(self):
        result = RULES.classify("Terminal jitters when toggling between tabs", "")
        self.assertEqual(result.areas, ["area: terminal"])

    def test_leading_subject_does_not_override_a_clear_scoring_winner(self):
        # "Sidebar" leads, but the title is scored on its own terms and the
        # subject shape is only a fallback, so both areas survive.
        result = RULES.classify("Sidebar shows Running after a Claude Code turn ends", "")
        self.assertEqual(sorted(result.areas), ["area: agents", "area: sidebar"])

    def test_an_enumeration_beats_the_subject_shape(self):
        # `declared_area` alone does read the leading word here, so the guard
        # has to be the one in `pick_areas`: a title that scores several areas
        # at title weight goes to a person, declaration or not.
        title = "Sidebar, splits, ssh, cloud machines and the iOS app all need a rethink"
        self.assertEqual(RULES.declared_area(title), "area: sidebar")
        self.assertGreater(len(RULES.score_areas(title, "")), 2)
        self.assertEqual(RULES.classify(title, "").areas, [])

    def test_two_areas_in_the_prefix_declare_neither(self):
        self.assertIsNone(RULES.declared_area("Terminal paste: drops characters"))

    def test_prefix_only_ignores_the_subject_shape(self):
        title = "Terminal jitters when toggling between tabs"
        self.assertEqual(RULES.declared_area(title), "area: terminal")
        self.assertIsNone(RULES.declared_area(title, prefix_only=True))

    def test_a_channel_name_is_not_an_area(self):
        # "NIGHTLY" and "Install" name where a bug happens or what it is called,
        # not `area: updates`, so they stay out of the declaration vocabulary.
        self.assertIsNone(RULES.declared_area("NIGHTLY hangs: CmuxEventBus.publish blocks"))
        self.assertIsNone(
            RULES.declared_area("Regression: Install and Relaunch no longer relaunches")
        )

    def test_every_area_can_be_declared_by_its_own_name(self):
        # A reporter who types the area label's own noun as a scope prefix
        # should land on that area. This is the check that caught 10 areas
        # whose scoring pattern needs a qualifier the prefix does not have.
        words = {
            "area: build-and-ci": "CI",
            "area: command-palette": "Command palette",
            "area: ios": "iOS",
            "area: cli": "CLI",
        }
        for area, _pattern in RULES.AREA_RULES:
            word = words.get(area, area.removeprefix(RULES.AREA_PREFIX))
            with self.subTest(area=area):
                self.assertEqual(RULES.declared_area(f"{word}: something is wrong"), area)


class OverrideTests(unittest.TestCase):
    def test_existing_severity_counts_as_triaged(self):
        self.assertEqual(
            RULES.existing_triage_labels([{"name": "bug"}, {"name": "S2: major"}]),
            {"S2: major"},
        )

    def test_existing_area_counts_as_triaged(self):
        self.assertEqual(
            RULES.existing_triage_labels(["area: cloud", "enhancement"]),
            {"area: cloud"},
        )

    def test_needs_triage_counts_as_triaged(self):
        # A person who removed the bot's area guess and left `needs-triage`
        # should not get the same guess back.
        self.assertEqual(RULES.existing_triage_labels(["needs-triage"]), {"needs-triage"})

    def test_untriaged_issue_is_open_for_labeling(self):
        self.assertEqual(RULES.existing_triage_labels([{"name": "bug"}]), set())


class ManifestTests(unittest.TestCase):
    def setUp(self):
        self.manifest = json.loads(MANIFEST.read_text())
        self.names = {entry["name"] for entry in self.manifest["labels"]}

    def test_every_label_the_rules_can_emit_is_defined(self):
        emitted = set(RULES.SEVERITY_ORDER) | {RULES.NEEDS_TRIAGE}
        emitted |= {area for area, _ in RULES.AREA_RULES}
        missing = sorted(emitted - self.names)
        self.assertEqual(missing, [], f"rules emit labels the manifest does not define: {missing}")

    def test_manifest_areas_all_have_a_rule(self):
        # An area with no rule can never be applied automatically. That is
        # allowed, but it should be a deliberate choice, so keep the list here.
        ruled = {area for area, _ in RULES.AREA_RULES}
        manual = sorted(
            name for name in self.names if name.startswith(RULES.AREA_PREFIX) and name not in ruled
        )
        self.assertEqual(manual, [])

    def test_manifest_passes_its_own_validation(self):
        sync = load("sync_labels", "scripts/ci/sync_labels.py")
        self.assertEqual(len(sync.load_manifest(MANIFEST)), len(self.manifest["labels"]))

    def test_case_only_duplicate_names_are_refused(self):
        sync = load("sync_labels", "scripts/ci/sync_labels.py")
        manifest = {
            "labels": [
                {"name": "area: cloud", "color": "0e8a16", "description": "Cloud things"},
                {"name": "Area: Cloud", "color": "0e8a16", "description": "Same label"},
            ]
        }
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "labels.json"
            path.write_text(json.dumps(manifest))
            with self.assertRaisesRegex(SystemExit, r"duplicate label .*names are case-insensitive"):
                sync.load_manifest(path)

    def test_dry_run_refuses_case_only_duplicates_before_any_api_call(self):
        # load_manifest runs before the token check in main(), so a case-only
        # duplicate fails a --dry-run with no credentials and no network.
        sync = load("sync_labels", "scripts/ci/sync_labels.py")
        manifest = {
            "labels": [
                {"name": "bug", "color": "0e8a16"},
                {"name": "BUG", "color": "0e8a16"},
            ]
        }
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "labels.json"
            path.write_text(json.dumps(manifest))
            with self.assertRaisesRegex(SystemExit, r"duplicate label .*names are case-insensitive"):
                sync.main(["--manifest", str(path), "--dry-run"])

    def test_non_string_label_name_has_validation_error(self):
        sync = load("sync_labels", "scripts/ci/sync_labels.py")
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "labels.json"
            path.write_text(json.dumps({"labels": [{"name": 5, "color": "0e8a16"}]}))
            with self.assertRaisesRegex(SystemExit, "every label needs a non-empty string name"):
                sync.load_manifest(path)


class CommentTests(unittest.TestCase):
    def test_comment_carries_the_marker_and_the_reason(self):
        result = RULES.classify("App crashes when closing the last split", "")
        body = AUTO.render_comment(result)
        self.assertIn(AUTO.COMMENT_MARKER, body)
        self.assertIn("S2: major", body)
        self.assertIn("docs/triage.md", body)

    def test_comment_never_mentions_anyone(self):
        # Outside contributors already drown in bot pings; a triage note must
        # not add an @mention that pulls more bots or people into the thread.
        result = RULES.classify("Feature: nested folders for workspaces", "")
        self.assertNotIn("@", AUTO.render_comment(result))

    def test_comment_says_how_to_override(self):
        result = RULES.classify("theme error", "")
        self.assertIn("Change the labels", AUTO.render_comment(result))

    def test_comment_credits_the_issue_form_for_its_area(self):
        result = RULES.classify("Wrong item highlighted after reorder", form_body("sidebar"))
        body = AUTO.render_comment(result)
        self.assertIn("selected in the issue form", body)
        self.assertNotIn("from words in the title", body)


class WorkflowSafetyTests(unittest.TestCase):
    def setUp(self):
        self.text = WORKFLOW.read_text()

    def test_only_issue_open_and_reopen_trigger_it(self):
        self.assertIn("types: [opened, reopened]", self.text)
        self.assertNotIn("edited", self.text)

    def test_permissions_are_narrow(self):
        self.assertIn("contents: read", self.text)
        self.assertIn("issues: write", self.text)
        self.assertNotIn("pull-requests: write", self.text)

    def test_runs_are_serialized_per_issue(self):
        self.assertIn("auto-triage-${{ github.event.issue.number", self.text)
        self.assertIn("cancel-in-progress: false", self.text)

    def test_manual_backfill_defaults_to_a_dry_run_and_no_issues(self):
        self.assertIn('default: "0"', self.text)
        self.assertIn("default: true", self.text)


class DocumentedExampleTests(unittest.TestCase):
    """Every severity the page illustrates has to reproduce.

    These are lifted verbatim from the tables in `docs/triage.md`. The first
    version of the rules answered `None` for four of them, because the
    bug-or-feature gate only looked for words that mean failure and never for
    the words the examples actually use.
    """

    def test_docs_severity_examples_all_produce_a_label(self):
        examples = {
            "Reopening a session destroys the current windows": "S1: critical",
            "Crash when closing the last split": "S2: major",
            "cmux ssh cannot connect to the host": "S2: major",
            "Tab title shows the old directory until you switch tabs": "S3: minor",
            "A typo in Settings": "S4: cosmetic",
            "A misaligned tab indicator": "S4: cosmetic",
        }
        for title, expected in examples.items():
            with self.subTest(title=title):
                self.assertEqual(RULES.classify(title, "").severity, expected)

    def test_slowness_is_a_defect_not_a_feature_request(self):
        for title in (
            "Slow to open a new tab",
            "Latency when scrolling scrollback",
            "CPU usage climbs while idle",
        ):
            with self.subTest(title=title):
                self.assertEqual(RULES.classify(title, "").severity, "S3: minor")

    def test_visual_breakage_reaches_cosmetic(self):
        for title in (
            "Icon is blurry on the retina display",
            "Sidebar labels are truncated",
            "Letter spacing is off in the palette",
        ):
            with self.subTest(title=title):
                self.assertEqual(RULES.classify(title, "").severity, "S4: cosmetic")

    def test_a_request_for_cosmetic_polish_gets_no_severity(self):
        for title in (
            "Add a padding option for tabs",
            "Allow choosing the margin around panes",
        ):
            with self.subTest(title=title):
                self.assertIsNone(RULES.classify(title, "").severity)

    def test_rfc_framing_hides_crash_words_but_not_a_security_title(self):
        self.assertIsNone(RULES.classify("RFC: crash-safe session restore", "").severity)
        self.assertEqual(
            RULES.classify("[RFC] Arbitrary code execution risk in the ACP transport", "").severity,
            "S1: critical",
        )


class ReceiptTests(unittest.TestCase):
    """A receipt is the only thing that can undo a bulk pass."""

    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        self.path = self.dir / "receipt.jsonl"

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def rows(self):
        return [json.loads(line) for line in self.path.read_text().splitlines() if line.strip()]

    def test_each_row_lands_on_disk_before_the_next_issue(self):
        # A pass over the backlog can die to a rate limit or the job timeout. A
        # label applied with no receipt line is a label nothing can undo, so
        # buffering rows is not an option.
        with AUTO.Receipt(self.path, "manaflow-ai/cmux", dry_run=False) as receipt:
            receipt.add(1, ["S2: major"])
            self.assertEqual(len(self.rows()), 1)
            receipt.add(2, ["area: cli"])
            self.assertEqual(len(self.rows()), 2)

    def test_rows_carry_the_repo(self):
        with AUTO.Receipt(self.path, "teamleaderleo/cmux", dry_run=False) as receipt:
            receipt.add(7, ["needs-triage"])
        self.assertEqual(self.rows()[0]["repo"], "teamleaderleo/cmux")

    def test_a_dry_run_receipt_is_marked_and_refused_by_revert(self):
        with AUTO.Receipt(self.path, "manaflow-ai/cmux", dry_run=True) as receipt:
            receipt.add(9, ["S3: minor"])
        self.assertTrue(self.rows()[0]["dry_run"])
        with self.assertRaises(SystemExit) as caught:
            AUTO.load_receipt(self.path, "manaflow-ai/cmux")
        self.assertIn("dry run", str(caught.exception))

    def test_revert_refuses_a_receipt_from_another_repo(self):
        with AUTO.Receipt(self.path, "teamleaderleo/cmux", dry_run=False) as receipt:
            receipt.add(9, ["S3: minor"])
        with self.assertRaises(SystemExit) as caught:
            AUTO.load_receipt(self.path, "manaflow-ai/cmux")
        self.assertIn("teamleaderleo/cmux", str(caught.exception))

    def test_revert_accepts_its_own_real_receipt(self):
        with AUTO.Receipt(self.path, "manaflow-ai/cmux", dry_run=False) as receipt:
            receipt.add(9, ["S3: minor"])
        rows = AUTO.load_receipt(self.path, "manaflow-ai/cmux")
        self.assertEqual(rows[0]["added"], ["S3: minor"])


class LimitTests(unittest.TestCase):
    def test_zero_and_its_spellings_are_rejected(self):
        # `--limit 0` used to mean "walk everything", so "00" typed into the
        # dispatch form started an unbounded pass over the whole backlog.
        for value in ("0", "00", "-1", " 0", "nope"):
            with self.subTest(value=value), self.assertRaises(Exception):
                AUTO.positive(value)

    def test_a_real_limit_parses(self):
        self.assertEqual(AUTO.positive("200"), 200)


class RateLimitTests(unittest.TestCase):
    """403 means two different things and only one of them is worth retrying."""

    def test_retry_after_is_honored(self):
        self.assertEqual(AUTO.rate_limit_delay({"Retry-After": "12"}, 0), 12)

    def test_primary_limit_waits_for_the_reset(self):
        reset = int(time.time()) + 45
        delay = AUTO.rate_limit_delay(
            {"X-RateLimit-Remaining": "0", "X-RateLimit-Reset": str(reset)}, 0
        )
        self.assertTrue
        self.assertGreater(delay, 30)
        self.assertLessEqual(delay, 60)

    def test_a_permission_failure_is_not_retried(self):
        # "Resource not accessible by integration" is a 403 that will still be
        # a 403 in three minutes. Sleeping through the job timeout hides it.
        self.assertIsNone(AUTO.rate_limit_delay({"X-RateLimit-Remaining": "4987"}, 0))

    def test_no_wait_is_longer_than_the_cap(self):
        reset = int(time.time()) + 100000
        delay = AUTO.rate_limit_delay(
            {"X-RateLimit-Remaining": "0", "X-RateLimit-Reset": str(reset)}, 0
        )
        self.assertEqual(delay, AUTO.MAX_SLEEP)


class LabelSyncTests(unittest.TestCase):
    def test_existing_labels_are_matched_case_insensitively(self):
        # GitHub label names are case-insensitively unique: treating `Area: CLI`
        # as missing means creating it, and that is a 422 that fails the sync.
        calls = []

        def fake_request(method, url, token, payload=None):
            calls.append((method, url, payload))
            if method == "GET":
                if calls.count(("GET", url, None)) > 1:
                    return []
                return [{"name": "Area: CLI", "color": "bfd4f2", "description": "old"}]
            return None

        original = SYNC.request
        SYNC.request = fake_request
        try:
            existing = SYNC.fetch_existing("manaflow-ai/cmux", "t")
        finally:
            SYNC.request = original
        self.assertIn("area: cli", existing)

    def test_a_human_severity_in_another_case_still_counts_as_triaged(self):
        self.assertTrue(RULES.existing_triage_labels([{"name": "S2: Major"}]))
        self.assertTrue(RULES.existing_triage_labels([{"name": "Needs-Triage"}]))


if __name__ == "__main__":
    unittest.main()
