#!/usr/bin/env python3
"""Execute nightly runner selectors for pooled native work and Linux control work."""
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
# The nightly signer jobs and their Linux picker.
SIGNER_ROUTE_JOBS = ('signer-build', 'signer-app', 'signer-app-notary', 'signer-dmg', 'pick-nightly-sign-runner')
TAIL_CONTROL_JOBS = (
    'visual-gate-nightly-verdict', 'report-visual-gate-nightly',
    'nightly-identity-legacy-published', 'report-nightly-failure', 'close-nightly-failure-issue',
)


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
            return json.loads(args[0])
        if node[1].lower() == 'contains':
            return str(args[1]).lower() in str(args[0]).lower()
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
                        expected = ('ubuntu-24.04' if attempt == 1 else
                                    overflow or 'blacksmith-32vcpu-ubuntu-2404')
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
                                expected = ('ubuntu-24.04' if owner != 'manaflow-ai' or attempt == 1
                                            else overflow or 'blacksmith-32vcpu-ubuntu-2404')
                                if repository == 'manaflow-ai/cmux' and track == 'nightly-next' and attempt == 1 and activation == dedicated:
                                    expected = dedicated
                                with self.subTest(job=name, **context):
                                    self.assertEqual(evaluate(expr, context), expected)

    def test_next_push_selects_the_picked_idle_owned_mac(self):
        picked = {'needs.pick-nightly-build-runner.outputs.owned': 'glaeda-side-std-xcode-26.6',
                  'needs.pick-nightly-build-runner.outputs.blacksmith': 'blacksmith-6vcpu-macos-26'}
        self.assertEqual(select(**picked), 'glaeda-side-std-xcode-26.6')
        # No idle owned runner now: the moving Blacksmith label, never a wait on the owned queue.
        self.assertEqual(select(**{**picked, 'needs.pick-nightly-build-runner.outputs.owned': ''}),
                         'blacksmith-6vcpu-macos-26')

    def test_main_keeps_its_worker_and_writer_environment(self):
        changes = {'github.ref': 'refs/heads/main'}
        self.assertEqual(select(**changes), 'glaeda-trusted-std-xcode-26.6')
        self.assertEqual(select('environment', **changes), 'ci-cache-writer')
        self.assertEqual(select('environment'), '')

    def test_next_build_never_waits_on_one_label_with_no_fallback(self):
        # Row 3 of the 2026-10-27 nightly path audit: the build read vars.CI_NIGHTLY_NEXT_BUILD_RUNNER
        # alone for every attempt, so two runs died at "Set up runner" and a rescue re-run went back
        # to the label that had refused it. The variable now only feeds the picker (OWNED_LABELS), and a
        # re-run of failed jobs (attempt 2, the rescue's), which keeps attempt 1's pick, takes the picked
        # Blacksmith label. A re-run that picks again reads its own pick.
        picked = {'needs.pick-nightly-build-runner.outputs.owned': 'glaeda-side-std-xcode-26.6',
                  'needs.pick-nightly-build-runner.outputs.blacksmith': 'blacksmith-6vcpu-macos-26',
                  'vars.CI_NIGHTLY_NEXT_BUILD_RUNNER': 'glaeda-dev-std-xcode-26.6'}
        self.assertEqual(select(**{**picked, 'github.run_attempt': 2}), 'blacksmith-6vcpu-macos-26')
        self.assertEqual(select(**{**picked, 'github.run_attempt': 3}), 'blacksmith-6vcpu-macos-26')
        self.assertEqual(select(**{**picked, 'github.run_attempt': 2,
                                   'needs.pick-nightly-build-runner.outputs.attempt': '2'}),
                         'glaeda-side-std-xcode-26.6')
        self.assertEqual(select(**{**picked, 'github.event_name': 'workflow_dispatch'}), 'glaeda-side-std-xcode-26.6')
        # A failed pick (empty outputs) takes Blacksmith 6 vCPU, never an unvalidated variable.
        for variable in ('macos-26', 'macos-15', 'glaeda-side-std-xcode-26.6', 'blacksmith-12vcpu-macos-26', ''):
            for attempt in (1, 2):
                with self.subTest(variable=variable, attempt=attempt):
                    self.assertEqual(select(**{'vars.CI_NIGHTLY_NEXT_BUILD_RUNNER': 'glaeda-dev-std-xcode-26.6',
                                               'vars.MACOS_RUNNER_26': variable, 'github.run_attempt': attempt}),
                                     'blacksmith-6vcpu-macos-26')
        self.assertEqual(select(**{**picked, 'inputs.nightly_next_unsigned_run': '123'}), 'blacksmith-32vcpu-ubuntu-2404')
        self.assertEqual(select(**{**picked, 'github.repository_owner': 'someone'}), 'macos-26')

    def test_decide_uses_only_read_permissions_for_metadata_and_placement(self):
        job = DOC['jobs']['decide']
        self.assertEqual(job['permissions'], {'actions': 'read', 'checks': 'read', 'contents': 'read'})
        script = next(step['with']['script'] for step in job['steps'] if step.get('id') == 'decide')
        self.assertNotRegex(script, r"github\.rest\.[A-Za-z]+\.(?:create|update|delete|upload)")
        self.assertNotIn('core.exportVariable', script)

    def test_decide_bootstraps_on_declared_hosted_linux_without_phantom_fleet(self):
        # No preceding job can give decide a live runner receipt. Its bounded
        # admission step still tries fleet for downstream work before overflow.
        route = DOC['jobs']['decide']['runs-on'].removeprefix('${{').removesuffix('}}')
        for attempt in (1, 2, 3):
            for configured in ('', 'unregistered-fleet', 'blacksmith-16vcpu-ubuntu-2404'):
                context = {'github.repository_owner': 'manaflow-ai', 'github.run_attempt': attempt,
                           'vars.CI_CONTROL_RUNNER': 'unregistered-fleet',
                           'vars.CI_NIGHTLY_NEXT_BUILD_RUNNER': 'unregistered-mini',
                           'vars.LINUX_RUNNER': configured}
                paid = configured if configured.startswith('blacksmith-') else 'blacksmith-32vcpu-ubuntu-2404'
                self.assertEqual(evaluate(parse_expression(route), context),
                                 'ubuntu-24.04' if attempt == 1 else paid)
        self.assertEqual(DOC['jobs']['decide']['environment'], 'ci-routing-agent')

    def test_only_the_nightly_routes_read_the_next_build_runner(self):
        readers = sorted(path.name for path in (ROOT / '.github/workflows').glob('*.y*ml')
                         if 'vars.CI_NIGHTLY_NEXT_BUILD_RUNNER' in path.read_text()
                         and 'CMUX_CI_RUNNER_VARIABLES' not in path.read_text())
        self.assertEqual(readers, ['nightly.yml'])
        uses = sorted(name for name, job in DOC['jobs'].items() if 'CI_NIGHTLY_NEXT_BUILD_RUNNER' in str(job.get('runs-on', '')))
        # The existing native routes use the nightly slot; the three secret-free Mac
        # jobs also read it for the bounded attempt-2 retry added in #29847. OwnedVerify in
        # test_nightly_sign_runner.py checks that retry and its later overflow destinations.
        self.assertEqual(uses, ['generate-nightly-deltas', 'sign-nightly-identity-legacy',
                                'signer-dmg-image', 'verify-final-dmg-nightly',
                                'verify-nightly-identity-legacy', 'verify-signed-nightly'])
        steps = sorted(name for name, job in DOC['jobs'].items() if 'CI_NIGHTLY_NEXT_BUILD_RUNNER' in str(job.get('steps', '')))
        # The verify jobs' owned pick (pick-nightly-sign-runner) offers the same labels as the build's.
        self.assertEqual(steps, ['pick-nightly-build-runner', 'pick-nightly-sign-runner'])

    def test_ghostty_helper_takes_owned_macos_26_then_blacksmith_macos_26(self):
        # Leo: "bro WHAT THE FUCK IS THE POINT OF 15???????? WHY". The helper builds with
        # Zig 0.16.0 against the macOS 26 SDK, so it takes build-nightly-app's owned pools
        # and falls back to Blacksmith macOS 26: never macOS 15, never a hosted Mac.
        def helper(**changes):
            return evaluate(parse_expression(
                DOC['jobs']['build-nightly-ghostty-cli-helper']['runs-on'].removeprefix('${{').removesuffix('}}')),
                {'github.repository_owner': 'manaflow-ai', 'github.repository': 'manaflow-ai/cmux',
                 'github.event_name': 'push', 'github.ref': 'refs/heads/nightly-next', 'github.run_attempt': 1,
                 'vars.CI_PR_POOL_OWNED': '1', 'vars.CI_SIDE_LANE_RUNNER': 'glaeda-side-std-xcode-26.6',
                 'vars.CI_SEED_TRUSTED_POOL': 'glaeda-trusted-std-xcode-26.6',
                 # nightly-next reads pick-nightly-build-runner's owned and Blacksmith picks
                 # (tests/test_nightly_build_runner.py covers every combination).
                 'needs.pick-nightly-build-runner.outputs.helper': 'glaeda-side-std-xcode-26.6',
                 'needs.pick-nightly-build-runner.outputs.attempt': '1',
                 'needs.pick-nightly-build-runner.outputs.dedicated': '',
                 'needs.pick-nightly-build-runner.outputs.blacksmith': 'blacksmith-6vcpu-macos-26', **changes})
        self.assertEqual(helper(), 'glaeda-side-std-xcode-26.6')
        # A retry or rescue re-run (a re-run of failed jobs keeps attempt 1's pick) leaves a busy mini for
        # Blacksmith macOS 26; a dispatch, or a re-run that picked again, takes its own owned pick.
        self.assertEqual(helper(**{'github.run_attempt': 2}), 'blacksmith-6vcpu-macos-26')
        self.assertEqual(helper(**{'github.event_name': 'workflow_dispatch'}), 'glaeda-side-std-xcode-26.6')
        self.assertEqual(helper(**{'github.run_attempt': 2, 'needs.pick-nightly-build-runner.outputs.attempt': '2'}),
                         'glaeda-side-std-xcode-26.6')
        # The dedicated builder admits only build-nightly-app: the helper never takes it.
        self.assertEqual(helper(**{'needs.pick-nightly-build-runner.outputs.helper': 'glaeda-trusted-next-nightly',
                                   'needs.pick-nightly-build-runner.outputs.dedicated': 'glaeda-trusted-next-nightly'}),
                         'blacksmith-6vcpu-macos-26')
        # While the app build holds the dedicated builder, the helper takes its own idle owned pick.
        self.assertEqual(helper(**{'needs.pick-nightly-build-runner.outputs.owned': 'glaeda-trusted-next-nightly',
                                   'needs.pick-nightly-build-runner.outputs.dedicated': 'glaeda-trusted-next-nightly'}),
                         'glaeda-side-std-xcode-26.6')
        self.assertEqual(helper(**{'github.ref': 'refs/heads/main'}), 'glaeda-trusted-std-xcode-26.6')
        self.assertEqual(helper(**{'github.ref': 'refs/heads/main', 'github.event_name': 'schedule'}),
                         'glaeda-trusted-std-xcode-26.6')
        # No owned pick (busy fleet, no routing token): Blacksmith.
        for changes in ({'github.run_attempt': 2},
                        {'github.event_name': 'workflow_dispatch', 'needs.pick-nightly-build-runner.outputs.helper': ''},
                        {'github.ref': 'refs/heads/main', 'vars.CI_PR_POOL_OWNED': '0'},
                        {'needs.pick-nightly-build-runner.outputs.helper': ''},
                        {'github.ref': 'refs/heads/main', 'vars.CI_SEED_TRUSTED_POOL': ''},
                        {'github.ref': 'refs/heads/other'}):
            with self.subTest(changes=changes):
                self.assertEqual(helper(**changes), 'blacksmith-6vcpu-macos-26')
        self.assertEqual(helper(**{'inputs.nightly_next_unsigned_run': '123'}), 'blacksmith-32vcpu-ubuntu-2404')
        self.assertEqual(helper(**{'github.repository_owner': 'someone'}), 'macos-26')
        self.assertNotIn('macos-15', nightly_expand(WORKFLOW_FILE.read_text()))

    def test_next_build_and_prepare_never_name_a_hosted_mac_past_the_fork_branch(self):
        for name in ('build-nightly-app',):
            with self.subTest(job=name):
                source = DOC['jobs'][name]['runs-on'].replace("github.repository_owner != 'manaflow-ai' && 'macos-26'", '')
                self.assertIsNone(re.search(r"'macos-[0-9]+'", source))

    def test_missing_owned_pool_uses_blacksmith_mac_fallback(self):
        self.assertEqual(select(**{'vars.CI_SIDE_LANE_RUNNER': ''}), 'blacksmith-6vcpu-macos-26')

    def test_next_retries_overflow_to_hosted_macos(self):
        # A NEXT retry with no pick takes Blacksmith 6 vCPU, never hosted; main keeps vars.MACOS_RUNNER_26.
        self.assertEqual(select(**{'github.run_attempt': 2}), 'blacksmith-6vcpu-macos-26')
        self.assertEqual(select(**{'github.run_attempt': 2, 'github.ref': 'refs/heads/main'}), 'blacksmith-12vcpu-macos-26')

    def test_prepare_runs_on_linux_on_every_attempt(self):
        def prepare(**changes):
            source = DOC['jobs']['prepare-nightly-variant-primary']['runs-on'].removeprefix('${{').removesuffix('}}')
            context = {'github.repository_owner': 'manaflow-ai', 'github.repository': 'manaflow-ai/cmux',
                       'github.event_name': 'push', 'github.ref': 'refs/heads/nightly-next', 'github.run_attempt': 1,
                       'vars.CI_PR_POOL_OWNED': '1', **changes}
            return evaluate(parse_expression(source), context)
        self.assertEqual(prepare(), 'blacksmith-32vcpu-ubuntu-2404')
        self.assertEqual(prepare(**{'github.run_attempt': 2}), 'blacksmith-32vcpu-ubuntu-2404')
        self.assertEqual(prepare(**{'inputs.nightly_next_unsigned_run': '123'}), 'blacksmith-32vcpu-ubuntu-2404')
        self.assertEqual(prepare(**{'github.repository_owner': 'someone'}), 'ubuntu-24.04')

    def test_prepare_fallback_follows_the_primary_then_retries_on_another_size(self):
        # After a primary success the fallback is a no-op on the primary's (healthy) label;
        # a retry after a failed primary takes another runner-set size, so one stalled size
        # never holds both.
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
                retry = label('prepare-nightly-variant', runner, 'failure')
                self.assertNotEqual(retry, primary)
                self.assertIn(retry, ('blacksmith-16vcpu-ubuntu-2404', 'blacksmith-32vcpu-ubuntu-2404'))
        # The retry picks from the declared set, whatever LINUX_RUNNER holds.
        members = ('blacksmith-16vcpu-ubuntu-2404', 'blacksmith-32vcpu-ubuntu-2404')
        for runner in ('', 'ubuntu-24.04', 'blacksmith-4vcpu-ubuntu-2404') + members:
            with self.subTest(runner=runner):
                self.assertIn(label('prepare-nightly-variant', runner, 'failure'), members)

    def test_signer_jobs_use_the_dedicated_blacksmith_linux_picker(self):
        # The picker validates the 4/16/32-vCPU set and rotates after a stalled queue;
        # signer jobs consume only its outputs, never hosted/GCP or a scalar variable.
        picker_context = {
            'github.repository_owner': 'manaflow-ai', 'github.run_attempt': 1,
            'vars.RUNNER_POOLS': '{"linux":"blacksmith-16vcpu-ubuntu-2404"}',
        }
        for name in SIGNER_ROUTE_JOBS:
            source = DOC['jobs'][name]['runs-on'].removeprefix('${{').removesuffix('}}')
            context = dict(picker_context)
            if name != 'pick-nightly-sign-runner':
                context.update({
                    'needs.pick-nightly-sign-runner.outputs.linux': 'blacksmith-4vcpu-ubuntu-2404',
                    'needs.pick-nightly-sign-runner.outputs.linux_alternate': 'blacksmith-16vcpu-ubuntu-2404',
                    'needs.pick-nightly-sign-runner.outputs.attempt': '1',
                })
            with self.subTest(job=name):
                selected = evaluate(parse_expression(source), context)
                if isinstance(selected, list):
                    selected = selected[0]
                self.assertIn(selected, {'blacksmith-4vcpu-ubuntu-2404', 'blacksmith-16vcpu-ubuntu-2404',
                                          'blacksmith-32vcpu-ubuntu-2404'})

    def test_credentialed_publish_controls_use_owned_claim_then_linux_overflow(self):
        # Release App publication jobs may use a drained owned Mac, but only the
        # picker output is trusted and their claim gate runs after checkout,
        # before any protected environment secret. A rerun keeps the measured Linux
        # overflow instead of reusing an older owned label.
        jobs = DOC["jobs"]
        route = (
            "needs.pick-nightly-sign-runner.outputs.attempt",
            "needs.pick-nightly-sign-runner.outputs.sign_owned_pool",
        )
        for name in ("publish-nightly", "publish-nightly-next-github", "publish-nightly-next-github-names"):
            with self.subTest(job=name):
                job = jobs[name]
                self.assertIn("always()", str(job.get("if", "")),
                              "an optional signing picker must not implicitly skip publication after a recovery")
                runs_on = str(job["runs-on"])
                for term in route:
                    self.assertIn(term, runs_on)
                self.assertNotIn("fromJSON(needs.pick-nightly-sign-runner.outputs.sign_owned)", runs_on)
                source = runs_on.removeprefix("${{").removesuffix("}}")
                fallback = {
                    "github.repository_owner": "manaflow-ai",
                    "github.run_attempt": 1,
                    "needs.pick-nightly-sign-runner.outputs.attempt": "1",
                    "needs.pick-nightly-sign-runner.outputs.sign_owned_pool": "",
                    "vars.LINUX_RUNNER": "blacksmith-16vcpu-ubuntu-2404",
                }
                self.assertEqual(evaluate(parse_expression(source), fallback), "blacksmith-16vcpu-ubuntu-2404")
                self.assertEqual(evaluate(parse_expression(source), {**fallback, "github.repository_owner": "someone"}),
                                 "ubuntu-24.04")
                self.assertNotIn("vars.CI_NIGHTLY_NEXT_BUILD_RUNNER", runs_on)
                steps = job["steps"]
                gate_index = next(i for i, step in enumerate(steps) if step.get("id") == "claim-gate")
                self.assertEqual(steps[gate_index]["name"], "Hold the whole Mac before any credential")
                self.assertIn("GLAEDA_JOB_CLAIM", steps[gate_index]["run"])
                self.assertIn("glaeda-signing-hooks.txt", steps[gate_index]["run"])
                self.assertNotIn("secrets.", steps[gate_index]["run"])
                checkout_index = next(i for i, step in enumerate(steps) if "actions/checkout@" in str(step.get("uses", "")))
                self.assertGreater(gate_index, checkout_index)
                self.assertTrue(any("signing-runner-claim.sh" in str(step.get("run", "")) for step in steps[gate_index + 1:]))
                needs = job["needs"]
                self.assertIn("pick-nightly-sign-runner", needs)

    def test_publication_controls_reject_unavailable_dedicated_m4pro(self):
        # Publication cannot use the dedicated label: those minis have no
        # exclusive-claim capacity. Keep the trusted owned-pool and Linux fallback.
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
                self.assertEqual(evaluate(expr, dedicated), "blacksmith-16vcpu-ubuntu-2404")
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

    def test_every_linux_nightly_job_takes_a_runner_set_member(self):
        # Never LINUX_RUNNER as-is: 16 vCPU when it names 16, else 32, whatever it holds
        # (empty, the overflow switch's hosted value, an old 4 vCPU value, 16 or 32).
        # The signer jobs have their own route (test_signer_jobs_take_hosted_ubuntu_then_blacksmith_4vcpu_never_16_or_32).
        members = {'blacksmith-16vcpu-ubuntu-2404', 'blacksmith-32vcpu-ubuntu-2404'}
        import json
        light = json.loads((ROOT / ".github/runners.json").read_text()).get("hosted_light_jobs", {})
        checked = 0
        for name, job in DOC['jobs'].items():
            runs_on = job.get('runs-on', '')
            if not isinstance(runs_on, str) or 'ubuntu' not in runs_on or 'macos' in runs_on or name in SIGNER_ROUTE_JOBS:
                continue
            checked += 1
            source = runs_on.removeprefix('${{').removesuffix('}}')
            for runner in ('', 'ubuntu-24.04', 'blacksmith-4vcpu-ubuntu-2404', *sorted(members)):
                for primary in ('success', 'failure'):
                    context = {'github.repository_owner': 'manaflow-ai', 'vars.LINUX_RUNNER': runner,
                               'github.run_attempt': 1,
                               'needs.decide.outputs.track': 'nightly-next',
                               'vars.CI_CLOUD_OVERFLOW_SAVED': '{"probe":"x"}',
                               'needs.prepare-nightly-variant-primary.result': primary}
                    with self.subTest(job=name, runner=runner, primary=primary):
                        self.assertIn(evaluate(parse_expression(source), context),
                                      {"blacksmith-4vcpu-ubuntu-2404", "blacksmith-8vcpu-ubuntu-2404"}
                                      if name == "legacy-identity-target" else
                                      (members | {"ubuntu-24.04"}) if f"nightly.yml#{name}" in light else members)
        self.assertGreater(checked, 20)

    def test_dispatch_fast_retries_rc_and_disabled_owned_use_blacksmith_pool(self):
        cases = [
            {'github.event_name': 'workflow_dispatch'},
            {'needs.decide.outputs.fast_build': 'true'}, {'vars.CI_PR_POOL_OWNED': '0'},
            {'github.ref': 'refs/heads/rc/1.2'}, {'github.repository': 'manaflow-ai/another'}, {'github.ref': 'refs/heads/feat-cmux-next'},
        ]
        for changes in cases:
            with self.subTest(changes=changes):
                # nightly-next with no pick: Blacksmith 6 vCPU; other refs: vars.MACOS_RUNNER_26.
                expected = 'blacksmith-6vcpu-macos-26' if 'github.ref' not in changes else 'blacksmith-12vcpu-macos-26'
                self.assertEqual(select(**changes), expected)
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
            "github.ref == 'refs/heads/nightly-next' && format('run-{0}', github.run_id)",
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
        self.assertEqual(group('nightly-next', '39124573091'), 'nightly-build-nightly-next-run-39124573091')
        self.assertNotEqual(group('nightly-next', '39124573091'), group('nightly-next', '39124573100'))
        self.assertNotEqual(group('main'), group('nightly-next', '39124573091'))

    def test_every_nightly_build_has_its_own_slot(self):
        # A shared warm slot (nightly-next-build-app-warm) replaced waiting builds, which
        # the nightly rule forbids, and its holder stuck on a dead label (2026-10-26)
        # held every newer promotion. The warm route is a pool now, so every route,
        # warm or Blacksmith, keeps a slot per run.
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
        self.assertEqual(select(**{'github.run_attempt': 2}), 'blacksmith-6vcpu-macos-26')
        self.assertEqual(select(**{'vars.CI_SIDE_LANE_RUNNER': ''}), 'blacksmith-6vcpu-macos-26')
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
    def test_unsigned_resume_is_linux_before_every_native_route(self):
        self.assertEqual(select(**{'inputs.nightly_next_unsigned_run': '123'}), 'blacksmith-32vcpu-ubuntu-2404')



