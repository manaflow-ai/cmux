#!/usr/bin/env python3
"""merge_compile_guard: a hand merge of a feat-cmux-next PR that changes Swift waits for its Release compile.

On 2026-10-21 (UTC) #22835, #21480 and #21487 were merged with `gh pr merge` while their compile was pending.
"""
from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HOOK = ROOT / "scripts/ci/merge-compile-guard-hook.sh"
sys.path.insert(0, str(ROOT / "scripts/ci"))
import merge_compile_guard as guard  # noqa: E402

COMPILE = guard.COMPILE
HEAD = "c" * 40
SWIFT = ["Packages/macOS/CmuxNext/Sources/A.swift"]


def pr(number=7, base="feat-cmux-next"):
    return {"number": number, "base": base, "head": HEAD, "state": "open"}


def check(name, status="completed", conclusion="success"):
    return {"name": name, "status": status, "conclusion": conclusion if status == "completed" else None}


class Verdict(unittest.TestCase):
    def test_a_swift_pr_merges_only_once_its_compile_passed(self):
        self.assertIn("still running", guard.verdict(pr(), SWIFT, [check(COMPILE, "in_progress")]))
        self.assertIn("still running", guard.verdict(pr(), SWIFT, [check(COMPILE, "queued")]))
        self.assertIn("finished failure", guard.verdict(pr(), SWIFT, [check(COMPILE, conclusion="failure")]))
        self.assertIn("finished cancelled", guard.verdict(pr(), SWIFT, [check(COMPILE, conclusion="cancelled")]))
        self.assertEqual(guard.verdict(pr(), SWIFT, [check(COMPILE)]), "")
        # A rerun that passed after a red counts.
        self.assertEqual(guard.verdict(pr(), SWIFT, [check(COMPILE, conclusion="failure"), check(COMPILE)]), "")

    def test_a_compile_not_created_yet_waits_while_cmux_next_routes_and_places(self):
        for job in guard.ROUTING:
            with self.subTest(job=job):
                self.assertIn("has not created", guard.verdict(pr(), SWIFT, [check(job, "in_progress")]))
        self.assertIn("no checks yet", guard.verdict(pr(), SWIFT, []))
        # cmux-next finished routing without a compile, or never ran on this head.
        self.assertEqual(guard.verdict(pr(), SWIFT, [check("cmux-next path routing")]), "")
        self.assertEqual(guard.verdict(pr(), SWIFT, [check("web / lint")]), "")

    def test_what_the_compile_does_not_cover_is_not_held(self):
        # The router skipped it (iOS, a package outside the graph, a fork).
        self.assertEqual(guard.verdict(pr(), ["ios/CmuxiOS/A.swift"], [check(COMPILE, conclusion="skipped")]), "")
        self.assertEqual(guard.verdict(pr(), ["webviews/src/a.tsx"], [check(COMPILE, "queued")]), "")
        self.assertEqual(guard.verdict(pr(base="main"), SWIFT, [check(COMPILE, "queued")]), "")

    def test_headers_manifests_and_projects_count_as_swift(self):
        for path in ("Sources/CCmuxAppFFI/include/ffi.h", "Packages/macOS/CmuxNext/Package.resolved",
                     "cmux.xcodeproj/project.pbxproj", "Config/Next.xcconfig", "Sources/X/module.modulemap"):
            with self.subTest(path=path):
                self.assertIn("still running", guard.verdict(pr(), [path], [check(COMPILE, "queued")]))


