#!/usr/bin/env python3
"""tests/guard_delta.py and the scan guards' changed-files-only mode, on throwaway git repos.

Each case checks the changed-files answer against the whole scan's: what the whole scan reports on the head and
not on the base is what the changed files report.

Run it: python3 tests/test_guard_delta.py
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import guard_delta  # noqa: E402
import test_network_allowlist as network  # noqa: E402
import test_outbound_hosts as outbound  # noqa: E402

DOC = "docs/privacy.md"
A = "Packages/Shared/Net/Sources/Api.swift"
B = "Packages/Shared/Net/Sources/Push.swift"


def row(host: str) -> str:
    return f"| `{host}` | connects | sends x |"


class Repo:
    def __init__(self, files: dict[str, str]):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.git("init", "-q")
        self.git("config", "user.email", "t@t")
        self.git("config", "user.name", "t")
        self.write(files)
        self.base = self.commit()

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-C", str(self.root), *args], check=True, capture_output=True,
                              text=True).stdout.strip()

    def write(self, files: dict[str, str | None]) -> None:
        for rel, text in files.items():
            path = self.root / rel
            if text is None:
                path.unlink()
                continue
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        self.git("add", "-A")

    def commit(self) -> str:
        self.git("commit", "-q", "-m", "x", "--allow-empty")
        return self.git("rev-parse", "HEAD")


def doc(*hosts: str) -> str:
    return "\n".join(row(h) for h in hosts) + "\n"


def swift(*hosts: str) -> str:
    return "".join(f'let u{i} = URL(string: "https://{h}/v1")!\n' for i, h in enumerate(hosts))


class Case(unittest.TestCase):
    def repo(self, files: dict[str, str]) -> Repo:
        repo = Repo(files)
        self.addCleanup(repo.tmp.cleanup)
        return repo


class Changed(Case):
    def test_no_base_unknown_base_or_a_rule_change_scans_everything(self):
        repo = self.repo({A: swift("api.cmux.dev"), "tests/rule.py": "x = 1\n"})
        old = {k: os.environ.pop(k, None) for k in ("CMUX_GUARDS_BASE_SHA", "GITHUB_EVENT_NAME")}
        try:
            self.assertIsNone(guard_delta.base_commit(repo.root))
            os.environ["CMUX_GUARDS_BASE_SHA"] = "0" * 40
            self.assertIsNone(guard_delta.base_commit(repo.root))
            os.environ["CMUX_GUARDS_BASE_SHA"] = repo.base
            self.assertEqual(guard_delta.base_commit(repo.root), repo.base)
            os.environ["GITHUB_EVENT_NAME"] = "pull_request"
            self.assertEqual(guard_delta.base_commit(repo.root), repo.base)
            os.environ["GITHUB_EVENT_NAME"] = "push"  # the branch's own run scans everything
            self.assertIsNone(guard_delta.base_commit(repo.root))
        finally:
            for k, v in old.items():
                os.environ.pop(k, None)
                if v is not None:
                    os.environ[k] = v
        repo.write({A: swift("api.cmux.dev", "new.cmux.dev")})
        self.assertEqual(guard_delta.changed(["tests/rule.py"], repo.root, repo.base), [A])
        repo.write({"tests/rule.py": "x = 2\n"})
        self.assertIsNone(guard_delta.changed(["tests/rule.py"], repo.root, repo.base))
        self.assertIsNone(guard_delta.changed(["tests/"], repo.root, repo.base))

    def test_an_uncommitted_edit_and_a_deleted_file_count(self):
        repo = self.repo({A: swift("api.cmux.dev"), B: swift("push.cmux.dev")})
        (repo.root / A).write_text(swift("other.cmux.dev"))  # not staged
        repo.write({B: None})
        self.assertEqual(guard_delta.changed([], repo.root, repo.base), [A, B])
        self.assertEqual(guard_delta.text_at_head([A, B], repo.root), {A: swift("other.cmux.dev")})
        self.assertEqual(guard_delta.blobs_at(repo.base, [A, B], repo.root),
                         {A: swift("api.cmux.dev"), B: swift("push.cmux.dev")})

    def test_symlinks_and_non_utf8_are_left_out(self):
        repo = self.repo({A: swift("api.cmux.dev")})
        (repo.root / B).parent.mkdir(parents=True, exist_ok=True)
        os.symlink("Api.swift", repo.root / B)
        (repo.root / "Packages/Shared/Net/Sources/Bin.swift").write_bytes(b"\xff\xfe x")
        repo.git("add", "-A")
        rev = repo.commit()
        rels = [A, B, "Packages/Shared/Net/Sources/Bin.swift"]
        self.assertEqual(set(guard_delta.blobs_at(rev, rels, repo.root)), {A})
        self.assertEqual(set(guard_delta.text_at_head(rels, repo.root)), {A})


class OutboundHosts(Case):
    def outcome(self, base: dict[str, str], head: dict[str, str | None]) -> tuple[list[str], list[str]]:
        """(changed-files problems, whole-scan problems the base did not have)."""
        repo = self.repo(base)
        before = set(outbound.problems(outbound.scan(repo.root), (repo.root / DOC).read_text()))
        repo.write(head)
        paths = guard_delta.changed(outbound.RULES, repo.root, repo.base)
        self.assertIsNotNone(paths)
        text = (repo.root / DOC).read_text()
        got = outbound.change_problems(repo.base, paths, text, repo.root)
        whole = [p for p in outbound.problems(outbound.scan(repo.root), text) if p not in before]
        return got, whole

    def check(self, base: dict[str, str], head: dict[str, str | None], n: int) -> list[str]:
        got, whole = self.outcome(base, head)
        self.assertEqual(len(got), n, got)
        self.assertEqual([p.split(":")[0] for p in got], [p.split(":")[0] for p in whole], (got, whole))
        return got

    def test_a_new_host_with_no_row_fails(self):
        got = self.check({DOC: doc("api.cmux.dev"), A: swift("api.cmux.dev")},
                         {A: swift("api.cmux.dev", "new.cmux.dev")}, 1)
        self.assertIn("new.cmux.dev: not in docs/privacy.md", got[0])

    def test_a_host_still_named_elsewhere_is_not_stale(self):
        self.check({DOC: doc("api.cmux.dev"), A: swift("api.cmux.dev"), B: swift("api.cmux.dev")},
                   {A: swift()}, 0)

    def test_a_host_named_nowhere_now_is_stale(self):
        got = self.check({DOC: doc("api.cmux.dev"), A: swift("api.cmux.dev"), B: swift("push.cmux.dev")},
                         {A: None, DOC: doc("api.cmux.dev", "push.cmux.dev")}, 1)
        self.assertIn("api.cmux.dev: listed in docs/privacy.md but no longer", got[0])

    def test_a_removed_row_whose_host_an_unchanged_file_names_fails(self):
        got = self.check({DOC: doc("api.cmux.dev", "push.cmux.dev"), A: swift("api.cmux.dev"),
                          B: swift("push.cmux.dev")}, {DOC: doc("api.cmux.dev")}, 1)
        self.assertIn("push.cmux.dev: not in docs/privacy.md, named at " + B, got[0])

    def test_an_added_row_no_code_names_is_stale(self):
        self.check({DOC: doc("api.cmux.dev"), A: swift("api.cmux.dev")},
                   {DOC: doc("api.cmux.dev", "gone.cmux.dev")}, 1)

    def test_a_built_host_is_looked_up_by_its_fixed_text(self):
        built = 'let u = "https://\\(site).Atlassian.net/x"\n'
        self.check({DOC: doc("*.atlassian.net"), A: built, B: built}, {A: swift()}, 0)
        self.check({DOC: doc("*.atlassian.net"), A: built, B: swift()}, {A: swift()}, 1)

    def test_a_problem_the_base_had_in_an_untouched_file_is_not_reported(self):
        self.check({DOC: doc("api.cmux.dev", "stale.cmux.dev"), A: swift("api.cmux.dev"), B: swift("old.cmux.dev")},
                   {A: swift("api.cmux.dev") + "// edit\n"}, 0)


ALLOW = "config/network/allowlist.json"
CATALOG = "config/iroh/managed-relay-catalog.json"
ICE_FILE = "cmux-next-ios/backend/src/ice.ts"


def allow(*entries: tuple[str, str]) -> str:
    return json.dumps({"hosts": [{"host": h, "named_in": how} for h, how in entries]})


def ice(*hosts: str) -> str:
    return "".join(f'const s{i} = "stun:{h}:3478";\n' for i, h in enumerate(hosts))


class NetworkAllowlist(Case):
    def check(self, base: dict[str, str], head: dict[str, str | None], n: int) -> list[str]:
        files = {CATALOG: json.dumps({"relays": []}), DOC: doc("api.cmux.dev", "push.cmux.dev", "new.cmux.dev"),
                 **base}
        repo = self.repo(files)

        def whole() -> list[str]:
            data, privacy = network.load(repo.root / ALLOW), (repo.root / DOC).read_text()
            found = outbound.scan(repo.root)
            return network.coverage_problems(data, network.code_hosts(found, privacy), network.ice_hosts(repo.root),
                                             set(), set(found))
        before = {p.split(" ")[0] for p in whole()}
        repo.write(head)
        paths = guard_delta.changed(network.RULES, repo.root, repo.base)
        self.assertIsNotNone(paths)
        got = network.change_problems(repo.base, paths, network.load(repo.root / ALLOW), (repo.root / DOC).read_text(),
                                      set(), repo.root)
        new = [p for p in whole() if p.split(" ")[0] not in before]
        self.assertEqual([p.split(" ")[0] for p in got], [p.split(" ")[0] for p in new], (got, new))
        self.assertEqual(len(got), n, got)
        return got

    def test_a_new_connectivity_host_with_no_entry_fails(self):
        self.check({ALLOW: allow(("api.cmux.dev", "code")), A: swift("api.cmux.dev")},
                   {A: swift("api.cmux.dev", "new.cmux.dev")}, 1)
        self.check({ALLOW: allow(), ICE_FILE: ice()}, {ICE_FILE: ice("stun.cmux.dev")}, 1)

    def test_a_host_still_named_elsewhere_is_not_stale(self):
        self.check({ALLOW: allow(("api.cmux.dev", "code")), A: swift("api.cmux.dev"), B: swift("api.cmux.dev")},
                   {A: swift()}, 0)
        self.check({ALLOW: allow(("stun.cmux.dev", "code")), A: swift("stun.cmux.dev"), ICE_FILE: ice("stun.cmux.dev")},
                   {A: swift()}, 0)

    def test_a_host_named_nowhere_now_is_stale(self):
        got = self.check({ALLOW: allow(("api.cmux.dev", "code"), ("push.cmux.dev", "code")), A: swift("api.cmux.dev"),
                          B: swift("push.cmux.dev")}, {A: None}, 1)
        self.assertIn("api.cmux.dev: named_in code", got[0])
        self.check({ALLOW: allow(("stun.cmux.dev", "code")), ICE_FILE: ice("stun.cmux.dev")}, {ICE_FILE: ice()}, 1)

    def test_a_problem_the_base_had_is_not_reported(self):
        self.check({ALLOW: allow(("gone.cmux.dev", "code")), A: swift("api.cmux.dev"), B: swift("new.cmux.dev")},
                   {A: swift("api.cmux.dev") + "// edit\n"}, 0)

    def test_a_rule_change_scans_everything(self):
        repo = self.repo({ALLOW: allow(), CATALOG: json.dumps({"relays": []}), DOC: doc("api.cmux.dev")})
        repo.write({ALLOW: allow(("api.cmux.dev", "code"))})
        self.assertIsNone(guard_delta.changed(network.RULES, repo.root, repo.base))


if __name__ == "__main__":
    unittest.main()
