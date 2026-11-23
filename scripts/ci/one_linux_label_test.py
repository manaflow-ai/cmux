#!/usr/bin/env python3
"""Tests for one_linux_label.py: every Linux x64 size picker becomes the one label."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import one_linux_label as olc  # noqa: E402

FORK = "github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository"


def rewrite(text: str, name: str = "w.yml", signing: set[str] | None = None) -> tuple[str, olc.Report]:
    report = olc.Report()
    return olc.rewrite_text(name, text, report, signing=set() if signing is None else signing), report


def job(runs_on: str, job_id: str = "build", extra: str = "") -> str:
    return f"jobs:\n  {job_id}:\n    runs-on: {runs_on}\n{extra}"


class OneLinuxLabelTest(unittest.TestCase):
    def test_size_pool_becomes_the_one_label(self) -> None:
        for picker in (
            "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.LINUX_RUNNER || fromJSON(vars.RUNNER_POOLS).linux_4 }}",
            f"${{{{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || {FORK} && 'blacksmith-4vcpu-ubuntu-2404' || fromJSON(vars.RUNNER_POOLS).linux }}}}",
            "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.CI_CLOUD_OVERFLOW_SAVED && "
            f"({FORK} && 'blacksmith-8vcpu-ubuntu-2404' || fromJSON(vars.RUNNER_POOLS).linux_8) || "
            f"({FORK} && 'blacksmith-2vcpu-ubuntu-2404' || fromJSON(vars.RUNNER_POOLS).linux_2) }}}}",
            "${{ vars.LINUX_RUNNER || fromJSON(vars.RUNNER_POOLS).linux_4 }}",
            "${{ fromJSON(vars.RUNNER_POOLS).linux_32 }}",
        ):
            out, report = rewrite(job(picker))
            self.assertIn(f"runs-on: {olc.CANONICAL}", out, picker)
            self.assertEqual(len(report.changed), 1)

    def test_canonical_keeps_forks_off_owned_hosts_and_names_no_size(self) -> None:
        self.assertIn("(vars.CI_FORK_LINUX_RUNNER || 'ubuntu-24.04')", olc.CANONICAL)
        self.assertTrue(olc.CANONICAL.endswith("'cmux-linux' }}"))
        self.assertIsNone(olc.SIZE_LEFT.search(olc.CANONICAL))

    def test_rerun_changes_nothing(self) -> None:
        out, _ = rewrite(job("${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || fromJSON(vars.RUNNER_POOLS).linux_8 }}"))
        again, report = rewrite(out)
        self.assertEqual(again, out)
        self.assertEqual(report.changed, [])

    def test_nightly_pin_keeps_its_branch(self) -> None:
        pin = "github.event_name == 'push' && github.ref == 'refs/heads/feat-cmux-next' && github.run_attempt == 1 && 'cmux-gcp-nightly-jit-x64'"
        out, _ = rewrite(job(f"${{{{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || {pin} || fromJSON(vars.RUNNER_POOLS).linux_4 }}}}"))
        self.assertIn(f"'ubuntu-24.04' || {pin} || {olc.FORK_PR} || 'cmux-linux' }}}}", out)

    def test_exceptions_stay(self) -> None:
        line = ("${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || contains(fromJSON('[\"blacksmith-2vcpu-ubuntu-2404\"]'), "
                "vars.CI_TRUSTED_RUNNER) && vars.CI_TRUSTED_RUNNER || fromJSON(vars.RUNNER_POOLS).linux }} # ephemeral-required: write token")
        text = job(line)
        out, report = rewrite(text)
        self.assertEqual(out, text)
        self.assertEqual(len(report.exceptions), 1)

    def test_owned_pool_unfit_job_stays(self) -> None:
        text = job("${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || fromJSON(vars.RUNNER_POOLS).linux_4 }} # owned-pool-unfit: timed out")
        out, report = rewrite(text)
        self.assertEqual(out, text)
        self.assertEqual(len(report.exceptions), 1)

    def test_ephemeral_only_and_signing_jobs_stay(self) -> None:
        mirror = (f"${{{{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || {FORK} && 'blacksmith-4vcpu-ubuntu-2404' || "
                  "contains(fromJSON('[\"blacksmith-4vcpu-ubuntu-2404\",\"blacksmith-8vcpu-ubuntu-2404\"]'), vars.LINUX_RUNNER) && "
                  "vars.LINUX_RUNNER || fromJSON(vars.RUNNER_POOLS).linux_8 }}")
        text = job(mirror)
        out, report = rewrite(text)
        self.assertEqual(out, text)
        self.assertEqual(len(report.exceptions), 1)
        text = job("${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || fromJSON(vars.RUNNER_POOLS).linux_4 }}", "sign")
        out, report = rewrite(text, signing={"sign"})
        self.assertEqual(out, text)
        self.assertEqual(len(report.exceptions), 1)

    def test_ephemeral_only_route_listing_a_hosted_label_first_stays(self) -> None:
        # language-boundaries.yml: the allowed list starts with a GitHub-hosted label, then the vendor sizes.
        trusted = ("${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || "
                   "contains(fromJSON('[\"ubuntu-24.04\",\"blacksmith-2vcpu-ubuntu-2404\"]'), vars.CI_TRUSTED_RUNNER) && "
                   "vars.CI_TRUSTED_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}")
        text = job(trusted)
        out, report = rewrite(text)
        self.assertEqual(out, text)
        self.assertEqual(len(report.exceptions), 1)

    def test_signing_detector_reads_the_job(self) -> None:
        text = ("jobs:\n  a:\n    runs-on: x\n    steps:\n      - run: echo\n        env:\n"
                "          K: ${{ secrets.APPLE_CERTIFICATE_P12 }}\n  b:\n    runs-on: x\n")
        self.assertEqual(olc.signing_jobs(text), {"a"})

    def test_a_placement_answer_is_kept(self) -> None:
        place = "needs.portable-placement.outputs.placed_attempt == '1' && needs.portable-placement.outputs.side_runner"
        out, _ = rewrite(job(f"${{{{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || {FORK} && 'blacksmith-4vcpu-ubuntu-2404' || "
                             f"{place} || fromJSON(vars.RUNNER_POOLS).linux_4 }}}}"))
        self.assertIn(f"|| {olc.FORK_PR} || {place} || 'cmux-linux' }}}}", out)

    def test_macos_windows_arm_and_matrix_untouched(self) -> None:
        for runs_on in (
            "${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || fromJSON(vars.RUNNER_POOLS).macos_26 }}",
            "${{ github.repository_owner != 'manaflow-ai' && 'windows-2025' || fromJSON(vars.RUNNER_POOLS).windows }}",
            "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04-arm' || fromJSON(vars.RUNNER_POOLS).linux_arm64 }}",
            "${{ matrix.runner }}",
            "${{ vars.CI_EVAL_STEP_GATEWAY }}",
        ):
            text = job(runs_on)
            self.assertEqual(rewrite(text)[0], text, runs_on)

    def test_matrix_value_is_rewritten(self) -> None:
        text = ("jobs:\n  smoke:\n    strategy:\n      matrix:\n        include:\n"
                "          - os: ${{ fromJSON(vars.RUNNER_POOLS).linux_4 }}\n"
                "          - os: ${{ fromJSON(vars.RUNNER_POOLS).macos_15 }}\n    runs-on: ${{ matrix.os }}\n")
        out, report = rewrite(text)
        self.assertIn(f"- os: {olc.CANONICAL}", out)
        self.assertIn("macos_15", out)
        self.assertEqual(len(report.changed), 1)

    def test_mixed_macos_expression_moves_only_its_linux_arm(self) -> None:
        expr = ("${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || needs.f.outputs.verdict == 'pass' && "
                f"({FORK} && 'blacksmith-2vcpu-ubuntu-2404' || fromJSON(vars.RUNNER_POOLS).linux_2) || "
                "needs.f.outputs.verdict == 'done' && !startsWith(vars.LINUX_RUNNER, 'blacksmith-') && vars.LINUX_RUNNER || "
                "needs.f.outputs.verdict == 'done' && fromJSON(vars.RUNNER_POOLS).linux_2 || fromJSON(vars.RUNNER_POOLS).macos_26 }}")
        out, report = rewrite(job(expr))
        self.assertIn("'macos-26'", out)
        self.assertIn("fromJSON(vars.RUNNER_POOLS).macos_26", out)
        self.assertIsNone(olc.SIZE_LEFT.search(out))
        self.assertEqual(out.count("needs.f.outputs.verdict == 'done' && 'cmux-linux'"), 1)
        self.assertEqual(len(report.changed), 1)

    def test_unknown_term_is_reported_not_guessed(self) -> None:
        text = job("${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || steps.x.outputs.label || fromJSON(vars.RUNNER_POOLS).linux_4 }}")
        out, report = rewrite(text)
        self.assertEqual(out, text)
        self.assertEqual(len(report.unconverted), 1)

    def test_split_respects_parens_and_strings(self) -> None:
        self.assertEqual(olc.split_top("a || (b || c) || 'd || e'"), ["a", "(b || c)", "'d || e'"])
        self.assertEqual(olc.or_terms("a || (b || c)"), ["a", "b", "c"])


if __name__ == "__main__":
    unittest.main()
