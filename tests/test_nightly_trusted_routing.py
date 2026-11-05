#!/usr/bin/env python3
"""Execute nightly runner selectors for pooled native work and Linux control work.

Nightlies never run on Blacksmith (Lawrence, 2026-10-30). Every nightly.yml route ends on our own runners:
a job holding a signing or publication secret on GitHub-hosted Ubuntu (the ephemeral runner the signing-secret
rules allow), the light placed controls and decide on hosted Ubuntu, the early native jobs on the owned nightly
slot, build-nightly-app and every other job on the nightly-only Mac pool.
"""
import json
import os
import re
import subprocess
import tempfile
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from nightly_workflow_text import expand as nightly_expand  # noqa: E402  (moved step scripts back inline)

import yaml

sys.path.insert(0, str(Path(__file__).parent))
from test_ci_fork_runner_routing import parse_expression

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_FILE = Path(os.environ.get('NIGHTLY_WORKFLOW_FILE', ROOT / '.github/workflows/nightly.yml'))
DOC = yaml.safe_load(nightly_expand(WORKFLOW_FILE.read_text()))
# The nightly signer jobs: GitHub-hosted Ubuntu on every attempt, never Blacksmith.
SIGNER_JOBS = ('signer-build', 'signer-app', 'signer-dmg')
# They, their picker, the cmux NIGHTLY-identity copy's release-signer jobs and the feed compare that picks its
# build (legacy-identity-target; all on the signer route itself) have their own routes, outside the 16/32 rule.
# sentry-dsyms-nightly (a network-bound Sentry upload, off the build's path) takes the signer route too.
SIGNER_ROUTE_JOBS = SIGNER_JOBS + ('pick-nightly-sign-runner', 'legacy-identity-target', 'legacy-signer-app', 'legacy-signer-dmg',
                                   'sentry-dsyms-nightly')
TAIL_CONTROL_JOBS = (
    'visual-gate-nightly-verdict', 'report-visual-gate-nightly',
    'nightly-identity-legacy-published', 'report-nightly-failure', 'close-nightly-failure-issue',
)
# Our runners' fallback labels (nightly.yml): the nightly-only Mac pool (vars.CI_NIGHTLY_ONLY_RUNNER), the
# owned nightly slot (vars.CI_NIGHTLY_NEXT_BUILD_RUNNER) and GitHub-hosted Ubuntu.
NIGHTLY_ONLY = 'glaeda-nightly-only-m4pro'
NIGHTLY_SLOT = 'glaeda-nightly-std-xcode-26.6'
# The signer's label: only a trusted-only mini that runs no pull request job carries it, and the secret-bearing
# jobs end on it as a literal, never on a label nightly builds or PR side lanes share.
SIGNING_SLOT = 'glaeda-trusted-next-signing'
HOSTED = 'ubuntu-24.04'
OUR_LABELS = {NIGHTLY_ONLY, NIGHTLY_SLOT, SIGNING_SLOT, HOSTED}
# Secret jobs that stay on GitHub-hosted Ubuntu until glaeda gives them the whole mini (its SIGNING_JOBS; the
# glaeda signing-jobs patch), never Blacksmith. Every other nightly job runs on our own minis
# (test_nightly_owned_minis_only.py).
HOSTED_SECRET_JOBS = ('promote-nightly-next-acked', 'keep-published-dsyms', 'sentry-dsyms-nightly',
                      'sign-release-notes', 'publish-release-notes', 'publish-nightly-reel',
                      'publish-nightly-identity-legacy', 'republish-nightly-deltas', 'legacy-identity-target')

DEFAULT_POOL_MEMBERS = {
    'linux_2': 'blacksmith-2vcpu-ubuntu-2404',
    'linux_4': 'blacksmith-4vcpu-ubuntu-2404',
    'linux_8': 'blacksmith-8vcpu-ubuntu-2404',
    'linux_16': 'blacksmith-16vcpu-ubuntu-2404',
    'linux_32': 'blacksmith-32vcpu-ubuntu-2404',
    'macos_15': 'blacksmith-6vcpu-macos-15',
    'macos_26': 'blacksmith-6vcpu-macos-26',
    'macos_26_large': 'blacksmith-12vcpu-macos-26',
}


def evaluate(node, context):
    kind = node[0]
    if kind in ('and', 'or'):
        value = None
        for child in node[1]:
            value = evaluate(child, context)
            if bool(value) == (kind == 'or'):
                return value
        return value
    if kind == 'literal':
        value = node[1]
        if value.startswith("'"):
            return value[1:-1].replace("''", "'")
        return {'true': True, 'false': False, 'null': None}.get(value, value)
    if kind == 'ref':
        return context.get(node[1], '')
    if kind == 'pool':
        # Resolve the same declared pool members as runs_on_labels.py. A test
        # may provide RUNNER_POOLS JSON to exercise a reconciled member; when
        # it does not, use the declaration's first member as the stable
        # fixture value.
        configured = context.get('vars.RUNNER_POOLS', '')
        try:
            pools = json.loads(configured) if configured else {}
        except (TypeError, json.JSONDecodeError):
            pools = {}
        if isinstance(pools, dict) and isinstance(pools.get(node[1]), str):
            return pools[node[1]]
        declaration = json.loads((ROOT / '.github/runners.json').read_text())
        members = declaration.get('pools', {}).get(node[1], {}).get('members', [])
        return members[0] if members else ''
    if kind == 'cmp':
        left, right = (str(evaluate(arg, context)).lower() for arg in node[2:])
        if node[1] in ('>', '<', '>=', '<='):
            left, right = float(left or 0), float(right or 0)
            return {'>': left > right, '<': left < right, '>=': left >= right, '<=': left <= right}[node[1]]
        return (left == right) == (node[1] == '==')
    if kind == 'not':
        return not evaluate(node[1], context)
    if kind == 'call':
        args = [evaluate(arg, context) for arg in node[2]]
        if node[1].lower() == 'startswith':
            return str(args[0]).lower().startswith(str(args[1]).lower())
        if node[1].lower() == 'format':
            return args[0].format(*args[1:])
        if node[1].lower() == 'fromjson':
            try:
                return json.loads(args[0])
            except (TypeError, json.JSONDecodeError):
                return {}
        if node[1].lower() == 'contains':
            return str(args[1]).lower() in str(args[0]).lower()
    if kind == 'prop':
        value = evaluate(node[1], context)
        return value.get(node[2], DEFAULT_POOL_MEMBERS.get(node[2], '')) if isinstance(value, dict) else DEFAULT_POOL_MEMBERS.get(node[2], '')
    raise ValueError(node)


def select(field='runs-on', **changes):
    context = {
        'github.repository_owner': 'manaflow-ai', 'github.repository': 'manaflow-ai/cmux', 'github.event_name': 'push',
        'github.ref': 'refs/heads/nightly-next', 'github.run_attempt': 1,
        # The picker ran on this attempt; a re-run of failed jobs keeps an older value.
        'needs.pick-nightly-build-runner.outputs.attempt': '1',
        'vars.CI_PR_POOL_OWNED': '1',
        'vars.CI_SIDE_LANE_RUNNER': 'glaeda-side-std-xcode-26.6',
        'vars.CI_SEED_TRUSTED_POOL': 'glaeda-trusted-std-xcode-26.6',
        'vars.MACOS_RUNNER_26': 'blacksmith-12vcpu-macos-26',
        'vars.LINUX_RUNNER': 'blacksmith-16vcpu-ubuntu-2404',
    }
    context.update(changes)
    source = DOC['jobs']['build-nightly-app'][field].removeprefix('${{').removesuffix('}}')
    return evaluate(parse_expression(source), context)


