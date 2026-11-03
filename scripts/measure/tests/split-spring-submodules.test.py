#!/usr/bin/env python3
"""Exercise submodule cache reuse with tiny local Git repositories, without a build.

Run: python3 scripts/measure/tests/split-spring-submodules.test.py
The performance count is upstream upload-pack sessions (clone or fetch), not
local reference reads. Both baseline and helper use the same fixture and Git.
"""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


HELPER = Path(__file__).resolve().parents[1] / "split-spring-submodules.py"
MODULES = ("ghostty", "ghostty-next")


class SubmoduleCacheTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="split spring submodules ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.env = {
            key: value for key, value in os.environ.items()
            if not key.startswith("GIT_")
        }
        self.env.update({
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_SYSTEM": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_ALLOW_PROTOCOL": "file",
            "GIT_AUTHOR_NAME": "Submodule fixture",
            "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
            "GIT_COMMITTER_NAME": "Submodule fixture",
            "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
            # Never invoke the agent host's installed global hooks in fixtures.
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "core.hooksPath",
            "GIT_CONFIG_VALUE_0": os.devnull,
        })
        self.upstreams = {}
        self.pins = {}
        for module in MODULES:
            upstream = self.root / (module + " upstream")
            upstream.mkdir()
            self.git(upstream, "init", "-b", "main")
            self.pins[module] = self.commit_file(upstream, "initial " + module)
            self.upstreams[module] = upstream
        self.parent = self.root / "parent"
        self.parent.mkdir()
        self.git(self.parent, "init", "-b", "main")
        for module, upstream in self.upstreams.items():
            self.git(self.parent, "submodule", "add", upstream.as_uri(), module)
        self.git(self.parent, "commit", "-m", "Pin initial submodules")
        self.cache = self.root / "cache"

    def run_command(self, cwd, args, env=None):
        result = subprocess.run(
            args, cwd=cwd, env=env or self.env, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30,
        )
        self.assertEqual(result.returncode, 0, f"{args}\n{result.stdout}\n{result.stderr}")
        return result.stdout.strip()

    def git(self, cwd, *args):
        return self.run_command(cwd, ["git", *args])

    def commit_file(self, repo, value):
        (repo / "fixture.txt").write_text(value + "\n")
        self.git(repo, "add", "fixture.txt")
        self.git(repo, "commit", "-m", value)
        return self.git(repo, "rev-parse", "HEAD")

    def checkout(self, name):
        checkout = self.root / name
        self.git(self.root, "clone", "--no-local", str(self.parent), str(checkout))
        return checkout

    def measured(self, checkout, helper=True):
        trace = self.root / (checkout.name + ".trace.jsonl")
        trace.unlink(missing_ok=True)
        env = dict(self.env, GIT_TRACE2_EVENT=str(trace))
        if helper:
            args = [sys.executable, str(HELPER), "--cache", str(self.cache), *MODULES]
        else:
            args = ["git", "submodule", "update", "--init", "--depth", "1", *MODULES]
        self.run_command(checkout, args, env)
        counts = dict.fromkeys(MODULES, 0)
        for line in trace.read_text().splitlines():
            event = json.loads(line)
            if event.get("event") != "child_start":
                continue
            command = " ".join(event.get("argv", []))
            if "git-upload-pack" not in command:
                continue
            for module, upstream in self.upstreams.items():
                if str(upstream) in command:
                    counts[module] += 1
        return counts

    def assert_pins(self, checkout, pins):
        for module, pin in pins.items():
            self.assertEqual(self.git(checkout / module, "rev-parse", "HEAD"), pin)
            expected = self.git(self.upstreams[module], "show", pin + ":fixture.txt")
            self.assertEqual((checkout / module / "fixture.txt").read_text().strip(), expected)
            alternate = Path(self.git(checkout / module, "rev-parse", "--git-path", "objects/info/alternates"))
            if not alternate.is_absolute():
                alternate = checkout / module / alternate
            self.assertFalse(alternate.exists(), "checkout must not depend on mutable cache objects")

    def test_reuse_exact_pins_and_refresh_initialized_submodule(self):
        baseline = self.measured(self.checkout("baseline"), helper=False)
        self.assertEqual(baseline, {module: 1 for module in MODULES})
        cold_checkout = self.checkout("cold")
        cold = self.measured(cold_checkout)
        self.assertEqual(cold, baseline)
        self.assert_pins(cold_checkout, self.pins)

        for name in ("warm one", "warm two"):
            checkout = self.checkout(name)
            warm = self.measured(checkout)
            self.assertEqual(warm, {module: 0 for module in MODULES})
            self.assert_pins(checkout, self.pins)
        before, after = sum(baseline.values()), sum(warm.values())
        print(
            f"PERFORMANCE upstream Git transfers per fresh checkout | before={before} | "
            f"after={after} | delta={after - before} ({(after - before) / before:.0%}) | "
            "tiny local submodules", flush=True,
        )

        # Publish a commit after warming: only the changed gitlink may fetch.
        changed_pins = dict(self.pins)
        changed_pins["ghostty"] = self.commit_file(self.upstreams["ghostty"], "updated ghostty")
        self.git(self.parent, "update-index", "--cacheinfo", "160000", changed_pins["ghostty"], "ghostty")
        self.git(self.parent, "commit", "-m", "Advance one gitlink")
        changed_checkout = self.checkout("changed pin")
        changed = self.measured(changed_checkout)
        self.assertEqual(changed, {"ghostty": 1, "ghostty-next": 0})
        self.assert_pins(changed_checkout, changed_pins)

        # A reused parent checkout still has the old initialized submodule HEAD.
        self.git(cold_checkout, "fetch", "origin")
        self.git(cold_checkout, "checkout", "--detach", "origin/main")
        self.assertEqual(self.git(cold_checkout / "ghostty", "rev-parse", "HEAD"), self.pins["ghostty"])
        refreshed = self.measured(cold_checkout)
        self.assertEqual(refreshed, {module: 0 for module in MODULES})
        self.assert_pins(cold_checkout, changed_pins)

        # A stopped clone can have the right HEAD but no files. Matching the
        # gitlink alone must not make a retry silently accept an empty tree.
        interrupted = self.checkout("interrupted clone")
        self.git(interrupted, "submodule", "init", "--", "ghostty")
        url = self.git(interrupted, "config", "--get", "submodule.ghostty.url")
        mirror = self.cache / hashlib.sha256(url.encode()).hexdigest()
        self.git(interrupted, "clone", "--no-checkout", "--no-hardlinks", str(mirror), "ghostty")
        self.git(interrupted / "ghostty", "remote", "set-url", "origin", url)
        self.assertEqual(self.git(interrupted / "ghostty", "rev-parse", "HEAD"), changed_pins["ghostty"])
        self.assertFalse((interrupted / "ghostty" / "fixture.txt").exists())
        recovered = self.measured(interrupted)
        self.assertEqual(recovered, {module: 0 for module in MODULES})
        self.assert_pins(interrupted, changed_pins)


if __name__ == "__main__":
    unittest.main()
