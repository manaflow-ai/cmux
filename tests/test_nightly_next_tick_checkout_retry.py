"""The nightly-next tick's checkouts are bounded and tried once more.

A tick that dies in a checkout promotes nothing until the next tick. On 2026-11-26 four ticks
(45775908335, 45777304889, 45779080244, 45779574719) died in "Checkout the gh rate-limit wait" on
"Operation too slow" after 65-212 s, minutes after the same runner's first checkout fetched.
"""
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / '.github/workflows/nightly-next-tick.yml'


def checkouts(job):
    return [s for s in job['steps'] if str(s.get('uses', '')).startswith('actions/checkout@')]


class TickCheckoutRetryTest(unittest.TestCase):
    def setUp(self):
        self.text = WORKFLOW.read_text()
        self.jobs = yaml.safe_load(self.text)['jobs']

    def test_every_checkout_is_bounded_and_retried_once(self):
        for name in ('request', 'unstick'):
            with self.subTest(job=name):
                steps = checkouts(self.jobs[name])
                self.assertEqual(len(steps) % 2, 0)
                for first, retry in zip(steps[::2], steps[1::2]):
                    self.assertIn('id', first)
                    self.assertTrue(first['continue-on-error'])
                    self.assertLessEqual(first['timeout-minutes'], 4)
                    self.assertEqual(retry['if'], f"steps.{first['id']}.outcome == 'failure'")
                    self.assertLessEqual(retry['timeout-minutes'], 4)
                    self.assertNotIn('continue-on-error', retry)
                    self.assertEqual(retry['with'], first['with'])


if __name__ == '__main__':
    unittest.main()