class NightlyTrustedRouting(unittest.TestCase):
    def test_tail_controls_ignore_stale_prebuild_placement(self):
        prefix = 'needs.pick-nightly-build-runner.outputs.'
        for name in TAIL_CONTROL_JOBS:
            source = DOC['jobs'][name]['runs-on'].removeprefix('${{').removesuffix('}}')
            expr = parse_expression(source)
            for helper in ('', 'glaeda-side-std-xcode-26.6', 'glaeda-trusted-next-nightly',
                           'blacksmith-6vcpu-macos-26'):
                for attempt in (1, 2, 3):
                    for overflow in ('', 'blacksmith-16vcpu-ubuntu-2404'):
                        context = {
                            'github.repository_owner': 'manaflow-ai', 'github.run_attempt': attempt,
                            prefix + 'attempt': str(attempt), prefix + 'helper': helper,
                            prefix + 'owned': helper, prefix + 'dedicated': 'glaeda-trusted-next-nightly',
                            'vars.LINUX_RUNNER': overflow,
                        }
                        # Every attempt takes the nightly-only pool, never hosted Ubuntu or Blacksmith, whatever
                        # LINUX_RUNNER holds: nightlies run only on our own minis (Lawrence, 2026-10-30).
                        expected = NIGHTLY_ONLY
                        with self.subTest(job=name, helper=helper, attempt=attempt, overflow=overflow):
                            self.assertEqual(evaluate(expr, context), expected)
                            self.assertEqual(evaluate(expr, {**context, 'github.repository_owner': 'fork'}),
                                             'ubuntu-24.04')

    def test_tail_controls_prefer_only_the_activated_nightly_mini(self):
        dedicated = 'glaeda-nightly-only-m4pro'
        for name in TAIL_CONTROL_JOBS:
            job = DOC['jobs'][name]
            self.assertIn('decide', job['needs'])
            expr = parse_expression(job['runs-on'].removeprefix('${{').removesuffix('}}'))
            for owner, repository in (('manaflow-ai', 'manaflow-ai/cmux'),
                                      ('manaflow-ai', 'manaflow-ai/other'), ('fork', 'fork/cmux')):
                for track in ('nightly-next', 'nightly', ''):
                    for attempt in (1, 2, 3):
                        for activation in (dedicated, '', 'glaeda-trusted-next-nightly',
                                           'glaeda-runner-unserved', 'macos-26', 'ubuntu-24.04'):
                            for overflow in ('', 'blacksmith-16vcpu-ubuntu-2404'):
                                context = {
                                    'github.repository_owner': owner, 'github.repository': repository,
                                    'github.run_attempt': attempt,
                                    'needs.decide.outputs.track': track,
                                    'vars.CI_NIGHTLY_ONLY_RUNNER': activation,
                                    'vars.LINUX_RUNNER': overflow,
                                }
                                # A re-run takes the nightly-only pool variable, else its literal, never
                                # Blacksmith; runner_label_policy.py keeps the variable at '' or the label
                                # (test_nightly_dedicated_mini.py test_reservation_variable_rejects_unknown_or_hosted_labels).
                                expected = ('ubuntu-24.04' if owner != 'manaflow-ai'
                                            else activation or NIGHTLY_ONLY)
                                if repository == 'manaflow-ai/cmux' and track == 'nightly-next' and attempt == 1 and activation == dedicated:
                                    expected = dedicated
                                with self.subTest(job=name, **context):
                                    self.assertEqual(evaluate(expr, context), expected)

    def test_next_push_selects_the_picked_idle_owned_mac(self):
        picked = {'needs.pick-nightly-build-runner.outputs.owned': 'glaeda-side-std-xcode-26.6',
                  'needs.pick-nightly-build-runner.outputs.blacksmith': 'blacksmith-6vcpu-macos-26'}
        self.assertEqual(select(**picked), 'glaeda-side-std-xcode-26.6')
        # No idle owned runner now: the plain nightly-only pool, never the picker's Blacksmith label, and
        # never the warm builder label, which only its idle pick names (test_ci_runs_on_fallback.py).
        self.assertEqual(select(**{**picked, 'needs.pick-nightly-build-runner.outputs.owned': ''}), NIGHTLY_ONLY)
        self.assertEqual(select(**{**picked, 'needs.pick-nightly-build-runner.outputs.owned': '',
                                   'vars.CI_NIGHTLY_ONLY_BUILDER_RUNNER': 'glaeda-nightly-only-m4pro-builder'}),
                         NIGHTLY_ONLY)

    def test_main_keeps_its_worker_and_writer_environment(self):
        changes = {'github.ref': 'refs/heads/main'}
        self.assertEqual(select(**changes), 'glaeda-trusted-std-xcode-26.6')
        self.assertEqual(select('environment', **changes), 'ci-cache-writer')
        self.assertEqual(select('environment'), '')

    def test_next_build_never_waits_on_one_label_with_no_fallback(self):
        # Row 3 of the 2026-10-27 nightly path audit: the build read vars.CI_NIGHTLY_NEXT_BUILD_RUNNER
        # alone for every attempt, so two runs died at "Set up runner" and a rescue re-run went back
        # to the label that had refused it. The variable now only feeds the picker (OWNED_LABELS), and a
        # re-run of failed jobs (attempt 2, the rescue's), which keeps attempt 1's pick, takes the nightly-only
        # builder pool (many minis, never one label), never Blacksmith. A re-run that picks again reads its own pick.
        picked = {'needs.pick-nightly-build-runner.outputs.owned': 'glaeda-side-std-xcode-26.6',
                  'needs.pick-nightly-build-runner.outputs.blacksmith': 'blacksmith-6vcpu-macos-26',
                  'vars.CI_NIGHTLY_NEXT_BUILD_RUNNER': 'glaeda-dev-std-xcode-26.6'}
        self.assertEqual(select(**{**picked, 'github.run_attempt': 2}), NIGHTLY_ONLY)
        self.assertEqual(select(**{**picked, 'github.run_attempt': 3}), NIGHTLY_ONLY)
        self.assertEqual(select(**{**picked, 'github.run_attempt': 2,
                                   'needs.pick-nightly-build-runner.outputs.attempt': '2'}),
                         'glaeda-side-std-xcode-26.6')
        self.assertEqual(select(**{**picked, 'github.event_name': 'workflow_dispatch'}), 'glaeda-side-std-xcode-26.6')
        # A failed pick (empty outputs) takes the plain nightly-only pool, never an unvalidated variable.
        for variable in ('macos-26', 'macos-15', 'glaeda-side-std-xcode-26.6', 'blacksmith-12vcpu-macos-26', ''):
            for attempt in (1, 2):
                with self.subTest(variable=variable, attempt=attempt):
                    self.assertEqual(select(**{'vars.CI_NIGHTLY_NEXT_BUILD_RUNNER': 'glaeda-dev-std-xcode-26.6',
                                               'vars.MACOS_RUNNER_26': variable, 'github.run_attempt': attempt}),
                                     NIGHTLY_ONLY)
        # An unsigned resume reads its pick like a build: restore work never leaves our runners.
        self.assertEqual(select(**{**picked, 'inputs.nightly_next_unsigned_run': '123'}), 'glaeda-side-std-xcode-26.6')
        self.assertEqual(select(**{**picked, 'github.repository_owner': 'someone'}), 'macos-26')

    def test_decide_uses_only_read_permissions_for_metadata_and_placement(self):
        job = DOC['jobs']['decide']
        self.assertEqual(job['permissions'], {'actions': 'read', 'checks': 'read', 'contents': 'read'})
        script = next(step['with']['script'] for step in job['steps'] if step.get('id') == 'decide')
        self.assertNotRegex(script, r"github\.rest\.[A-Za-z]+\.(?:create|update|delete|upload)")
        self.assertNotIn('core.exportVariable', script)

    def test_decide_bootstraps_on_the_nightly_only_pool_without_phantom_fleet(self):
        # No preceding job can give decide a live runner receipt, so it takes the plain nightly-only pool on
        # every attempt, never hosted Ubuntu or Blacksmith, whatever LINUX_RUNNER holds.
        route = DOC['jobs']['decide']['runs-on'].removeprefix('${{').removesuffix('}}')
        for attempt in (1, 2, 3):
            for configured in ('', 'unregistered-fleet', 'blacksmith-16vcpu-ubuntu-2404'):
                context = {'github.repository_owner': 'manaflow-ai', 'github.run_attempt': attempt,
                           'vars.CI_CONTROL_RUNNER': 'unregistered-fleet',
                           'vars.CI_NIGHTLY_NEXT_BUILD_RUNNER': 'unregistered-mini',
                           'vars.LINUX_RUNNER': configured}
                self.assertEqual(evaluate(parse_expression(route), context), NIGHTLY_ONLY)
                self.assertEqual(evaluate(parse_expression(route), {**context, 'github.repository_owner': 'fork'}),
                                 'ubuntu-24.04')
        self.assertEqual(DOC['jobs']['decide']['environment'], 'ci-routing-agent')

    def test_only_the_nightly_routes_read_the_next_build_runner(self):
        readers = sorted(path.name for path in (ROOT / '.github/workflows').glob('*.y*ml')
                         if 'vars.CI_NIGHTLY_NEXT_BUILD_RUNNER' in path.read_text()
                         and 'CMUX_CI_RUNNER_VARIABLES' not in path.read_text())
        self.assertEqual(readers, ['nightly.yml'])
        uses = sorted(name for name, job in DOC['jobs'].items() if 'CI_NIGHTLY_NEXT_BUILD_RUNNER' in str(job.get('runs-on', '')))
        # The owned-only Mac signing and verify jobs end on the owned nightly slot, then the side lane, then
        # the std pool (test_nightly_sign_runner.py OWNED_ONLY_JOBS); the early native jobs
        # (build-nightly-inputs, the Ghostty helper) fall back to the nightly slot.
        # The secret-bearing jobs and their pickers end on the signer's label instead (SIGNING_SLOT);
        # promote-nightly-next keeps its earlier route (a main dispatch, which the signer refuses).
        self.assertEqual(uses, ['build-nightly-ghostty-cli-helper', 'build-nightly-inputs',
                                'promote-nightly-next', 'verify-final-dmg-nightly', 'verify-nightly-identity-legacy',
                                'verify-recovered-nightly-next', 'verify-signed-nightly'])
        steps = sorted(name for name, job in DOC['jobs'].items() if 'CI_NIGHTLY_NEXT_BUILD_RUNNER' in str(job.get('steps', '')))
        # The verify jobs' owned pick (pick-nightly-sign-runner) offers the same labels as the build's; its
        # signing pick and the recovery's (find-nightly-next-recovery) offer only the signing label.
        self.assertEqual(steps, ['pick-nightly-build-runner', 'pick-nightly-sign-runner'])
        # Their OWNED_LABELS is the signer's label as a literal: no variable chooses it.
        signing = sorted(name for name, job in DOC['jobs'].items()
                         if any((step.get('env') or {}).get('OWNED_LABELS') == SIGNING_SLOT for step in job.get('steps', [])))
        self.assertEqual(signing, ['find-nightly-next-recovery', 'pick-nightly-sign-runner'])
        self.assertNotIn('CI_NIGHTLY_SIGNING_POOL', str(DOC['jobs']))

    def test_ghostty_helper_takes_owned_macos_26_then_the_nightly_slot(self):
        # Leo: "bro WHAT THE FUCK IS THE POINT OF 15???????? WHY". The helper builds with
        # Zig 0.16.0 against the macOS 26 SDK, so it takes build-nightly-app's owned pools
        # and falls back to the owned nightly slot: never macOS 15, never a hosted Mac, never Blacksmith.
        def helper(**changes):
            return evaluate(parse_expression(
                DOC['jobs']['build-nightly-ghostty-cli-helper']['runs-on'].removeprefix('${{').removesuffix('}}')),
                {'github.repository_owner': 'manaflow-ai', 'github.repository': 'manaflow-ai/cmux',
                 'github.event_name': 'push', 'github.ref': 'refs/heads/nightly-next', 'github.run_attempt': 1,
                 'vars.CI_PR_POOL_OWNED': '1', 'vars.CI_SIDE_LANE_RUNNER': 'glaeda-side-std-xcode-26.6',
                 'vars.CI_SEED_TRUSTED_POOL': 'glaeda-trusted-std-xcode-26.6',
                 # nightly-next reads pick-nightly-build-runner's owned picks
                 # (tests/test_nightly_build_runner.py covers every combination).
                 'needs.pick-nightly-build-runner.outputs.helper': 'glaeda-side-std-xcode-26.6',
                 'needs.pick-nightly-build-runner.outputs.attempt': '1',
                 'needs.pick-nightly-build-runner.outputs.dedicated': '',
                 'needs.pick-nightly-build-runner.outputs.blacksmith': 'blacksmith-6vcpu-macos-26', **changes})
        self.assertEqual(helper(), 'glaeda-side-std-xcode-26.6')
        # A retry or rescue re-run (a re-run of failed jobs keeps attempt 1's pick) leaves a busy mini for
        # the owned nightly slot; a dispatch, or a re-run that picked again, takes its own owned pick.
        self.assertEqual(helper(**{'github.run_attempt': 2}), NIGHTLY_SLOT)
        self.assertEqual(helper(**{'github.event_name': 'workflow_dispatch'}), 'glaeda-side-std-xcode-26.6')
        self.assertEqual(helper(**{'github.run_attempt': 2, 'needs.pick-nightly-build-runner.outputs.attempt': '2'}),
                         'glaeda-side-std-xcode-26.6')
        # The dedicated builder admits only build-nightly-app: the helper never takes it.
        self.assertEqual(helper(**{'needs.pick-nightly-build-runner.outputs.helper': 'glaeda-trusted-next-nightly',
                                   'needs.pick-nightly-build-runner.outputs.dedicated': 'glaeda-trusted-next-nightly'}),
                         NIGHTLY_SLOT)
        # While the app build holds the dedicated builder, the helper takes its own idle owned pick.
        self.assertEqual(helper(**{'needs.pick-nightly-build-runner.outputs.owned': 'glaeda-trusted-next-nightly',
                                   'needs.pick-nightly-build-runner.outputs.dedicated': 'glaeda-trusted-next-nightly'}),
                         'glaeda-side-std-xcode-26.6')
        self.assertEqual(helper(**{'github.ref': 'refs/heads/main'}), 'glaeda-trusted-std-xcode-26.6')
        self.assertEqual(helper(**{'github.ref': 'refs/heads/main', 'github.event_name': 'schedule'}),
                         'glaeda-trusted-std-xcode-26.6')
        # No owned pick (busy fleet, no routing token): the owned nightly slot, never Blacksmith.
        for changes in ({'github.run_attempt': 2},
                        {'github.event_name': 'workflow_dispatch', 'needs.pick-nightly-build-runner.outputs.helper': ''},
                        {'github.ref': 'refs/heads/main', 'vars.CI_PR_POOL_OWNED': '0'},
                        {'needs.pick-nightly-build-runner.outputs.helper': ''},
                        {'github.ref': 'refs/heads/main', 'vars.CI_SEED_TRUSTED_POOL': ''},
                        {'github.ref': 'refs/heads/other'}):
            with self.subTest(changes=changes):
                self.assertEqual(helper(**changes), NIGHTLY_SLOT)
        # An unsigned resume reads the helper pick like a build.
        self.assertEqual(helper(**{'inputs.nightly_next_unsigned_run': '123'}), 'glaeda-side-std-xcode-26.6')
        # The nightly-only reservation, when enabled, comes first on attempt 1 only.
        self.assertEqual(helper(**{'vars.CI_NIGHTLY_ONLY_RUNNER': NIGHTLY_ONLY,
                                   'needs.decide.outputs.track': 'nightly-next'}), NIGHTLY_ONLY)
        self.assertEqual(helper(**{'vars.CI_NIGHTLY_ONLY_RUNNER': NIGHTLY_ONLY, 'github.run_attempt': 2,
                                   'needs.decide.outputs.track': 'nightly-next'}), NIGHTLY_SLOT)
        self.assertEqual(helper(**{'github.repository_owner': 'someone'}), 'macos-26')
        self.assertNotIn('macos-15', nightly_expand(WORKFLOW_FILE.read_text()))

    def test_next_build_and_prepare_never_name_a_hosted_mac_past_the_fork_branch(self):
        for name in ('build-nightly-app',):
            with self.subTest(job=name):
                source = DOC['jobs'][name]['runs-on'].replace("github.repository_owner != 'manaflow-ai' && 'macos-26'", '')
                self.assertIsNone(re.search(r"'macos-[0-9]+'", source))

    def test_missing_owned_pool_uses_the_nightly_only_builder(self):
        self.assertEqual(select(**{'vars.CI_SIDE_LANE_RUNNER': ''}), NIGHTLY_ONLY)

    def test_retries_take_the_nightly_only_builder_never_hosted_or_blacksmith(self):
        # A NEXT or main retry with no pick takes the plain nightly-only pool, never hosted, never
        # Blacksmith, whatever vars.MACOS_RUNNER_26 holds.
        self.assertEqual(select(**{'github.run_attempt': 2}), NIGHTLY_ONLY)
        self.assertEqual(select(**{'github.run_attempt': 2, 'github.ref': 'refs/heads/main'}), NIGHTLY_ONLY)

    def test_prepare_takes_our_nightly_pool_on_every_attempt(self):
        def prepare(**changes):
            source = DOC['jobs']['prepare-nightly-variant-primary']['runs-on'].removeprefix('${{').removesuffix('}}')
            context = {'github.repository_owner': 'manaflow-ai', 'github.repository': 'manaflow-ai/cmux',
                       'github.event_name': 'push', 'github.ref': 'refs/heads/nightly-next', 'github.run_attempt': 1,
                       'vars.CI_PR_POOL_OWNED': '1', **changes}
            return evaluate(parse_expression(source), context)
        # Unplaced, every attempt takes the nightly-only Mac pool, never Blacksmith.
        self.assertEqual(prepare(), NIGHTLY_ONLY)
        self.assertEqual(prepare(**{'github.run_attempt': 2}), NIGHTLY_ONLY)
        self.assertEqual(prepare(**{'inputs.nightly_next_unsigned_run': '123'}), NIGHTLY_ONLY)
        self.assertEqual(prepare(**{'github.repository_owner': 'someone'}), 'ubuntu-24.04')

    def test_prepare_fallback_follows_the_primary_then_retries_on_our_pool(self):
        # After a primary success the fallback is a no-op on the primary's (healthy) label; a retry after a
        # failed primary takes the nightly-only pool (several minis, never one host), never Blacksmith.
        def label(job, runner, primary_result=''):
            source = DOC['jobs'][job]['runs-on'].removeprefix('${{').removesuffix('}}')
            context = {'github.repository_owner': 'manaflow-ai', 'vars.LINUX_RUNNER': runner,
                               'github.run_attempt': 1,
                               'needs.decide.outputs.track': 'nightly-next',
                       'needs.prepare-nightly-variant-primary.result': primary_result}
            return evaluate(parse_expression(source), context)
        for runner in ('', 'blacksmith-16vcpu-ubuntu-2404', 'blacksmith-32vcpu-ubuntu-2404'):
            with self.subTest(runner=runner):
                primary = label('prepare-nightly-variant-primary', runner)
                self.assertEqual(label('prepare-nightly-variant', runner, 'success'), primary)
                self.assertEqual(label('prepare-nightly-variant', runner, 'failure'), NIGHTLY_ONLY)
        # Whatever LINUX_RUNNER holds, the retry never reads it.
        for runner in ('', 'ubuntu-24.04', 'blacksmith-4vcpu-ubuntu-2404', 'blacksmith-16vcpu-ubuntu-2404'):
            with self.subTest(runner=runner):
                self.assertEqual(label('prepare-nightly-variant', runner, 'failure'), NIGHTLY_ONLY)
        for job in ('prepare-nightly-variant-primary', 'prepare-nightly-variant'):
            self.assertNotIn('LINUX_RUNNER', DOC['jobs'][job]['runs-on'])
            self.assertNotIn('RUNNER_POOLS', DOC['jobs'][job]['runs-on'])



    def test_publication_controls_reject_unavailable_dedicated_m4pro(self):
        # Publication cannot use the dedicated label: glaeda-nightly-only-admit refuses every signing-class job,
        # since those minis have no exclusive-claim capacity. It takes the signer's label, never Blacksmith.
        jobs = DOC["jobs"]
        dedicated = {
            "github.repository_owner": "manaflow-ai",
            "github.repository": "manaflow-ai/cmux",
            "github.ref": "refs/heads/nightly-next",
            "github.event_name": "push",
            "github.run_attempt": 1,
            "vars.CI_NIGHTLY_ONLY_RUNNER": "glaeda-nightly-only-m4pro",
            "vars.LINUX_RUNNER": "blacksmith-16vcpu-ubuntu-2404",
            "needs.pick-nightly-sign-runner.outputs.attempt": "1",
            "needs.pick-nightly-sign-runner.outputs.sign_owned_pool": "",
        }
        for name in ("publish-nightly", "publish-nightly-next-github", "publish-nightly-next-github-names"):
            source = jobs[name]["runs-on"].removeprefix("${{").removesuffix("}}")
            expr = parse_expression(source)
            with self.subTest(job=name):
                self.assertNotEqual(evaluate(expr, dedicated), "glaeda-nightly-only-m4pro")
                self.assertEqual(evaluate(expr, dedicated), SIGNING_SLOT)
                self.assertNotEqual(evaluate(expr, {**dedicated, "github.repository": "someone/cmux",
                                                   "github.repository_owner": "someone"}),
                                    "glaeda-nightly-only-m4pro")
                self.assertEqual(evaluate(expr, {**dedicated, "github.repository": "someone/cmux",
                                                 "github.repository_owner": "someone"}), "ubuntu-24.04")
                for changes in ({"github.run_attempt": 2},
                                {"github.event_name": "schedule"},
                                {"github.ref": "refs/heads/main"},
                                {"vars.CI_NIGHTLY_ONLY_RUNNER": ""}):
                    with self.subTest(changes=changes):
                        self.assertNotEqual(evaluate(expr, {**dedicated, **changes}),
                                            "glaeda-nightly-only-m4pro")

    def test_every_linux_nightly_job_takes_one_of_our_runners(self):
        # Nightlies never use Blacksmith (Lawrence, 2026-10-30). Every job whose route can name Ubuntu (a
        # Linux control, or a fork's fallback) resolves, with no placement or pick, to GitHub-hosted Ubuntu,
        # the owned nightly slot or the nightly-only Mac pool, whatever LINUX_RUNNER or RUNNER_POOLS hold.
        # Only a secret job glaeda does not give the whole mini yet takes hosted Ubuntu.
        checked = 0
        for name, job in DOC['jobs'].items():
            runs_on = job.get('runs-on', '')
            if not isinstance(runs_on, str) or 'ubuntu' not in runs_on or 'macos' in runs_on:
                continue
            checked += 1
            source = runs_on.removeprefix('${{').removesuffix('}}')
            self.assertNotIn('blacksmith', source, name)
            self.assertNotIn('RUNNER_POOLS', source, name)
            self.assertNotIn('LINUX_RUNNER', source, name)
            for runner in ('', 'ubuntu-24.04', 'blacksmith-4vcpu-ubuntu-2404', 'blacksmith-16vcpu-ubuntu-2404',
                           'blacksmith-32vcpu-ubuntu-2404'):
                for attempt in (1, 2, 3):
                    for primary in ('success', 'failure'):
                        context = {'github.repository_owner': 'manaflow-ai', 'github.repository': 'manaflow-ai/cmux',
                                   'vars.LINUX_RUNNER': runner, 'github.run_attempt': attempt,
                                   'vars.RUNNER_POOLS': json.dumps({'linux': runner or 'blacksmith-4vcpu-ubuntu-2404'}),
                                   'needs.decide.outputs.track': 'nightly-next',
                                   'vars.CI_CLOUD_OVERFLOW_SAVED': '{"probe":"x"}',
                                   'needs.prepare-nightly-variant-primary.result': primary}
                        allowed = {HOSTED} if name in HOSTED_SECRET_JOBS else OUR_LABELS - {HOSTED}
                        with self.subTest(job=name, runner=runner, attempt=attempt, primary=primary):
                            self.assertIn(evaluate(parse_expression(source), context), allowed)
        self.assertGreater(checked, 20)

    def test_dispatch_fast_retries_rc_and_disabled_owned_use_the_nightly_only_builder(self):
        cases = [
            {'github.event_name': 'workflow_dispatch'},
            {'needs.decide.outputs.fast_build': 'true'}, {'vars.CI_PR_POOL_OWNED': '0'},
            {'github.ref': 'refs/heads/rc/1.2'}, {'github.repository': 'manaflow-ai/another'}, {'github.ref': 'refs/heads/feat-cmux-next'},
        ]
        for changes in cases:
            with self.subTest(changes=changes):
                # No pick, any ref: the plain nightly-only pool, never vars.MACOS_RUNNER_26 or Blacksmith.
                self.assertEqual(select(**changes), NIGHTLY_ONLY)
        self.assertEqual(select(**{'github.repository_owner': 'someone'}), 'macos-26')

    def test_trusted_next_uses_its_own_state_without_shared_cache_secrets(self):
        steps = {step.get('name'): step for step in DOC['jobs']['build-nightly-app']['steps']}
        context = {
            'needs.decide.outputs.track': 'nightly-next',
            'needs.decide.outputs.cold_cache': 'false',
            'steps.compilation-cache-bound.outputs.save': 'true',
            'steps.compilation-cache-restore.outputs.cache-hit': 'false',
            'steps.swift-packages-restore.outputs.cache-hit': 'false',
        }
        # The dedicated builder keeps DerivedData and its cache on its own
        # runner. A normal owned Mac starts clean but must use the shared cache.
        for name in ('Restore Xcode compilation cache', 'Cache Swift packages',
                     'Save Xcode compilation cache', 'Save Swift packages'):
            with self.subTest(step=name):
                self.assertFalse(evaluate(parse_expression(steps[name]['if']),
                                          {**context, 'steps.release-derived-data.outputs.mode': 'incremental'}))
                self.assertTrue(evaluate(parse_expression(steps[name]['if']),
                                         {**context, 'steps.release-derived-data.outputs.mode': ''}))

    def test_next_runs_do_not_hold_the_workflow_lock_for_post_publication_checks(self):
        group = DOC["concurrency"]["group"]
        self.assertIn(
            "github.ref == 'refs/heads/nightly-next' && (github.event_name == 'push' && 'push' || "
            "format('run-{0}', github.run_id))",
            group,
        )
        self.assertIn("github.ref_name == 'main' && 'nightly-shared'", group)

    def test_owned_next_and_main_have_independent_pending_slots(self):
        def group(branch, run_id=''):
            context = {
                'github.ref_name': branch,
                'github.ref': f'refs/heads/{branch}',
                'github.event_name': 'push',
                'github.run_id': run_id,
            }
            return re.sub(r'\$\{\{(.*?)\}\}',
                          lambda match: str(evaluate(parse_expression(match[1]), context)),
                          DOC['concurrency']['group'])
        self.assertEqual(group('main'), 'nightly-build-nightly-shared-full')
        # Every nightly-next push shares one group: a waiting push run is replaced by a newer one, so only the
        # newest head builds (Leo, 2026-11-05: "why do multiple merges even build the f***ing nightlies anyway?").
        self.assertEqual(group('nightly-next', '39124573091'), 'nightly-build-nightly-next-push')
        self.assertEqual(group('nightly-next', '39124573091'), group('nightly-next', '39124573100'))
        self.assertNotEqual(group('main'), group('nightly-next', '39124573091'))

    def test_every_nightly_build_has_its_own_slot(self):
        # A shared warm slot (nightly-next-build-app-warm) replaced waiting builds, which
        # the nightly rule forbids, and its holder stuck on a dead label (2026-10-26)
        # held every newer promotion. The warm route is a pool now, so every route,
        # warm or the nightly-only builder, keeps a slot per run.
        job = DOC['jobs']['build-nightly-app']
        def group(**changes):
            context = {
                'github.repository': 'manaflow-ai/cmux', 'github.event_name': 'push',
                'github.ref': 'refs/heads/nightly-next', 'github.run_attempt': 1, 'github.run_id': '1',
                'needs.decide.outputs.fast_build': 'false', 'vars.CI_PR_POOL_OWNED': '1',
                'vars.CI_SIDE_LANE_RUNNER': 'glaeda-side-std-xcode-26.6',
            }
            context.update(changes)
            return re.sub(r'\$\{\{(.*?)\}\}',
                          lambda match: str(evaluate(parse_expression(match[1]), context)),
                          job['concurrency']['group'])
        self.assertEqual(group(), 'nightly-build-app-1')
        self.assertNotEqual(group(**{'github.run_id': '2'}), group())
        self.assertIn('glaeda-side-std-xcode-26.6', select(**{'needs.pick-nightly-build-runner.outputs.owned': 'glaeda-side-std-xcode-26.6'}))
        self.assertEqual(select(**{'github.run_attempt': 2}), NIGHTLY_ONLY)
        self.assertEqual(select(**{'vars.CI_SIDE_LANE_RUNNER': ''}), NIGHTLY_ONLY)
        self.assertEqual(group(**{'vars.CI_SIDE_LANE_RUNNER': '', 'github.run_id': '1'}), 'nightly-build-app-1')
        self.assertEqual(group(**{'github.run_attempt': 2}), 'nightly-build-app-1')
        self.assertEqual(group(**{'github.event_name': 'workflow_dispatch'}), 'nightly-build-app-1')
        self.assertEqual(group(**{'github.ref': 'refs/heads/main'}), 'nightly-build-app-1')
        self.assertNotEqual(group(**{'github.event_name': 'workflow_dispatch'}), group(**{'github.event_name': 'workflow_dispatch', 'github.run_id': '2'}))
        self.assertFalse(job['concurrency']['cancel-in-progress'])

    def test_a_superseded_next_run_never_enters_the_build_slot(self):
        # Job concurrency is decided when the job becomes ready, not in push order:
        # an older run whose resolver finished late could otherwise replace the
        # newer run's waiting build. The resolver re-reads nightly-next last.
        resolver = DOC['jobs']['resolve-nightly-cmux-tui-client']
        self.assertEqual(resolver['steps'][-1]['id'], 'superseded')
        self.assertIn('git/ref/heads/nightly-next', resolver['steps'][-1]['run'])
        self.assertIn('superseded', resolver['outputs'])
        context = {'needs.decide.outputs.should_build': 'true', 'github.event_name': 'push',
                   'needs.resolve-nightly-cmux-tui-client.outputs.already_published': 'false',
                   'needs.decide.outputs.continue_only': 'false'}
        for job in ('build-nightly-app', 'build-nightly-ghostty-cli-helper'):
            build_if = parse_expression(DOC['jobs'][job]['if'])
            with self.subTest(job=job):
                self.assertTrue(evaluate(build_if, {**context, 'needs.resolve-nightly-cmux-tui-client.outputs.superseded': 'false'}))
                self.assertFalse(evaluate(build_if, {**context, 'needs.resolve-nightly-cmux-tui-client.outputs.superseded': 'true'}))

    def test_only_a_build_replaced_before_it_started_goes_unreported(self):
        script = next(step for step in DOC['jobs']['report-nightly-failure']['steps']
                      if step.get('name') == 'Open or update the nightly failure issue')['with']['script']
        # A replaced build never got a runner; a timed-out or cancelled one did.
        self.assertIn("!build.runner_name && !(build.steps || []).length", script)
        # Other failed jobs of the run still report.
        self.assertIn("!(replaced && k === 'build-nightly-app')", script)
        # listJobsForWorkflowRun needs Actions read; without it the timeout this
        # must still report would throw before any issue is opened.
        self.assertEqual(DOC['jobs']['report-nightly-failure']['permissions'].get('actions'), 'read')
        # A build cancelled while queued for a runner also never started; only a
        # newer push (nightly-next moved past this run's tip) makes it a replacement.
        step = next(step for step in DOC['jobs']['report-nightly-failure']['steps']
                    if step.get('name') == 'Open or update the nightly failure issue')
        self.assertIn('needs.decide.outputs.head_sha', step['env']['TIP_SHA'])
        self.assertIn("ref: 'heads/nightly-next'", script)
        self.assertIn("process.env.TIP_SHA", script)
        # An unreadable job list reports rather than going silent.
        self.assertIn("catch (error)", script.split("listJobsForWorkflowRun")[1][:600])

    def test_runner_guard_accepts_only_the_complete_nightly_capability_tuple(self):
        source = (ROOT / 'tests/test_ci_self_hosted_guard.sh').read_text()
        function = re.search(r'^check_no_self_hosted_fleet_runners\(\) \{\n.*?^\}',
                             source, re.M | re.S).group()
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory)
            workflows = fixture / '.github/workflows'
            workflows.mkdir(parents=True)
            nightly = workflows / 'nightly.yml'
            nightly.write_text('runs-on: ' + DOC['jobs']['build-nightly-app']['runs-on'] + '\n')
            script = 'ROOT_DIR="$1"\n' + function + '\ncheck_no_self_hosted_fleet_runners'
            def check():
                return subprocess.run(['bash', '-c', script, 'guard', str(fixture)], capture_output=True, text=True)
            self.assertEqual(check().returncode, 0)
            nightly.write_text('runs-on: glaeda-trusted-next-nightly\n')
            self.assertNotEqual(check().returncode, 0)

    def test_runner_guard_accepts_only_the_scoped_nightly_only_route(self):
        source = (ROOT / 'tests/test_ci_self_hosted_guard.sh').read_text()
        function = re.search(r'^check_no_self_hosted_fleet_runners\(\) \{\n.*?^\}',
                             source, re.M | re.S).group()
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory)
            workflows = fixture / '.github/workflows'
            workflows.mkdir(parents=True)
            nightly = workflows / 'nightly.yml'
            script = 'ROOT_DIR="$1"\n' + function + '\ncheck_no_self_hosted_fleet_runners'
            def check(route):
                nightly.write_text('runs-on: ' + route + '\n')
                result = subprocess.run(['bash', '-c', script, 'guard', str(fixture)],
                                        capture_output=True, text=True)
                return result.returncode
            for name in TAIL_CONTROL_JOBS:
                with self.subTest(job=name):
                    self.assertEqual(check(DOC['jobs'][name]['runs-on']), 0)
            route = DOC['jobs'][TAIL_CONTROL_JOBS[0]]['runs-on']
            for old, new in (("github.repository == 'manaflow-ai/cmux'", "github.repository == 'manaflow-ai/other'"),
                             ("track == 'nightly-next'", "track == 'nightly'"),
                             ("github.run_attempt == 1", "github.run_attempt >= 1"),
                             ('glaeda-nightly-only-m4pro', 'glaeda-unregistered')):
                with self.subTest(mutation=new):
                    self.assertNotEqual(check(route.replace(old, new)), 0)
            self.assertNotEqual(check('glaeda-nightly-only-m4pro'), 0)

    @unittest.skipUnless('nightly_next_unsigned_run' in DOC[True]['workflow_dispatch']['inputs'],
                         'unsigned resume is owned by PR 21161, not landed on this base yet')
    def test_unsigned_resume_stays_on_our_runners(self):
        # A resume restores the original inputs on the plain nightly-only pool (no Blacksmith Linux leg).
        self.assertEqual(select(**{'inputs.nightly_next_unsigned_run': '123'}), NIGHTLY_ONLY)
        self.assertNotIn('nightly_next_unsigned_run', DOC['jobs']['build-nightly-app']['runs-on'])



