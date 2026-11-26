#!/usr/bin/env python3
"""git-mirror-bundle.yml publishes the bundle glaeda-git-mirror seeds a mini's full mirror from.

glaeda-git-mirror reads v1/any/latest/git-mirror-cmux- in the public NEXT bucket and the
`cmux.bundle` inside the archive it names; it accepts only keys matching
git-mirror-cmux-<10 digits>-<12 hex>. This pins that contract and the writer's trust.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import r2_cache_prune as prune  # noqa: E402
sys.path.insert(0, str(ROOT / "tests"))
import workflow_jobs  # noqa: E402

DOC = yaml.safe_load((ROOT / ".github/workflows/git-mirror-bundle.yml").read_text())
PROBE = DOC["jobs"]["probe"]
PROBE_STEPS = {step.get("name"): step for step in PROBE["steps"]}
JOB = DOC["jobs"]["bundle"]
STEPS = {step.get("name"): step for step in JOB["steps"]}
TRIGGERS = DOC.get("on", DOC.get(True))  # YAML 1.1 reads a bare `on` key as True


def runs_on_text(job: dict, where: str) -> str:
    """The job's runs-on, every matrix cell; a matrix nothing resolves fails."""
    cells = workflow_jobs.runs_on_cells(job)
    if cells is None:
        raise AssertionError(f"{where}: runs-on has a matrix value nothing resolves")
    return "\n".join(cells)


WRITER_ENVIRONMENT = {"name": "${{ github.ref == 'refs/heads/feat-cmux-next' && 'next-cache-writer' || '' }}"}


