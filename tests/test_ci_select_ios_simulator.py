#!/usr/bin/env python3
"""select_ios_simulator.py against a fake simctl: today's shared device, and glaeda's per-slot devices."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import re
import tempfile
import unittest
import unittest.mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "select_ios_simulator.py"
WORKFLOW = ROOT / ".github" / "workflows" / "test-ios.yml"

RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
OLD_RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-26-2"
IPHONE_17 = "com.apple.CoreSimulator.SimDeviceType.iPhone-17"


def load():
    spec = importlib.util.spec_from_file_location("select_ios_simulator", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeSimctl:
    """An in-memory CoreSimulator device set behind `xcrun simctl` and `xcrun --sdk`."""

    def __init__(self, devices=None, sdk="26.5"):
        # runtime -> list of device dicts
        self.devices = {RUNTIME: [], OLD_RUNTIME: []}
        for runtime, device in devices or []:
            self.devices.setdefault(runtime, []).append(device)
        self.sdk = sdk
        self.calls: list[list[str]] = []
        self.next_id = 0

    def new_udid(self):
        self.next_id += 1
        return f"UDID-{self.next_id}"

    def find(self, udid):
        for runtime, items in self.devices.items():
            for device in items:
                if device["udid"] == udid:
                    return runtime, device
        raise AssertionError(f"no device {udid}")

    def handle(self, args):
        assert args[0] == "xcrun", args
        self.calls.append(args[1:])
        if args[1:3] == ["--sdk", "iphonesimulator"]:
            return self.sdk
        assert args[1] == "simctl", args
        verb, rest = args[2], args[3:]
        if verb == "list":
            what = rest[0]
            if what == "devices":
                available = "available" in rest
                return json.dumps({"devices": {
                    runtime: [dict(d) for d in items if not available or d.get("isAvailable", True)]
                    for runtime, items in self.devices.items()}})
            if what == "runtimes":
                return json.dumps({"runtimes": [
                    {"identifier": RUNTIME, "version": "26.5", "platform": "iOS", "isAvailable": True,
                     "name": "iOS 26.5", "supportedDeviceTypes": [{"identifier": IPHONE_17}]}]})
            if what == "devicetypes":
                return json.dumps({"devicetypes": [{"name": "iPhone 17", "identifier": IPHONE_17}]})
        if verb == "create":
            name, type_id, runtime = rest
            udid = self.new_udid()
            self.devices.setdefault(runtime, []).append({"udid": udid, "name": name, "state": "Shutdown",
                                                         "deviceTypeIdentifier": type_id, "isAvailable": True})
            return udid
        if verb == "clone":
            source, name = rest
            runtime, device = self.find(source)
            assert device["state"] == "Shutdown", "simctl clone needs the source shut down"
            udid = self.new_udid()
            self.devices[runtime].append({**device, "udid": udid, "name": name})
            return udid
        if verb == "boot":
            _, device = self.find(rest[0])
            if device["state"] == "Booted":
                raise RuntimeError("already booted")
            device["state"] = "Booted"
            device["boots"] = device.get("boots", 0) + 1
            return ""
        if verb == "bootstatus":
            _, device = self.find(rest[0])
            assert device["state"] == "Booted"
            return ""
        if verb == "shutdown":
            _, device = self.find(rest[0])
            device["state"] = "Shutdown"
            return ""
        if verb == "delete":
            runtime, device = self.find(rest[0])
            self.devices[runtime].remove(device)
            return ""
        raise AssertionError(f"unexpected simctl call {args}")

    def verbs(self):
        return [call[1] for call in self.calls if call[0] == "simctl" and call[1] != "list"]

    def named(self, name):
        return [(runtime, d) for runtime, items in self.devices.items() for d in items if d["name"] == name]


def shared(udid="SHARED", name="iPhone 17", runtime=RUNTIME, state="Shutdown"):
    return runtime, {"udid": udid, "name": name, "state": state, "deviceTypeIdentifier": IPHONE_17,
                     "isAvailable": True}


class Harness:
    def __init__(self, fake, env, lock_dir):
        self.module = load()
        self.module.LOCK_PATH = str(Path(lock_dir) / "slots.lock")
        self.fake = fake
        self.env = {"DEVICE_FAMILY": "iphone", "GITHUB_RUN_ID": "42", **env}

    def run(self):
        fake = self.fake

        def check_output(args, text=False, **_):
            out = fake.handle(list(args))
            return out if text else out.encode()

        def run(args, check=False, **_):
            try:
                fake.handle(list(args))
            except RuntimeError:
                if check:
                    raise
            return unittest.mock.Mock(returncode=0)

        def check_call(args, stdout=None, **_):
            fake.handle(list(args))
            if list(args)[2:3] == ["bootstatus"] and stdout is None:
                # The real bootstatus prints progress on stdout, which the workflow appends to $GITHUB_ENV.
                print(f"Monitoring boot status for {args[3]}.")
            return 0

        out = io.StringIO()
        with unittest.mock.patch.object(self.module.subprocess, "check_output", check_output), \
                unittest.mock.patch.object(self.module.subprocess, "run", run), \
                unittest.mock.patch.object(self.module.subprocess, "check_call", check_call), \
                unittest.mock.patch.dict(self.module.os.environ, self.env, clear=True), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            self.module.main()
        return dict(line.split("=", 1) for line in out.getvalue().splitlines())


class SelectIOSSimulator(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def select(self, fake, **env):
        return Harness(fake, env, self.tmp.name).run()

    def test_without_a_slot_the_shared_device_is_used_untouched(self):
        fake = FakeSimctl([shared()])
        self.assertEqual(self.select(fake), {"SIMULATOR_ID": "SHARED", "SIMULATOR_NAME": "iPhone 17"})
        self.assertEqual(fake.verbs(), [])
        # A hosted runner ignores a stray slot.
        fake = FakeSimctl([shared()])
        self.assertEqual(self.select(fake, GLAEDA_SIM_SLOT="1", RUNNER_ENVIRONMENT="github-hosted"),
                         {"SIMULATOR_ID": "SHARED", "SIMULATOR_NAME": "iPhone 17"})
        self.assertEqual(fake.verbs(), [])

    def test_without_a_slot_a_missing_device_is_created_for_the_run(self):
        fake = FakeSimctl()
        out = self.select(fake)
        self.assertEqual(out["SIMULATOR_NAME"], "cmux CI 42 iPhone 17")
        self.assertNotIn("SIMULATOR_KEEP", out)
        self.assertEqual(fake.verbs(), ["create"])

    def test_a_slot_gets_its_own_device_cloned_from_a_once_booted_base(self):
        fake = FakeSimctl([shared()])
        out = self.select(fake, GLAEDA_SIM_SLOT="1", RUNNER_ENVIRONMENT="self-hosted")
        self.assertEqual(out["SIMULATOR_NAME"], "cmux CI slot 1 iPhone 17")
        self.assertEqual(out["SIMULATOR_KEEP"], "1")
        self.assertNotEqual(out["SIMULATOR_ID"], "SHARED")
        # The base was created, booted once (first-boot migration), shut down, cloned; the slot booted.
        self.assertEqual(fake.verbs(), ["create", "boot", "bootstatus", "shutdown", "clone", "boot", "bootstatus"])
        [(runtime, base)] = fake.named("cmux CI base iPhone 17")
        self.assertEqual((runtime, base["state"], base["boots"]), (RUNTIME, "Shutdown", 1))
        [(runtime, slot)] = fake.named("cmux CI slot 1 iPhone 17")
        # The shared device's pin: same device type and runtime.
        self.assertEqual((runtime, slot["deviceTypeIdentifier"], slot["state"]), (RUNTIME, IPHONE_17, "Booted"))
        # The shared device is never touched.
        self.assertEqual(fake.named("iPhone 17")[0][1]["state"], "Shutdown")

        # The next job of slot 1 reuses the booted device: no create, clone, boot or shutdown.
        fake.calls.clear()
        again = self.select(fake, GLAEDA_SIM_SLOT="1", RUNNER_ENVIRONMENT="self-hosted")
        self.assertEqual(again["SIMULATOR_ID"], out["SIMULATOR_ID"])
        self.assertEqual(fake.verbs(), [])

        # Slot 2 clones the existing base; the base is not booted again.
        fake.calls.clear()
        second = self.select(fake, GLAEDA_SIM_SLOT="2", RUNNER_ENVIRONMENT="self-hosted")
        self.assertEqual(second["SIMULATOR_NAME"], "cmux CI slot 2 iPhone 17")
        self.assertNotEqual(second["SIMULATOR_ID"], out["SIMULATOR_ID"])
        self.assertEqual(fake.verbs(), ["clone", "boot", "bootstatus"])
        self.assertEqual(fake.named("cmux CI base iPhone 17")[0][1]["boots"], 1)

        # A slot device shut down by a job's erase cycle is booted again, not recreated.
        fake.named("cmux CI slot 2 iPhone 17")[0][1]["state"] = "Shutdown"
        fake.calls.clear()
        self.assertEqual(self.select(fake, GLAEDA_SIM_SLOT="2")["SIMULATOR_ID"], second["SIMULATOR_ID"])
        self.assertEqual(fake.verbs(), ["boot", "bootstatus"])

    def test_a_slot_device_of_a_stale_pin_is_replaced(self):
        # A runtime update: the slot and base devices on the old runtime go, new ones on the pin come.
        stale_slot = shared("OLD-SLOT", "cmux CI slot 1 iPhone 17", OLD_RUNTIME, "Booted")
        stale_base = shared("OLD-BASE", "cmux CI base iPhone 17", OLD_RUNTIME)
        fake = FakeSimctl([shared(), stale_slot, stale_base])
        out = self.select(fake, GLAEDA_SIM_SLOT="1")
        self.assertEqual([runtime for runtime, _ in fake.named("cmux CI slot 1 iPhone 17")], [RUNTIME])
        self.assertEqual([runtime for runtime, _ in fake.named("cmux CI base iPhone 17")], [RUNTIME])
        self.assertNotIn(out["SIMULATOR_ID"], ("OLD-SLOT", "SHARED"))

    def test_a_slot_without_a_shared_device_uses_the_created_pin(self):
        fake = FakeSimctl()
        out = self.select(fake, GLAEDA_SIM_SLOT="3")
        self.assertEqual(out["SIMULATOR_NAME"], "cmux CI slot 3 iPhone 17")
        self.assertEqual(fake.named("cmux CI 42 iPhone 17"), [])

    def test_an_explicit_ios_version_ignores_the_slot(self):
        fake = FakeSimctl([shared()])
        out = self.select(fake, GLAEDA_SIM_SLOT="1", IOS_VERSION="26.5")
        self.assertEqual(out["SIMULATOR_NAME"], "cmux CI 42 iPhone 17")
        self.assertNotIn("SIMULATOR_KEEP", out)

    def test_a_malformed_slot_fails(self):
        with self.assertRaises(SystemExit):
            self.select(FakeSimctl([shared()]), GLAEDA_SIM_SLOT="1; rm")

    def test_the_workflow_never_deletes_a_kept_device(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        steps = re.findall(r"- name: Remove compatibility simulator\n(?:        #.*\n)*        if: (.*)\n", text)
        self.assertEqual(len(steps), 2)
        for condition in steps:
            self.assertIn("env.SIMULATOR_KEEP != '1'", condition)


if __name__ == "__main__":
    unittest.main()