class LightJobsOnAFreeMini(unittest.TestCase):
    """The nightly's light jobs take a mini idle when build-nightly-app finished, else the nightly-only pool.

    Leo, 2026-10-31: "i mean the linux things cant our minis just run them" and "we just need the
    nightlies bro". await-nightly-tree-marker (bash, curl, python3) and the preparation jobs
    have no environment and no secret; build-nightly-app's last step places them
    (scripts/ci/portable_job_placement.py, NIGHTLY=1). Only those three jobs read its outputs, and no job
    that holds a signing or publishing environment ever does."""

    LIGHT = ('prepare-nightly-variant-primary', 'prepare-nightly-variant', 'await-nightly-tree-marker')
    MINI = 'glaeda-side-std-xcode-26.6'

    def runs_on(self, job, **changes):
        context = {'github.repository_owner': 'manaflow-ai', 'github.run_attempt': 1,
                   'vars.LINUX_RUNNER': 'blacksmith-32vcpu-ubuntu-2404',
                   'needs.build-nightly-app.outputs.light_attempt': '1',
                   'needs.build-nightly-app.outputs.light_mini_runner': self.MINI,
                   'needs.build-nightly-app.outputs.light_mini_jobs': f' {" ".join(self.LIGHT)} ', **changes}
        source = DOC['jobs'][job]['runs-on'].removeprefix('${{').removesuffix('}}')
        return evaluate(parse_expression(source), context)

    def test_a_placed_light_job_takes_the_free_mini(self):
        for job in self.LIGHT:
            with self.subTest(job=job):
                self.assertEqual(self.runs_on(job), self.MINI)
                # Placed only the other job: this one takes the nightly-only pool, never Blacksmith.
                other = next(name for name in self.LIGHT if name != job)
                self.assertEqual(self.runs_on(job, **{'needs.build-nightly-app.outputs.light_mini_jobs': f' {other} '}),
                                 NIGHTLY_ONLY)

    def test_no_placement_a_stale_one_or_a_fork_keeps_the_old_route(self):
        for job in self.LIGHT:
            for changes, expected in (
                    ({'needs.build-nightly-app.outputs.light_mini_jobs': ''}, None),
                    ({'needs.build-nightly-app.outputs.light_attempt': ''}, None),
                    # A re-run of failed jobs keeps attempt 1's outputs: the mini may be busy by now.
                    ({'github.run_attempt': 2}, None),
                    ({'vars.LINUX_RUNNER': 'blacksmith-16vcpu-ubuntu-2404', 'github.run_attempt': 2},
                     None),
                    ({'github.repository_owner': 'someone'}, 'ubuntu-24.04')):
                with self.subTest(job=job, changes=changes):
                    if expected is None:
                        # The nightly-only pool whatever LINUX_RUNNER holds, never Blacksmith.
                        expected = NIGHTLY_ONLY
                    self.assertEqual(self.runs_on(job, **changes), expected)

    def test_light_jobs_hold_no_environment_and_no_secret(self):
        for job in self.LIGHT:
            with self.subTest(job=job):
                self.assertNotIn('environment', DOC['jobs'][job])
                self.assertNotIn('secrets.', json.dumps(DOC['jobs'][job]))
                self.assertNotIn('id-token', DOC['jobs'][job].get('permissions', {}))

    def test_only_the_light_jobs_read_the_placement(self):
        readers = sorted(name for name, job in DOC['jobs'].items() if 'light_mini' in str(job.get('runs-on', '')))
        self.assertEqual(readers, sorted(self.LIGHT))
        step = next(step for step in DOC['jobs']['build-nightly-app']['steps'] if step.get('id') == 'place-light-start')
        self.assertEqual(step['env']['JOBS'].split(), list(self.LIGHT))
        self.assertEqual(step['env']['NIGHTLY'], '1')
        self.assertEqual(step['env']['NIGHTLY_WAIT_FOR_FLEET'], '1')
        self.assertEqual(step['timeout-minutes'], 5)
        # No fleet Linux step: a nightly job never takes vars.LINUX_RUNNER as it is.
        self.assertEqual(step['env']['FLEET_LINUX'], '')
        self.assertTrue(step['continue-on-error'])
        # Only after the token the nightly-next-only mint step makes.
        self.assertIn("steps.light-route-token.outputs.token != ''", step['if'])

    def test_the_placement_waits_beside_the_uploads_and_is_collected_last(self):
        steps = DOC['jobs']['build-nightly-app']['steps']
        ids = [step.get('id') for step in steps]
        names = [step.get('name') for step in steps]
        start, collect = steps[ids.index('place-light-start')], steps[ids.index('place-light')]
        self.assertEqual(start['run'], 'bash scripts/ci/nightly-steps/light-placement.sh start')
        self.assertEqual(collect['run'], 'bash scripts/ci/nightly-steps/light-placement.sh finish')
        # Started before the archive and the uploads, so its wait for an idle runner overlaps them.
        self.assertLess(ids.index('light-route-token'), ids.index('place-light-start'))
        self.assertLess(ids.index('place-light-start'), names.index('Archive unsigned nightly app'))
        self.assertLess(names.index('Upload unsigned nightly app'), ids.index('place-light'))
        # Collected only when started, and still the last step before the always() cleanup that ends it.
        self.assertIn("steps.place-light-start.outcome == 'success'", collect['if'])
        self.assertTrue(collect['continue-on-error'])
        # Only the helper cleanup follows it (the fleet Linux offer is gone: nightlies run only on our minis).
        self.assertEqual(names[ids.index('place-light') + 1:], ['Stop the helper builds still running'])
        self.assertTrue(steps[-1]['if'].startswith('always()'))
        # The job's outputs read the collecting step.
        outputs = DOC['jobs']['build-nightly-app']['outputs']
        for key in ('light_mini_runner', 'light_mini_jobs', 'light_attempt'):
            with self.subTest(output=key):
                self.assertIn('steps.place-light.', outputs[key])
                self.assertNotIn('place-light-start', outputs[key])

    def test_the_build_job_mints_only_the_routing_token_for_the_placement(self):
        steps = DOC['jobs']['build-nightly-app']['steps']
        mint = next(step for step in steps if step.get('id') == 'light-route-token')
        self.assertIn("github.ref == 'refs/heads/nightly-next'", mint['if'])
        self.assertIn("inputs.nightly_next_unsigned_run == ''", mint['if'])
        self.assertEqual(mint['with']['private-key'], '${{ secrets.GLAEDA_ROUTE_APP_KEY }}')
        self.assertEqual(sorted(key for key in mint['with'] if key.startswith('permission-')),
                         ['permission-administration', 'permission-organization-self-hosted-runners'])
        self.assertTrue(all(value == 'read' for key, value in mint['with'].items() if key.startswith('permission-')))


    def test_light_placement_runs_in_the_background_and_hands_its_outputs_to_the_collecting_step(self):
        with tempfile.TemporaryDirectory() as tmp:
            tree = Path(tmp) / 'tree'
            (tree / 'scripts/ci/nightly-steps').mkdir(parents=True)
            for name in ('scripts/ci/background_build.py', 'scripts/ci/nightly-steps/light-placement.sh'):
                (tree / name).write_bytes((ROOT / name).read_bytes())
            # A stand-in placement: it writes the outputs and summary the real one writes, after
            # the start step has already returned.
            (tree / 'scripts/ci/portable_job_placement.py').write_text(
                'import os, time\n'
                'time.sleep(1)\n'
                'open(os.environ["GITHUB_OUTPUT"], "a").write("mini_runner=glaeda-nightly-only-m4pro\\n'
                'mini_jobs= prepare-nightly-variant \\n")\n'
                'open(os.environ["GITHUB_STEP_SUMMARY"], "a").write("placed\\n")\n'
                'print("portable placement: placed")\n')
            runner_temp = Path(tmp) / 'runner'
            runner_temp.mkdir()
            start_out, finish_out, summary = (Path(tmp) / n for n in ('start.out', 'finish.out', 'summary'))
            for path in (start_out, finish_out, summary):
                path.write_text('')
            base = {**os.environ, 'RUNNER_TEMP': str(runner_temp)}
            script = ['bash', 'scripts/ci/nightly-steps/light-placement.sh']
            subprocess.run([*script, 'start'], cwd=tree, check=True, capture_output=True,
                           env={**base, 'GITHUB_OUTPUT': str(start_out), 'GITHUB_STEP_SUMMARY': str(summary)})
            finished = subprocess.run([*script, 'finish'], cwd=tree, capture_output=True, text=True,
                                      env={**base, 'GITHUB_OUTPUT': str(finish_out), 'GITHUB_STEP_SUMMARY': str(summary)})
            self.assertEqual(finished.returncode, 0, finished.stdout + finished.stderr)
            self.assertIn('portable placement: placed', finished.stdout)
            self.assertEqual(start_out.read_text(), '')
            self.assertEqual(finish_out.read_text(),
                             'mini_runner=glaeda-nightly-only-m4pro\nmini_jobs= prepare-nightly-variant \n')
            self.assertEqual(summary.read_text(), 'placed\n')
            # A placement that fails fails the collecting step (continue-on-error), so the light jobs take the
            # nightly-only pool.
            (tree / 'scripts/ci/portable_job_placement.py').write_text('raise SystemExit(3)\n')
            subprocess.run(['rm', '-rf', str(runner_temp / 'nightly-helper-builds')], check=True)
            subprocess.run([*script, 'start'], cwd=tree, check=True, capture_output=True,
                           env={**base, 'GITHUB_OUTPUT': str(start_out), 'GITHUB_STEP_SUMMARY': str(summary)})
            failed = subprocess.run([*script, 'finish'], cwd=tree, capture_output=True, text=True,
                                    env={**base, 'GITHUB_OUTPUT': str(finish_out), 'GITHUB_STEP_SUMMARY': str(summary)})
            self.assertNotEqual(failed.returncode, 0)