class Contract(unittest.TestCase):
    def test_the_reader_finds_it(self) -> None:
        env = DOC["env"]
        self.assertEqual(env["CI_CACHE_R2_PUBLIC_URL"], "https://ci-cache-next.cmux.com")
        self.assertEqual(env["CI_CACHE_R2_BUCKET"], "cmux-ci-cache-next")
        self.assertEqual(env["CI_CACHE_R2_NAMESPACE"], "any")
        fetch = STEPS["Fetch the mirrored branches"]["run"]
        self.assertIn("bundle/cmux.bundle", fetch)
        self.assertIn('echo "key=git-mirror-cmux-$(date -u +%Y%m%d%H).${head:0:12}"', fetch)
        for branch in ("main", "feat-cmux-next", "nightly-next"):
            self.assertIn(f"+refs/heads/{branch}:refs/heads/{branch}", fetch)
        # Full history: a shallow bundle could not seed a never-shallow mirror.
        self.assertNotIn("--depth", fetch)
        # The guests' blobless bundle is filtered; the fetch and CI's full bundle never are.
        full = [l for l in fetch.splitlines() if "fetch --quiet" in l or "bundle/cmux.bundle" in l]
        self.assertTrue(full)
        self.assertFalse([l for l in full if "--filter" in l])
        self.assertIn("http.lowSpeedLimit=1024", fetch)
        self.assertIn("bundle verify", fetch)
        guests = STEPS["Publish the raw bundles for guests"]["run"]
        self.assertIn("scripts/ci/git_bundle_list.py plan", guests)
        self.assertIn('put "$rolling/$f" text/plain no-store', guests)
        save = STEPS["Publish the bundle"]
        self.assertEqual(save["uses"], "./.github/actions/cache-save")
        self.assertEqual(save["with"]["path"], "${{ runner.temp }}/bundle")
        self.assertEqual(save["with"]["key"], "${{ steps.fetch.outputs.key }}")
        due = PROBE_STEPS["Is a bundle due"]["run"]
        self.assertIn("latest/git-mirror-cmux-", due)
        self.assertIn(r"^git-mirror-cmux-([0-9]{10})\.[0-9a-f]{12}$", due)

    def test_only_feat_cmux_next_writes_with_the_next_writer(self) -> None:
        self.assertEqual(DOC["permissions"], {})
        self.assertEqual(JOB["permissions"], {"contents": "read"})
        self.assertEqual(workflow_jobs.resolve(JOB).environment, WRITER_ENVIRONMENT)
        self.assertIn("github.ref == 'refs/heads/feat-cmux-next'", PROBE["if"])
        self.assertIn("needs.probe.outputs.due == 'true'", JOB["if"])
        self.assertEqual(TRIGGERS["push"]["branches"], ["feat-cmux-next"])
        self.assertNotIn("pull_request", TRIGGERS)
        self.assertNotIn("pull_request_target", TRIGGERS)
        self.assertEqual(DOC["concurrency"]["group"], "git-mirror-bundle-${{ github.ref }}")
        self.assertFalse(DOC["concurrency"]["cancel-in-progress"])
        self.assertEqual(JOB["needs"], "probe")
        self.assertTrue(runs_on_text(JOB, "bundle").endswith("'cmux-linux' }}"))

    def test_cheap_probe_is_separate_from_the_bundle_writer(self) -> None:
        # Frequent pushes require only a HEAD/read; the full 2.36 GB bundle
        # only starts when the probe says due. Both take the one Linux label
        # (scripts/ci/one_linux_label.py), which sizes itself.
        self.assertEqual(PROBE["permissions"], {})
        self.assertEqual(PROBE["outputs"]["due"], "${{ steps.due.outputs.due }}")
        self.assertTrue(runs_on_text(PROBE, "probe").endswith("'cmux-linux' }}"))
        self.assertNotRegex(runs_on_text(PROBE, "probe"), r"vars\.LINUX_RUNNER(?![A-Z_])|RUNNER_POOLS\)\.linux")
        self.assertNotRegex(runs_on_text(JOB, "bundle"), r"vars\.LINUX_RUNNER(?![A-Z_])|RUNNER_POOLS\)\.linux")
        self.assertNotIn("Fetch the mirrored branches", PROBE_STEPS)
        self.assertNotIn("Publish the bundle", PROBE_STEPS)
        self.assertNotIn("Is a bundle due", STEPS)
        for name in ("Fetch the mirrored branches", "Checkout the cache tooling", "Publish the bundle"):
            self.assertNotIn("if", STEPS[name])
        self.assertEqual(workflow_jobs.resolve(JOB).environment, WRITER_ENVIRONMENT)

    def test_prune_keeps_a_day_and_the_pointed_one(self) -> None:
        key = "git-mirror-cmux-2026102709.0123456789ab"
        self.assertEqual(prune.retention_days(key), 1)
        # r2-cache.sh pins one pointer per dash-terminated prefix, and the pruner keeps every pointer's
        # target: past the stable prefix the key has no dash, so no per-hour pointer pins a bundle for good.
        self.assertNotIn("-", key.removeprefix("git-mirror-cmux-"))


