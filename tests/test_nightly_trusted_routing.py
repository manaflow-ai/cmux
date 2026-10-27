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

import yaml

sys.path.insert(0, str(Path(__file__).parent))
from test_ci_fork_runner_routing import parse_expression

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_FILE = Path(os.environ.get('NIGHTLY_WORKFLOW_FILE', ROOT / '.github/workflows/nightly.yml'))
DOC = yaml.safe_load(WORKFLOW_FILE.read_text())


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
        return (left == right) == (node[1] == '==')
    if kind == 'call':
        args = [evaluate(arg, context) for arg in node[2]]
        if node[1].lower() == 'format':
            return args[0].format(*args[1:])
        if node[1].lower() == 'fromjson':
            return json.loads(args[0])
    raise ValueError(node)


def select(field='runs-on', **changes):
    context = {
        'github.repository_owner': 'manaflow-ai', 'github.repository': 'manaflow-ai/cmux', 'github.event_name': 'push',
        'github.ref': 'refs/heads/nightly-next', 'github.run_attempt': 1,
        'vars.CI_PR_POOL_OWNED': '1',
        'vars.CI_SIDE_LANE_RUNNER': 'glaeda-side-std-xcode-26.6',
        'vars.CI_SEED_TRUSTED_POOL': 'glaeda-trusted-std-xcode-26.6',
        'vars.MACOS_RUNNER_26': 'blacksmith-12vcpu-macos-26',
        'vars.LINUX_RUNNER': 'blacksmith-4vcpu-ubuntu-2404',
    }
    context.update(changes)
    source = DOC['jobs']['build-nightly-app'][field].removeprefix('${{').removesuffix('}}')
    return evaluate(parse_expression(source), context)


class NightlyTrustedRouting(unittest.TestCase):
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
        # re-run (attempt 2, the rescue's) takes the picked Blacksmith label.
        picked = {'needs.pick-nightly-build-runner.outputs.owned': 'glaeda-side-std-xcode-26.6',
                  'needs.pick-nightly-build-runner.outputs.blacksmith': 'blacksmith-6vcpu-macos-26',
                  'vars.CI_NIGHTLY_NEXT_BUILD_RUNNER': 'glaeda-dev-std-xcode-26.6'}
        self.assertEqual(select(**{**picked, 'github.run_attempt': 2}), 'blacksmith-6vcpu-macos-26')
        self.assertEqual(select(**{**picked, 'github.run_attempt': 3}), 'blacksmith-6vcpu-macos-26')
        # A failed pick (empty outputs) takes Blacksmith 6 vCPU, never an unvalidated variable.
        for variable in ('macos-26', 'macos-15', 'glaeda-side-std-xcode-26.6', 'blacksmith-12vcpu-macos-26', ''):
            for attempt in (1, 2):
                with self.subTest(variable=variable, attempt=attempt):
                    self.assertEqual(select(**{'vars.CI_NIGHTLY_NEXT_BUILD_RUNNER': 'glaeda-dev-std-xcode-26.6',
                                               'vars.MACOS_RUNNER_26': variable, 'github.run_attempt': attempt}),
                                     'blacksmith-6vcpu-macos-26')
        self.assertEqual(select(**{**picked, 'inputs.nightly_next_unsigned_run': '123'}), 'blacksmith-4vcpu-ubuntu-2404')
        self.assertEqual(select(**{**picked, 'github.repository_owner': 'someone'}), 'macos-26')

    def test_only_the_nightly_pickers_read_the_next_build_runner(self):
        readers = sorted(path.name for path in (ROOT / '.github/workflows').glob('*.y*ml')
                         if 'vars.CI_NIGHTLY_NEXT_BUILD_RUNNER' in path.read_text()
                         and 'CMUX_CI_RUNNER_VARIABLES' not in path.read_text())
        self.assertEqual(readers, ['nightly.yml'])
        uses = sorted(name for name, job in DOC['jobs'].items() if 'CI_NIGHTLY_NEXT_BUILD_RUNNER' in str(job.get('runs-on', '')))
        self.assertEqual(uses, [])
        steps = sorted(name for name, job in DOC['jobs'].items() if 'CI_NIGHTLY_NEXT_BUILD_RUNNER' in str(job.get('steps', '')))
        self.assertEqual(steps, ['pick-nightly-build-runner'])

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
                 'vars.CI_SEED_TRUSTED_POOL': 'glaeda-trusted-std-xcode-26.6', **changes})
        self.assertEqual(helper(), 'glaeda-side-std-xcode-26.6')
        # The NEXT build override holds every attempt on its label; the helper never reads it, so a
        # retry or rescue re-run leaves a busy mini for Blacksmith macOS 26.
        self.assertEqual(helper(**{'vars.CI_NIGHTLY_NEXT_BUILD_RUNNER': 'glaeda-dev-std-xcode-26.6'}),
                         'glaeda-side-std-xcode-26.6')
        self.assertEqual(helper(**{'vars.CI_NIGHTLY_NEXT_BUILD_RUNNER': 'glaeda-side-std-xcode-26.6',
                                   'github.run_attempt': 2}), 'blacksmith-6vcpu-macos-26')
        self.assertEqual(helper(**{'github.ref': 'refs/heads/main'}), 'glaeda-trusted-std-xcode-26.6')
        self.assertEqual(helper(**{'github.ref': 'refs/heads/main', 'github.event_name': 'schedule'}),
                         'glaeda-trusted-std-xcode-26.6')
        for changes in ({'github.run_attempt': 2}, {'github.event_name': 'workflow_dispatch'},
                        {'vars.CI_PR_POOL_OWNED': '0'}, {'vars.CI_SIDE_LANE_RUNNER': ''},
                        {'github.ref': 'refs/heads/main', 'vars.CI_SEED_TRUSTED_POOL': ''},
                        {'github.ref': 'refs/heads/other'}):
            with self.subTest(changes=changes):
                self.assertEqual(helper(**changes), 'blacksmith-6vcpu-macos-26')
        self.assertEqual(helper(**{'inputs.nightly_next_unsigned_run': '123'}), 'ubuntu-24.04')
        self.assertEqual(helper(**{'github.repository_owner': 'someone'}), 'macos-26')
        self.assertNotIn('macos-15', WORKFLOW_FILE.read_text())

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
        self.assertEqual(prepare(), 'blacksmith-4vcpu-ubuntu-2404')
        self.assertEqual(prepare(**{'github.run_attempt': 2}), 'blacksmith-4vcpu-ubuntu-2404')
        self.assertEqual(prepare(**{'inputs.nightly_next_unsigned_run': '123'}), 'blacksmith-4vcpu-ubuntu-2404')
        self.assertEqual(prepare(**{'github.repository_owner': 'someone'}), 'ubuntu-24.04')

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
        }
        for name in ('Restore Xcode compilation cache', 'Cache Swift packages',
                     'Save Xcode compilation cache', 'Save Swift packages'):
            with self.subTest(step=name):
                self.assertFalse(evaluate(parse_expression(steps[name]['if']), context))

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

    @unittest.skipUnless('nightly_next_unsigned_run' in DOC[True]['workflow_dispatch']['inputs'],
                         'unsigned resume is owned by PR 21161, not landed on this base yet')
    def test_unsigned_resume_is_linux_before_every_native_route(self):
        self.assertEqual(select(**{'inputs.nightly_next_unsigned_run': '123'}), 'blacksmith-4vcpu-ubuntu-2404')


if __name__ == '__main__':
    unittest.main()
