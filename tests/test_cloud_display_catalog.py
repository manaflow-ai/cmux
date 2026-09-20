"""Execute the guest display catalog; no guest VM or GUI is mutated."""
import concurrent.futures
import importlib.machinery
import importlib.util
import json
import sys
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import uuid


sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader(
    "cmux_display", str(Path(__file__).resolve().parents[1] /
                        "tests/fixtures/cmux-display"))
spec = importlib.util.spec_from_loader(loader.name, loader)
display = importlib.util.module_from_spec(spec)
loader.exec_module(display)


class CloudDisplayCatalogTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def catalog(self, vm="a", occupied=lambda _: False):
        return display.DisplayCatalog(self.root / vm, occupied=occupied)

    def test_second_display_is_distinct_and_keeps_first_receipt(self):
        catalog = self.catalog()
        first_request, second_request = str(uuid.uuid4()), str(uuid.uuid4())
        first = catalog.allocate(first_request)
        second = catalog.allocate(second_request)
        self.assertEqual((first, second), (2, 3))
        self.assertEqual(catalog.allocate(first_request), first)
        self.assertEqual(display.descriptor(1)["port"], 6901)
        self.assertNotEqual(display.descriptor(first)["port"], display.descriptor(second)["port"])

    def test_vm_catalogs_can_use_identical_display_ids_independently(self):
        a, b = self.catalog("a"), self.catalog("b")
        request = str(uuid.uuid4())
        self.assertEqual(a.allocate(request), b.allocate(request))
        a.allocate(str(uuid.uuid4()))
        self.assertEqual(a.numbers(), [2, 3])
        self.assertEqual(b.numbers(), [2])

    def test_reconnect_restores_stable_resource_and_retry_identity(self):
        request = str(uuid.uuid4())
        first = self.catalog()
        number = first.allocate(request)
        restored = self.catalog()
        self.assertEqual(restored.allocate(request), number)
        self.assertEqual(restored.numbers(), [number])

    def test_concurrent_retry_allocates_one_resource(self):
        catalog = self.catalog()
        request = str(uuid.uuid4())
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(catalog.allocate, [request] * 32))
        self.assertEqual(set(results), {2})
        self.assertEqual(catalog.numbers(), [2])

    def test_existing_guest_ports_and_x_sockets_are_not_adopted(self):
        catalog = self.catalog(occupied=lambda number: number in (2, 3))
        self.assertEqual(catalog.allocate(str(uuid.uuid4())), 4)

    def test_capacity_failure_does_not_replace_existing_displays(self):
        catalog = self.catalog()
        for _ in range(display.MAX_DISPLAYS - 1):
            catalog.allocate(str(uuid.uuid4()))
        before = catalog.path.read_bytes()
        with self.assertRaises(ValueError):
            catalog.allocate(str(uuid.uuid4()))
        self.assertEqual(catalog.path.read_bytes(), before)

    def test_unknown_request_cannot_mutate_catalog(self):
        catalog = self.catalog()
        for request in (None, "", "../../other-vm", "$(touch /tmp/not-allowed)"):
            with self.assertRaises((ValueError, TypeError, AttributeError)):
                catalog.allocate(request)
        self.assertFalse(catalog.path.exists())

    def test_corrupt_persisted_identity_fails_closed(self):
        catalog = self.catalog()
        catalog.path.write_text(json.dumps({"version": 1, "displays": [
            {"number": 1, "request": str(uuid.uuid4())}]}))
        with self.assertRaises(ValueError):
            self.catalog()

    def test_supervision_keeps_display_and_session_environment_separate(self):
        catalog = self.catalog()
        service = display.DisplayService(catalog, self.root / "runtime")
        environments = []

        class Process:
            def terminate(self):
                pass

        def spawn(_command, **options):
            environments.append(options["env"].copy())
            return Process()

        def launch(_command, **_options):
            return mock.Mock(stdout=f"DBUS_SESSION_BUS_ADDRESS='unix:path=/tmp/bus-{len(environments)}'\nDBUS_SESSION_BUS_PID=1\n")

        with mock.patch.object(display.subprocess, "Popen", side_effect=spawn), \
             mock.patch.object(display.subprocess, "run", side_effect=launch), \
             mock.patch.object(display.shutil, "which", side_effect=lambda name: name), \
             mock.patch.object(service, "wait_for_port", return_value=True), \
             mock.patch.object(display, "ready", return_value=True):
            try:
                first = service.handle({"action": "create", "request": str(uuid.uuid4())})
                second = service.handle({"action": "create", "request": str(uuid.uuid4())})
                self.assertEqual(first["created"], "display:2")
                self.assertEqual(second["created"], "display:3")
                self.assertEqual(len(second["displays"]), 3)
                displays = sorted({env["DISPLAY"] for env in environments})
                self.assertEqual(displays, [":2", ":3"])
                by_display = {env["DISPLAY"]: env for env in environments}
                self.assertNotEqual(by_display[":2"]["CMUX_DESKTOP_RUNTIME_DIR"], by_display[":3"]["CMUX_DESKTOP_RUNTIME_DIR"])
                self.assertNotEqual(by_display[":2"]["DBUS_SESSION_BUS_ADDRESS"], by_display[":3"]["DBUS_SESSION_BUS_ADDRESS"])
                for env in by_display.values():
                    self.assertNotIn("NOTIFY_SOCKET", env)
            finally:
                service.shutdown.set()

    def test_start_failure_retains_resource_and_replay_receipt(self):
        service = display.DisplayService(self.catalog(), self.root / "runtime")
        request = str(uuid.uuid4())
        with mock.patch.object(display.subprocess, "run", side_effect=OSError("starter unavailable")), mock.patch.object(display, "ready", return_value=True):
            try:
                result = service.handle({"action": "create", "request": request})
                retried = service.handle({"action": "create", "request": request})
                self.assertEqual(result["error"], "display_start_failed")
                self.assertEqual(retried["created"], result["created"])
                self.assertEqual(len(retried["displays"]), 2)
                self.assertEqual(retried["displays"][0]["id"], "display:1")
            finally:
                service.shutdown.set()


if __name__ == "__main__":
    unittest.main()
