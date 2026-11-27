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
import test_egress_gate as egress  # noqa: E402
import test_ci_noclobber_sweep as noclobber  # noqa: E402
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


LIST = "tests/egress_ungated.json"
R = "cmux-tui/crates/x/src/a.rs"
S = "cmux-tui/crates/x/src/b.rs"
NEW = "let c = reqwest::Client::new();\n"


def listed(entries: dict[str, dict[str, int]]) -> str:
    return json.dumps({"files": entries})


class EgressGate(Case):
    def check(self, base: dict[str, str], head: dict[str, str | None], n: int) -> list[str]:
        repo = self.repo(base)
        before = set(egress.problems(egress.scan(repo.root), egress.load(repo.root / LIST)))
        repo.write(head)
        paths = guard_delta.changed(egress.RULES, repo.root, repo.base)
        self.assertIsNotNone(paths)
        now = egress.load(repo.root / LIST)
        got = egress.change_problems(repo.base, paths, now, repo.root)
        whole = [p for p in egress.problems(egress.scan(repo.root), now) if p not in before]
        self.assertEqual(got, whole)
        self.assertEqual(len(got), n, got)
        self.assertEqual(egress.check(repo.root, now), egress.problems(egress.scan(repo.root), now))  # no base set
        return got

    def test_a_new_site_fails(self):
        got = self.check({LIST: listed({}), R: "fn f() {}\n"}, {R: NEW}, 1)
        self.assertIn(f"{R}: 1 new reqwest-client", got[0])

    def test_a_listed_site_moved_to_the_gate_needs_the_entry_removed(self):
        self.check({LIST: listed({R: {"reqwest-client": 1}}), R: NEW}, {R: "fn f() {}\n"}, 1)
        self.check({LIST: listed({R: {"reqwest-client": 1}}), R: NEW}, {R: "fn f() {}\n", LIST: listed({})}, 0)

    def test_an_entry_edited_for_an_untouched_file_is_checked(self):
        self.check({LIST: listed({R: {"reqwest-client": 1}}), R: NEW}, {LIST: listed({})}, 1)
        self.check({LIST: listed({R: {"reqwest-client": 1}}), R: NEW, S: NEW},
                   {LIST: listed({R: {"reqwest-client": 1}, S: {"reqwest-client": 1}})}, 0)

    def test_a_deleted_file_with_an_entry_fails_until_the_entry_goes(self):
        self.check({LIST: listed({R: {"reqwest-client": 1}}), R: NEW}, {R: None}, 1)

    def test_a_problem_the_base_had_in_an_untouched_or_touched_file_is_not_reported(self):
        self.check({LIST: listed({}), R: NEW, S: "fn f() {}\n"}, {S: "fn g() {}\n"}, 0)
        self.check({LIST: listed({}), R: NEW}, {R: NEW + "// edit\n"}, 0)
        self.check({LIST: listed({}), R: NEW}, {R: NEW + NEW}, 1)  # one more site is new


SH = "#!/bin/bash\n"
HERE = 'DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\n'
TEMPLATE = 't=$(mktemp "/tmp/x.$USER.XXXXXX")\n'
SHADOW = "mktemp() { echo /tmp/x; }\n"


class NoclobberSweep(Case):
    def check(self, base: dict[str, str], head: dict[str, str | None], n: int) -> list[str]:
        """The changed-files problems: every one the whole scan has and the base had not, and only the whole
        scan's (a touched file's old problem counts: the sweep reads that file whole)."""
        repo = self.repo(base)
        before = set(noclobber.unapproved(noclobber.hits(repo.root), {}))
        repo.write(head)
        paths = guard_delta.changed(noclobber.RULES, repo.root, repo.base)
        self.assertIsNotNone(paths)
        only = noclobber.reach(repo.root, paths)
        got = noclobber.unapproved(noclobber.hits(repo.root, only), {})
        whole = noclobber.unapproved(noclobber.hits(repo.root), {})
        self.assertLessEqual({p for p in whole if p not in before}, set(got), (got, whole))
        self.assertLessEqual(set(got), set(whole))
        self.assertEqual(len(got), n, got)
        return got

    def test_a_new_guessable_name_fails(self):
        self.check({"scripts/a.sh": SH}, {"scripts/a.sh": SH + "f=/tmp/out.$$\n"}, 1)

    def test_a_sourced_file_that_shadows_mktemp_fails_its_untouched_sourcer(self):
        base = {"scripts/a.sh": SH + HERE + '. "$DIR/lib.sh"\n' + TEMPLATE, "scripts/lib.sh": SH + "f() { :; }\n"}
        got = self.check(base, {"scripts/lib.sh": SH + SHADOW}, 1)
        self.assertTrue(got[0].startswith("scripts/a.sh:4:"), got)

    def test_a_source_chain_through_a_file_outside_the_dirs_is_followed(self):
        base = {"scripts/a.sh": SH + 'ROOT="$(git rev-parse --show-toplevel)"\n. "$ROOT/tools/mid.sh"\n' + TEMPLATE,
                "tools/mid.sh": SH + HERE + '. "$DIR/deep.sh"\n', "tools/deep.sh": SH + "f() { :; }\n"}
        self.check(base, {"tools/deep.sh": SH + SHADOW}, 1)

    def test_a_problem_in_an_untouched_file_is_not_reported(self):
        self.check({"scripts/a.sh": SH + "f=/tmp/out.$$\n", "scripts/b.sh": SH},
                   {"scripts/b.sh": SH + "echo hi\n"}, 0)

    def test_an_app_name_only_an_untouched_file_hits_is_still_found(self):
        repo = self.repo({"scripts/a.sh": SH + 's=/tmp/cmux-debug-$TAG.sock\nf=/tmp/out.$$\n', "scripts/b.sh": SH})
        found = noclobber.with_app_names(repo.root, {"scripts/b.sh"}, [])
        self.assertTrue(any(h[3].startswith("/tmp/cmux-debug-") for h in found), found)
        self.assertEqual(noclobber.unapproved(found, {}), [], "the grep-found file's other hits are the base's")


if __name__ == "__main__":
    unittest.main()