class CmuxTuiClientPrefetch(unittest.TestCase):
    """The cmux-tui client "Bundle the cmux-tui client" installs is fetched beside the compile into the
    cache that step reads, with the same manifest and checks, and joined before the install."""

    def test_the_prefetch_fetches_what_the_bundle_step_installs_into_its_cache(self):
        steps = DOC['jobs']['build-nightly-app']['steps']
        by_name = {step.get('name'): step for step in steps}
        fetch, bundle = by_name['Fetch the resolved cmux-tui tree companions'], by_name['Bundle the cmux-tui client']
        for key in ('CMUX_TUI_CLIENT_COMMIT', 'CMUX_TUI_CLIENT_CACHE'):
            with self.subTest(env=key):
                self.assertEqual(fetch['env'][key], bundle['env'][key])
        # GH_TOKEN would change how pin-cmux-tui.sh reads GitHub in the same step: only the prefetch gets it.
        self.assertNotIn('GH_TOKEN', fetch['env'])
        self.assertEqual(fetch['env']['PREFETCH_GH_TOKEN'], bundle['env']['GH_TOKEN'])
        # The prefetch never runs where the bundle step does not, nor before the tree is published.
        for condition in ("needs.decide.outputs.fast_build != 'true'", "needs.decide.outputs.build_only != 'true'"):
            self.assertIn(condition, fetch['if'])
            self.assertIn(condition, bundle['if'])
        self.assertIn("needs.resolve-nightly-cmux-tui-client.outputs.tree_pending != 'true'", fetch['if'])
        self.assertLess(steps.index(fetch), [step.get('name') for step in steps].index('Build nightly app (Release)'))
        prefetch = (ROOT / 'scripts/ci/nightly-steps/app-fetch-tree-companions.sh').read_text()
        install = (ROOT / 'scripts/ci/nightly-steps/app-bundle-cmux-tui-client.sh').read_text()
        for flag in ('--require-capability wireguard-hub', '--require-acpmux',
                     'https://files.cmux.com/cmux-tui/${'):
            with self.subTest(flag=flag):
                self.assertIn(flag, prefetch)
                self.assertIn(flag, install)
        self.assertIn('background_build.py start --state "$RUNNER_TEMP/nightly-helper-builds" cmux-tui-client', prefetch)
        join = install.index('background_build.py join --state "$state" cmux-tui-client')
        self.assertLess(join, install.index('./scripts/install-cmux-tui-client.sh'))
        # A failed prefetch drops its cache, so the install downloads everything itself.
        self.assertIn('rm -rf "${CMUX_TUI_CLIENT_CACHE:?}"', install[join:install.index('./scripts/install-cmux-tui-client.sh')])