class LightJobsOnAFreeMini(unittest.TestCase):
    """The nightly's light jobs take a mini idle when build-nightly-app finished, else Blacksmith.

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
                # Placed only the other job: this one keeps the runner set's Blacksmith member.
                other = next(name for name in self.LIGHT if name != job)
                self.assertEqual(self.runs_on(job, **{'needs.build-nightly-app.outputs.light_mini_jobs': f' {other} '}),
                                 ('blacksmith-16vcpu-ubuntu-2404' if job == 'prepare-nightly-variant' else 'blacksmith-32vcpu-ubuntu-2404'))

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
                        if changes.get('vars.LINUX_RUNNER') == 'blacksmith-16vcpu-ubuntu-2404':
                            expected = ('blacksmith-32vcpu-ubuntu-2404' if job == 'prepare-nightly-variant'
                                        else 'blacksmith-16vcpu-ubuntu-2404')
                        else:
                            expected = ('blacksmith-16vcpu-ubuntu-2404' if job == 'prepare-nightly-variant'
                                        else 'blacksmith-32vcpu-ubuntu-2404')
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
        step = next(step for step in DOC['jobs']['build-nightly-app']['steps'] if step.get('id') == 'place-light')
        # The primary preparation keeps its placement-aware runs-on but is not offered: it ran 4.8 min on a
        # dedicated nightly Mac against 57 s on its Blacksmith route (runs 41360732074, 41358657711).
        self.assertEqual(step['env']['JOBS'].split(), [job for job in self.LIGHT if job != 'prepare-nightly-variant-primary'])
        self.assertEqual(step['env']['NIGHTLY'], '1')
        self.assertEqual(step['env']['NIGHTLY_WAIT_FOR_FLEET'], '1')
        self.assertEqual(step['timeout-minutes'], 5)
        # No fleet Linux step: a nightly job never takes vars.LINUX_RUNNER as it is.
        self.assertEqual(step['env']['FLEET_LINUX'], '')
        self.assertTrue(step['continue-on-error'])
        # Only after the token the nightly-next-only mint step makes.
        self.assertIn("steps.light-route-token.outputs.token != ''", step['if'])

    def test_the_build_job_mints_only_the_routing_token_for_the_placement(self):
        steps = DOC['jobs']['build-nightly-app']['steps']
        mint = next(step for step in steps if step.get('id') == 'light-route-token')
        self.assertIn("github.ref == 'refs/heads/nightly-next'", mint['if'])
        self.assertIn("inputs.nightly_next_unsigned_run == ''", mint['if'])
        self.assertEqual(mint['with']['private-key'], '${{ secrets.GLAEDA_ROUTE_APP_KEY }}')
        self.assertEqual(sorted(key for key in mint['with'] if key.startswith('permission-')),
                         ['permission-administration', 'permission-organization-self-hosted-runners'])
        self.assertTrue(all(value == 'read' for key, value in mint['with'].items() if key.startswith('permission-')))


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

    def test_the_daemon_takes_the_helper_pick_else_blacksmith_linux(self):
        source = DOC['jobs']['build-nightly-remote-daemon']['runs-on'].removeprefix('${{').removesuffix('}}')
        mini = 'glaeda-side-std-xcode-26.6'
        base = {'github.repository_owner': 'manaflow-ai', 'github.ref': 'refs/heads/nightly-next', 'github.run_attempt': 1,
                'vars.LINUX_RUNNER': 'blacksmith-32vcpu-ubuntu-2404',
                'needs.pick-nightly-build-runner.outputs.attempt': '1',
                'needs.pick-nightly-build-runner.outputs.helper': mini,
                'needs.pick-nightly-build-runner.outputs.dedicated': 'glaeda-nightly-dedicated'}
        self.assertEqual(evaluate(parse_expression(source), base), mini)
        for changes in ({'needs.pick-nightly-build-runner.outputs.helper': ''},
                        {'needs.pick-nightly-build-runner.outputs.dedicated': mini},
                        {'github.run_attempt': 2},
                        {'github.ref': 'refs/heads/main'}):
            with self.subTest(changes=changes):
                self.assertEqual(evaluate(parse_expression(source), {**base, **changes}), 'blacksmith-32vcpu-ubuntu-2404')

    def test_the_daemon_is_a_peer_the_app_build_stops_for(self):
        peers = DOC['jobs']['build-nightly-app']['env']['NIGHTLY_PUBLISH_PEERS'].split()
        self.assertIn('build-nightly-remote-daemon', peers)


class PickerReRun(unittest.TestCase):
    """The owned-pool rescue and the nightly-next tick re-run pick-nightly-build-runner, and with it every job
    that needs it, so a re-run picks its runner fresh (scripts/ci/owned_pool_rescue.py repick_job(), on main).
    That re-runs the Ghostty helper even after it succeeded, and an artifact name it already uploaded is
    refused unless the upload overwrites: without that, the rescue falls back to a re-run of failed jobs,
    which keeps attempt 1's stalled Blacksmith pick."""

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
CREDENTIALED_CONTROL_MEMBERS = ('blacksmith-16vcpu-ubuntu-2404', 'blacksmith-32vcpu-ubuntu-2404')


