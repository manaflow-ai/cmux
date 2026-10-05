"""Execute the guest display catalog; no guest VM or GUI is mutated."""
import concurrent.futures
import importlib.machinery
import importlib.util
import json
import os
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
            return mock.Mock(stdout=f"DBUS_SESSION_BUS_ADDRESS='unix:path=/tmp/bus-{len(environments)}'; export DBUS_SESSION_BUS_ADDRESS;\nDBUS_SESSION_BUS_PID={os.getpid()}; export DBUS_SESSION_BUS_PID;\n")

        readiness_calls = {}
        def readiness(number):
            readiness_calls[number] = readiness_calls.get(number, 0) + 1
            return readiness_calls[number] > 1

        with mock.patch.object(display.subprocess, "Popen", side_effect=spawn), \
             mock.patch.object(display.subprocess, "run", side_effect=launch), \
             mock.patch.object(display.shutil, "which", side_effect=lambda name: name), \
             mock.patch.object(service, "wait_for_port", return_value=True), \
             mock.patch.object(display, "ready", side_effect=readiness):
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

    def test_novnc_recovery_does_not_terminate_guest_desktop(self):
        service = display.DisplayService(self.catalog(), self.root / "runtime")
        number = 2

        class Process:
            def __init__(self):
                self.terminated = False

            def terminate(self):
                self.terminated = True

        x_server = Process()
        old_websockify = Process()
        new_websockify = Process()
        service.processes[number] = [x_server]
        service.named_processes[number] = {"xvnc": x_server, "dbus": Process()}
        service.websockify_processes[number] = old_websockify
        environment = {"DISPLAY": ":2"}
        runtime = self.root / "runtime" / "2"
        runtime.mkdir(parents=True)

        with mock.patch.object(display, "ready", return_value=False), \
             mock.patch.object(display, "rfb_ready", return_value=True), \
             mock.patch.object(display, "novnc_ready", return_value=False), \
             mock.patch.object(display.shutil, "which", return_value="/usr/bin/websockify"), \
             mock.patch.object(display.subprocess, "Popen", return_value=new_websockify), \
             mock.patch.object(service, "wait_for_port", return_value=True), \
             mock.patch.object(service, "set_wallpaper"), \
             mock.patch.object(service, "terminate_untracked_websockify"):
            service.start_components(number, environment, runtime)

        self.assertFalse(x_server.terminated)
        self.assertTrue(old_websockify.terminated)
        self.assertIs(service.websockify_processes[number], new_websockify)
        service.shutdown.set()

    def test_additional_display_novnc_listens_beside_the_primary_desktop(self):
        """Displays 2+ must be reachable on the VM private address like :1;
        a loopback-only websockify refused the client's route."""
        service = display.DisplayService(self.catalog(), self.root / "runtime")
        launched = []

        class Process:
            def terminate(self):
                pass

        def popen(command, **_options):
            launched.append(command)
            return Process()

        with mock.patch.object(display.subprocess, "Popen", side_effect=popen), \
             mock.patch.object(service, "terminate_untracked_websockify") as stale, \
             mock.patch.object(service, "wait_for_port", return_value=True):
            service.start_websockify(3, {}, "/usr/bin/websockify")

        stale.assert_called_once_with(3)
        self.assertIn("[::]:6903", launched[0])
        self.assertIn("127.0.0.1:5903", launched[0])
        self.assertNotIn("127.0.0.1:6903", launched[0])
        service.shutdown.set()

    def test_untracked_websockify_matches_only_this_displays_proxy(self):
        proc = self.root / "proc"
        uid = os.getuid()

        def process(pid, *argv):
            entry = proc / str(pid)
            entry.mkdir(parents=True)
            (entry / "cmdline").write_bytes(b"\0".join(arg.encode() for arg in argv) + b"\0")

        websockify = ["/usr/bin/python3", "/usr/bin/websockify", "--web", "/usr/share/novnc", "--heartbeat", "30"]
        process(101, *websockify, "127.0.0.1:6902", "127.0.0.1:5902")
        process(102, *websockify, "[::]:6902", "127.0.0.1:5902")
        process(103, *websockify, "127.0.0.1:6903", "127.0.0.1:5903")
        process(104, *websockify, "[::]:6901", "127.0.0.1:5901")
        process(105, "/usr/bin/python3", "/home/cmux/.cmux/cmux-display", "serve")

        pids = display.DisplayService.untracked_websockify_pids(2, proc=proc)

        self.assertEqual(sorted(pids), [101, 102])
        self.assertEqual(uid, os.getuid())

    def test_untracked_websockify_is_not_ready_so_it_is_rebound(self):
        """A restarted helper keeps the X session but must replace a proxy it
        did not start, which may still be bound to loopback."""
        service = display.DisplayService(self.catalog(), self.root / "runtime")
        number = 2

        class Process:
            def poll(self):
                return None

        service.named_processes[number] = {"xvnc": Process()}
        service.processes[number] = [service.named_processes[number]["xvnc"]]
        with mock.patch.object(display, "ready", return_value=True):
            self.assertFalse(service.service_ready(number))
            service.websockify_processes[number] = Process()
            self.assertTrue(service.service_ready(number))
        service.shutdown.set()

    def test_crashed_session_component_restarts_without_restarting_x(self):
        service = display.DisplayService(self.catalog(), self.root / "runtime")
        number = 2

        class Process:
            def __init__(self, exit_code=None):
                self.exit_code = exit_code
                self.terminated = False

            def terminate(self):
                self.terminated = True

            def poll(self):
                return self.exit_code

        x_server = Process()
        dbus = Process()
        crashed_openbox = Process(1)
        replacement = Process()
        service.processes[number] = [x_server, dbus, crashed_openbox]
        service.named_processes[number] = {"xvnc": x_server, "dbus": dbus, "openbox": crashed_openbox}
        service.websockify_processes[number] = Process()
        environment = {"DISPLAY": ":2"}
        runtime = self.root / "runtime" / "2"
        runtime.mkdir(parents=True)

        with mock.patch.object(display, "ready", return_value=False), \
             mock.patch.object(display, "rfb_ready", return_value=True), \
             mock.patch.object(display, "novnc_ready", return_value=True), \
             mock.patch.object(display.shutil, "which", side_effect=lambda name: name), \
             mock.patch.object(display.subprocess, "Popen", return_value=replacement), \
             mock.patch.object(service, "set_wallpaper"):
            service.start_components(number, environment, runtime)

        self.assertFalse(x_server.terminated)
        self.assertIs(service.named_processes[number]["openbox"], replacement)
        service.shutdown.set()

    def fake_proc(self, processes):
        proc = self.root / "proc"
        for pid, argv in processes.items():
            entry = proc / str(pid)
            entry.mkdir(parents=True)
            (entry / "cmdline").write_bytes(b"\0".join(arg.encode() for arg in argv) + b"\0")
        return proc

    def test_recovery_adopts_display_scoped_processes_by_full_command(self):
        """Recovery matches exact argv; the pgrep patterns it replaced were
        rejected by pgrep's regex dialect, so nothing was ever adopted."""
        service = display.DisplayService(self.catalog(), self.root / "runtime")
        runtime = self.root / "runtime" / "2"
        proc = self.fake_proc({
            12345: [str(runtime / "bin" / "cmux-display-2-openbox")],
            12346: [str(self.root / "runtime" / "3" / "bin" / "cmux-display-3-openbox")],
            22222: ["/usr/bin/Xvnc", ":2", "-geometry", "1440x900", "-rfbport", "5902", "-localhost"],
            33333: ["/usr/bin/Xvnc", ":3", "-rfbport", "5903"],
        })
        real = display.matching_pids
        with mock.patch.object(service, "matching_pids",
                               side_effect=lambda predicate: real(predicate, proc=proc)):
            service.recover_processes(2, runtime, {"DISPLAY": ":2"})
        self.assertEqual(service.named_processes[2]["openbox"].pid, 12345)
        self.assertEqual(service.named_processes[2]["xvnc"].pid, 22222)

    def rfb_server(self, script):
        """A one-shot loopback RFB peer driven by `script(connection)`."""
        import socket
        import threading
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        received = []

        def serve():
            connection, _ = listener.accept()
            with connection:
                script(connection, received)
            listener.close()

        threading.Thread(target=serve, daemon=True).start()
        return listener.getsockname()[1] - 5900, received

    def test_health_probe_completes_authentication_instead_of_black_marking(self):
        """An aborted handshake is a black mark; Xvnc then refused every
        websockify viewer with "Too many security failures"."""
        def script(connection, received):
            connection.sendall(b"RFB 003.008\n")
            received.append(display.recv_exact(connection, 12))
            connection.sendall(bytes([1, 1]))
            received.append(display.recv_exact(connection, 1))
            connection.sendall(b"\x00\x00\x00\x00")

        number, received = self.rfb_server(script)
        self.assertTrue(display.rfb_ready(number))
        self.assertEqual(received, [b"RFB 003.008\n", b"\x01"])

    def test_black_listing_server_is_alive_so_the_session_is_kept(self):
        def script(connection, _received):
            connection.sendall(b"RFB 003.003\n\x00\x00\x00\x00\x00\x00\x00\x1aToo many security failures")

        number, _ = self.rfb_server(script)
        self.assertTrue(display.rfb_ready(number))

    def test_additional_displays_disable_rfb_black_listing(self):
        service = display.DisplayService(self.catalog(), self.root / "runtime")
        launched = []

        class Process:
            def terminate(self):
                pass

            def poll(self):
                return None

        def popen(command, **_options):
            launched.append(command)
            return Process()

        runtime = self.root / "runtime" / "2"
        runtime.mkdir(parents=True)
        with mock.patch.object(display, "ready", return_value=False), \
             mock.patch.object(display, "rfb_ready", return_value=False), \
             mock.patch.object(display, "novnc_ready", return_value=True), \
             mock.patch.object(display.shutil, "which", side_effect=lambda name: f"/usr/bin/{name}"), \
             mock.patch.object(display.subprocess, "Popen", side_effect=popen), \
             mock.patch.object(service, "wait_for_port", return_value=True), \
             mock.patch.object(service, "start_dbus"), \
             mock.patch.object(service, "start_session_components"), \
             mock.patch.object(service, "set_wallpaper"), \
             mock.patch.object(service, "terminate_untracked_websockify"):
            service.start_components(2, {"DISPLAY": ":2"}, runtime)
        xvnc = next(command for command in launched if command[0].endswith("Xvnc"))
        self.assertIn("-UseBlacklist=0", xvnc)
        service.shutdown.set()

    def standby_service(self, occupied=lambda _: False):
        """A service whose display starts are recorded and complete at once."""
        service = display.DisplayService(self.catalog(occupied=occupied), self.root / "runtime")
        started = []

        def start(number):
            started.append(number)
            service.states[number] = "running"
            finished = display.threading.Event()
            finished.set()
            service.jobs[number] = finished
            return finished

        service.start = start
        return service, started

    def test_new_display_takes_the_running_standby_and_warms_the_next(self):
        """New Display hands over an already-running desktop instead of
        starting Xvnc and a session while the user waits."""
        service, started = self.standby_service()
        with mock.patch.object(display, "ready", return_value=True):
            listed = service.handle({"action": "list"})
            self.assertEqual(service.standby, 2)
            self.assertEqual([d["id"] for d in listed["displays"]], ["display:1"],
                             "the standby is not a display until it is requested")
            created = service.handle({"action": "create", "request": str(uuid.uuid4())})
        self.assertEqual(created["created"], "display:2")
        self.assertEqual(service.catalog.numbers(), [2])
        self.assertEqual(service.standby, 3)
        self.assertEqual(started, [2, 2, 3])
        service.shutdown.set()

    def test_retried_create_keeps_its_display_and_the_standby(self):
        service, _ = self.standby_service()
        request = str(uuid.uuid4())
        with mock.patch.object(display, "ready", return_value=True):
            service.handle({"action": "list"})
            first = service.handle({"action": "create", "request": request})
            again = service.handle({"action": "create", "request": request})
        self.assertEqual(first["created"], again["created"])
        self.assertEqual(service.catalog.numbers(), [2])
        self.assertEqual(service.standby, 3)
        service.shutdown.set()

    def test_standby_does_not_consume_display_capacity(self):
        service, _ = self.standby_service()
        for _ in range(display.MAX_DISPLAYS - 2):
            service.catalog.allocate(str(uuid.uuid4()))
        with mock.patch.object(display, "ready", return_value=True):
            listed = service.handle({"action": "list"})
        self.assertTrue(listed["canCreate"])
        self.assertEqual(service.standby, display.MAX_DISPLAYS)
        with mock.patch.object(display, "ready", return_value=True):
            created = service.handle({"action": "create", "request": str(uuid.uuid4())})
        self.assertEqual(created["created"], f"display:{display.MAX_DISPLAYS}")
        self.assertIsNone(service.standby, "no slot remains for another standby")
        self.assertFalse(created["canCreate"])
        service.shutdown.set()

    def test_failed_standby_is_retired_not_handed_over(self):
        service, _ = self.standby_service()
        with mock.patch.object(display, "ready", return_value=True):
            service.handle({"action": "list"})
            service.states[2] = "unavailable"
            created = service.handle({"action": "create", "request": str(uuid.uuid4())})
        self.assertNotEqual(created["created"], "display:2")
        self.assertNotIn(2, service.catalog.numbers())
        self.assertNotIn(service.standby, (None, 2))
        service.shutdown.set()

    def test_launching_standby_number_is_never_recorded_for_another_request(self):
        catalog = self.catalog()
        self.assertEqual(catalog.allocate(str(uuid.uuid4()), reserved={2}), 3)
        self.assertEqual(catalog.free_number(reserved={4}), 2)

    def test_concurrent_creates_keep_one_standby_outside_the_catalog(self):
        service, _ = self.standby_service()
        with mock.patch.object(display, "ready", return_value=True):
            service.handle({"action": "list"})
            with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
                created = list(pool.map(
                    lambda _: service.handle({"action": "create", "request": str(uuid.uuid4())})["created"],
                    range(6)))
        numbers = service.catalog.numbers()
        self.assertEqual(len(set(created)), 6)
        self.assertEqual(len(numbers), 6)
        self.assertIsNotNone(service.standby)
        self.assertNotIn(service.standby, numbers)
        service.shutdown.set()

    def test_restarted_service_adopts_the_running_standby(self):
        service, started = self.standby_service()
        service.catalog.allocate(str(uuid.uuid4()))
        service.adopt_standby(is_display_server=lambda number: number == 4)
        self.assertEqual(service.standby, 4)
        self.assertEqual(started, [4])
        service.shutdown.set()

    def test_additional_desktop_clients_use_display_scoped_process_names(self):
        service = display.DisplayService(self.catalog(), self.root / "runtime")
        source = self.root / "openbox"
        source.write_text("#!/bin/sh\n")
        runtime = self.root / "runtime" / "2"
        scoped = service.scoped_component_path("openbox", str(source), 2, runtime)
        self.assertEqual(Path(scoped).name, "cmux-display-2-openbox")
        self.assertTrue(Path(scoped).exists())

    def test_start_failure_retains_resource_and_replay_receipt(self):
        service = display.DisplayService(self.catalog(), self.root / "runtime")
        request = str(uuid.uuid4())
        with mock.patch.object(display.subprocess, "run", side_effect=OSError("starter unavailable")), \
             mock.patch.object(display.shutil, "which", return_value=None), \
             mock.patch.object(display, "ready", return_value=False):
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