class PrimaryPreparationOnFleetLinux(unittest.TestCase):
    """prepare-nightly-variant-primary takes fleet Linux first: median 45 s on Linux against 202 s on a
    dedicated nightly Mac (download 49 s and upload 85 s on the Mac network). build-nightly-app's place-fleet
    names the label only while an idle runner waits there, so the job starts at once; otherwise the light
    placement's mini, then the nightly-only pool, never Blacksmith (#31636 reverted a Blacksmith-only route that
    queued 5-14 min)."""

    FLEET = 'cmux-fleet-linux-x64'
    MINI = 'glaeda-nightly-only-m4pro'

    def runs_on(self, **changes):
        context = {'github.repository_owner': 'manaflow-ai', 'github.run_attempt': 1,
                   'vars.LINUX_RUNNER': 'blacksmith-32vcpu-ubuntu-2404',
                   'needs.build-nightly-app.outputs.light_attempt': '1',
                   'needs.build-nightly-app.outputs.light_linux_runner': self.FLEET,
                   'needs.build-nightly-app.outputs.light_mini_runner': self.MINI,
                   'needs.build-nightly-app.outputs.light_mini_jobs': ' prepare-nightly-variant-primary ', **changes}
        source = DOC['jobs']['prepare-nightly-variant-primary']['runs-on'].removeprefix('${{').removesuffix('}}')
        return evaluate(parse_expression(source), context)


    def test_the_fallback_leg_keeps_its_mini_and_pool_route(self):
        fallback = DOC['jobs']['prepare-nightly-variant']
        self.assertNotIn('light_linux_runner', fallback['runs-on'])
        self.assertIn('prepare-nightly-variant-primary', fallback['needs'])



