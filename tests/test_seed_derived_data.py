#!/usr/bin/env python3
"""Compile admission may start from the nightly seed's DerivedData, never be judged by it."""
import json
import os
import re
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import seed_derived_data as seed  # noqa: E402

BUILD_TIME_NS = 1_700_000_000_000_000_000
FAKE_R2 = """#!/usr/bin/env bash
# restore <dir> <key> <prefix>: stands in for scripts/ci/r2-cache.sh.
dir="$2"
[ -z "${FAKE_CALLS:-}" ] || echo "$3" >> "$FAKE_CALLS"
sleep "${FAKE_DELAY:-0}"
echo "cache-hit=false" >> "$GITHUB_OUTPUT"
case "$FAKE_MODE" in
  hit)
    rm -rf "$dir"; mkdir -p "$dir"; tar -xf "$FAKE_ARCHIVE" -C "$dir"
    echo "cache-matched-key=${4}0123abc" >> "$GITHUB_OUTPUT" ;;
  fail) exit 1 ;;
esac
"""


class SeedDerivedData(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.source = self.root / "src"
        (self.source / "Sources").mkdir(parents=True)
        (self.source / "Sources/App.swift").write_text("let app = 1\n")
        (self.source / "Sources/Other.swift").write_text("let other = 1\n")
        for path in self.source.rglob("*.swift"):
            os.utime(path, ns=(BUILD_TIME_NS, BUILD_TIME_NS))
        self.derived = self.root / "derived-data-compile-admission"
        self.fake = self.root / "r2-cache.sh"
        self.fake.write_text(FAKE_R2)
        self.env = dict(os.environ)
        os.environ["CMUX_R2_CACHE_SCRIPT"] = str(self.fake)

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.env)

    def publish_seed(self, with_manifest=True):
        """Build the seed the way nightly.yml does: record, build, prune, archive."""
        seed.record(self.source, self.derived)
        (self.derived / "Build").mkdir()
        (self.derived / "Build/App.o").write_text("object")
        (self.derived / "Logs").mkdir()
        (self.derived / "Logs/build.xcactivitylog").write_text("log")
        (self.derived / "Index.noindex").mkdir()
        self.assertEqual(seed.prune(self.derived)["save"], "true")
        self.assertFalse((self.derived / "Logs").exists())
        self.assertFalse((self.derived / "Index.noindex").exists())
        if not with_manifest:
            (self.derived / seed.MANIFEST).unlink()
        archive = self.root / "seed.tar"
        with tarfile.open(archive, "w") as bundle:
            bundle.add(self.derived, arcname=".")
        os.environ["FAKE_ARCHIVE"] = str(archive)
        # The consumer is a fresh runner: fresh DerivedData from resolve, and
        # every checked-out file stamped now.
        import shutil
        shutil.rmtree(self.derived)
        self.derived.mkdir()
        (self.derived / "from-resolve").write_text("resolve")
        for path in self.source.rglob("*.swift"):
            os.utime(path)

    def adopt(self, mode):
        os.environ["FAKE_MODE"] = mode
        # On darwin a hit runs `defaults write com.apple.dt.XCBuild ...`;
        # tests must never change the developer's real Xcode default.
        with mock.patch.object(seed.sys, "platform", "linux"):
            return seed.adopt(self.source, self.derived, "admission-derived-data-v1-x-base", "admission-derived-data-v1-x-")

    def mtime(self, relative):
        return (self.source / relative).stat().st_mtime_ns

    def test_a_hit_swaps_in_the_seed_and_ages_only_unchanged_inputs(self):
        self.publish_seed()
        (self.source / "Sources/App.swift").write_text("let app = 2\n")

        result = self.adopt("hit")

        self.assertEqual(result["hit"], "true")
        self.assertEqual(result["key"], "admission-derived-data-v1-x-0123abc")
        self.assertEqual((result["unchanged_inputs"], result["changed_inputs"]), ("1", "1"))
        self.assertEqual((self.derived / "Build/App.o").read_text(), "object")
        self.assertFalse((self.derived / "from-resolve").exists())
        self.assertEqual(self.mtime("Sources/Other.swift"), BUILD_TIME_NS)
        self.assertGreater(self.mtime("Sources/App.swift"), BUILD_TIME_NS)
        self.assertFalse(self.derived.with_name(self.derived.name + ".seed").exists())

    def test_a_miss_leaves_the_resolved_derived_data_alone(self):
        self.publish_seed()
        result = self.adopt("miss")
        self.assertEqual(result, {"hit": "false", "reason": "no-seed"})
        self.assertEqual((self.derived / "from-resolve").read_text(), "resolve")
        self.assertGreater(self.mtime("Sources/Other.swift"), BUILD_TIME_NS)

    def test_a_seed_without_recorded_inputs_is_refused(self):
        self.publish_seed(with_manifest=False)
        result = self.adopt("hit")
        self.assertEqual(result["reason"], "seed-without-input-manifest")
        self.assertTrue((self.derived / "from-resolve").exists())
        self.assertFalse((self.derived / "Build").exists())
        self.assertFalse(self.derived.with_name(self.derived.name + ".seed").exists())

    def test_a_failed_restore_is_a_cold_build(self):
        self.publish_seed()
        os.environ["FAKE_MODE"] = "fail"
        output = self.root / "output"
        os.environ["GITHUB_OUTPUT"] = str(output)
        self.assertEqual(seed.main(["seed", "adopt", str(self.source), str(self.derived), "k", "p-"]), 0)
        self.assertIn("hit=false", output.read_text())
        self.assertTrue((self.derived / "from-resolve").exists())

    def start_then_adopt(self, mode, start_args=None):
        """Download in the background, as compile admission does while it resolves."""
        os.environ["FAKE_MODE"] = mode
        os.environ["FAKE_CALLS"] = str(self.root / "calls")
        seed.start(self.derived, *(start_args or ("admission-derived-data-v1-x-base", "admission-derived-data-v1-x-")))
        # The resolve step runs meanwhile and rewrites the DerivedData.
        import shutil
        shutil.rmtree(self.derived)
        self.derived.mkdir()
        (self.derived / "from-resolve").write_text("resolve")
        output = self.root / "output"
        output.unlink(missing_ok=True)
        os.environ["GITHUB_OUTPUT"] = str(output)
        with mock.patch.object(seed.sys, "platform", "linux"):
            seed.main(["seed", "adopt", str(self.source), str(self.derived),
                       "admission-derived-data-v1-x-base", "admission-derived-data-v1-x-"])
        return dict(line.split("=", 1) for line in output.read_text().splitlines())

    def calls(self):
        return (self.root / "calls").read_text().split()

    def assert_no_leftovers(self):
        leftovers = sorted(p.name for p in self.root.iterdir() if p.name.startswith(self.derived.name + "."))
        self.assertEqual(leftovers, [])

    def test_adopt_waits_for_the_background_download_instead_of_downloading_again(self):
        self.publish_seed()
        (self.source / "Sources/App.swift").write_text("let app = 2\n")
        os.environ["FAKE_DELAY"] = "1"

        result = self.start_then_adopt("hit")

        self.assertEqual(result["hit"], "true")
        self.assertEqual(result["key"], "admission-derived-data-v1-x-0123abc")
        self.assertEqual((result["unchanged_inputs"], result["changed_inputs"]), ("1", "1"))
        self.assertEqual(self.calls(), ["admission-derived-data-v1-x-base"])
        self.assertEqual((self.derived / "Build/App.o").read_text(), "object")
        self.assertFalse((self.derived / "from-resolve").exists())
        self.assertEqual(self.mtime("Sources/Other.swift"), BUILD_TIME_NS)
        self.assert_no_leftovers()

    def test_a_failed_background_download_is_a_cold_build(self):
        self.publish_seed()
        result = self.start_then_adopt("fail")
        self.assertEqual(result["hit"], "false")
        self.assertEqual(self.calls(), ["admission-derived-data-v1-x-base"])
        self.assertEqual((self.derived / "from-resolve").read_text(), "resolve")
        self.assertGreater(self.mtime("Sources/Other.swift"), BUILD_TIME_NS)
        self.assert_no_leftovers()

    def test_a_background_miss_leaves_the_resolved_derived_data_alone(self):
        self.publish_seed()
        result = self.start_then_adopt("miss")
        self.assertEqual(result, {"hit": "false", "reason": "no-seed"})
        self.assertEqual((self.derived / "from-resolve").read_text(), "resolve")
        self.assert_no_leftovers()

    def test_a_killed_background_download_is_downloaded_again(self):
        # A runner that reaps a step's processes when the step ends would
        # kill the download; adopt must not mistake that for a missing seed.
        self.publish_seed()
        os.environ["FAKE_DELAY"] = "30"
        real_start = seed.start

        def start_and_kill(*args):
            real_start(*args)
            ticket = json.loads(self.derived.with_name(self.derived.name + ".seed.ticket").read_text())
            seed.stop(ticket["pid"])
            os.environ["FAKE_DELAY"] = "0"

        with mock.patch.object(seed, "start", start_and_kill):
            result = self.start_then_adopt("hit")
        self.assertEqual(result["hit"], "true")
        self.assertEqual(self.calls()[-1], "admission-derived-data-v1-x-base")
        self.assert_no_leftovers()

    def test_a_download_started_for_other_keys_is_not_adopted(self):
        self.publish_seed()
        result = self.start_then_adopt("hit", ("admission-derived-data-v1-y-base", "admission-derived-data-v1-y-"))
        # The stray download is stopped and adopt fetches its own keys.
        self.assertEqual(result["hit"], "true")
        self.assertEqual(result["key"], "admission-derived-data-v1-x-0123abc")
        self.assertEqual(self.calls()[-1], "admission-derived-data-v1-x-base")
        self.assert_no_leftovers()

    def test_prune_refuses_an_unrecorded_or_oversized_seed(self):
        self.derived.mkdir()
        self.assertEqual(seed.prune(self.derived)["reason"], "no-input-manifest")
        seed.record(self.source, self.derived)
        limit = seed.MAX_RAW_BYTES
        try:
            seed.MAX_RAW_BYTES = 1
            self.assertEqual(seed.prune(self.derived)["reason"], "too-large")
        finally:
            seed.MAX_RAW_BYTES = limit


