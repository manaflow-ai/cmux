#!/usr/bin/env python3
"""scripts/cmux-next/swift-port-rank.py on a throwaway git repository.

A pure logic declaration (no platform import, no platform call) ranks by its lines times its file's commits; a file
that imports AppKit or a declaration that calls NSView is not pure; a file in a package an iOS app reaches (transitively) is iOS-shared and left out of the ranking; a mirror
declaration whose name the SDK schema
has (or the swift_app bindings name) is generated-now, one only a Rust struct names is schema-first, the rest are port.

Run it after a change to the script:
  python3 -I scripts/cmux-next/tests/test_swift_port_rank.py
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

_git_fixture_env = importlib.util.spec_from_file_location(
    "git_fixture_env",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "tests", "git_fixture_env.py"),
)
git_fixture_env = importlib.util.module_from_spec(_git_fixture_env)
_git_fixture_env.loader.exec_module(git_fixture_env)

SCRIPTS = Path(__file__).resolve().parents[1]
SRC = "Packages/macOS/CmuxNext/Sources"
TABLE = "plans/cmux-next/swift-logic-classes.tsv"
HEADER = "module\tkind\tname\tordinal\tclass\tlogic_share\tmirror_share\tpath\treason\n"

spec = importlib.util.spec_from_file_location("cmux_next_swift_port_rank_under_test", SCRIPTS / "swift-port-rank.py")
rank = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = rank
spec.loader.exec_module(rank)


class PortRankTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="cmux-swift-port-rank-")
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.repo = root / "repo"
        self.repo.mkdir()
        config = root / "gitconfig"
        config.write_text("[user]\n\tname = Fixture\n\temail = fixture@example.com\n[maintenance]\n\tauto = false\n"
                          "[gc]\n\tauto = 0\n")
        saved = {k: os.environ.get(k) for k in ("GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_GLOBAL", "HOME")}
        os.environ.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=str(config), HOME=str(root))
        self.addCleanup(lambda: [os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)
                                 for k, v in saved.items()])
        self.env = git_fixture_env.fixture_env({k: v for k, v in os.environ.items() if not k.startswith("GIT_")})
        self.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=str(config), HOME=str(root))
        self.git("init", "--quiet", "--initial-branch=feat-cmux-next")

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], env=self.env, text=True, capture_output=True,
                              check=True).stdout.strip()

    def write(self, relative, text):
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit(self):
        self.git("add", "-A")
        self.git("commit", "--quiet", "--allow-empty", "--no-verify", "-m", "change")

    def run_rank(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(rank.main(["--repo", str(self.repo), "--json"]), 0)
        return json.loads(out.getvalue())

    def test_pure_logic_ranks_by_churn_and_mirror_lines_fall_in_buckets(self):
        mod = f"{SRC}/CmuxNextDomain"
        self.write(f"{mod}/Hot.swift", "import Foundation\nstruct Hot {\n    let a = 1\n}\n")  # 3 lines, pure
        self.write(f"{mod}/Big.swift", "struct Big {\n" + "    let a = 1\n" * 8 + "}\n")  # 10 lines, pure
        self.write(f"{mod}/Mac.swift", "import AppKit\nstruct Mac {\n    let a = 1\n}\n")  # platform import
        self.write(f"{mod}/Call.swift", "struct Call {\n    let v = NSView()\n}\n")  # platform call
        self.write(f"{mod}/Wire.swift", "struct ListAgentsRequest {\n    let a: Int\n}\n"  # a bindings request: 3
                   "struct ActivitySnapshot {\n    let b: Int\n}\n"  # schema type, Snapshot suffix: 3
                   "struct RustOnly {\n    let c: Int\n}\n"  # a Rust struct only: 3
                   "final class Feed {\n    var d = 0\n}\n")  # neither: 3
        rows = [("CmuxNextDomain", "struct", n, 0, "MIRROR", 0, 100, f"{mod}/Wire.swift", "wire")
                for n in ("ListAgentsRequest", "ActivitySnapshot", "RustOnly")]
        rows.append(("CmuxNextDomain", "class", "Feed", 0, "MIXED", 0, 100, f"{mod}/Wire.swift", "state"))
        self.write(TABLE, HEADER + "".join("\t".join(str(v) for v in r) + "\n" for r in rows))
        self.write(rank.SCHEMA, json.dumps({"types": {"Activity": {}}, "commands": {"agent.list_agents": {}},
                                            "events": {}}))
        self.write(rank.BINDINGS, json.dumps({"types": {}, "families": {"Agents": {"requests": {
            "agent.list": {"name": "ListAgentsRequest"}}}}}))
        # ios/CmuxiOS reaches Packages/Shared/Core, which reaches the counted CmuxNextShared folder: both are
        # iOS-shared (the counter only reads CmuxNext's closure, so the fixture's shared code sits in it).
        self.write("ios/CmuxiOS/Package.swift", 'Package(dependencies: [.package(path: "../../Packages/Shared/Core")])\n')
        self.write("Packages/Shared/Core/Package.swift", 'dependencies: [.package(path: "../../macOS/CmuxNext/Sources/'
                   'CmuxNextShared")]\n')
        self.write(f"{SRC}/CmuxNextShared/Shared.swift", "struct Shared {\n" + "    let a = 1\n" * 30 + "}\n")
        self.write("crates/x/src/lib.rs", "pub struct RustOnly { c: i64 }\n")
        self.commit()
        for i in range(4):  # Hot.swift gets 4 more commits: 3 lines x 5 = 15 > Big's 10 x 1
            self.write(f"{mod}/Hot.swift", f"import Foundation\nstruct Hot {{\n    let a = {i}\n}}\n")
            self.commit()
        r = self.run_rank()
        self.assertEqual(r["ios_shared"]["pure_logic_lines"], 32)
        self.assertEqual(r["ios_shared"]["packages"], {"Packages/Shared/Core": ["CmuxiOS"],
                                                       f"{SRC}/CmuxNextShared": ["CmuxiOS"], "ios/CmuxiOS": ["CmuxiOS"]})
        self.assertNotIn("Shared.swift", [f["path"].rsplit("/", 1)[1] for f in r["files"]])  # mac-only by default
        files = {f["path"].rsplit("/", 1)[1]: f for f in r["files"]}
        self.assertEqual([f["path"].rsplit("/", 1)[1] for f in r["files"]][:2], ["Hot.swift", "Big.swift"])
        self.assertEqual((files["Hot.swift"]["pure"], files["Hot.swift"]["churn"], files["Hot.swift"]["score"]),
                         (3, 5, 15))
        self.assertEqual((files["Mac.swift"]["pure"], files["Mac.swift"]["platform_imports"]), (0, ["AppKit"]))
        self.assertEqual((files["Call.swift"]["pure"], files["Call.swift"]["logic"]), (0, 3))
        self.assertEqual(r["pure_logic_lines"], 13 + 32)
        self.assertEqual(r["mirror"]["buckets"], {"generated-now": 6, "schema-first": 3, "port": 3})
        self.assertEqual(r["mirror_lines"], 12)

    def test_candidates_strip_one_swift_suffix_and_the_extension_prefix(self):
        self.assertEqual(rank.candidates("Outer.ActivitySnapshot"), ["ActivitySnapshot", "Activity"])
        self.assertEqual(rank.pascal("agent.list_agents"), "AgentListAgents")


if __name__ == "__main__":
    unittest.main()