class DaemonBesideTheApp(unittest.TestCase):
    """build-nightly-remote-daemon (a Go cross-compile on Linux) builds while build-nightly-app compiles,
    not after it: its queue and build sat between the app and signing (Leo, 2026-10-31, on "the daemon
    built alongside the app": "just do whatever hurries all this shit up"). Both take the run's build
    number from resolve-nightly-cmux-tui-client, so a re-run of only one of them (the owned-pool rescue
    re-runs the app's picker and its dependents) still names the same daemon assets."""

    def test_the_daemon_does_not_wait_for_the_app(self):
        daemon = DOC['jobs']['build-nightly-remote-daemon']
        self.assertNotIn('build-nightly-app', daemon['needs'])
        self.assertNotIn('needs.build-nightly-app', json.dumps(daemon))
        # It runs exactly when the app builds (and never for a build-only measurement).
        app_if = DOC['jobs']['build-nightly-app']['if']
        self.assertTrue(daemon['if'].startswith(app_if), daemon['if'])
        self.assertIn("needs.decide.outputs.build_only != 'true'", daemon['if'])

    def test_one_build_number_for_the_app_and_the_daemon(self):
        jobs = DOC['jobs']
        resolve = jobs['resolve-nightly-cmux-tui-client']
        self.assertEqual(resolve['outputs']['daemon_build'], '${{ steps.daemon-build.outputs.build }}')
        step = next(step for step in resolve['steps'] if step.get('id') == 'daemon-build')
        self.assertIn('${GITHUB_RUN_ID}$(printf \'%02d\' "${GITHUB_RUN_ATTEMPT:-1}")', step['run'])
        source = '${{ needs.resolve-nightly-cmux-tui-client.outputs.daemon_build }}'
        metadata = next(step for step in jobs['build-nightly-app']['steps'] if step.get('id') == 'remote_daemon')
        # The step passes the resolver's build to its script (scripts/ci/nightly-steps/) through env.
        self.assertEqual(metadata['env']['RESOLVED_DAEMON_BUILD'], source)
        self.assertIn('build="${RESOLVED_DAEMON_BUILD}"', metadata['run'])
        self.assertNotIn('GITHUB_RUN_ATTEMPT', metadata['run'])
        build = next(step for step in jobs['build-nightly-remote-daemon']['steps']
                     if step['name'] == 'Build immutable SSH daemon assets once for every app variant')
        self.assertEqual(build['env']['BUILD'], source)
        # The same version formula as the app's step; verify_remote_daemon_release.py refuses a mismatch.
        self.assertIn('nightly_version.py marketing --track "$TRACK"', build['run'])
        self.assertIn('--next-base "$(python3 scripts/ci/nightly_version.py next-base)"', build['run'])

    def test_the_daemon_takes_the_helper_pick_else_the_owned_nightly_pool(self):
        # Nightlies never run on Blacksmith (user, Oct 30): run 41683652930 built the daemon on
        # blacksmith-32vcpu-ubuntu-2404 because the helper pick was empty. With no helper, NEXT's first
        # attempt takes the all-nightly reservation, and every other case our nightly-only pool.
        source = DOC['jobs']['build-nightly-remote-daemon']['runs-on'].removeprefix('${{').removesuffix('}}')
        mini = 'glaeda-side-std-xcode-26.6'
        base = {'github.repository_owner': 'manaflow-ai', 'github.repository': 'manaflow-ai/cmux',
                'github.ref': 'refs/heads/nightly-next', 'github.run_attempt': 1,
                'needs.decide.outputs.track': 'nightly-next',
                'vars.LINUX_RUNNER': 'blacksmith-32vcpu-ubuntu-2404',
                'vars.CI_NIGHTLY_ONLY_RUNNER': 'glaeda-nightly-only-m4pro',
                'needs.pick-nightly-build-runner.outputs.attempt': '1',
                'needs.pick-nightly-build-runner.outputs.helper': mini,
                'needs.pick-nightly-build-runner.outputs.dedicated': 'glaeda-nightly-dedicated'}
        self.assertEqual(evaluate(parse_expression(source), base), mini)
        for changes in ({'needs.pick-nightly-build-runner.outputs.helper': ''},
                        {'needs.pick-nightly-build-runner.outputs.dedicated': mini},
                        {'github.run_attempt': 2},
                        {'github.ref': 'refs/heads/main', 'needs.decide.outputs.track': 'nightly'},
                        {'needs.pick-nightly-build-runner.outputs.helper': '', 'vars.CI_NIGHTLY_ONLY_RUNNER': ''}):
            with self.subTest(changes=changes):
                self.assertEqual(evaluate(parse_expression(source), {**base, **changes}), 'glaeda-nightly-only-m4pro')
        self.assertNotIn('RUNNER_POOLS', source)
        self.assertNotIn('blacksmith', source)
        self.assertEqual(evaluate(parse_expression(source), {**base, 'github.repository_owner': 'fork'}), 'ubuntu-24.04')

    def test_the_daemon_attestation_takes_the_owned_nightly_pool_first(self):
        job = DOC['jobs']['attest-nightly-remote-daemon']
        source = job['runs-on'].removeprefix('${{').removesuffix('}}')
        context = {'github.repository_owner': 'manaflow-ai', 'github.repository': 'manaflow-ai/cmux',
                   'github.ref': 'refs/heads/nightly-next', 'github.run_attempt': 1,
                   'vars.CI_NIGHTLY_ONLY_RUNNER': 'glaeda-nightly-only-m4pro'}
        self.assertEqual(evaluate(parse_expression(source), context), 'glaeda-nightly-only-m4pro')
        self.assertEqual(evaluate(parse_expression(source), {'github.repository_owner': 'fork'}), 'ubuntu-24.04')
        self.assertEqual(job['permissions'], {'contents': 'read', 'attestations': 'write', 'id-token': 'write'})

    def test_the_daemon_is_a_peer_the_app_build_stops_for(self):
        peers = DOC['jobs']['build-nightly-app']['env']['NIGHTLY_PUBLISH_PEERS'].split()
        self.assertIn('build-nightly-remote-daemon', peers)


