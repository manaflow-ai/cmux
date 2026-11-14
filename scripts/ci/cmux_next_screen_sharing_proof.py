"""Mounted iPhone Screen Sharing proof; host approval is setup, never viewer input.

The runner supplies an isolated simulator and its own tagged Mac. This module
does not provision credentials, replace identity storage, or borrow a host.
Only a complete start/frame/input/stop sequence can produce a passing receipt.
"""
import argparse
from contextlib import contextmanager
import hashlib
import importlib.util
import json
import os
import signal
import shutil
import subprocess
import tempfile
import re
import secrets
import time
import zipfile
from pathlib import Path


class ProofFailure(RuntimeError):
    """Fixed descriptions only: account, device and session values stay private."""


@contextmanager
def private_workspace(can_remove):
    # A failed remote cleanup may leave a lease marker here. Keep it on the
    # quarantined host for recovery rather than losing ownership evidence.
    directory = tempfile.mkdtemp(prefix="cmux-ss-", dir="/tmp")
    try:
        yield directory
    finally:
        if can_remove():
            shutil.rmtree(directory)


ERROR_CODES = {
    "device_hub_configuration_timeout", "host_cloud_namespace_unavailable",
    "host_admission_unverified", "host_staging_backend_unverified",
    "host_namespace_prepare_failed", "host_namespace_cleanup_failed",
    "host_remote_prepare_failed", "host_remote_cleanup_failed",
    "proof_incomplete", "proof_interrupted", "host_cleanup_failed", "runner_preflight_failed",
    "host_command_unavailable", "host_command_failed", "device_identity_secure_enclave_unavailable",
    "device_identity_corrupt_key_blob", "device_identity_unavailable",
    "mac_artifact_not_completed_at_requested_source", "invalid_mac_job", "invalid_mac_job_receipt",
    "mac_bundle_path_mismatch", "mac_bundle_tag_mismatch", "host_rpc_incomplete", "host_rpc_refused",
    "host_rpc_action_failed", "host_rpc_unavailable", "host_exited_before_account_ready",
    "host_account_not_ready", "host_socket_path_too_long", "host_namespace_not_fresh",
    "host_tag_already_running", "host_namespace_has_existing_account", "host_exited_before_hub_ready",
    "host_account_mismatch", "host_hub_not_ready", "host_screen_and_input_grants_missing",
    "host_input_log_bound", "phone_start_unverified", "phone_frame_unverified", "phone_input_unverified",
    "phone_stop_unverified", "host_stop_unverified",
}


def safe_error(code):
    return isinstance(code, str) and (code in ERROR_CODES or bool(re.fullmatch(r"device_identity_keychain_-?[0-9]{1,10}", code)))


def positive_fps(value):
    match = re.search(r"(?:^|[ ·])([0-9]+(?:\.[0-9]+)?) fps(?:[ ·]|$)", value)
    return bool(match and float(match[1]) > 0)


def input_text(events, after):
    """Only host-delivered key events newer than this challenge count."""
    return "".join(e.get("chars", "") for e in events
                   if isinstance(e, dict) and e.get("kind") == "key"
                   and isinstance(e.get("t"), (int, float)) and e["t"] >= after)


