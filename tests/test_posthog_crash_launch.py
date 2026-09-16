#!/usr/bin/env python3
"""Run a tagged macOS app against a loopback PostHog collector.

Exercises startup scan -> envelope parsing -> real SDK HTTP capture, plus
relaunch deduplication and telemetry opt-out. Run on an isolated fleet GUI
session with an unused tag; no fixture events are sent to PostHog Cloud.
"""
import argparse
import gzip
import http.server
import json
import os
from pathlib import Path
import plistlib
import queue
import subprocess
import tempfile
import threading


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    app = args.app.resolve()
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    bundle_id = info["CFBundleIdentifier"]
    prefix = "com.cmuxterm.app.debug."
    assert bundle_id.startswith(prefix), "Refusing an untagged app"
    tag = bundle_id.removeprefix(prefix)
    socket_path = Path(f"/tmp/cmux-debug-{tag}.sock")
    assert not socket_path.exists(), "Tag already has a running instance"
    prior = subprocess.run(["defaults", "read", bundle_id], capture_output=True)
    assert prior.returncode != 0, "Use a fresh tag with no saved preferences"
    args.output.mkdir(parents=True, exist_ok=True)
    events = queue.Queue()
    batches = []
    collector_contacted = threading.Event()
    seen_event_ids = set()
    event_ids_lock = threading.Lock()

    class Collector(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            if self.headers.get("Content-Encoding") == "gzip":
                body = gzip.decompress(body)
            payload = json.loads(body)
            collector_contacted.set()
            batches.append({"path": self.path, "payload": payload})
            for event in payload.get("batch", []):
                if event.get("event") == "$exception":
                    # A process can exit after HTTP delivery but before the SDK
                    # persists its acknowledgement. Retries retain the same UUID;
                    # a duplicate capture creates a new UUID and must fail.
                    event_id = event["uuid"]
                    with event_ids_lock:
                        if event_id not in seen_event_ids:
                            seen_event_ids.add(event_id)
                            events.put(event)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":1,"featureFlags":{},"errorsWhileComputingFlags":false}')

        def do_GET(self):
            collector_contacted.set()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{}')

        def log_message(self, *_):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Collector)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    process = None
    log = None
    results = []
    with tempfile.TemporaryDirectory(prefix=f"cmux-crash-e2e-{tag}-") as directory:
        root = Path(directory)
        crash_dir = root / "state/cmux/crash"
        crash_dir.mkdir(parents=True)
        executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
        private_reason = "Opening /Users/Jane Doe/Private Contract.pdf password=private-e2e-token"
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(("CMUX_", "XCTest", "XCInject", "TEST_RUNNER_"))}
        env.update({
            "CMUX_POSTHOG_ENABLE": "1",
            "CMUX_POSTHOG_TEST_HOST": f"http://127.0.0.1:{server.server_port}",
            "CMUX_POSTHOG_DEBUG": "1",
            "CMUX_SOCKET_PATH": str(socket_path),
            "CMUX_BUNDLE_ID": bundle_id,
            "XDG_STATE_HOME": str(root / "state"),
            "XDG_CONFIG_HOME": str(root / "config"),
            "CMUXTERM_REPO_ROOT": str(root),
        })

        def fixture(name, version, native=False):
            event = {
                "exception": {"values": [{"type": "EXC_BAD_ACCESS", "value": private_reason,
                                           "mechanism": {"type": "mach", "handled": False}}]},
                "contexts": {"app": {"app_version": version, "app_build": "6422",
                                      "app_identifier": "com.cmuxterm.app"}},
                "debug_meta": {"images": [{"code_file": str(executable)}]},
            }
            if native:
                event.pop("exception")
                event["contexts"] = {"os": {"name": "macOS"}}
                event["release"] = "1.3.2-HEAD-ghostty"
                event["platform"] = "native"
            payload = json.dumps(event).encode()
            envelope = b'{}\n' + json.dumps({"type": "event", "length": len(payload)}).encode()
            (crash_dir / f"{name}.ghosttycrash").write_bytes(envelope + b'\n' + payload + b'\n')

        def stop():
            nonlocal process, log
            if process is not None:
                process.terminate()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
                process = None
            if log is not None:
                log.close()
                log = None
            # Only our now-stopped tag owns this socket.
            socket_path.unlink(missing_ok=True)

        def launch(label, enabled=True):
            nonlocal process, log
            subprocess.run(["defaults", "write", bundle_id, "sendAnonymousTelemetry", "-bool",
                            "true" if enabled else "false"], check=True)
            log = (args.output / f"{label}.log").open("wb")
            process = subprocess.Popen([str(executable)], cwd=root, env=env, stdout=log, stderr=log)

        def receive(version, native=False):
            event = events.get(timeout=60)
            properties = event["properties"]
            assert properties["crash_app_version"] == version, properties
            assert properties["crash_app_build"] == (info["CFBundleVersion"] if native else "6422"), properties
            assert properties["crash_app_namespace"] == (bundle_id if native else "com.cmuxterm.app"), properties
            assert properties["app_version"] == info["CFBundleShortVersionString"], properties
            assert properties["$app_namespace"] == bundle_id, properties
            assert properties["$app_version"] == info["CFBundleShortVersionString"], properties
            assert properties["$app_build"] == info["CFBundleVersion"], properties
            expected_type = "UnknownCrash" if native else "EXC_BAD_ACCESS"
            assert properties["$exception_fingerprint"] == f"cmux-mac-crash:{expected_type}"
            assert properties["$exception_list"][0]["value"] == "Previous launch crashed"
            serialized = json.dumps(event)
            assert "private-e2e-token" not in serialized and "Jane Doe" not in serialized
            assert process.poll() is None, "App exited during capture"
            return event

        def assert_quiet(label):
            # A negative assertion needs an observation window. The local SDK
            # collector flushes each event immediately (flushAt=1).
            try:
                unexpected = events.get(timeout=8)
            except queue.Empty:
                assert process.poll() is None, "App exited instead of applying its gate"
                results.append(label)
            else:
                raise AssertionError(f"Unexpected exception for {label}: {unexpected}")

        try:
            # Prove the built app accepts the loopback SDK host before creating
            # synthetic crash data. Older builds fail without uploading fixtures.
            launch("collector-preflight")
            assert collector_contacted.wait(timeout=45), "App did not contact the loopback collector"
            stop()
            fixture("first", "0.64.22")
            launch("first")
            captured = [receive("0.64.22")]
            results.append("startup captures crashed-build and reporting-build identity through real SDK")
            stop()
            launch("relaunch")
            assert_quiet("same crash is not captured after relaunch")
            stop()
            fixture("second", "0.64.21")
            launch("new-crash")
            captured.append(receive("0.64.21"))
            results.append("a newer crash is captured independently")
            stop()
            fixture("native", info["CFBundleShortVersionString"], native=True)
            launch("native-crash")
            captured.append(receive(info["CFBundleShortVersionString"], native=True))
            results.append("native minidump envelope uses the frozen previous-launch identity")
            stop()
            fixture("disabled", "0.64.20")
            launch("disabled", enabled=False)
            assert_quiet("telemetry opt-out suppresses crash capture")
            (args.output / "events.json").write_text(json.dumps(captured, indent=2))
            (args.output / "summary.json").write_text(json.dumps({"tag": tag, "passed": results}, indent=2))
            print(json.dumps({"tag": tag, "passed": results}, indent=2))
        finally:
            stop()
            server.shutdown()
            subprocess.run(["defaults", "delete", bundle_id], capture_output=True)
            (args.output / "requests.json").write_text(json.dumps(batches, indent=2))


if __name__ == "__main__":
    main()
