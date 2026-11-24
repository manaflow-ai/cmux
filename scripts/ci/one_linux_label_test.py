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
        self.assertIn("'ubuntu-24.04'", olc.CANONICAL)
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
        self.assertIn(f"'ubuntu-24.04' || {pin} || {olc.FORK_PR} || {olc.OVERFLOW} || 'cmux-linux' }}}}", out)

    def test_exceptions_stay(self) -> None:
        line = ("${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || contains(fromJSON('[\"blacksmith-2vcpu-ubuntu-2404\"]'), "
                "vars.CI_TRUSTED_RUNNER) && vars.CI_TRUSTED_RUNNER || fromJSON(vars.RUNNER_POOLS).linux }} # ephemeral-required: write token")
        text = job(line)
        out, report = rewrite(text)
        self.assertEqual(out, text)
        self.assertEqual(len(report.exceptions), 1)

    def test_owned_pool_unfit_job_keeps_todays_label(self) -> None:
        text = job("${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || fromJSON(vars.RUNNER_POOLS).linux_4 }} # owned-pool-unfit: timed out")
        out, report = rewrite(text)
        self.assertEqual(out, job("${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'blacksmith-4vcpu-ubuntu-2404' }} # owned-pool-unfit: timed out"))
        self.assertEqual(len(report.exceptions), 1)
        self.assertEqual(rewrite(out)[0], out)

    def test_ephemeral_only_and_signing_jobs_stay(self) -> None:
        mirror = (f"${{{{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || {FORK} && 'blacksmith-4vcpu-ubuntu-2404' || "
                  "contains(fromJSON('[\"blacksmith-4vcpu-ubuntu-2404\",\"blacksmith-8vcpu-ubuntu-2404\"]'), vars.LINUX_RUNNER) && "
                  "vars.LINUX_RUNNER || fromJSON(vars.RUNNER_POOLS).linux_8 }}")
        # Frozen to the label each resolves to today (LINUX_RUNNER is not listed, so linux_8 answers).
        out, report = rewrite(job(mirror))
        self.assertEqual(out, job(f"${{{{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || {FORK} && 'blacksmith-4vcpu-ubuntu-2404' || "
                                  "'cmux-fleet-linux-x64' }} # ephemeral-required: credentialed job, frozen to today's label"))
        self.assertEqual(len(report.exceptions), 1)
        # The comment keeps it an exception on the next run, with no variable left to mark it.
        again, report = rewrite(out)
        self.assertEqual(again, out)
        self.assertEqual((len(report.exceptions), report.changed), (1, []))
        text = job("${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || fromJSON(vars.RUNNER_POOLS).linux_4 }}", "sign")
        out, report = rewrite(text, signing={"sign"})
        self.assertEqual(out, job("${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'blacksmith-4vcpu-ubuntu-2404' }}"
                                  " # ephemeral-required: holds signing material", "sign"))
        self.assertEqual(len(report.exceptions), 1)

    def test_ephemeral_only_route_keeps_its_ephemeral_label_as_a_literal(self) -> None:
        # language-boundaries.yml: the allowed list starts with a GitHub-hosted label, then the vendor sizes. Today's
        # CI_TRUSTED_RUNNER (the 4 vCPU size) is not listed, so the job runs on its fallback.
        trusted = ("${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || "
                   "contains(fromJSON('[\"ubuntu-24.04\",\"blacksmith-2vcpu-ubuntu-2404\"]'), vars.CI_TRUSTED_RUNNER) && "
                   "vars.CI_TRUSTED_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}")
        out, report = rewrite(job(trusted))
        self.assertEqual(out, job("${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'blacksmith-4vcpu-ubuntu-2404' }} # ephemeral-required: credentialed job, frozen to today's label"))
        self.assertEqual(len(report.exceptions), 1)
        # A PR-control job: CI_PR_CONTROL_SKIP_FLEET is '1' today, and the trusted runner is listed.
        control = ("${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.CI_PR_CONTROL_SKIP_FLEET != '1' && "
                   "'cmux-gcp-pr-control-jit-x64' || contains(fromJSON('[\"blacksmith-2vcpu-ubuntu-2404\",\"blacksmith-4vcpu-ubuntu-2404\"]'), "
                   "vars.CI_TRUSTED_RUNNER) && vars.CI_TRUSTED_RUNNER || 'blacksmith-2vcpu-ubuntu-2404' }}")
        self.assertEqual(olc.freeze_expr(control),
                         "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'blacksmith-4vcpu-ubuntu-2404' }}")

    def test_signing_detector_reads_the_job(self) -> None:
        text = ("jobs:\n  a:\n    runs-on: x\n    steps:\n      - run: echo\n        env:\n"
                "          K: ${{ secrets.APPLE_CERTIFICATE_P12 }}\n  b:\n    runs-on: x\n")
        self.assertEqual(olc.signing_jobs(text), {"a"})

    def test_a_placement_answer_is_kept(self) -> None:
        place = "needs.portable-placement.outputs.placed_attempt == '1' && needs.portable-placement.outputs.side_runner"
        out, _ = rewrite(job(f"${{{{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || {FORK} && 'blacksmith-4vcpu-ubuntu-2404' || "
                             f"{place} || fromJSON(vars.RUNNER_POOLS).linux_4 }}}}"))
        self.assertIn(f"|| {olc.FORK_PR} || {place} || {olc.OVERFLOW} || 'cmux-linux' }}}}", out)

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

    def test_unknown_term_is_kept_and_only_the_variable_frozen(self) -> None:
        text = job("${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || steps.x.outputs.label || fromJSON(vars.RUNNER_POOLS).linux_4 }}")
        out, report = rewrite(text)
        self.assertEqual(out, job("${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || steps.x.outputs.label || 'blacksmith-4vcpu-ubuntu-2404' }}"))
        self.assertEqual((len(report.changed), len(report.unconverted)), (1, 0))

    def test_unknown_variable_is_reported_not_guessed(self) -> None:
        # The `linux` pool's value is not known today, so the line keeps its variable and is reported.
        text = job("${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || steps.x.outputs.label || fromJSON(vars.RUNNER_POOLS).linux }}")
        out, report = rewrite(text)
        self.assertEqual(out, text)
        self.assertEqual(len(report.unconverted), 1)

    def test_freeze_resolves_each_variable_to_todays_label(self) -> None:
        g = "github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04'"
        for expr, want in (
            (f"${{{{ {g} || vars.LINUX_RUNNER || fromJSON(vars.RUNNER_POOLS).linux_4 }}}}", f"${{{{ {g} || 'cmux-fleet-linux-x64' }}}}"),
            # CI_REPAIR_SKIP_FLEET is '1' today: the repair pool is skipped.
            (f"${{{{ {g} || vars.CI_REPAIR_SKIP_FLEET != '1' && 'cmux-gcp-repair-jit-x64' || fromJSON(vars.RUNNER_POOLS).linux_4 }}}}",
             f"${{{{ {g} || 'blacksmith-4vcpu-ubuntu-2404' }}}}"),
            # CI_DEPLOY_SKIP_FLEET is empty today: the deploy pool answers.
            (f"${{{{ {g} || vars.CI_DEPLOY_SKIP_FLEET != '1' && 'cmux-gcp-deploy-jit-x64' || fromJSON(vars.RUNNER_POOLS).linux_2 }}}}",
             f"${{{{ {g} || 'cmux-gcp-deploy-jit-x64' }}}}"),
            # CI_CLOUD_OVERFLOW_SAVED is empty today: its arm is dead, even one naming an unknown pool.
            (f"${{{{ {g} || vars.CI_CLOUD_OVERFLOW_SAVED && fromJSON(vars.RUNNER_POOLS).linux_16 || 'blacksmith-2vcpu-ubuntu-2404' }}}}",
             f"${{{{ {g} || 'blacksmith-2vcpu-ubuntu-2404' }}}}"),
            # A fork arm inside parentheses stays; only the pool in it is frozen.
            (f"${{{{ {g} || ({FORK} && 'blacksmith-2vcpu-ubuntu-2404' || fromJSON(vars.RUNNER_POOLS).linux_4) }}}}",
             f"${{{{ {g} || ({FORK} && 'blacksmith-2vcpu-ubuntu-2404' || 'blacksmith-4vcpu-ubuntu-2404') }}}}"),
            (f"${{{{ {g} || !startsWith(vars.LINUX_RUNNER, 'blacksmith-') && vars.LINUX_RUNNER || fromJSON(vars.RUNNER_POOLS).linux_4 }}}}",
             f"${{{{ {g} || 'cmux-fleet-linux-x64' }}}}"),
        ):
            self.assertEqual(olc.freeze_expr(expr), want, expr)

    def test_freeze_line_says_a_label_once_and_guards_an_unguarded_route(self) -> None:
        g = "github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04'"
        for expr, want in (
            # A fork arm naming the label its pool froze to collapses, in parentheses or at the end.
            (f"${{{{ {g} || ({FORK} && 'blacksmith-4vcpu-ubuntu-2404' || fromJSON(vars.RUNNER_POOLS).linux_4) }}}}",
             f"${{{{ {g} || 'blacksmith-4vcpu-ubuntu-2404' }}}}"),
            (f"${{{{ {g} || {FORK} && 'blacksmith-4vcpu-ubuntu-2404' || fromJSON(vars.RUNNER_POOLS).linux_4 }}}}",
             f"${{{{ {g} || 'blacksmith-4vcpu-ubuntu-2404' }}}}"),
            # No owner guard: an unset variable failed in a fork; the frozen label would queue there, so it is guarded.
            ("${{ fromJSON(vars.RUNNER_POOLS).linux_4 }}", f"${{{{ {g} || 'blacksmith-4vcpu-ubuntu-2404' }}}}"),
            # A GitHub-hosted label needs no guard.
            ("${{ fromJSON(vars.RUNNER_POOLS).provenance }}", "${{ 'ubuntu-latest' }}"),
        ):
            self.assertEqual(olc.freeze_line(expr), want, expr)

    def test_provenance_job_keeps_its_hosted_runner_without_the_variable(self) -> None:
        text = job("${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-latest' || fromJSON(vars.RUNNER_POOLS).provenance }} # github-hosted-required: npm", "publish-npm")
        out, report = rewrite(text, name="x-publish-npm.yml")
        self.assertEqual(out, job("${{ 'ubuntu-latest' }} # github-hosted-required: npm", "publish-npm"))
        self.assertEqual(rewrite(out, name="x-publish-npm.yml")[0], out)

    def test_probe_job_keeps_its_variable(self) -> None:
        name, job_id = next(iter(olc.PROBE_JOBS))
        text = job("${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || fromJSON(vars.RUNNER_POOLS).linux_4 }}", job_id)
        self.assertEqual(rewrite(text, name=name)[0], text)

    def test_split_respects_parens_and_strings(self) -> None:
        self.assertEqual(olc.split_top("a || (b || c) || 'd || e'"), ["a", "(b || c)", "'d || e'"])
        self.assertEqual(olc.or_terms("a || (b || c)"), ["a", "b", "c"])


if __name__ == "__main__":
    unittest.main()
