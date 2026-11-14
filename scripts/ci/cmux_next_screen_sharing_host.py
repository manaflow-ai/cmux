"""Run-owned Mac fixture for the protected iOS screen proof.

Uses the completed fleet bundle unchanged. No re-signing, keychain-list changes,
software identity replacement, permission grants, or borrowed processes.
"""
import contextlib
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import socket
import subprocess
import time


class HostFailure(RuntimeError):
    pass


def require_admission(env):
    # Defense in depth: the protected HQ job and its runner hook provide this
    # identity. These fields do not acquire a lease or authorize an SSH caller.
    expected = {"GITHUB_ACTIONS": "true", "GITHUB_REPOSITORY": "manaflow-ai/cmuxterm-hq",
                "GITHUB_WORKFLOW_REF": "manaflow-ai/cmuxterm-hq/.github/workflows/ios-screen-sharing-proof.yml@refs/heads/main",
                "GLAEDA_JOB_CLAIM": "exclusive"}
    if (any(env.get(key) != value for key, value in expected.items())
            or not re.fullmatch(r"[0-9a-f]{64}", env.get("GLAEDA_HOOK_SHA256", ""))
            or not re.fullmatch(r"[0-9a-f]{24}", env.get("GLAEDA_CAPTURE_LEASE_ID", ""))):
        raise HostFailure("host_admission_unverified")


def command(argv, *, timeout=60, env=None):
    try:
        result = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        raise HostFailure("host_command_unavailable") from None
    if result.returncode:
        raise HostFailure("host_command_failed")
    return result.stdout.strip()


def preflight():
    # This runs on the managed Mac, before either app is built or authenticated.
    answer = command(["xcrun", "swift", "-e",
                      'import CryptoKit; print(SecureEnclave.isAvailable ? "available" : "unavailable")'])
    if answer != "available":
        raise HostFailure("device_identity_secure_enclave_unavailable")
    command(["axe", "--version"])


def validate_job(job, source, digest):
    if (not re.fullmatch(r"[0-9a-f]{40}", source)
            or not re.fullmatch(r"[0-9a-f]{64}", digest)
            or job.get("kind") != "cmux" or job.get("state") != "done"
            or job.get("source_digest") != source or job.get("source_tree_verified") is not True
            or job.get("artifact") != "sha256:" + digest
            or not re.fullmatch(r"cap[a-z0-9]+", job.get("tag", ""))):
        raise HostFailure("mac_artifact_not_completed_at_requested_source")


def job_receipt(job_id, source, digest):
    if not re.fullmatch(r"[0-9a-f]{24}", job_id):
        raise HostFailure("invalid_mac_job")
    client = os.environ.get("CMUX_CI_CLIENT", "cmux-ci")
    try:
        job = json.loads(command([client, "status", job_id]))
    except ValueError:
        raise HostFailure("invalid_mac_job_receipt") from None
    if not isinstance(job, dict):
        raise HostFailure("invalid_mac_job_receipt")
    validate_job(job, source, digest)
    return job


