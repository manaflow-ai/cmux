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

The exact key hashes the inspector page (inspector/index.html, which build.rs
compiles in) when the key step runs, before "Build the web bundles". That
records what the binary embeds only while no later step rewrites the page
in-tree, so this also checks the page stays committed and only compared.
"""
from __future__ import annotations

import re
import subprocess
import unittest
from pathlib import Path

import yaml

from nightly_workflow_text import nightly_text

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "cmux-next" / "build-optchat-chief.sh"
BUNDLES = ROOT / "scripts" / "cmux-next" / "build-web-bundles.sh"
INSPECTOR = "Native/OptChat/optchat-chief/inspector/index.html"


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

    def test_the_keyed_inspector_page_is_the_one_the_binary_embeds(self) -> None:
        key_script = (ROOT / "scripts" / "cmux-next" / "optchat-chief-input-key.py").read_text(encoding="utf-8")
        self.assertIn(f'GENERATED_INSPECTOR = "{INSPECTOR}"', key_script)
        self.assertIn('lines.append(f"inspector {file_digest(GENERATED_INSPECTOR)}")', key_script)
        tracked = subprocess.run(["git", "-C", str(ROOT), "ls-files", "--error-unmatch", INSPECTOR],
                                 capture_output=True, text=True)
        self.assertEqual(tracked.returncode, 0, f"{INSPECTOR} must stay committed: the key hashes the checkout's copy")
        self.assertLess(self.names.index("Prepare the OptChat Chief cache key"),
                        self.names.index("Build the web bundles (cmux-next)"))
        # No step after the key rewrites the page: none runs its generator.
        for name, step in self.steps.items():
            self.assertNotIn("build-optchat-inspector-web.sh", str(step.get("run", "")), name)
        for script in sorted((ROOT / "scripts" / "ci" / "nightly-steps").glob("*.sh")):
            self.assertNotIn("build-optchat-inspector-web.sh", script.read_text(encoding="utf-8"), script.name)
        # build-web-bundles.sh: the --from install compares the handed-off page and never
        # copies it; an in-tree build runs the generator with --check only.
        bundles = BUNDLES.read_text(encoding="utf-8")
        from_branch = bundles.split('if [ "$MODE" = from ]; then', 1)[1].split("\nfi\n", 1)[0]
        self.assertIn('cmp -s "$FROM_ROOT/$INSPECTOR/index.html" "$ROOT/$INSPECTOR/index.html"', from_branch)
        self.assertNotRegex(from_branch, r'(cp|mv|install|rsync)\b[^\n]*\$INSPECTOR')
        writes = [line.strip() for line in bundles.splitlines()
                  if "build-optchat-inspector-web.sh\"" in line and "--check" not in line]
        self.assertEqual(writes, ['"$ROOT/scripts/cmux-next/build-optchat-inspector-web.sh" --out "$(out "$INSPECTOR")"'])
        self.assertRegex(bundles, re.escape('if [ -n "$OUT_ROOT" ]; then\n  "$ROOT/scripts/cmux-next/build-optchat-inspector-web.sh" --out'))


if __name__ == "__main__":
    unittest.main()
