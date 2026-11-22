#!/usr/bin/env python3
import pathlib
import sys
import tempfile
import textwrap
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
# Imported by name, never loaded by path: one module object per file (the script module load check).
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
import check_runs_on_pools as module  # noqa: E402
import check_no_hosted_runs_on as hosted  # noqa: E402

FORK_REPO = "github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04'"
FORK_PR = ("github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository"
           " && 'blacksmith-4vcpu-ubuntu-2404'")


class LiteralLabelsTests(unittest.TestCase):
    def test_plain_labels_are_hits(self):
        self.assertEqual(module.literal_labels("ubuntu-latest"), ["ubuntu-latest"])
        self.assertEqual(module.literal_labels("blacksmith-4vcpu-ubuntu-2404"), ["blacksmith-4vcpu-ubuntu-2404"])

    def test_macos_and_windows_are_not_linux(self):
        self.assertEqual(module.literal_labels("${{ vars.X || 'blacksmith-6vcpu-macos-15' || 'windows-2025' }}"), [])

    def test_fork_branches_may_keep_a_literal(self):
        text = f"${{{{ {FORK_REPO} || {FORK_PR} || fromJSON(vars.RUNNER_POOLS).linux }}}}"
        self.assertEqual(module.literal_labels(text), [])

    def test_trusted_fallback_is_not_a_hit(self):
        # The selector's one-job Blacksmith fallback is ephemeral by design (f1effe9077c); a trusted job never reads
        # RUNNER_POOLS, whose x64 pools lead with the persistent pool.
        text = (f"${{{{ {FORK_REPO} || contains(fromJSON('[\"blacksmith-2vcpu-ubuntu-2404\"]'), "
                "vars.CI_TRUSTED_RUNNER) && vars.CI_TRUSTED_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}")
        self.assertEqual(module.literal_labels(text), [])

    def test_both_sides_of_a_conditional_are_hits(self):
        text = (f"${{{{ {FORK_REPO} || vars.CI_CLOUD_OVERFLOW_SAVED && 'blacksmith-8vcpu-ubuntu-2404' "
                "|| 'blacksmith-2vcpu-ubuntu-2404' }}")
        self.assertEqual(module.literal_labels(text),
                         ["blacksmith-8vcpu-ubuntu-2404", "blacksmith-2vcpu-ubuntu-2404"])

    def test_a_fork_condition_inside_a_group_covers_only_its_own_alternative(self):
        text = ("${{ (github.event.pull_request.head.repo.fork && 'ubuntu-24.04' || 'blacksmith-4vcpu-ubuntu-2404') }}")
        self.assertEqual(module.literal_labels(text), ["blacksmith-4vcpu-ubuntu-2404"])

    def test_an_enclosing_fork_condition_covers_the_group(self):
        text = "${{ github.event.pull_request.head.repo.fork && ('ubuntu-24.04') || fromJSON(vars.RUNNER_POOLS).linux }}"
        self.assertEqual(module.literal_labels(text), [])

    def test_same_repo_condition_is_not_fork_only(self):
        text = "${{ !github.event.pull_request.head.repo.fork && 'ubuntu-24.04' || fromJSON(vars.RUNNER_POOLS).linux }}"
        self.assertEqual(module.literal_labels(text), ["ubuntu-24.04"])

    def test_comparison_operand_is_not_a_target(self):
        text = "${{ vars.CI_NIGHTLY_MINI_PUBLISHER == 'ubuntu-24.04' && fromJSON(vars.RUNNER_POOLS).linux || 'x' }}"
        self.assertEqual(module.literal_labels(text), [])


class WorkflowTests(unittest.TestCase):
    def run_on(self, body: str, name: str = "w.yml"):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / name
            path.write_text(textwrap.dedent(body), encoding="utf-8")
            return module.hits([path])

    def test_list_and_matrix_runs_on(self):
        found = self.run_on("""
            on: push
            jobs:
              a:
                runs-on: [self-hosted, ubuntu-22.04]
                steps: []
              b:
                strategy:
                  matrix:
                    runner: [blacksmith-4vcpu-ubuntu-2404-arm, macos-15]
                runs-on: ${{ matrix.runner }}
                steps: []
              c:
                runs-on: ${{ fromJSON(vars.RUNNER_POOLS).linux }}
                steps: []
            """)
        self.assertEqual(found, [("w.yml", "a", ["ubuntu-22.04"]),
                                 ("w.yml", "b", ["blacksmith-4vcpu-ubuntu-2404-arm"])])

    def test_exceptions_are_skipped(self):
        found = self.run_on("""
            on: push
            jobs:
              language-boundaries:
                runs-on: blacksmith-4vcpu-ubuntu-2404
                steps: []
            """, name="language-boundaries.yml")
        self.assertEqual(found, [])

    def test_repository_workflows_have_no_hits(self):
        self.assertEqual(module.hits(module.workflow_files([])), [])


class HostedLabelTests(unittest.TestCase):
    """check_no_hosted_runs_on: GitHub-hosted runners start nothing in manaflow-ai (Leo, 2026-11-21: "the ci must
    flow")."""

    def test_hosted_fallbacks_are_hits(self):
        jit = "'cmux-gcp-nightly-jit-x64'"
        self.assertEqual(hosted.hosted_labels(f"${{{{ {FORK_REPO} || github.run_attempt == 1 && {jit} || 'ubuntu-24.04' }}}}"),
                         ["ubuntu-24.04"])
        self.assertEqual(hosted.hosted_labels("${{ vars.X == 'macos-26' && 'macos-26' || 'glaeda-trusted-next-signing' }}"),
                         ["macos-26"])
        self.assertEqual(hosted.hosted_labels("ubuntu-24.04 # a comment"), ["ubuntu-24.04"])
        self.assertEqual(hosted.hosted_labels("windows-2025"), ["windows-2025"])

    def test_a_hosted_entry_in_a_selector_list_is_a_hit(self):
        text = (f"${{{{ {FORK_REPO} || contains(fromJSON('[\"ubuntu-24.04\",\"blacksmith-2vcpu-ubuntu-2404\"]'), "
                "vars.CI_TRUSTED_RUNNER) && vars.CI_TRUSTED_RUNNER || 'cmux-gcp-gate-jit-x64' }}")
        self.assertEqual(hosted.hosted_labels(text), ["ubuntu-24.04"])

    def test_owned_labels_fork_branches_and_comparisons_pass(self):
        for text in (f"${{{{ {FORK_REPO} || 'cmux-gcp-nightly-jit-x64' }}}}", "cmux-fleet-linux-x64",
                     "${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || fromJSON(vars.RUNNER_POOLS).macos_26 }}",
                     "${{ vars.CI_NIGHTLY_MINI_PUBLISHER == 'ubuntu-24.04' && 'cmux-gcp-nightly-jit-x64' || 'x' }}",
                     "blacksmith-6vcpu-macos-26 # macos-26 named in a comment"):
            self.assertEqual(hosted.hosted_labels(text), [], text)

    def test_repository_workflows_reach_no_hosted_label(self):
        self.assertEqual(hosted.hits(module.workflow_files([])), [])


if __name__ == "__main__":
    unittest.main()