class PickerReRun(unittest.TestCase):
    """The owned-pool rescue and the nightly-next tick re-run pick-nightly-build-runner, and with it every job
    that needs it, so a re-run picks its runner fresh (scripts/ci/owned_pool_rescue.py repick_job(), on main).
    That re-runs the Ghostty helper even after it succeeded, and an artifact name it already uploaded is
    refused unless the upload overwrites: without that, the rescue falls back to a re-run of failed jobs,
    which keeps attempt 1's stalled pick."""

    def test_the_ghostty_helper_s_uploads_overwrite(self):
        steps = DOC['jobs']['build-nightly-ghostty-cli-helper']['steps']
        uploads = [step for step in steps if 'actions/upload-artifact@' in str(step.get('uses', ''))]
        self.assertTrue(uploads)
        for step in uploads:
            self.assertIs(step['with'].get('overwrite'), True, step['with'].get('name'))

    def test_the_daemon_s_upload_overwrites(self):
        # It builds beside the app, so a picker re-run that rescues a stuck app build re-runs it after it succeeded.
        steps = DOC['jobs']['build-nightly-remote-daemon']['steps']
        uploads = [step for step in steps if 'actions/upload-artifact@' in str(step.get('uses', ''))]
        self.assertTrue(uploads)
        for step in uploads:
            self.assertIs(step['with'].get('overwrite'), True, step['with'].get('name'))

    def test_the_picker_s_own_marker_upload_overwrites(self):
        steps = DOC['jobs']['pick-nightly-build-runner']['steps']
        for step in steps:
            if 'actions/upload-artifact@' in str(step.get('uses', '')):
                self.assertIs(step['with'].get('overwrite'), True, step['with'].get('name'))


