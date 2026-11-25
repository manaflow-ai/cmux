import unittest

from hid_inject_log import validate_script, verdict


class ValidateScript(unittest.TestCase):
    def test_good_script(self):
        script = {"steps": [{"do": "move", "x": 1, "y": 2}, {"do": "key", "key_code": 2, "modifiers": ["cmd"]},
                            {"do": "drag", "from": [10, 10], "to": [300, 10], "duration_ms": 250, "hz": 120},
                            {"do": "wait", "ms": 100}, {"do": "click", "x": 5, "y": 5, "count": 2}]}
        self.assertEqual(validate_script(script), [])

    def test_bad_steps(self):
        self.assertEqual(validate_script({"steps": []}), ["no steps"])
        problems = validate_script({"steps": [{"do": "fly"}, {"do": "key", "key_code": "d"},
                                              {"do": "drag", "from": [1], "to": [2, 2], "hz": 5000}]})
        self.assertEqual(len(problems), 4)

    def test_key_code_bool_and_missing_point(self):
        problems = validate_script({"steps": [{"do": "key", "key_code": True}, {"do": "click", "x": 1}]})
        self.assertEqual(len(problems), 2)

    def test_rate_floor(self):
        self.assertIn("rate_floor must be in (0, 1]", validate_script({"steps": [{"do": "wait"}], "rate_floor": 1.5}))


class Verdict(unittest.TestCase):
    def log(self, achieved, posted=True, events=([1, "drag", 0, 0, -1],)):
        return {"posted": posted, "rate_floor": 0.95, "events": list(events),
                "steps": [{"do": "drag", "target_hz": 120, "achieved_hz": achieved, "events": 32}]}

    def test_ran_at_rate(self):
        self.assertEqual(verdict(self.log(119.6)), ("ran", ""))

    def test_below_floor_is_not_run(self):
        status, reason = verdict(self.log(110.0))
        self.assertEqual(status, "not run")
        self.assertIn("110.0 Hz achieved, target 120 Hz", reason)

    def test_plan_mode_is_not_run(self):
        self.assertEqual(verdict(self.log(120, posted=False))[0], "not run")

    def test_no_events_is_not_run(self):
        self.assertEqual(verdict(self.log(120, events=()))[0], "not run")

    def test_missing_rate_is_not_run(self):
        self.assertEqual(verdict(self.log(None))[0], "not run")


if __name__ == "__main__":
    unittest.main()