class ScreenProof:
    def __init__(self, phone, hub, events, *, clock=time.monotonic,
                 wall=time.time, sleep=time.sleep, timeout=180):
        self.phone, self.hub, self.events = phone, hub, events
        self.clock, self.wall, self.sleep, self.timeout = clock, wall, sleep, timeout
        self.receipt = {"schema": "cmux-ios-screen-proof-v1", "passed": False,
                        "start": False, "live_frame": False, "host_input": False,
                        "viewer_stop": False, "host_stopped": False,
                        "physical_iphone_proven": False}

    def wait(self, check, description):
        end = self.clock() + self.timeout
        while self.clock() < end:
            answer = check()
            if answer:
                return answer
            self.sleep(0.5)
        raise ProofFailure(description)

    def run(self, host_name, viewer_name, nonce):
        before = self.hub({"action": "state"})
        if (not before.get("signed_in") or not before.get("this_device")
                or before.get("sharing") is not True or "host_session" not in before
                or before["host_session"] or before.get("pending_requests")):
            raise ProofFailure("Host must be signed in, shared and idle before the UI start")
        self.phone.open_host(host_name)

        def pending():
            rows = [r for r in self.hub({"action": "state"}).get("pending_requests", [])
                    if r.get("viewer_name") == viewer_name and r.get("scope") == "full"]
            if len(rows) > 1:
                raise ProofFailure("Ambiguous phone request")
            return rows[0] if rows else None

        request = self.wait(pending, "The mounted phone start did not reach the host")
        session, viewer = request.get("id"), request.get("viewer")
        if not session or not viewer or viewer == before["this_device"]:
            raise ProofFailure("Phone request has no distinct session identity")
        answer = self.hub({"action": "decide", "session": session, "choice": "once"})
        if answer.get("decided") != "once":
            raise ProofFailure("Host did not approve the phone request")
        self.receipt["start"] = True

        def connected():
            live = self.hub({"action": "state"}).get("host_session") or {}
            return (live.get("id") == session and live.get("viewer") == viewer
                    and live.get("scope") == "full" and live.get("connected") is True
                    and positive_fps(self.phone.stats()))

        self.wait(connected, "The exact phone session never streamed frames")
        # A screenshot is required as well as positive inbound video fps. The
        # adapter retains it privately; raw screen pixels never enter a public zip.
        self.wait(lambda: self.phone.live_frame("live"),
                  "The phone did not display the host input probe")
        self.receipt["live_frame"] = True
        started = self.wall()
        self.phone.type_challenge(nonce)
        self.wait(lambda: nonce.casefold() in input_text(self.events(), started).casefold(),
                  "Fresh phone input did not arrive at the host probe")
        self.receipt["host_input"] = True
        self.phone.screenshot("input")
        if not connected():
            raise ProofFailure("The bound session ended before mounted Stop")
        self.phone.close()
        self.wait(self.phone.back_on_page, "Phone stop did not return to Screen Sharing")
        self.receipt["viewer_stop"] = True

        def stopped():
            state = self.hub({"action": "state"})
            return (state.get("signed_in") is True and "host_session" in state
                    and state["host_session"] is None
                    and all(r.get("id") != session for r in state.get("pending_requests", [])))

        self.wait(stopped, "Phone stop left the host session active")
        self.receipt["host_stopped"] = True
        self.phone.screenshot("stopped")
        self.receipt["passed"] = True
        salt = secrets.token_hex(32)
        self.receipt["session_sha256"] = hashlib.sha256((salt + session).encode()).hexdigest()
        return self.receipt


def export_receipt(receipt, out):
    """Archive only the explicit public receipt, never a directory of runner logs."""
    allowed = {"schema", "passed", "start", "live_frame", "host_input", "viewer_stop",
               "host_stopped", "physical_iphone_proven", "session_sha256", "source_sha",
               "mac_job", "mac_artifact_sha256", "error_code", "cleanup", "simulator_cleanup"}
    if set(receipt) - allowed:
        raise ProofFailure("Unrecognized public receipt field")
    for field, pattern in {"schema": r"cmux-ios-screen-proof-v1", "source_sha": r"[a-f0-9]{40}",
                           "mac_job": r"[a-f0-9]{24}", "mac_artifact_sha256": r"[a-f0-9]{64}",
                           "session_sha256": r"[a-f0-9]{64}"}.items():
        if field in receipt and (not isinstance(receipt[field], str) or not re.fullmatch(pattern, receipt[field])):
            raise ProofFailure("Invalid public receipt value")
    if "error_code" in receipt and not safe_error(receipt["error_code"]):
        raise ProofFailure("Invalid public error code")
    for field in ("passed", "start", "live_frame", "host_input", "viewer_stop", "host_stopped",
                  "physical_iphone_proven", "cleanup", "simulator_cleanup"):
        if field in receipt and not isinstance(receipt[field], bool):
            raise ProofFailure("Invalid public phase value")
    public = dict(receipt)
    public["passed"] = public.get("passed") is True and all(
        public.get(k) is True for k in ("start", "live_frame", "host_input", "viewer_stop", "host_stopped", "cleanup", "simulator_cleanup"))
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    path = out / "screen-sharing-proof.json"
    path.write_text(json.dumps(public, indent=2) + "\n")
    with zipfile.ZipFile(out / "evidence.zip", "w", zipfile.ZIP_DEFLATED) as archive:
        archive.write(path, path.name)
    return public["passed"]