class RollingList(unittest.TestCase):
    """scripts/ci/git_bundle_list.py: a weekly base, a delta since it, and a creationToken list a guest's later
    `git fetch` takes only the newer bundles from (RFD 0056 part 3)."""

    def setUp(self) -> None:
        import tempfile
        self.tmp = Path(tempfile.mkdtemp(prefix="bundle-list-"))
        self.src = self.tmp / "src"
        self.git("init", "-q", "-b", "main", str(self.src), cwd=self.tmp)
        self.commit("one")
        self.built = self.tmp / "built.bundle"
        self.git("bundle", "create", "-q", str(self.built), "--filter=blob:none", "--branches")
        self.published: dict[str, bytes] = {}

    def tearDown(self) -> None:
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def git(self, *args: str, cwd: Path | None = None) -> str:
        import subprocess
        return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *args], cwd=cwd or self.src,
                              check=True, capture_output=True, text=True).stdout

    def commit(self, name: str) -> None:
        (self.src / name).write_text(name)
        self.git("add", name)
        self.git("commit", "-qm", name)

    def fetch(self, url: str, byte_range: int | None = None) -> bytes | None:
        body = self.published.get(url.rsplit("/", 1)[1])
        return None if body is None else (body[:byte_range] if byte_range else body)

    def publish(self, out: Path, upload: list[str]) -> None:
        for name in upload:
            self.published[name] = (out / name).read_bytes()

    def test_first_publish_rotates_then_a_delta_follows(self) -> None:
        import git_bundle_list as gbl
        out = self.tmp / "out1"
        first = gbl.plan(self.src, self.built, out, "https://edge/x", 1_000_000, fetch=self.fetch)
        self.assertTrue(first["rotated"])
        self.assertEqual(first["upload"], [gbl.BASE, gbl.LIST])
        listed = gbl.parse_list((out / gbl.LIST).read_text())
        self.assertEqual(listed["bundle"]["heuristic"], "creationToken")
        self.assertEqual(listed["base"]["creationtoken"], "1000000")
        self.assertEqual(listed["base"]["filter"], "blob:none")
        self.publish(out, first["upload"])

        self.commit("two")
        second = gbl.plan(self.src, self.built, self.tmp / "out2", "https://edge/x", 1_000_100, fetch=self.fetch)
        self.assertFalse(second["rotated"])
        self.assertTrue(second["delta"])
        self.assertEqual(second["upload"], [gbl.DELTA, gbl.LIST])
        listed = gbl.parse_list((self.tmp / "out2" / gbl.LIST).read_text())
        self.assertEqual(listed["base"]["creationtoken"], "1000000")
        self.assertEqual(listed["delta"]["creationtoken"], "1000100")
        # The delta needs the base's tip and carries only what came after it.
        header = (self.tmp / "out2" / gbl.DELTA).read_bytes().split(b"PACK", 1)[0].decode()
        self.assertIn("-" + gbl.header_tips(self.published[gbl.BASE])[0], header)

    def test_an_old_base_rotates(self) -> None:
        import git_bundle_list as gbl
        self.published[gbl.LIST] = gbl.render_list([("base", gbl.BASE, 1)]).encode()
        self.published[gbl.BASE] = self.built.read_bytes()
        got = gbl.plan(self.src, self.built, self.tmp / "o", "https://edge/x", 1 + gbl.BASE_MAX_DAYS * 86400,
                       fetch=self.fetch)
        self.assertTrue(got["rotated"])
        self.assertIn("days old", got["why"])

    def test_nothing_new_since_the_base_lists_the_base_alone(self) -> None:
        import git_bundle_list as gbl
        self.published[gbl.LIST] = gbl.render_list([("base", gbl.BASE, 50)]).encode()
        self.published[gbl.BASE] = self.built.read_bytes()
        got = gbl.plan(self.src, self.built, self.tmp / "o", "https://edge/x", 60, fetch=self.fetch)
        self.assertEqual((got["rotated"], got["delta"], got["upload"]), (False, False, [gbl.LIST]))

    def test_a_guest_clones_from_it_and_a_later_fetch_takes_only_the_delta(self) -> None:
        import git_bundle_list as gbl
        out = self.tmp / "edge"
        self.publish(out, gbl.plan(self.src, self.built, out, "https://edge/x", 100, fetch=self.fetch)["upload"])
        guest = self.tmp / "guest.git"
        env_url = f"file://{out}/{gbl.LIST}"
        self.git("clone", "-q", "--bare", "--filter=blob:none", f"--bundle-uri={env_url}", f"file://{self.src}",
                 str(guest), cwd=self.tmp)
        self.assertEqual(self.git("config", "fetch.bundleCreationToken", cwd=guest).strip(), "100")
        self.commit("two")
        self.publish(out, gbl.plan(self.src, self.built, out, "https://edge/x", 200, fetch=self.fetch)["upload"])
        self.git("fetch", "-q", "origin", cwd=guest)
        self.assertEqual(self.git("config", "fetch.bundleCreationToken", cwd=guest).strip(), "200")
        self.assertEqual(self.git("rev-parse", "refs/bundles/heads/main", cwd=guest).strip(),
                         self.git("rev-parse", "HEAD").strip())


if __name__ == "__main__":
    unittest.main()