class Targets(unittest.TestCase):
    def targets(self, command):
        return [(repo, selector) for repo, selector, _ in guard.merge_targets(command, "/tmp")]

    def test_every_merge_form_names_its_pull_request(self):
        cmux = "manaflow-ai/cmux"
        cases = {
            "gh pr merge 22835 --squash": [(None, "22835")],
            "gh pr merge 22835 -R manaflow-ai/cmux --squash": [(cmux, "22835")],
            "gh pr merge --squash --repo manaflow-ai/cmux '#21480'": [(cmux, "21480")],
            # Unquoted, `#21480` is a shell comment: the checkout's branch is what merges.
            "gh pr merge --squash --repo manaflow-ai/cmux #21480": [(cmux, None)],
            "gh pr merge --repo=manaflow-ai/cmux 8": [(cmux, "8")],
            "gh pr merge https://github.com/manaflow-ai/cmux/pull/21487 --auto --squash": [(cmux, "21487")],
            "gh pr merge --squash -t 'fix 123' 9": [(None, "9")],
            'gh pr merge -b "it\\"s 99" 7': [(None, "7")],
            "gh pr merge --squash": [(None, None)],
            # A redirect's fd is not a pull request; the checkout's branch is merged.
            "gh pr merge --squash 2>/dev/null": [(None, None)],
            "gh pr merge --squash --delete-branch 2>&1": [(None, None)],
            "gh pr merge --squash\ngit log -1 4242": [(None, None)],
            "gh pr merge my-branch": [(None, "my-branch")],
            "gh pr merge 123-fix": [(None, "123-fix")],
            'gh pr merge "$PR" --squash': [(None, guard.UNKNOWN)],
            "gh api -X PUT repos/manaflow-ai/cmux/pulls/22914/merge -f merge_method=squash -f sha=abc":
                [(cmux, "22914")],
            "gh api -X PUT repos/{owner}/{repo}/pulls/5/merge": [(None, "5")],
            'gh api -X PUT "repos/manaflow-ai/cmux/pulls/$N/merge"': [(cmux, guard.UNKNOWN)],
            'gh api graphql -f query="mutation{mergePullRequest(input:{})}"': [(None, guard.UNKNOWN)],
            "GH_REPO=manaflow-ai/cmux gh pr merge 5": [(cmux, "5")],
            "git log && gh pr merge 3 -R manaflow-ai/cmux --squash": [(cmux, "3")],
            # A redirect with no fd of its own leaves the number before it alone.
            "gh pr merge 5 >out.txt 2>&1": [(None, "5")],
            "gh pr merge 5 > /tmp/log 2>&1": [(None, "5")],
            # A comment ends at its newline; the next line still runs.
            "echo hi # merge next\ngh pr merge 5 --squash": [(None, "5")],
            'git commit -m "a # b" && gh pr merge 9': [(None, "9")],
            "gh pr merge feat#2": [(None, "feat#2")],
            # Wrappers and shells run the merge too.
            'bash -c "gh pr merge 5"': [(None, "5")],
            "env GH_REPO=manaflow-ai/cmux gh pr merge 5": [(cmux, "5")],
            "command gh pr merge 5": [(None, "5")],
            "/opt/homebrew/bin/gh pr merge 5": [(None, "5")],
            "nice -n 10 gh pr merge 5": [(None, "5")],
            "gh pr merge 5 --squash; echo $'it\\'s'": [(None, "5")],
            'echo "unbalanced && gh pr merge 5': [(None, guard.UNKNOWN)],
        }
        for command, want in cases.items():
            with self.subTest(command=command):
                self.assertEqual(self.targets(command), want)

    def test_a_cd_before_the_merge_moves_its_checkout(self):
        self.assertEqual(guard.merge_targets("cd ../other && gh pr merge 6", "/tmp/a"), [(None, "6", "/tmp/a/../other")])

    def test_text_that_only_mentions_a_merge_names_nothing(self):
        for command in ("git merge origin/feat-cmux-next", "gh pr view 3 --json mergeable",
                        "gh api repos/manaflow-ai/cmux/pulls/3/update-branch -X PUT", "echo gh pr merged",
                        'git grep -n "gh pr merge"', 'rg "gh pr merge N --squash" CLAUDE.md',
                        'git commit -m "docs: use gh pr merge 22835 --squash"',
                        "cat > notes.md <<'EOF'\nthen gh pr merge 77\nEOF\necho done",
                        "echo 'unbalanced"):
            with self.subTest(command=command):
                self.assertEqual(self.targets(command), [])

    def test_other_repositories_are_not_guarded(self):
        reader = lambda *a: self.fail("read another repo")  # noqa: E731
        self.assertEqual(guard.refusal("gh pr merge 662 -R teamleaderleo/leo-workspace --squash", None, reader), "")

    def test_a_merge_in_a_checkout_it_cannot_read_is_refused_unless_it_names_the_repo(self):
        for command in ('ssh host "cd wt && gh pr merge 5"', 'cd "$WT" && gh pr merge 5'):
            with self.subTest(command=command):
                self.assertEqual(guard.merge_targets(command, "/tmp")[0][2], guard.REMOTE)
                self.assertIn("can't read", guard.refusal(command, "/tmp", lambda *a: self.fail("read")))
        self.assertEqual(guard.refusal('ssh host "gh pr merge 5 -R manaflow-ai/cmux"', "/tmp", lambda *a: ""), "")

    def test_a_merge_it_cannot_name_is_refused(self):
        why = guard.refusal('gh pr merge "$PR" -R manaflow-ai/cmux', None, lambda *a: self.fail("read"))
        self.assertIn("can't name", why)


