#!/usr/bin/env python3
"""Execute nightly runner selectors for trusted pushes, overflow, and unsigned resume."""
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
        'vars.CI_SEED_TRUSTED_POOL': 'glaeda-trusted-std-xcode-26.6',
        'vars.CI_NIGHTLY_TRUSTED_RUNNER': 'glaeda-runner-main-glaeda',
        'vars.CI_NIGHTLY_NEXT_TRUSTED_POOL': 'glaeda-trusted-std-xcode-26.6',
        'vars.CI_NIGHTLY_NEXT_TRUSTED_RUNNER': 'glaeda-runner-next-glaeda',
    }
    context.update(changes)
    source = DOC['jobs']['build-nightly-app'][field].removeprefix('${{').removesuffix('}}')
    return evaluate(parse_expression(source), context)


class NightlyTrustedRouting(unittest.TestCase):
    def test_next_push_selects_its_dedicated_trusted_worker(self):
        self.assertEqual(select(), ['glaeda-trusted-std-xcode-26.6', 'glaeda-runner-next-glaeda', 'glaeda-trusted-next-nightly'])

    def test_main_keeps_its_worker_and_writer_environment(self):
        changes = {'github.ref': 'refs/heads/main'}
        self.assertEqual(select(**changes), ['glaeda-trusted-std-xcode-26.6', 'glaeda-runner-main-glaeda'])
        self.assertEqual(select('environment', **changes), 'ci-cache-writer')
        self.assertEqual(select('environment'), '')

    def test_next_never_borrows_main_or_pr_pool_on_missing_configuration(self):
        for variable in ('vars.CI_NIGHTLY_NEXT_TRUSTED_POOL', 'vars.CI_NIGHTLY_NEXT_TRUSTED_RUNNER'):
            self.assertEqual(select(**{variable: ''}), 'blacksmith-12vcpu-macos-26')

    def test_dispatch_fast_retries_rc_and_disabled_owned_take_hosted(self):
        cases = [
            {'github.event_name': 'workflow_dispatch'}, {'github.run_attempt': 2},
            {'needs.decide.outputs.fast_build': 'true'}, {'vars.CI_PR_POOL_OWNED': '0'},
            {'github.ref': 'refs/heads/rc/1.2'}, {'github.repository': 'manaflow-ai/another'}, {'github.ref': 'refs/heads/feat-cmux-next'},
        ]
        for changes in cases:
            with self.subTest(changes=changes):
                self.assertEqual(select(**changes), 'blacksmith-12vcpu-macos-26')
        self.assertEqual(select(**{'github.repository_owner': 'someone'}), 'macos-26')

    def test_trusted_next_uses_its_own_state_without_shared_cache_secrets(self):
        steps = {step.get('name'): step for step in DOC['jobs']['build-nightly-app']['steps']}
        context = {
            'needs.decide.outputs.track': 'nightly-next',
            'steps.persistent-release.outputs.enabled': 'true',
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
        def group(branch):
            context = {'github.ref_name': branch, 'github.event_name': 'push'}
            return re.sub(r'\$\{\{(.*?)\}\}',
                          lambda match: str(evaluate(parse_expression(match[1]), context)),
                          DOC['concurrency']['group'])
        self.assertEqual(group('main'), 'nightly-build-nightly-shared-full')
        self.assertEqual(group('nightly-next'), 'nightly-build-nightly-next-full')
        self.assertNotEqual(group('main'), group('nightly-next'))

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
        self.assertEqual(select(**{'inputs.nightly_next_unsigned_run': '123'}), 'ubuntu-24.04')


if __name__ == '__main__':
    unittest.main()
