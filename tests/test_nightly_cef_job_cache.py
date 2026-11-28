"""app-fetch-chromium-engine.sh keeps the job's CEF in RUNNER_TEMP, where glaeda-disk does not reclaim it.

Run 46142021653 (2026-11-28): glaeda-disk --pressure removed ~/Library/Caches/cmux/cef/cef-157.0.0-cmux.54
between the fetch and the Release embed phase, which has no key to fetch again, and the nightly failed its
third-party notices check. The job's own folder, seeded from the host cache, is what later steps read.
"""
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/nightly-steps/app-fetch-chromium-engine.sh"


class CefJobCacheTest(unittest.TestCase):
    def run_script(self, host_entries):
        work = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, work)
        host = work / "host-cache"
        host.mkdir()
        for name in host_entries:
            (host / name).mkdir()
            (host / name / ".verified").write_text("sha")
        (work / "scripts/cmux-next").mkdir(parents=True)
        (work / "scripts/ci").mkdir(parents=True)
        root_sh = work / "scripts/cmux-next/cef-cache-root.sh"
        root_sh.write_text(f'#!/usr/bin/env bash\necho "${{CMUX_CEF_CACHE_DIR:-{host}}}"\n')
        root_sh.chmod(0o755)
        (work / "scripts/ci/background_build.py").write_text(
            "import os, sys\nopen(os.environ['SEEN'], 'w').write(os.environ.get('CMUX_CEF_CACHE_DIR', ''))\n")
        temp = work / "runner-temp"
        temp.mkdir()
        env = dict(os.environ, RUNNER_TEMP=str(temp), GITHUB_ENV=str(work / "github-env"),
                   SEEN=str(work / "seen"), CMUX_CEF_CACHE_DIR="/stale/elsewhere")
        subprocess.run(["bash", "-e", str(SCRIPT)], cwd=work, env=env, check=True, capture_output=True)
        return work, temp / "cef-cache"

    def test_later_steps_and_the_fetch_read_the_job_folder(self):
        work, job = self.run_script(["cef-157.0.0-cmux.54", "shim"])
        self.assertEqual((work / "github-env").read_text(), f"CMUX_CEF_CACHE_DIR={job}\n")
        self.assertEqual((work / "seen").read_text(), str(job))

    def test_host_cache_seeds_the_job_folder(self):
        work, job = self.run_script(["cef-157.0.0-cmux.54", "shim"])
        self.assertEqual((job / "cef-157.0.0-cmux.54/.verified").read_text(), "sha")
        self.assertTrue((job / "shim").is_dir())
        # The host copy staying or going changes nothing the job reads.
        shutil.rmtree(work / "host-cache")
        self.assertTrue((job / "cef-157.0.0-cmux.54/.verified").exists())

    def test_empty_host_cache_still_sets_the_root(self):
        work, job = self.run_script([])
        self.assertTrue(job.is_dir())
        self.assertIn(str(job), (work / "github-env").read_text())


if __name__ == "__main__":
    unittest.main()
