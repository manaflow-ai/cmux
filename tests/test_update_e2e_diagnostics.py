"""The signed update replay keeps the evidence behind a staging failure."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/cmux-next/update-e2e.py"
spec = importlib.util.spec_from_file_location("update_e2e", SCRIPT)
replay = importlib.util.module_from_spec(spec)
with patch.object(sys, "argv", [str(SCRIPT)]):
    spec.loader.exec_module(replay)


class App:
    path = "/scratch/cmux NEXT.app"

    def __init__(self, states):
        self.states = iter(states)
        self.last = {}

    def status(self):
        self.last = next(self.states, self.last)
        return self.last

    def rpc(self, *args):
        return {"error": "check refused"}


class StagingEvidenceTests(unittest.TestCase):
    def run_stage(self, states, expected_build=None, installed="old"):
        def wait(predicate, *_):
            for _ in range(15):
                result = predicate()
                if result:
                    return result
            return None

        output = io.StringIO()
        replay.results.clear()
        with contextlib.redirect_stdout(output), patch.object(replay, "wait", wait), \
                patch.object(replay, "bundle_build", return_value=installed):
            result = replay.stage_update(App(states), "quit path", expected_build)
        diagnostics = [line for line in output.getvalue().splitlines() if line.startswith("[DIAGNOSTIC] ")]
        self.assertEqual(len(diagnostics), 1, output.getvalue())
        return result, json.loads(diagnostics[0].removeprefix("[DIAGNOSTIC] "))

    def test_timeout_keeps_check_error_and_status_log_even_if_socket_disappears(self):
        state = {"phase": "error", "automatic_checks": False, "log": ["signature rejected"]}
        (staged, _), evidence = self.run_stage([state, {}])
        self.assertIsNone(staged)
        self.assertEqual(replay.results[0][1], "FAIL")
        self.assertEqual(evidence["check_result"], {"error": "check refused"})
        self.assertIn(state, evidence["states"])
        self.assertEqual(evidence["states"][-1], {})

    def test_success_keeps_raw_installing_contract_and_notice_card_assertion(self):
        state = {"phase": "installing", "detected_version": "new", "badge": "Update Ready", "card": None,
                 "log": ["signature verified"]}
        (staged, log), evidence = self.run_stage([state])
        self.assertEqual(staged, state)
        self.assertEqual(log, "signature verified")
        self.assertTrue(all(row[1] == "PASS" for row in replay.results))
        self.assertEqual(evidence["states"], [state])

    def test_changing_status_history_is_bounded_and_keeps_final_error(self):
        states = [{"phase": "downloading", "log": [str(n)]} for n in range(15)]
        states.append({"phase": "error", "log": ["download failed"]})
        (staged, _), evidence = self.run_stage(states)
        self.assertIsNone(staged)
        self.assertLessEqual(len(evidence["states"]), 12)
        self.assertEqual(evidence["states"][-1], states[-1])


if __name__ == "__main__":
    unittest.main()
