"""screen-share-e2e.py reports each device's real stage and passes only on a varied frame."""
import importlib.util
import json
import subprocess
import sys
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "screen-share-e2e.py"
SPEC = importlib.util.spec_from_file_location("screen_share_e2e", SCRIPT)
e2e = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = e2e
SPEC.loader.exec_module(e2e)

LISTING = {
    "devices": [
        {"name": "cosmic-gray", "kind": "computer", "screen": {"action": "view", "route": "hub"}},
        {"name": "air-blue", "kind": "computer", "screen": {"action": "view", "route": "hub"}},
        {"name": "old-mini", "kind": "computer", "screen": {"action": "none", "reason": "offline"}},
        {"name": "iphone", "kind": "phone", "screen": {"action": "none", "reason": "phone"}},
        {"name": "build-vm", "kind": "computer", "screen": {"action": "none", "reason": "no-desktop"}},
    ]
}


class FakeCmux:
    """A cmux CLI whose Screen Sharing tabs go through `script[device]`, one row per mac-screens read."""

    def __init__(self, script, refuse=()):
        self.script, self.refuse = script, set(refuse)
        self.tabs, self.reads, self.calls = {}, {}, []

    def __call__(self, args):
        self.calls.append(args)
        out, code = "", 0
        if args[:2] == ["device", "list"]:
            out = json.dumps(LISTING)
        elif args[:2] == ["tab", "new-mac-screen"]:
            device = args[3]
            if device in self.refuse:
                return subprocess.CompletedProcess(args, 1, "", "error: --scope view opens only your own devices.")
            self.tabs[f"tab_{device}"] = device
        elif args[:2] == ["app", "mac-screens"]:
            rows = []
            for tab, device in self.tabs.items():
                steps = self.script[device]
                index = min(self.reads.get(tab, 0), len(steps) - 1)
                self.reads[tab] = self.reads.get(tab, 0) + 1
                rows.append({"tab": tab, "device": device, **steps[index]})
            out = json.dumps({"tabs": rows})
        elif args[:2] == ["tab", "close"]:
            self.tabs.pop(args[2], None)
        return subprocess.CompletedProcess(args, code, out, "")


def frame(variance):
    return {"hub_phase": "streaming", "phase": "connected", "has_frame": True, "luma_variance": variance, "first_frame_ms": 300}


class StageTests(unittest.TestCase):
    def test_each_stage_is_named(self):
        cases = [
            (None, "no tab"),
            ({"hub_phase": "idle", "phase": "ended", "has_frame": False}, "connect card"),
            ({"hub_phase": "requesting", "phase": None, "has_frame": False}, "no answer"),
            ({"hub_phase": "waiting_for_approval", "has_frame": False}, "waiting for Allow"),
            ({"hub_phase": "streaming", "phase": "connecting", "has_frame": False}, "no link"),
            ({"hub_phase": "streaming", "phase": "connected", "has_frame": False}, "no frame"),
            (frame(3.0), "flat frame"),
            (frame(900.0), "ok"),
            ({"hub_phase": "streaming", "phase": "connected", "has_frame": True}, "flat frame"),
        ]
        for row, stage in cases:
            self.assertEqual(e2e.stage_of(row, 25.0)[0], stage, row)

    def test_only_hub_screens_are_opened(self):
        names, skipped = e2e.viewable_devices(LISTING)
        self.assertEqual(names, ["cosmic-gray", "air-blue"])
        self.assertEqual({s.device: s.stage for s in skipped},
                         {"old-mini": "skipped (offline)", "build-vm": "skipped (no-desktop)"})


class RunTests(unittest.TestCase):
    def run_check(self, fake, *argv):
        clock = iter(range(0, 10_000))
        original = e2e.check_device

        def fast(run, name, timeout, floor, keep):
            return original(run, name, timeout, floor, keep, clock=lambda: float(next(clock)), sleep=lambda _: None)

        e2e.check_device = fast
        try:
            return e2e.main(["--json", "--timeout", "5", *argv], run=fake)
        finally:
            e2e.check_device = original

    def test_a_real_picture_on_every_device_passes_and_closes_its_tabs(self):
        fake = FakeCmux({
            "cosmic-gray": [{"hub_phase": "requesting", "has_frame": False}, frame(900.0)],
            "air-blue": [frame(1200.0)],
        })
        self.assertEqual(self.run_check(fake), 0)
        self.assertEqual(fake.tabs, {})
        opened = [c for c in fake.calls if c[:2] == ["tab", "new-mac-screen"]]
        self.assertEqual([c[-2:] for c in opened], [["--scope", "view"]] * 2)

    def test_a_stall_a_flat_frame_or_a_refusal_fails(self):
        for script, refuse in [
            ({"cosmic-gray": [{"hub_phase": "requesting", "has_frame": False}], "air-blue": [frame(900.0)]}, ()),
            ({"cosmic-gray": [frame(0.0)], "air-blue": [frame(900.0)]}, ()),
            ({"cosmic-gray": [frame(900.0)], "air-blue": [frame(900.0)]}, ("air-blue",)),
        ]:
            self.assertEqual(self.run_check(FakeCmux(script, refuse)), 1, script)

    def test_offline_fails_only_when_required(self):
        script = {"cosmic-gray": [frame(900.0)], "air-blue": [frame(900.0)]}
        self.assertEqual(self.run_check(FakeCmux(script)), 0)
        self.assertEqual(self.run_check(FakeCmux(script), "--require-online"), 1)


if __name__ == "__main__":
    unittest.main()