def load(workflow):
    return yaml.safe_load((ROOT / ".github/workflows" / workflow).read_text())


def steps(workflow, job):
    return load(workflow)["jobs"][job]["steps"]


def named(step_list, name):
    matches = [index for index, step in enumerate(step_list) if step.get("name") == name]
    assert len(matches) == 1, name
    return matches[0], step_list[matches[0]]


class Wiring(unittest.TestCase):
    def test_only_the_nightly_seeder_writes_the_seed_and_admission_reads_the_same_key(self):
        seeder = steps("nightly.yml", "refresh-test-compilation-cache")
        record_at, _ = named(seeder, "Record DerivedData seed inputs")
        build_at, _ = named(seeder, "Refresh test compilation cache")
        save_at, save = named(seeder, "Save DerivedData seed")
        self.assertLess(record_at, build_at)
        self.assertLess(build_at, save_at)
        self.assertEqual(save["with"]["backend"], "r2")
        written = save["with"]["key"]
        suffix = "${{ needs.decide.outputs.head_sha }}"
        self.assertTrue(written.endswith(suffix))

        admission = steps("ci-macos.yml", "macos-compile-admission")
        resolve_at, _ = named(admission, "Resolve Swift packages")
        adopt_at, adopt = named(admission, "Adopt the nightly DerivedData seed")
        compile_at, _ = named(admission, "Compile app-host test product")
        forget_at, forget = named(admission, "Forget the adopted-build inode override")
        self.assertLess(resolve_at, adopt_at)
        self.assertLess(adopt_at, compile_at)
        self.assertLess(compile_at, forget_at)
        self.assertEqual(adopt["env"]["SEED_PREFIX"], written[: -len(suffix)])
        self.assertIn("steps.seed-derived-data.outputs.hit == 'true'", forget["if"])

        for path in (ROOT / ".github/workflows").glob("*.yml"):
            text = path.read_text()
            if "admission-derived-data-" in text and path.name not in {"nightly.yml", "ci-macos.yml", "seed-derived-data.yml"}:
                self.fail(f"{path.name} names the admission DerivedData seed")
        self.assertNotIn("secrets.", json.dumps(adopt))

    def test_every_main_push_seeds_incrementally_under_the_key_admission_reads(self):
        workflow = load("seed-derived-data.yml")
        triggers = workflow.get("on", workflow.get(True))
        # Only trusted main code may write a seed pull requests adopt.
        self.assertEqual(set(triggers), {"push", "workflow_dispatch"})
        self.assertEqual(triggers["push"]["branches"], ["main"])
        # cancel-in-progress would starve publishing while merges keep
        # arriving faster than a seed builds; see the comment beside it.
        self.assertIs(workflow["concurrency"]["cancel-in-progress"], False)
        # One group per pool: a seed is only useful to admission on that pool.
        self.assertIn(workflow["jobs"]["seed"]["runs-on"].strip("${} "), workflow["concurrency"]["group"])

        seeder = steps("seed-derived-data.yml", "seed")
        resolve_at, _ = named(seeder, "Resolve Swift packages")
        adopt_at, adopt = named(seeder, "Adopt the newest seed")
        record_at, _ = named(seeder, "Record seed inputs")
        build_at, _ = named(seeder, "Build")
        save_at, save = named(seeder, "Save seed")
        self.assertLess(resolve_at, adopt_at)
        self.assertLess(adopt_at, record_at)
        self.assertLess(record_at, build_at)
        self.assertLess(build_at, save_at)
        self.assertIs(adopt.get("continue-on-error"), True)
        self.assertEqual(save["with"]["backend"], "r2")
        self.assertEqual(save["with"]["key"], "${{ steps.key.outputs.prefix }}${{ github.sha }}")

        # Same key shape, runner and Xcode as the nightly seeder, or pull
        # requests would never match what this writes.
        _, key = named(seeder, "Compute seed key")
        self.assertIn("admission-derived-data-v1-${RUNNER_OS}-${RUNNER_ARCH}-${fingerprint}-", key["run"])
        nightly = load("nightly.yml")["jobs"]["refresh-test-compilation-cache"]
        job = workflow["jobs"]["seed"]
        self.assertEqual(job["runs-on"], nightly["runs-on"])
        self.assertEqual(job["env"]["CMUX_CI_XCODE_APP"], nightly["env"]["CMUX_CI_XCODE_APP"])

        # Resolve against the same Swift package cache admission restores, so
        # a layout change invalidates both keys together.
        _, seed_spm = named(seeder, "Cache Swift packages")
        _, admission_spm = named(steps("ci-macos.yml", "macos-compile-admission"), "Cache Swift packages")
        self.assertEqual(seed_spm["with"]["key"], admission_spm["with"]["key"])

    def test_the_seed_pool_differs_from_admission_only_in_runner_size(self):
        # Seeds used to queue behind pull requests on admission's own pool.
        # They may move to a larger runner of the same image, since neither
        # the seed key nor the product key names the size, but never to
        # another image or Xcode.
        runs_on = load("seed-derived-data.yml")["jobs"]["seed"]["runs-on"]
        admission = load("ci-macos.yml")["jobs"]["macos-compile-admission"]["runs-on"]
        larger = "vars.MACOS_RUNNER_PR == 'blacksmith-6vcpu-macos-26' && 'blacksmith-12vcpu-macos-26'"
        self.assertIn(larger, runs_on)
        # Any other pool value is admission's pull-request pool, unchanged.
        fallback = "vars.MACOS_RUNNER_PR || 'blacksmith-6vcpu-macos-15'"
        self.assertTrue(runs_on.rstrip("} ").endswith(f"{larger} || {fallback}"), runs_on)
        self.assertIn(fallback, admission)

    def test_main_push_publishes_the_product_admission_would_compile(self):
        """Pull requests adopt this product in place of compiling, so it has to
        be the admission product: same key, same staging, same packaging, same
        artifact name, published only by a main push, after the seed is saved."""
        workflow = load("seed-derived-data.yml")
        job = workflow["jobs"]["seed"]
        seeder = job["steps"]
        admission = steps("ci-macos.yml", "macos-compile-admission")

        # The consumer names the job and step that must have compiled it.
        self.assertNotIn("name", job)
        build_at, build = named(seeder, "Build")
        self.assertIn("canonical-build", build["run"])
        _, admission_compile = named(admission, "Compile app-host test product")
        self.assertIn("canonical-build", admission_compile["run"])

        save_at, _ = named(seeder, "Save seed")
        key_at, key = named(seeder, "Identify reusable compiled products")
        _, admission_key = named(admission, "Identify reusable compiled products")
        self.assertEqual(key["id"], "product-key")
        self.assertEqual(key["run"], admission_key["run"])
        # The contract fingerprints rustc and cargo, so the key waits for them.
        install_at, _ = named(seeder, "Install compilation dependencies")
        self.assertLess(install_at, key_at)
        self.assertLess(key_at, build_at)

        stage_at, stage = named(seeder, "Stage compiled package frameworks")
        _, admission_stage = named(admission, "Stage compiled package frameworks")
        self.assertEqual(stage["run"], admission_stage["run"])

        package_at, package = named(seeder, "Package compiled app-host test product")
        _, admission_package = named(admission, "Package compiled app-host test product")
        for line in admission_package["run"].splitlines():
            line = line.strip()
            if line.startswith(("(cd ", "python3 ", "COPYFILE_DISABLE=1 ", "echo \"sha256=")):
                self.assertIn(line, package["run"])

        upload_at, upload = named(seeder, "Upload compiled app-host test product")
        _, admission_upload = named(admission, "Upload compiled app-host test product")
        self.assertEqual(upload["uses"], admission_upload["uses"])
        for field in ("name", "path", "compression-level"):
            self.assertEqual(upload["with"][field], admission_upload["with"][field], field)
        self.assertIn("retention-days", upload["with"])

        # Staging and relocation rewrite Build/Products, so they run only once
        # the seed incremental builds read is already saved.
        self.assertLess(build_at, save_at)
        self.assertLess(save_at, stage_at)
        self.assertLess(stage_at, package_at)
        self.assertLess(package_at, upload_at)

        # Only a main push is a trusted producer; a dispatch would upload a
        # product nothing adopts.
        for step in (stage, package, upload):
            self.assertIn("github.event_name == 'push'", step["if"])
            self.assertIn("github.ref == 'refs/heads/main'", step["if"])
            self.assertIs(step.get("continue-on-error"), True)
        self.assertIn("steps.package-products.outcome == 'success'", upload["if"])
        self.assertNotIn("secrets.", json.dumps([stage, package, upload]))

    def test_the_seeder_reads_and_writes_through_the_public_url_admission_reads(self):
        # r2-cache.sh restores through CI_CACHE_R2_PUBLIC_URL and refuses to
        # save without it, so a seeder without it never reads or writes a seed.
        seeder = load("seed-derived-data.yml")
        admission = load("ci-macos.yml")
        self.assertEqual(
            seeder.get("env", {}).get("CI_CACHE_R2_PUBLIC_URL"),
            admission["env"]["CI_CACHE_R2_PUBLIC_URL"],
        )

    def test_the_seed_downloads_while_packages_resolve(self):
        # The download needs only the fingerprint, so it starts before the
        # resolve and the adopt step waits for it instead of downloading
        # serially after the resolve (~40 s of each admission, 2026-09-24).
        admission = steps("ci-macos.yml", "macos-compile-admission")
        key_at, _ = named(admission, "Compute test compilation cache key")
        start_at, start = named(admission, "Start the DerivedData seed download")
        resolve_at, _ = named(admission, "Resolve Swift packages")
        adopt_at, adopt = named(admission, "Adopt the nightly DerivedData seed")
        self.assertLess(key_at, start_at)
        self.assertLess(start_at, resolve_at)
        self.assertLess(resolve_at, adopt_at)
        self.assertEqual(start["if"], adopt["if"])
        self.assertEqual(start["env"], adopt["env"])
        self.assertIs(start.get("continue-on-error"), True)
        self.assertIn("seed_derived_data.py start", start["run"])
        self.assertIn("seed_derived_data.py adopt", adopt["run"])
        # The adopt step's own deadline must fire before the step timeout, or
        # a timed-out step leaves the detached download pulling a seed through
        # the compile.
        self.assertLess(seed.FETCH_WAIT_SECONDS, adopt["timeout-minutes"] * 60 - 30)
        # Like adoption, starting the download never decides what the product
        # is, so it must not move the product recipe (and every edit to it
        # would otherwise invalidate every reusable product).
        sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts/ci"))
        import product_input_identity
        self.assertIn("Start the DerivedData seed download", product_input_identity.NON_PRODUCT_RECIPE_STEPS)

    def test_adoption_is_optional_and_limited_to_pull_requests(self):
        admission = steps("ci-macos.yml", "macos-compile-admission")
        _, adopt = named(admission, "Adopt the nightly DerivedData seed")
        self.assertIs(adopt.get("continue-on-error"), True)
        self.assertIn("github.event_name == 'pull_request'", adopt["if"])
        # An unset repository variable is null, and Actions compares null with
        # '0' as the numbers 0 and 0. A bare `vars.X != '0'` is therefore false
        # while X is unset, which turned adoption off everywhere. Unset has to
        # mean on, so the kill switch gets a non-zero default first.
        self.assertIn("(vars.CI_ADMISSION_SEED_DERIVED_DATA || '1') != '0'", adopt["if"])
        self.assertIn("timeout-minutes", adopt)

    def test_no_workflow_compares_a_bare_variable_with_zero(self):
        bare = re.compile(r"vars\.[A-Z0-9_]+\s*[!=]=\s*'0'")
        offenders = [
            f"{path.name}:{number}"
            for path in sorted((ROOT / ".github/workflows").glob("*.yml"))
            for number, line in enumerate(path.read_text().splitlines(), 1)
            if bare.search(line)
        ]
        self.assertEqual(offenders, [], "an unset variable is null, which equals '0'; give it a default first")


if __name__ == "__main__":
    unittest.main()
