#!/usr/bin/env python3
"""A media tour's before tree reads its submodules from local copies, not the network.

Run 45837430593 (job 139976029698) lost before tree 8f9660c2's ghostty-next clone: the github.com
transfer died ("curl 18"), then every retry hit a dead local proxy in 0 ms, so 3 What's New befores
had no app. scripts/cmux-next/media/submodules-from-local.sh checks a tree's submodules out from a
donor checkout's git directories or the fleet's submodule mirrors over file://.

Each test builds a superproject whose .gitmodules names https://github.com/ URLs and forbids https
(protocol.https.allow=never), so any network read fails the test.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "cmux-next" / "media" / "submodules-from-local.sh"
WORKFLOW = ROOT / ".github" / "workflows" / "cmux-next-media.yml"

SUB_URL = "https://github.com/example/ghostty-next.git"
NESTED_URL = "https://github.com/example/nested.git"


def git(*args: str, cwd: Path | None = None, env: dict | None = None) -> str:
    return subprocess.run(["git", *args], cwd=cwd, env=env, check=True,
                          capture_output=True, text=True).stdout.strip()


class SubmodulesFromLocalTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_CONFIG")}
        home = self.tmp / "home"
        home.mkdir()
        self.env.update(HOME=str(home), GIT_CONFIG_NOSYSTEM="1",
                        GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t",
                        GIT_COMMITTER_EMAIL="t@t",
                        GLAEDA_GIT_MIRROR_DIR=str(self.tmp / "no-fleet-mirror"))
        gc = home / ".gitconfig"
        gc.write_text("[protocol \"https\"]\n\tallow = never\n[init]\n\tdefaultBranch = main\n")

        # nested <- sub <- super, as real repos on disk.
        self.nested = self.repo("nested-src", {"n.txt": "n"})
        self.sub = self.repo("sub-src", {"s.txt": "s"})
        self.add_submodule(self.sub, self.nested, NESTED_URL, "nested")
        self.sup = self.repo("super-src", {"README": "r"})
        self.add_submodule(self.sup, self.sub, SUB_URL, "ghostty-next")

        # A donor: a superproject .git whose modules/ holds the submodules (as the head checkout does),
        # built here by cloning the sources and placing their git dirs where git keeps them.
        self.donor = self.tmp / "donor.git"
        (self.donor / "modules").mkdir(parents=True)
        git("clone", "-q", "--bare", str(self.sub), str(self.donor / "modules" / "ghostty-next"), env=self.env)
        git("--git-dir", str(self.donor / "modules" / "ghostty-next"), "config", "remote.origin.url",
            SUB_URL, env=self.env)
        nested_dir = self.donor / "modules" / "ghostty-next" / "modules" / "nested"
        git("clone", "-q", "--bare", str(self.nested), str(nested_dir), env=self.env)
        git("--git-dir", str(nested_dir), "config", "remote.origin.url", NESTED_URL, env=self.env)

        self.tree = self.tmp / "before-tree"
        git("clone", "-q", str(self.sup), str(self.tree), env=self.env)

    def repo(self, name: str, files: dict) -> Path:
        p = self.tmp / name
        p.mkdir()
        git("init", "-q", cwd=p, env=self.env)
        for f, body in files.items():
            (p / f).write_text(body)
        git("add", ".", cwd=p, env=self.env)
        git("commit", "-qm", "init", cwd=p, env=self.env)
        return p

    def add_submodule(self, parent: Path, child: Path, url: str, path: str) -> None:
        env = dict(self.env, GIT_ALLOW_PROTOCOL="file")
        git("-c", "protocol.file.allow=always", "submodule", "add", "-q", str(child), path, cwd=parent, env=env)
        git("config", "-f", ".gitmodules", f"submodule.{path}.url", url, cwd=parent, env=env)
        git("add", ".gitmodules", cwd=parent, env=env)
        git("commit", "-qm", f"add {path}", cwd=parent, env=env)

    def run_script(self, *donors: Path) -> subprocess.CompletedProcess:
        return subprocess.run(["bash", str(SCRIPT), str(self.tree), *map(str, donors)], env=self.env,
                              capture_output=True, text=True)

    def test_checks_out_nested_submodules_from_the_donor_with_no_network(self):
        r = self.run_script(self.donor)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual((self.tree / "ghostty-next" / "s.txt").read_text(), "s")
        self.assertEqual((self.tree / "ghostty-next" / "nested" / "n.txt").read_text(), "n")
        self.assertIn("from the local copy", r.stdout)

    def test_reads_the_fleet_mirror_by_its_glaeda_url(self):
        root = self.tmp / "fleet" / "submodules"
        root.mkdir(parents=True)
        for src, url, name in ((self.sub, SUB_URL, "ghostty-next"), (self.nested, NESTED_URL, "nested")):
            d = root / f"{name}.git"
            git("clone", "-q", "--bare", str(src), str(d), env=self.env)
            git("--git-dir", str(d), "config", "glaeda.url", url, env=self.env)
        self.env["GLAEDA_GIT_MIRROR_DIR"] = str(self.tmp / "fleet")
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual((self.tree / "ghostty-next" / "nested" / "n.txt").read_text(), "n")

    def test_a_copy_without_the_pin_is_not_used(self):
        # The donor lacks the superproject's newer pin: the script falls through to the URL,
        # which https=never refuses, so it fails instead of checking out a wrong commit.
        (self.sub / "s.txt").write_text("s2")
        git("commit", "-qam", "newer", cwd=self.sub, env=self.env)
        git("-C", "ghostty-next", "pull", "-q", cwd=self.sup,
            env=dict(self.env, GIT_ALLOW_PROTOCOL="file"))
        git("commit", "-qam", "bump", cwd=self.sup, env=self.env)
        git("pull", "-q", cwd=self.tree, env=self.env)
        r = self.run_script(self.donor)
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn("ghostty-next.git: from the local copy", r.stdout)

    def test_the_workflow_reads_before_trees_through_it(self):
        text = WORKFLOW.read_text()
        self.assertIn("submodules-from-local.sh", text)
        body = text.split("submodules() {", 1)[1].split("\n          }", 1)[0]
        self.assertIn("submodules-from-local.sh", body)
        self.assertNotIn("git -C \"$1\" submodule update", body)


if __name__ == "__main__":
    unittest.main()