class CredentialedControls(unittest.TestCase):
    def select(self, job, pool='', attempt=1, owner='manaflow-ai'):
        # The shared parser intentionally discards properties of call results.
        # Resolve this JSON property lazily so the fork branch still tests
        # short-circuit behavior without pretending the entire object is a label.
        class Context(dict):
            def get(self, key, default=''):
                if key == 'pool_linux':
                    return json.loads(pool or '{}').get('linux', '')
                return super().get(key, default)
        source = DOC['jobs'][job]['runs-on'][3:-2]
        self.assertIn("fromJSON(vars.RUNNER_POOLS || '{}').linux", source)
        source = source.replace("fromJSON(vars.RUNNER_POOLS || '{}').linux", 'pool_linux')
        return evaluate(parse_expression(source), Context({
            'github.repository_owner': owner,
            'github.run_attempt': attempt,
            'vars.RUNNER_POOLS': pool,
        }))

    def test_live_trusted_member_is_used(self):
        for job in CREDENTIALED_CONTROL_JOBS:
            for member in CREDENTIALED_CONTROL_MEMBERS:
                with self.subTest(job=job, member=member):
                    self.assertEqual(self.select(job, json.dumps({'linux': member})), member)

    def test_unset_and_untrusted_routes_stay_ephemeral_on_every_attempt(self):
        for job in CREDENTIALED_CONTROL_JOBS:
            for pool in ('', '{}', '{"linux":"ubuntu-24.04"}',
                         '{"linux":"cmux-fleet-linux-x64"}',
                         '{"linux":"glaeda-side-std-xcode-26.6"}'):
                with self.subTest(job=job, pool=pool):
                    self.assertEqual(self.select(job, pool), CREDENTIALED_CONTROL_MEMBERS[1])
                    self.assertEqual(self.select(job, pool, attempt=2), CREDENTIALED_CONTROL_MEMBERS[0])

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