def phone_ui_module():
    spec = importlib.util.spec_from_file_location(
        "cloud_pair_ui", Path(__file__).with_name("cmux_next_cloud_pair_proof.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Phone:
    def __init__(self, simctl, udid, bundle, env, screenshots, ocr):
        module = phone_ui_module()
        self.ui = module.PhoneUI(simctl, udid, bundle, env)
        self.ocr = str(ocr)
        self.screenshots = Path(screenshots)
        self.screenshots.mkdir(parents=True, exist_ok=True)

    def control(self, identifier):
        return self.ui.control(lambda n: n.get("AXIdentifier") == identifier,
                               "Screen Sharing control")

    def open_host(self, name):
        self.ui.tap(self.control("settings.screenSharing"))
        self.ui.tap(self.control("screenSharing.mac." + name))

    def stats(self):
        rows = self.ui.find(lambda n: n.get("AXIdentifier") == "screen.stats")
        if len(rows) > 1:
            raise ProofFailure("Ambiguous phone stats")
        return str(rows[0].get("AXLabel", "")) if rows else ""

    def screenshot(self, name):
        path = self.screenshots / (name + ".png")
        # Remove only the previous image made by this adapter, so a failed
        # capture cannot accidentally reuse a stale frame.
        path.unlink(missing_ok=True)
        self.ui.run(self.ui.simctl + ["io", self.ui.udid, "screenshot", str(path)])
        if not path.is_file() or path.stat().st_size < 8 or path.read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
            raise ProofFailure("Phone screenshot missing or invalid")
        return path

    def live_frame(self, name):
        path = self.screenshot(name)
        text = self.ui.run([self.ocr, str(path)])
        lines = [line.partition("\t")[2].casefold() for line in text.splitlines()]
        return any("inputprobe" in line and "what this mac received" in line for line in lines)

    def type_challenge(self, nonce):
        self.ui.named("Keyboard", "viewer keyboard")
        # Tap the mounted software keys, preserving the phone input path.
        for char in nonce:
            self.ui.tap(self.ui.control(lambda n, c=char: n.get("type") == "Key"
                                        and str(n.get("AXLabel", "")).casefold() == c, "software key"))

    def close(self):
        self.ui.tap(self.control("screen.close"))

    def back_on_page(self):
        return bool(self.ui.find(lambda n: n.get("AXIdentifier") == "screenSharing.page"))


def host_module():
    spec = importlib.util.spec_from_file_location(
        "screen_host", Path(__file__).with_name("cmux_next_screen_sharing_host.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preflight", action="store_true")
    parser.add_argument("--finalize-cleanup", action="store_true")
    parser.add_argument("--status", type=int, default=1)
    parser.add_argument("--source-sha")
    parser.add_argument("--mac-job")
    parser.add_argument("--artifact-sha256")
    parser.add_argument("--sims")
    parser.add_argument("--udid")
    parser.add_argument("--viewer-name")
    parser.add_argument("--bundle-id")
    parser.add_argument("--out", type=Path)
    args = parser.parse_args(argv)
    host_api = host_module()
    if args.preflight:
        try:
            host_api.require_admission(os.environ)
            host_api.preflight()
            if os.environ.get("CMUX_SCREEN_PROOF_MAC_JOB"):
                host_api.job_receipt(os.environ["CMUX_SCREEN_PROOF_MAC_JOB"],
                                     os.environ.get("CMUX_SCREEN_PROOF_SOURCE", ""),
                                     os.environ.get("CMUX_SCREEN_PROOF_ARTIFACT", ""))
        except host_api.HostFailure as error:
            # All HostFailure descriptions are fixed safe codes.
            print(str(error))
            return 1
        print("secure_enclave_available")
        return 0
    if not args.out:
        parser.error("--out required")
    if args.finalize_cleanup:
        path = args.out / "screen-sharing-proof.json"
        receipt = json.loads(path.read_text()) if path.exists() else {}
        simulator_absent = False
        if args.sims:
            try:
                Path(args.sims).lstat()
            except FileNotFoundError:
                simulator_absent = True
            except OSError:
                pass  # An unreadable path cannot prove removal.
        receipt["simulator_cleanup"] = args.status == 0 and simulator_absent
        receipt["passed"] = receipt["simulator_cleanup"] and not receipt.get("error_code") and all(
            receipt.get(key) is True for key in
            ("start", "live_frame", "host_input", "viewer_stop", "host_stopped", "cleanup"))
        if not receipt["simulator_cleanup"]:
            receipt.update(cleanup=False, passed=False)
            receipt.setdefault("error_code", "host_cleanup_failed")
        return 0 if export_receipt(receipt, args.out) else 1
    for key in ("source_sha", "mac_job", "artifact_sha256", "sims", "udid", "viewer_name", "bundle_id"):
        if not getattr(args, key):
            parser.error("missing proof binding: " + key)
    receipt = {"schema": "cmux-ios-screen-proof-v1", "passed": False, "cleanup": False, "simulator_cleanup": False,
               "source_sha": args.source_sha, "mac_job": args.mac_job,
               "mac_artifact_sha256": args.artifact_sha256, "physical_iphone_proven": False}
    root = Path(__file__).resolve().parents[2]
    phone = host = attempt = work = None
    def interrupted(_signum, _frame):
        raise ProofFailure("Proof interrupted")
    previous = {sig: signal.signal(sig, interrupted) for sig in (signal.SIGTERM, signal.SIGINT)}
    try:
        host_api.require_admission(os.environ)
        host_api.preflight()
        email, password = (os.environ.get(key, "") for key in
                           ("CMUX_UITEST_STACK_EMAIL", "CMUX_UITEST_STACK_PASSWORD"))
        if not email or not password:
            raise ProofFailure("Protected test account unavailable")
        with private_workspace(lambda: host is None or host.cleanup_ok is True) as directory:
            work = Path(directory)
            app, info = host_api.fetch_app(args.mac_job, args.source_sha, args.artifact_sha256, work)
            ocr = work / "ocr"
            host_api.command(["xcrun", "swiftc", str(root / "cmux-next-ios/verify/e2e/ocr.swift"),
                              "-o", str(ocr)], timeout=120)
            phone_env = {k: v for k, v in os.environ.items() if not k.startswith("SIMCTL_CHILD_")}
            phone_env.update(SIMCTL_CHILD_CMUX_MOBILE_STACK_EMAIL=email,
                             SIMCTL_CHILD_CMUX_MOBILE_STACK_PASSWORD=password)
            phone = Phone(["xcrun", "simctl", "--set", args.sims], args.udid,
                          args.bundle_id, phone_env, work / "screens", ocr)
            host = host_api.Host(app, info, work, (email, password))
            with host:
                name = "Screen Proof " + secrets.token_hex(5)
                host.prepare(name, root / "cmux-next-ios/verify/screen-sharing/InputProbe.swift")
                host.viewer_name = args.viewer_name
                try:
                    phone.ui.launch(["-cmux-mobile-tab", "settings", "-cmux-mobile-no-restore"])
                    attempt = ScreenProof(phone, host.hub, host.events)
                    receipt.update(attempt.run(name, args.viewer_name,
                                               "".join(secrets.choice("abcdefghijklmnopqrstuvwxyz") for _ in range(12))))
                finally:
                    # Stop only this new simulator app before removing its hub
                    # device, so it cannot re-register while cleanup runs.
                    phone.ui.run(phone.ui.simctl + ["terminate", args.udid, args.bundle_id])
        # Keychain cleanup alone does not remove the private HOME, app logs or
        # simulator screenshots. Publish cleanup only after their owner exits
        # its temporary workspace and absence is read back.
        receipt["cleanup"] = host.cleanup_ok and not work.exists()
        if not receipt["cleanup"]:
            receipt.update(passed=False, error_code="host_cleanup_failed")
    except (Exception, KeyboardInterrupt) as error:
        if attempt:
            receipt.update(attempt.receipt)
        code = "proof_incomplete"
        if isinstance(error, host_api.HostFailure) and safe_error(str(error)):
            code = str(error)
        elif attempt:
            code = next((label for phase, label in (("start", "phone_start_unverified"),
                        ("live_frame", "phone_frame_unverified"), ("host_input", "phone_input_unverified"),
                        ("viewer_stop", "phone_stop_unverified"), ("host_stopped", "host_stop_unverified"))
                        if not receipt.get(phase)), "host_cleanup_failed")
        receipt.update(passed=False, error_code=code,
                       cleanup=bool(host and host.cleanup_ok and work and not work.exists()))
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)
    # The simulator still exists. Publish a pending receipt, never green, until
    # the shell's EXIT cleanup has shut down and deleted the owned device set.
    complete = receipt.get("passed") is True and receipt.get("cleanup") is True
    export_receipt(receipt, args.out)
    return 0 if complete else 1


if __name__ == "__main__":
    raise SystemExit(main())
