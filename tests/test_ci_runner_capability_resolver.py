#!/usr/bin/env python3
"""The capability resolver must never emit a partial or fork-hostile map.

A runner label that GitHub does not recognise is not an error: the job stays
``queued`` until someone notices, and it holds its workflow's concurrency group
while it waits. Every assertion here exists to keep that outcome unreachable --
a fork resolving to Blacksmith, a fleet missing a capability, a map that parses
but does not mean anything.
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RESOLVER = ROOT / "scripts" / "ci" / "resolve_runners.py"
REAL_MAP = ROOT / ".github" / "runners.json"
REUSABLE_WORKFLOW = ROOT / ".github" / "workflows" / "resolve-runners.yml"
PROOF_WORKFLOW = ROOT / ".github" / "workflows" / "ios-app-store.yml"

spec = importlib.util.spec_from_file_location("resolve_runners", RESOLVER)
assert spec and spec.loader
resolver = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = resolver
spec.loader.exec_module(resolver)


MINIMAL_MAP = {
    "capabilities": {
        "linux": "x86_64 Linux",
        "macos_26": "macOS 26 image",
    },
    "fleets": {
        "blacksmith": {
            "linux": "blacksmith-4vcpu-ubuntu-2404",
            "macos_26": "blacksmith-6vcpu-macos-26",
        },
        "hosted": {
            "linux": "ubuntu-24.04",
            "macos_26": "macos-15",
        },
    },
    "owners": {"manaflow-ai": "blacksmith"},
    "default_fleet": "hosted",
}


def write_map(document: object) -> Path:
    handle = tempfile.NamedTemporaryFile(
        "w", suffix=".json", delete=False, encoding="utf-8"
    )
    with handle:
        if isinstance(document, str):
            handle.write(document)
        else:
            json.dump(document, handle)
    return Path(handle.name)


class FleetSelectionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.map_path = write_map(MINIMAL_MAP)
        self.addCleanup(self.map_path.unlink, True)

    def test_fork_owner_resolves_to_the_hosted_fleet_with_no_configuration(self) -> None:
        fleet, _, labels = resolver.resolve(map_path=self.map_path, owner="teamleaderleo")

        self.assertEqual(fleet, "hosted")
        self.assertEqual(labels, MINIMAL_MAP["fleets"]["hosted"])
        self.assertFalse(
            [label for label in labels.values() if label.startswith("blacksmith-")],
            "a fork has no Blacksmith access; a blacksmith-* label there queues forever",
        )

    def test_mapped_owner_resolves_to_its_fleet(self) -> None:
        fleet, _, labels = resolver.resolve(map_path=self.map_path, owner="manaflow-ai")

        self.assertEqual(fleet, "blacksmith")
        self.assertEqual(labels, MINIMAL_MAP["fleets"]["blacksmith"])

    def test_missing_owner_still_resolves_to_the_default_fleet(self) -> None:
        fleet, _, labels = resolver.resolve(map_path=self.map_path, owner="")

        self.assertEqual(fleet, "hosted")
        self.assertEqual(labels, MINIMAL_MAP["fleets"]["hosted"])

    def test_fleet_override_wins_over_the_owner(self) -> None:
        fleet, reason, labels = resolver.resolve(
            map_path=self.map_path, owner="manaflow-ai", forced_fleet="hosted"
        )

        self.assertEqual(fleet, "hosted")
        self.assertIn("override", reason)
        self.assertEqual(labels, MINIMAL_MAP["fleets"]["hosted"])

    def test_blank_fleet_override_is_treated_as_unset(self) -> None:
        for blank in ("", "   ", None):
            with self.subTest(blank=blank):
                fleet, _, _ = resolver.resolve(
                    map_path=self.map_path, owner="manaflow-ai", forced_fleet=blank
                )
                self.assertEqual(fleet, "blacksmith")

    def test_unknown_fleet_override_fails_loudly(self) -> None:
        with self.assertRaises(resolver.ResolveError) as caught:
            resolver.resolve(map_path=self.map_path, owner="manaflow-ai", forced_fleet="warp")

        self.assertIn("warp", str(caught.exception))


class MalformedMapTests(unittest.TestCase):
    def assert_rejected(self, document: object, needle: str) -> None:
        path = write_map(document)
        self.addCleanup(path.unlink, True)
        with self.assertRaises(resolver.ResolveError) as caught:
            resolver.resolve(map_path=path, owner="manaflow-ai")
        self.assertIn(needle, str(caught.exception))

    def test_unparseable_json_fails_loudly(self) -> None:
        self.assert_rejected("{ not json", "not valid JSON")

    def test_missing_top_level_field_fails_loudly(self) -> None:
        document = json.loads(json.dumps(MINIMAL_MAP))
        del document["default_fleet"]
        self.assert_rejected(document, "default_fleet")

    def test_a_fleet_missing_a_capability_fails_loudly(self) -> None:
        document = json.loads(json.dumps(MINIMAL_MAP))
        del document["fleets"]["hosted"]["macos_26"]
        self.assert_rejected(document, "missing capability keys: macos_26")

    def test_a_fleet_with_an_undeclared_capability_fails_loudly(self) -> None:
        document = json.loads(json.dumps(MINIMAL_MAP))
        document["fleets"]["hosted"]["macos_99"] = "macos-99"
        self.assert_rejected(document, "undeclared capability keys: macos_99")

    def test_an_empty_label_fails_loudly(self) -> None:
        document = json.loads(json.dumps(MINIMAL_MAP))
        document["fleets"]["hosted"]["macos_26"] = ""
        self.assert_rejected(document, "non-empty string label")

    def test_default_fleet_must_exist(self) -> None:
        document = json.loads(json.dumps(MINIMAL_MAP))
        document["default_fleet"] = "nope"
        self.assert_rejected(document, "default_fleet")

    def test_owner_must_name_a_declared_fleet(self) -> None:
        document = json.loads(json.dumps(MINIMAL_MAP))
        document["owners"]["manaflow-ai"] = "nope"
        self.assert_rejected(document, "undeclared fleet")

    def test_missing_map_file_fails_loudly(self) -> None:
        with self.assertRaises(resolver.ResolveError) as caught:
            resolver.resolve(map_path=ROOT / "no" / "such" / "runners.json", owner="x")
        self.assertIn("cannot read runner map", str(caught.exception))


class OverrideTests(unittest.TestCase):
    """`fromJSON(vars.X)` on an unset variable fails the workflow, so the
    override arrives as a plain string and is parsed here instead."""

    def setUp(self) -> None:
        self.map_path = write_map(MINIMAL_MAP)
        self.addCleanup(self.map_path.unlink, True)

    def test_unset_and_blank_overrides_change_nothing(self) -> None:
        for text in (None, "", "   ", "\n"):
            with self.subTest(text=text):
                _, _, labels = resolver.resolve(
                    map_path=self.map_path, owner="manaflow-ai", overrides_text=text
                )
                self.assertEqual(labels, MINIMAL_MAP["fleets"]["blacksmith"])

    def test_override_replaces_one_capability(self) -> None:
        _, _, labels = resolver.resolve(
            map_path=self.map_path,
            owner="manaflow-ai",
            overrides_text='{"macos_26": "macos-15"}',
        )

        self.assertEqual(labels["macos_26"], "macos-15")
        self.assertEqual(labels["linux"], "blacksmith-4vcpu-ubuntu-2404")

    def test_malformed_override_fails_loudly(self) -> None:
        with self.assertRaises(resolver.ResolveError) as caught:
            resolver.resolve(
                map_path=self.map_path, owner="manaflow-ai", overrides_text="{nope"
            )
        self.assertIn("not valid JSON", str(caught.exception))

    def test_override_of_an_unknown_capability_fails_loudly(self) -> None:
        with self.assertRaises(resolver.ResolveError) as caught:
            resolver.resolve(
                map_path=self.map_path,
                owner="manaflow-ai",
                overrides_text='{"macos_27": "macos-15"}',
            )
        self.assertIn("unknown capability keys: macos_27", str(caught.exception))


class RealMapTests(unittest.TestCase):
    def setUp(self) -> None:
        self.document = resolver.load_map(REAL_MAP)

    def test_every_capability_is_answered_by_every_fleet(self) -> None:
        declared = set(self.document["capabilities"])
        for name, labels in self.document["fleets"].items():
            with self.subTest(fleet=name):
                self.assertEqual(set(labels), declared)

    def test_the_repository_owner_routes_to_blacksmith(self) -> None:
        fleet, _, labels = resolver.resolve(map_path=REAL_MAP, owner="manaflow-ai")

        self.assertEqual(fleet, "blacksmith")
        self.assertEqual(labels["linux"], "blacksmith-4vcpu-ubuntu-2404")
        self.assertEqual(labels["macos_15"], "blacksmith-6vcpu-macos-15")
        self.assertEqual(labels["macos_26"], "blacksmith-6vcpu-macos-26")
        self.assertEqual(labels["macos_26_ios"], "blacksmith-6vcpu-macos-26")
        self.assertEqual(labels["macos_26_large"], "blacksmith-12vcpu-macos-26")

    def test_a_fork_never_lands_on_organization_only_capacity(self) -> None:
        _, _, labels = resolver.resolve(map_path=REAL_MAP, owner="some-personal-account")

        for capability, label in labels.items():
            with self.subTest(capability=capability):
                self.assertFalse(label.startswith("blacksmith-"), label)
                self.assertFalse(label.startswith("warp-"), label)
                self.assertFalse(label.startswith("depot-"), label)

    def test_no_fleet_falls_back_to_metered_capacity(self) -> None:
        for name, labels in self.document["fleets"].items():
            for capability, label in labels.items():
                with self.subTest(fleet=name, capability=capability):
                    self.assertFalse(label.startswith("warp-"), label)


class WiringTests(unittest.TestCase):
    def test_the_reusable_workflow_never_fromjsons_a_repository_variable(self) -> None:
        text = REUSABLE_WORKFLOW.read_text(encoding="utf-8")
        for line_number, line in enumerate(text.splitlines(), start=1):
            if line.lstrip().startswith("#"):
                continue
            with self.subTest(line=line_number):
                self.assertNotIn(
                    "fromJSON(vars.",
                    line.replace(" ", ""),
                    "fromJSON() on an unset repository variable fails the whole workflow",
                )

    def test_the_reusable_workflow_keeps_read_only_permissions(self) -> None:
        text = REUSABLE_WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("permissions:\n  contents: read\n", text)
        self.assertNotIn("write", text.split("jobs:", 1)[0])

    def test_the_proof_of_concept_names_a_declared_capability(self) -> None:
        text = PROOF_WORKFLOW.read_text(encoding="utf-8")
        marker = "fromJSON(needs.runners.outputs.map)."
        self.assertIn(marker, text)

        declared = set(resolver.load_map(REAL_MAP)["capabilities"])
        used = set()
        for chunk in text.split(marker)[1:]:
            used.add(chunk.split()[0].strip("}").strip())
        self.assertTrue(used)
        self.assertEqual(used - declared, set())

    def test_the_cli_fails_with_a_nonzero_exit_on_a_broken_map(self) -> None:
        path = write_map("{ broken")
        self.addCleanup(path.unlink, True)
        result = subprocess.run(
            [sys.executable, str(RESOLVER), "--map", str(path), "--owner", "manaflow-ai"],
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertIn("not valid JSON", result.stderr)

    def test_the_cli_prints_only_the_map_on_stdout(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                str(RESOLVER),
                "--map",
                str(REAL_MAP),
                "--owner",
                "some-personal-account",
                "--fleet",
                "",
                "--overrides",
                "",
            ],
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(result.stdout), resolver.load_map(REAL_MAP)["fleets"]["hosted"]
        )


class TheResolverStartsAnywhere(unittest.TestCase):
    def test_the_hosted_fleet_keeps_each_capability_s_os(self):
        # A fork asking for macOS 26 must get macOS 26, not an older image
        # and never an org-only label it cannot schedule.
        import json

        runners = json.loads(
            (Path(__file__).resolve().parents[1] / ".github/runners.json").read_text(encoding="utf-8")
        )
        for capability, label in runners["fleets"]["hosted"].items():
            with self.subTest(capability=capability):
                self.assertFalse(label.startswith("blacksmith-"))
                if capability.startswith("macos_26"):
                    self.assertEqual(label, "macos-26")
                elif capability.startswith("macos_15"):
                    self.assertEqual(label, "macos-15")

    def test_the_resolver_job_does_not_run_on_a_fleet_it_resolves(self):
        # A fork has no Blacksmith and no variables. If the resolver's own
        # runs-on could fall back to an org-only label, it would queue forever
        # before it could pick the hosted fleet.
        import yaml

        workflow = Path(__file__).resolve().parents[1] / ".github/workflows/resolve-runners.yml"
        jobs = yaml.safe_load(workflow.read_text(encoding="utf-8"))["jobs"]
        for name, job in jobs.items():
            with self.subTest(job=name):
                self.assertEqual(job["runs-on"], "ubuntu-24.04")


if __name__ == "__main__":
    unittest.main(verbosity=2)