CREDENTIALED_CONTROL_JOBS = ('attest-nightly-remote-daemon', 'route-visual-gate-nightly', 'published-in')


class CredentialedControls(unittest.TestCase):
    """The visual-gate router and the published-in comment never read RUNNER_POOLS or another Blacksmith route
    (nightlies never use Blacksmith). published-in takes hosted Ubuntu; the router, which holds the
    routing App key, takes the reservation on attempt 1 when it is enabled, else hosted Ubuntu."""

    def select(self, job, pool='', attempt=1, owner='manaflow-ai', variable=''):
        source = DOC['jobs'][job]['runs-on'].removeprefix('${{').removesuffix('}}')
        return evaluate(parse_expression(source), {
            'github.repository_owner': owner, 'github.repository': f'{owner}/cmux',
            'github.ref': 'refs/heads/nightly-next', 'needs.decide.outputs.track': 'nightly-next',
            'github.run_attempt': attempt, 'vars.RUNNER_POOLS': pool, 'vars.CI_NIGHTLY_ONLY_RUNNER': variable,
        })

    def test_the_pool_variable_is_never_read(self):
        for job in CREDENTIALED_CONTROL_JOBS:
            with self.subTest(job=job):
                runs_on = DOC['jobs'][job]['runs-on']
                self.assertNotIn('RUNNER_POOLS', runs_on)
                self.assertNotIn('blacksmith', runs_on)
                self.assertNotIn('LINUX_RUNNER', runs_on)

    def test_every_attempt_takes_our_nightly_pool(self):
        # Every attempt takes the nightly-only pool: its minis run only nightly.yml from nightly-next or main
        # (glaeda-nightly-only-admit), so a credentialed control never shares a mini with PR code.
        for job in CREDENTIALED_CONTROL_JOBS:
            for pool in ('', '{}', '{"linux":"blacksmith-16vcpu-ubuntu-2404"}', '{"linux":"cmux-fleet-linux-x64"}'):
                for attempt in (1, 2, 3):
                    for variable in ('', NIGHTLY_ONLY):
                        with self.subTest(job=job, pool=pool, attempt=attempt, variable=variable):
                            expected = NIGHTLY_ONLY
                            self.assertEqual(self.select(job, pool, attempt, variable=variable), expected)

    def test_forks_short_circuit_pool_parsing(self):
        for job in CREDENTIALED_CONTROL_JOBS:
            self.assertEqual(self.select(job, 'not json', owner='someone'), 'ubuntu-24.04')

    def test_credential_permissions_remain_scoped_to_each_control(self):
        self.assertEqual(DOC['jobs'][CREDENTIALED_CONTROL_JOBS[0]]['permissions'], {
            'contents': 'read', 'attestations': 'write', 'id-token': 'write'})
        self.assertEqual(DOC['jobs'][CREDENTIALED_CONTROL_JOBS[1]]['environment'], 'ci-routing-agent')
        self.assertEqual(DOC['jobs'][CREDENTIALED_CONTROL_JOBS[2]]['permissions'], {
            'contents': 'read', 'pull-requests': 'write'})



if __name__ == '__main__':
    unittest.main()