def fetch_app(job_id, source, digest, work):
    job = job_receipt(job_id, source, digest)
    client = os.environ.get("CMUX_CI_CLIENT", "cmux-ci")
    # The fleet client verifies every blob and the assembled code signature.
    destination = Path(work) / "mac-bundle"
    path = Path(command([client, "artifact", "--bundle", "--zip-sha256", digest,
                         job_id, str(destination)], timeout=900)).resolve()
    if not path.is_relative_to(destination.resolve()) or path.suffix != ".app":
        raise HostFailure("mac_bundle_path_mismatch")
    info = plistlib.loads((path / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "com.cmuxterm.app.debug." + job["tag"]:
        raise HostFailure("mac_bundle_tag_mismatch")
    return path, info


def identity_service(app, bundle, env):
    # Use the app's own resolver and launch environment, not a second Cloud
    # environment table. DeviceHub uses auth_namespace (not auth_storage_namespace).
    try:
        selection = json.loads(command([str(app / "Contents/Resources/bin/cmux"),
                                        "--json", "cloud", "env", "get", "--backend", "staging"],
                                       env={**env, "CMUX_BUNDLE_ID": bundle}, timeout=30))
    except ValueError:
        raise HostFailure("host_cloud_namespace_unavailable") from None
    if (not isinstance(selection, dict) or selection.get("bundle_id") != bundle
            or type(selection.get("legacy_storage")) is not bool
            or not isinstance(selection.get("auth_namespace"), str)
            or not re.fullmatch(r"[A-Za-z0-9._-]{1,200}", selection["auth_namespace"])):
        raise HostFailure("host_cloud_namespace_unavailable")
    if (selection.get("name") != "staging"
            or selection.get("stack_project_id") != "454ecd03-1db2-4050-845e-4ce5b0cd9895"):
        raise HostFailure("host_staging_backend_unverified")
    suffix = "" if selection["legacy_storage"] else ".cloud." + selection["auth_namespace"]
    return bundle + suffix + ".device-hub"


def rpc(path, method, params=None, *, timeout=10):
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(timeout)
            client.connect(str(path))
            client.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            data = b""
            while not data.endswith(b"\n"):
                chunk = client.recv(65536)
                if not chunk or len(data) + len(chunk) > 2 ** 20:
                    raise HostFailure("host_rpc_incomplete")
                data += chunk
        answer = json.loads(data)
        if answer.get("ok") is not True or not isinstance(answer.get("result"), dict):
            raise HostFailure("host_rpc_refused")
        if "error" in answer["result"]:
            raise HostFailure("host_rpc_action_failed")
        return answer["result"]
    except (OSError, ValueError):
        raise HostFailure("host_rpc_unavailable") from None


def stop(proc):
    if proc is None:
        return
    # Every caller creates a new session. The recorded PID is our group, and
    # the parent exiting alone cannot prove its children have stopped.
    with contextlib.suppress(ProcessLookupError):
        os.killpg(proc.pid, signal.SIGTERM)
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        pass
    with contextlib.suppress(ProcessLookupError):
        os.killpg(proc.pid, signal.SIGKILL)
    proc.wait(timeout=10)
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        state = subprocess.run(["ps", "-axo", "pgid=,stat="],
                               capture_output=True, text=True, timeout=5)
        if state.returncode:
            raise subprocess.SubprocessError("owned_group_state_unavailable")
        if not any(len(fields := line.split()) == 2 and fields[0] == str(proc.pid)
                   and not fields[1].startswith("Z") for line in state.stdout.splitlines()):
            return
        time.sleep(min(0.1, max(0, deadline - time.monotonic())))
    raise subprocess.SubprocessError("owned_group_still_running")


class Host:
    def __init__(self, app, info, work, credentials):
        self.app, self.info, self.work = app, info, Path(work)
        self.credentials = credentials
        self.proc = self.probe = self.log = None
        self.viewer_name = None
        self.device = None
        self.owns_auth = False
        self.auth_prepared = self.device_prepared = False
        self.account_mismatch = False
        self.namespace = None
        self.lease = os.environ.get("GLAEDA_CAPTURE_LEASE_ID", "")
        self.cleanup_ok = False
        self.sock = self.work / "host.sock"
        self.events_path = self.work / "input.jsonl"

    def hub(self, params):
        return rpc(self.sock, "debug.device_hub", params)

    def _capture(self, phase, *, auth):
        params = {"lease_id": self.lease,
                  "bundle_id": self.info["CFBundleIdentifier"] if auth else self.namespace}
        if auth:
            result = rpc(self.sock, "debug.cloud.capture_" + phase, params, timeout=30)
            verified = all(result.get(key) is True for key in
                           ("ok", "keychain_absent", "files_absent", "verified_absent"))
        else:
            result = rpc(self.sock, "debug.device_hub", {"action": "capture_" + phase, **params}, timeout=30)
            verified = (result.get("ok") is True and result.get("verified_absent") is True
                        and result.get("hub_quiescent") is True
                        and all(type(result.get(key)) is int and result[key] >= 0
                                for key in ("identity_removed", "relays_removed")))
        if not verified or result.get("code") != "ok":
            raise HostFailure("host_namespace_" + phase + "_failed")

    def _launch(self, env, home):
        self.proc = subprocess.Popen([str(self.app / "Contents/MacOS" / self.info["CFBundleExecutable"]),
                                      "--cloud-backend", "staging"],
                                     cwd=home, env=env, stdout=self.log, stderr=subprocess.STDOUT,
                                     start_new_session=True)

    def _account(self):
        end = time.monotonic() + 180
        while time.monotonic() < end:
            if self.proc.poll() is not None:
                raise HostFailure("host_exited_before_account_ready")
            try:
                account = rpc(self.sock, "auth.status")
            except HostFailure:
                time.sleep(1)
                continue
            if (account.get("restoring") is False and account.get("cloud_environment")
                    and account.get("cloud_unavailable") is None):
                return account
            time.sleep(1)
        raise HostFailure("host_account_not_ready")

    def __enter__(self):
        if len(str(self.sock).encode()) > 100:
            raise HostFailure("host_socket_path_too_long")
        bundle = self.info["CFBundleIdentifier"]
        processes = command(["ps", "-axo", "command="])
        if "/" + self.app.name + "/Contents/MacOS/" in processes:
            raise HostFailure("host_tag_already_running")
        home = self.work / "home"
        home.mkdir(mode=0o700)
        config = self.work / "cmux-next.json"
        config.write_text("{}\n")
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(("CMUX", "ACPMUX", "MUX_", "GITHUB_", "ACTIONS_", "SIMCTL_CHILD_"))}
        env.update(self.info.get("LSEnvironment") or {})
        for key in ("CMUX_SOCKET_PATH", "CMUX_TAG", "CMUX_BUNDLE_ID"):
            env.pop(key, None)
        env.update(HOME=str(home), CFFIXED_USER_HOME=str(home), XDG_CONFIG_HOME=str(home / ".config"),
                   CMUX_NEXT_CONFIG_FILE=str(config), CMUX_NEXT_SOCKET_PATH=str(self.sock),
                   CMUX_NEXT_NO_ACTIVATE="1", CMUX_NEXT_SOCKET_MODE="automation",
                   CMUX_NEXT_CLOUD_BACKEND="staging")
        # Resolve only after isolating the environment. Read attributes only,
        # never a key's value; 44 is errSecItemNotFound. Remote's separate key
        # scope is tied to the daemon state root beneath this private home.
        service = identity_service(self.app, bundle, env)
        self.namespace = service.removesuffix(".device-hub")
        # Any existing item makes this service pre-owned, even when a previous
        # launch wrote a signing blob but never committed its device-id.
        found = subprocess.run(["security", "find-generic-password", "-s", service],
                               capture_output=True, timeout=20)
        if found.returncode != 44:
            raise HostFailure("host_namespace_not_fresh")
        email, password = self.credentials
        self.log = (self.work / "host-private.log").open("w")
        try:
            # Inspect this fresh tag without launch credentials before claiming
            # its auth store. Never replace or clear a restored account.
            self._launch(env, home)
            account = self._account()
            if account.get("signed_in") is not False or account.get("user_id"):
                raise HostFailure("host_namespace_has_existing_account")
            self._capture("prepare", auth=True)
            self.auth_prepared = True
            self._capture("prepare", auth=False)
            self.device_prepared = True
            stop(self.proc)
            self.proc = None
            self.sock.unlink(missing_ok=True)  # this process's socket only
            env.update(CMUX_DEV_AUTH_PROFILE="agent", CMUX_DEV_AUTH_ACCOUNT=email,
                       CMUX_UITEST_STACK_EMAIL=email, CMUX_UITEST_STACK_PASSWORD=password)
            self.owns_auth = True
            self._launch(env, home)
            end = time.monotonic() + 180
            while time.monotonic() < end:
                if self.proc.poll() is not None:
                    raise HostFailure("host_exited_before_hub_ready")
                try:
                    account = rpc(self.sock, "auth.status")
                    state = self.hub({"action": "state"})
                except HostFailure:
                    time.sleep(1)
                    continue
                if account.get("signed_in") is True:
                    if str(account.get("email", "")).casefold() != email.casefold():
                        # Do not clear a different account, even on a fresh tag.
                        self.owns_auth = False
                        self.account_mismatch = True
                        raise HostFailure("host_account_mismatch")
                    if state.get("signed_in") is True and state.get("this_device"):
                        self.device = state["this_device"]
                        return self
                code = state.get("last_error")
                if isinstance(code, str) and (code in {"device_identity_secure_enclave_unavailable", "device_identity_corrupt_key_blob", "device_identity_unavailable", "device_hub_configuration_timeout"}
                                              or re.fullmatch(r"device_identity_keychain_-?[0-9]{1,10}", code)):
                    raise HostFailure(code)
                time.sleep(1)
            raise HostFailure("host_hub_not_ready")
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def prepare(self, name, probe_source):
        grants = rpc(self.sock, "debug.mac_screen", {"action": "state"}).get("share", {})
        if grants.get("screen_recording") is not True or grants.get("accessibility") is not True:
            raise HostFailure("host_screen_and_input_grants_missing")
        self.hub({"action": "rename", "device": self.device, "name": name})
        self.hub({"action": "set_shared", "shared": True})
        binary = self.work / "input-probe"
        command(["xcrun", "swiftc", "-O", str(probe_source), "-o", str(binary)], timeout=120)
        self.probe = subprocess.Popen([str(binary), str(self.events_path)], stdout=self.log,
                                      stderr=subprocess.STDOUT, start_new_session=True)

    def events(self):
        try:
            # A partial last write is ignored until the next bounded observation.
            data = self.events_path.read_bytes()
            if len(data) > 1024 * 1024:
                raise HostFailure("host_input_log_bound")
            return [json.loads(line) for line in data.splitlines() if line.endswith(b"}")]
        except FileNotFoundError:
            return []

    def __exit__(self, *_):
        failures = []
        try:
            stop(self.probe)
        except (OSError, subprocess.SubprocessError):
            failures.append("probe")
        if self.device and self.viewer_name:
            try:
                rows = [row for row in self.hub({"action": "state"}).get("devices", [])
                        if row.get("name") == self.viewer_name and row.get("id") != self.device
                        and row.get("platform") == "ios"]
                if len(rows) != 1:
                    raise HostFailure("phone_cleanup_identity_ambiguous")
                self.hub({"action": "remove", "device": rows[0]["id"]})
            except HostFailure:
                failures.append("phone")
        if self.device:
            for params in ({"action": "stop_sharing"}, {"action": "set_shared", "shared": False},
                           {"action": "remove", "device": self.device}):
                try:
                    self.hub(params)
                except HostFailure:
                    failures.append("device")
        if self.owns_auth:
            try:
                if not self.auth_prepared or not self.device_prepared:
                    raise HostFailure("host_namespace_cleanup_failed")
                if rpc(self.sock, "debug.cloud.end_session").get("ended") is not True:
                    raise HostFailure("host_signout_not_acknowledged")
                account = rpc(self.sock, "auth.status")
                if account.get("signed_in") is not False or account.get("restoring") is not False:
                    raise HostFailure("host_signout_not_complete")
            except HostFailure:
                failures.append("auth")
        if self.account_mismatch:
            failures.append("account_mismatch")
        elif "auth" not in failures:
            # Auth absence must be verified before removing the device lease
            # marker, keeping a failed cleanup attributable and retryable.
            try:
                if self.auth_prepared:
                    self._capture("cleanup", auth=True)
                if self.device_prepared:
                    self._capture("cleanup", auth=False)
            except HostFailure:
                failures.append("namespace")
        try:
            stop(self.proc)
        except (OSError, subprocess.SubprocessError):
            failures.append("app")
        if self.log:
            self.log.close()
        self.cleanup_ok = not failures
