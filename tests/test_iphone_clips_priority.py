"""The iPhone What's New clips rank above plain agent steps in the simulator queue.

Run 45978228941 queued both clips as plain agent steps; neither left the queue in 3600 s, so nothing published.
"""
import pathlib
import re
import unittest

WF = pathlib.Path(__file__).resolve().parents[1] / ".github/workflows/cmux-next-iphone-clips.yml"


class IphoneClipsPriority(unittest.TestCase):
    def test_clip_steps_ask_pr_priority_with_a_deadline(self):
        text = WF.read_text()
        self.assertRegex(text, r'rank=\(--priority pr --deadline "\$\{QUEUE_S\}s"\)')
        run = re.search(r'"\$client" run --class simulator(.*?)> "\$log"', text, re.S)
        self.assertIsNotNone(run)
        self.assertIn('${rank[@]+"${rank[@]}"}', run.group(1))  # bash 3.2 + set -u: an empty array is unbound

    def test_rank_is_feature_checked(self):
        self.assertIn("run --help 2>/dev/null | grep -q -- '--priority {'", WF.read_text())


if __name__ == "__main__":
    unittest.main()
