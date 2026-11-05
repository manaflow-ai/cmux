#!/usr/bin/env python3
"""An extension's JOURNEY_END hooks run at every journey's end, whatever ended it, before its `finally` clean-up steps
(driver EXT_JOURNEY_END). No fleet, no app.

    python3 scripts/journeys/test_journey_end_hooks.py

cmux-ad m29 item 3 (2026-11-05): 23 films of the resize-videos gallery have no moov atom. In 17 of them a plain
journey (bv-dt, sf-*, bcpp3, rkd) failed a step or was not run between video_start and video_stop: nothing sent
record_stop, run.py fetched the movie while the app still wrote it, and the lease then ended the app. A kit's recorder
extension (ext_video on the resize-videos kit branches) now stops a recording it left running from a JOURNEY_END hook,
so the movie is finished before the fetch. This test gives the driver such a hook, as an ext_*.py module does.
"""
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE.parent / "cmux-next")]
import driver as D  # noqa: E402

FILM = "bv-dt-bottom-light-dark-r0"


class RecorderApp:
    """The app side the hook talks to: a recording that runs until the hook stops it."""

    bundle = "/Applications/cmux NEXT.app"
    pid = 4242

    def __init__(self):
        self.calls = []
        self.recording = False
        self.snapshot_window = None

    def snapshot(self, path):
        raise OSError("no window server in a unit test")


def stop_left_recording(j, status, reason):
    """A recorder extension's JOURNEY_END hook: stops the film a step left recording; None when there is none."""
    if not j.app.recording:
        return None
    j.app.calls.append(("record_stop", status, reason))
    j.app.recording = False
    return {"film": FILM, "stopped_at_journey_end": f"{status}: {reason}"}


def failing_hook(j, status, reason):
    j.app.calls.append("failing_hook")
    raise RuntimeError("the app stopped answering")


def step_test_film(j, step):
    j.app.recording = True
    return {"recording": FILM}


def step_test_fail(j, step):
    raise D.StepError("bv_devtools: DevTools of tab None did not become closed")


def step_test_not_run(j, step):
    raise D.NotRun("hid_drag: no CuaDriver drag reached the app")


def step_test_pass(j, step):
    return {}


def step_test_cleanup(j, step):
    j.app.calls.append("cleanup")
    return {}


STEPS = (step_test_film, step_test_fail, step_test_not_run, step_test_pass, step_test_cleanup)


def install_extension(*hooks):
    """Loads a recorder extension the way the kit's ext_*.py modules load (driver.load_extensions over a folder that
    holds it): a module whose JOURNEY_END is HOOKS. Returns the module, for remove_extension."""
    import types
    module = types.ModuleType("ext_test_recorder")
    module.install = lambda driver: None
    module.JOURNEY_END = tuple(hooks)
    saved = sys.modules.get(module.__name__)
    sys.modules[module.__name__] = module
    original = D.__file__
    try:
        with tempfile.TemporaryDirectory() as folder:
            (Path(folder) / "ext_test_recorder.py").write_text("")
            D.__file__ = str(Path(folder) / "driver.py")  # load_extensions reads the folder beside the driver
            D.load_extensions(D)
    finally:
        D.__file__ = original
        if saved is None:
            sys.modules.pop(module.__name__, None)
        else:
            sys.modules[module.__name__] = saved
    return module


def remove_extension(module):
    hooks = getattr(D, "EXT_JOURNEY_END", None)
    if hooks is not None:
        hooks[:] = [h for h in hooks if h not in module.JOURNEY_END]


class JourneyEndHooks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        for fn in STEPS:
            setattr(D.Journey, fn.__name__, fn)

    @classmethod
    def tearDownClass(cls):
        for fn in STEPS:
            delattr(D.Journey, fn.__name__)

    def use(self, *hooks):
        module = install_extension(*hooks)
        self.addCleanup(remove_extension, module)

    def play(self, steps):
        app = RecorderApp()
        spec = {"id": "jr-journey-end", "steps": steps, "finally": [{"do": "test_cleanup", "title": "clean-up"}]}
        with tempfile.TemporaryDirectory() as out:
            result = D.Journey(spec, app, out, D.now() + 60, 1.0).run()
        return app, result

    def ends(self, result):
        return [s for s in result["steps"] if s.get("title") == "journey end"]

    def test_a_failed_step_stops_the_film_before_the_clean_up(self):
        self.use(stop_left_recording)
        app, result = self.play([{"do": "test_film"}, {"do": "test_fail"}])
        self.assertEqual(result["status"], "fail")
        self.assertFalse(app.recording, "the film a failed step left running was never stopped")
        self.assertEqual(app.calls[0][:2], ("record_stop", "fail"))
        self.assertIn("did not become closed", app.calls[0][2])
        self.assertEqual(app.calls[1:], ["cleanup"])
        [end] = self.ends(result)
        self.assertEqual((end["do"], end["ok"], end["finally"]), ("stop_left_recording", True, True))
        self.assertEqual(end["result"]["film"], FILM)

    def test_a_not_run_step_stops_the_film_too(self):
        self.use(stop_left_recording)
        app, result = self.play([{"do": "test_film"}, {"do": "test_not_run"}])
        self.assertEqual(result["status"], "not run")
        self.assertFalse(app.recording, "the film a not-run step left running was never stopped")
        self.assertEqual(app.calls[0][:2], ("record_stop", "not run"))

    def test_a_journey_that_stopped_its_film_adds_no_step(self):
        # A film stopped by its own video_stop (or a px_film that stopped it on its error) leaves the hook nothing.
        self.use(stop_left_recording)
        app, result = self.play([{"do": "test_pass"}])
        self.assertEqual(self.ends(result), [])
        self.assertEqual(app.calls, ["cleanup"])

    def test_a_hook_that_raises_is_recorded_and_the_clean_up_still_runs(self):
        self.use(failing_hook, stop_left_recording)
        app, result = self.play([{"do": "test_film"}, {"do": "test_fail"}])
        self.assertEqual(result["status"], "fail")
        self.assertEqual(app.calls[:1], ["failing_hook"], "the journey-end hooks did not run")
        self.assertEqual(app.calls[1][0], "record_stop")
        self.assertEqual(app.calls[-1], "cleanup")
        failed, stopped = self.ends(result)
        self.assertEqual((failed["do"], failed["ok"]), ("failing_hook", False))
        self.assertIn("stopped answering", failed["error"])
        self.assertTrue(stopped["ok"])


if __name__ == "__main__":
    unittest.main()
