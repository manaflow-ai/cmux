"""A guard step that reads the checkout must not run when the checkout failed.

Run 45260382948 (PR #52648, 2026-11-23) reported three errors of the shape
`can't open file '/home/runner/work/cmux/cmux/tests/test_static_analysis_ratchet.py'`.
Nothing was missing from the change: the Checkout step's fetch had timed out, the
action left `.git` with no worktree, and the guard steps below it run on
`!cancelled()`, so they ran in an empty directory and read as the change's red.
"""
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / '.github/workflows/cmux-next-guards.yml'
JOB = 'security-holes'
GATE = ("steps.checkout.outcome == 'success' "
        "|| steps.checkout-retry.outcome == 'success'")


class GuardsSkipWhenCheckoutFailedTests(unittest.TestCase):
    def setUp(self):
        self.steps = yaml.safe_load(WORKFLOW.read_text())['jobs'][JOB]['steps']

    def step(self, **by):
        key, value = next(iter(by.items()))
        matches = [s for s in self.steps if s.get(key) == value]
        self.assertEqual(len(matches), 1, f'{key}={value!r}: {len(matches)} steps')
        return matches[0]

    def test_checkout_is_retried_once_and_fails_loudly(self):
        checkout = self.step(id='checkout')
        self.assertTrue(checkout.get('continue-on-error'),
                        'a timed-out checkout must not end the job before the retry')
        retry = self.step(id='checkout-retry')
        self.assertEqual(retry.get('if'), "steps.checkout.outcome == 'failure'")
        self.assertTrue(retry.get('continue-on-error'))
        loud = [s for s in self.steps
                if s.get('if') == ("steps.checkout.outcome == 'failure' "
                                   "&& steps.checkout-retry.outcome == 'failure'")]
        self.assertTrue(loud, 'two failed checkouts must fail the job in their own step')
        self.assertIn('exit 1', loud[0].get('run', ''),
                      "the step that names the checkout failure must fail the job")

    def test_every_step_reading_the_worktree_is_gated_on_a_checkout(self):
        for step in self.steps:
            run = step.get('run') or ''
            if not any(token in run for token in ('tests/', 'scripts/')):
                continue
            with self.subTest(step=step.get('name')):
                self.assertIn(GATE, str(step.get('if')),
                              'this step reads files from the checkout, so it must not run '
                              'when both checkout attempts failed')


if __name__ == '__main__':
    unittest.main()