def fake_gh(bin_dir: Path, answers: dict[str, str], log: Path) -> None:
    """A `gh` that prints answers[<the first argument that names an endpoint>] and logs its argv."""
    script = bin_dir / "gh"
    script.write_text(textwrap.dedent(f"""\
        #!{sys.executable}
        import json, sys
        args = sys.argv[1:]
        with open({str(log)!r}, "a") as f:
            f.write(json.dumps(args) + "\\n")
        answers = {json.dumps(answers)}
        for arg in args:
            for key, value in answers.items():
                if arg.startswith(key):
                    print(value)
                    sys.exit(0)
        sys.exit(1)
        """))
    script.chmod(script.stat().st_mode | stat.S_IEXEC)


class Hook(unittest.TestCase):
    def run_hook(self, command: str, compile_state: tuple[str, str | None] | None):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            subprocess.run(["git", "init", "-q", str(tmp)], check=True)
            subprocess.run(["git", "-C", str(tmp), "remote", "add", "origin", "https://github.com/manaflow-ai/cmux.git"],
                           check=True)
            bin_dir = tmp / "bin"
            bin_dir.mkdir()
            log = tmp / "gh.log"
            runs = [check("cmux-next path routing")]
            if compile_state:
                runs.append(check(COMPILE, *compile_state))
            fake_gh(bin_dir, {
                "repos/manaflow-ai/cmux/pulls/22835/files": "\n".join(json.dumps(f) for f in SWIFT),
                "repos/manaflow-ai/cmux/pulls/22835": json.dumps(pr(22835)),
                "view": json.dumps({"number": 22835}),
                f"repos/manaflow-ai/cmux/commits/{HEAD}/check-runs": "\n".join(json.dumps(r) for r in runs),
            }, log)
            payload = json.dumps({"tool_name": "Bash", "cwd": str(tmp), "tool_input": {"command": command}})
            env = {**os.environ, "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}"}
            done = subprocess.run(["bash", str(HOOK)], input=payload, capture_output=True, text=True, env=env,
                                  timeout=60)
            self.assertEqual(done.returncode, 0, done.stderr)
            calls = log.read_text().splitlines() if log.exists() else []
            return (json.loads(done.stdout) if done.stdout.strip() else None), calls

    def test_a_merge_with_the_compile_pending_is_refused(self):
        out, _ = self.run_hook("gh pr merge 22835 -R manaflow-ai/cmux --squash", ("in_progress", None))
        decision = out["hookSpecificOutput"]
        self.assertEqual(decision["permissionDecision"], "deny")
        self.assertIn("#22835 changes Swift", decision["permissionDecisionReason"])

    def test_a_merge_after_a_green_compile_goes_ahead(self):
        out, calls = self.run_hook("gh pr merge 22835 -R manaflow-ai/cmux --squash", ("completed", "success"))
        self.assertIsNone(out)
        self.assertTrue(any("--paginate" in json.loads(c) for c in calls))

    def test_a_bare_merge_checks_the_checkouts_branch(self):
        """gh refuses `pr view -R` without a selector, so the branch is looked up in the checkout."""
        out, calls = self.run_hook("gh pr merge --squash 2>&1", ("in_progress", None))
        self.assertIn("#22835 changes Swift", out["hookSpecificOutput"]["permissionDecisionReason"])
        view = [json.loads(c) for c in calls if json.loads(c)[:2] == ["pr", "view"]]
        self.assertEqual(view, [["pr", "view", "--json", "number"]])
        out, _ = self.run_hook("gh pr merge --squash", ("completed", "success"))
        self.assertIsNone(out)

    def test_an_unreadable_github_refuses(self):
        out, _ = self.run_hook("gh pr merge 1 -R manaflow-ai/cmux --squash", None)
        self.assertIn("could not read #1 from GitHub", out["hookSpecificOutput"]["permissionDecisionReason"])

    def test_other_commands_never_start_python_or_gh(self):
        out, calls = self.run_hook("git status && gh pr view 22835", None)
        self.assertIsNone(out)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
