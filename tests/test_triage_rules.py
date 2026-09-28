import importlib.util
import json
import pathlib
import sys
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


if __name__ == "__main__":
    unittest.main()
