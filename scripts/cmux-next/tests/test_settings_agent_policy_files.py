#!/usr/bin/env python3
"""schemas/settings/source/agent-policy/: one <key>.json per setting, so two PRs that each add a setting never conflict.

The single agent-policy.json was a list of groups every new setting edited: 30 of the 118 PRs that touched it in
the 14 days to 2026-11-25 conflicted on GitHub against the base they opened on (scripts/ci/conflict_hotspots.py);
replayed as one file per key, 2 did (both edited the same key). gen-settings-sources.py reads the directory and
groups keys with the same agent and why, so the generated Swift (agentSettableKeys, agentRefusedKeys) is unchanged.
"""
import importlib.util
import json
import os
import subprocess
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
SCRIPT = os.path.join(ROOT, "scripts/cmux-next/gen-settings-sources.py")
POLICY = os.path.join(ROOT, "schemas/settings/source/agent-policy")


def load():
    spec = importlib.util.spec_from_file_location("gen_settings_sources_policy", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class AgentPolicyFiles(unittest.TestCase):
    def test_the_monolith_is_gone_and_every_file_is_one_key(self):
        self.assertFalse(os.path.exists(POLICY + ".json"))
        names = sorted(os.listdir(POLICY))
        self.assertIn("_refusals.json", names)
        for name in names:
            with self.subTest(name=name):
                self.assertTrue(name.endswith(".json"), name)
                with open(os.path.join(POLICY, name), encoding="utf-8") as handle:
                    entry = json.load(handle)
                if name != "_refusals.json":
                    self.assertLessEqual(set(entry), {"agent", "why"})
                    self.assertIn("agent", entry)

    def test_the_generator_groups_every_key_once(self):
        module = load()
        data = module.load_agent_policy()
        keys = [key for group in data["groups"] for key in group["keys"]]
        self.assertEqual(len(keys), len(set(keys)))
        self.assertEqual(sorted(keys), sorted(name[:-5] for name in os.listdir(POLICY) if name != "_refusals.json"))
        self.assertEqual(module.section_row_keys() - set(keys), set())
        for group in data["groups"]:
            self.assertEqual(len({(group["agent"], group.get("why"))}), 1)

    def test_two_branches_that_each_add_a_key_merge_without_a_conflict(self):
        env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com", "GIT_COMMITTER_NAME": "t",
               "GIT_COMMITTER_EMAIL": "t@example.com", "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_SYSTEM": os.devnull}
        with tempfile.TemporaryDirectory() as repo:
            def git(*args):
                return subprocess.run(["git", "-C", repo, *args], env=env, text=True, capture_output=True, check=True)

            def write(key, agent):
                path = os.path.join(repo, "agent-policy", key + ".json")
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "w", encoding="utf-8") as handle:
                    json.dump({"agent": agent}, handle, indent=2)
                    handle.write("\n")
                git("add", "-A")
                git("commit", "-q", "-m", key)

            git("init", "-q", "-b", "main")
            for name in sorted(os.listdir(POLICY))[:40]:
                if name != "_refusals.json":
                    write(name[:-5], "settable")
            git("checkout", "-q", "-b", "one")
            write("appearance.zzOne", "settable")
            git("checkout", "-q", "main")
            git("checkout", "-q", "-b", "two")
            write("appearance.zzTwo", "privacy")
            merged = subprocess.run(["git", "-C", repo, "merge-tree", "--write-tree", "one", "two"], env=env,
                                    text=True, capture_output=True)
            self.assertEqual(merged.returncode, 0, merged.stdout)


if __name__ == "__main__":
    unittest.main()
