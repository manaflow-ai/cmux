#!/usr/bin/env python3
"""nightly.yml repairs an OptChat Chief cache entry that fails validation.

build-optchat-chief.sh rebuilds a restored Chief whose binary or provenance
does not validate (corrupt bytes, a symlink, a wrong identity). Actions cache
keys are immutable, and an exact restore reports cache-hit=true whatever its
contents, so a save gated on cache-hit would never replace a bad entry: every
later nightly would restore it and rebuild again.

So the workflow, with no new permissions (deleting the bad entry by key would
need actions: write):
- restores with a primary key unique to this run, which never exists yet, and
  finds the newest saved generation through restore-keys (the newest entry of
  a matching prefix wins);
- saves each generation under that unique key, so a repaired entry becomes the
  newest one and the next restore prefers it;
- saves only when the build script reports it rebuilt the entry (its result
  file says "built"), not on cache-hit, so a reused entry is not saved again.
"""
from __future__ import annotations

import unittest
from pathlib import Path

import yaml

from nightly_workflow_text import nightly_text

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "cmux-next" / "build-optchat-chief.sh"


def steps_by_name() -> tuple[list[str], dict[str, dict]]:
    job = yaml.safe_load(nightly_text())["jobs"]["build-nightly-app"]
    steps = job["steps"]
    names = [step.get("name", "") for step in steps]
    return names, {step.get("name", ""): step for step in steps}


class ChiefCacheRepairTests(unittest.TestCase):
    def setUp(self) -> None:
        self.names, self.steps = steps_by_name()

    def step(self, name: str) -> dict:
        self.assertIn(name, self.steps, f"nightly.yml has no step {name!r}")
        return self.steps[name]

    def test_save_depends_on_the_build_result_not_cache_hit(self) -> None:
        save = self.step("Save the OptChat Chief cache")
        self.assertNotIn("cache-hit", save["if"], "a save gated on cache-hit never repairs a bad exact entry")
        self.assertIn("steps.chief-cache-result.outputs.rebuilt == 'true'", save["if"])
        result = self.step("Read whether the OptChat Chief was rebuilt")
        self.assertEqual(result.get("id"), "chief-cache-result")
        self.assertIn("CMUX_NEXT_OPTCHAT_CHIEF_RESULT_FILE", result["run"])
        self.assertIn("rebuilt=true", result["run"])
        # The result exists only after the background build is joined.
        self.assertLess(self.names.index("Bundle the OptChat Chief and the iPhone host"),
                        self.names.index("Read whether the OptChat Chief was rebuilt"))
        self.assertLess(self.names.index("Read whether the OptChat Chief was rebuilt"),
                        self.names.index("Save the OptChat Chief cache"))

    def test_a_saved_generation_is_preferred_by_the_next_restore(self) -> None:
        key = self.step("Prepare the OptChat Chief cache key")["run"]
        self.assertIn('save_key="${cache_key}-g${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"', key)
        self.assertIn('restore_prefix="${cache_key}-g"', key)
        self.assertIn("CMUX_NEXT_OPTCHAT_CHIEF_RESULT_FILE=", key)
        restore = self.step("Restore the OptChat Chief cache")["with"]
        self.assertEqual(restore["key"], "${{ steps.chief-cache-key.outputs.save_key }}")
        self.assertEqual(restore["restore-keys"].strip(), "${{ steps.chief-cache-key.outputs.restore_prefix }}")
        save = self.step("Save the OptChat Chief cache")["with"]
        self.assertEqual(save["key"], "${{ steps.chief-cache-key.outputs.save_key }}")
        self.assertEqual(save["path"], restore["path"])

    def test_the_build_script_reports_reuse_and_rebuild(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("CMUX_NEXT_OPTCHAT_CHIEF_RESULT_FILE", script)
        self.assertIn("report_result reused", script)
        self.assertIn("report_result built", script)


if __name__ == "__main__":
    unittest.main()
