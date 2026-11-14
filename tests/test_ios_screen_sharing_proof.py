"""Fail-closed proof transitions; these tests do not claim a live simulator run."""
import importlib.util
import json
from pathlib import Path
import tempfile
import subprocess
import unittest
from unittest.mock import MagicMock, Mock, patch
import zipfile

SPEC = importlib.util.spec_from_file_location(
    "screen_proof", Path(__file__).resolve().parents[1] / "scripts/ci/cmux_next_screen_sharing_proof.py")
proof = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(proof)


class Rig:
    def __init__(self):
        self.now, self.phase, self.calls, self.shots = 0, "idle", [], []
        self.fps, self.wrong_viewer, self.sticky, self.stale = "Direct · 30 fps · 20 KB/s", False, False, False
        self.keys = []
        self.visible_probe = True

    def clock(self): return self.now
    def sleep(self, seconds): self.now += seconds
    def open_host(self, name):
        self.calls.append("mounted-start")
        self.phase = "pending"
    def stats(self): return self.fps
    def screenshot(self, name): self.shots.append(name)
    def live_frame(self, name):
        self.screenshot(name)
        return self.visible_probe
    def type_challenge(self, nonce):
        self.calls.append("phone-keys")
        self.keys.append({"kind": "key", "t": -1 if self.stale else self.now, "chars": nonce})
    def close(self):
        self.calls.append("mounted-stop")
        if not self.sticky: self.phase = "stopped"
    def back_on_page(self): return True
    def hub(self, params):
        if params["action"] == "decide":
            self.calls.append("approval")
            self.phase = "live"
            return {"decided": "once"}
        pending = [{"id": "session", "viewer": "phone", "viewer_name": "wrong" if self.wrong_viewer else "Phone",
                    "scope": "full"}] if self.phase == "pending" else []
        live = {"id": "session", "viewer": "phone", "scope": "full", "connected": True} if self.phase == "live" else None
        return {"signed_in": True, "this_device": "host", "sharing": True,
                "host_session": live, "pending_requests": pending}
    def instance(self):
        return proof.ScreenProof(self, self.hub, lambda: self.keys, clock=self.clock,
                                 wall=self.clock, sleep=self.sleep, timeout=1)


class ProofTests(unittest.TestCase):
    def test_workspace_uses_durable_owned_lease_parent(self):
        lease = "a" * 24
        parent = Path("/protected-captures") / lease
        env = {"GLAEDA_CAPTURE_LEASE_ID": lease, "GLAEDA_CAPTURE_CLEANUP_PATH": str(parent / "cleanup.json")}
        info = Mock(st_mode=0o40700, st_uid=proof.os.getuid())
        with patch.object(proof.Path, "lstat", return_value=info):
            self.assertEqual(proof.workspace_parent(env), parent)
            for override in ({"GLAEDA_CAPTURE_LEASE_ID": "b" * 24},
                             {"GLAEDA_CAPTURE_CLEANUP_PATH": str(parent / "other.json")},
                             {"GLAEDA_CAPTURE_CLEANUP_PATH": str(Path("/tmp") / lease / "cleanup.json")},
                             {"RUNNER_TEMP": "/protected-captures"},
                             {"GITHUB_WORKSPACE": "/protected-captures"},
                             {"GLAEDA_CAPTURE_CLEANUP_PATH": "relative/cleanup.json"}):
                with self.subTest(override=override), self.assertRaises(proof.ProofFailure):
                    proof.workspace_parent({**env, **override})
        for mode, uid in ((0o40722, proof.os.getuid()), (0o120700, proof.os.getuid()),
                          (0o40700, proof.os.getuid() + 1)):
            with self.subTest(mode=mode, uid=uid), \
                    patch.object(proof.Path, "lstat", return_value=Mock(st_mode=mode, st_uid=uid)), \
                    self.assertRaises(proof.ProofFailure):
                proof.workspace_parent(env)

    def test_full_sequence_requires_host_input_and_stop(self):
        rig = Rig()
        receipt = rig.instance().run("Mac", "Phone", "abcxyz")
        self.assertTrue(receipt["passed"])
        self.assertEqual(rig.calls, ["mounted-start", "approval", "phone-keys", "mounted-stop"])
        self.assertEqual(rig.shots, ["live", "input", "stopped"])
        self.assertNotIn("session", receipt.values())

    def test_wrong_viewer_never_approved(self):
        rig = Rig(); rig.wrong_viewer = True
        with self.assertRaises(proof.ProofFailure): rig.instance().run("Mac", "Phone", "abc")
        self.assertEqual(rig.calls, ["mounted-start"])

    def test_zero_fps_never_claims_live_frame(self):
        rig = Rig(); rig.fps = "Direct · 0 fps · 0 KB/s"
        attempt = rig.instance()
        with self.assertRaises(proof.ProofFailure): attempt.run("Mac", "Phone", "abc")
        self.assertFalse(attempt.receipt["live_frame"])
        self.assertNotIn("phone-keys", rig.calls)

    def test_positive_fps_with_blank_renderer_is_not_live(self):
        rig = Rig(); rig.visible_probe = False
        attempt = rig.instance()
        with self.assertRaises(proof.ProofFailure): attempt.run("Mac", "Phone", "abc")
        self.assertFalse(attempt.receipt["live_frame"])
        self.assertNotIn("phone-keys", rig.calls)

    def test_stale_input_never_counts_as_reception(self):
        rig = Rig(); rig.stale = True
        attempt = rig.instance()
        with self.assertRaises(proof.ProofFailure): attempt.run("Mac", "Phone", "abc")
        self.assertFalse(attempt.receipt["host_input"])

    def test_ui_dismissal_does_not_prove_host_stop(self):
        rig = Rig(); rig.sticky = True
        attempt = rig.instance()
        with self.assertRaises(proof.ProofFailure): attempt.run("Mac", "Phone", "abc")
        self.assertTrue(attempt.receipt["viewer_stop"])
        self.assertFalse(attempt.receipt["host_stopped"])
        self.assertFalse(attempt.receipt["passed"])

    def test_session_ended_before_close_is_not_proven_stopped_by_phone(self):
        rig = Rig()
        original = rig.screenshot
        def screenshot(name):
            original(name)
            if name == "input": rig.phase = "stopped"
        rig.screenshot = screenshot
        attempt = rig.instance()
        with self.assertRaises(proof.ProofFailure): attempt.run("Mac", "Phone", "abc")
        self.assertFalse(attempt.receipt["viewer_stop"])
        self.assertNotIn("mounted-stop", rig.calls)

    def test_public_success_waits_for_simulator_cleanup_and_fails_on_teardown_error(self):
        for status in (0, 1):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as directory:
                receipt = Rig().instance().run("Mac", "Phone", "abc")
                receipt["cleanup"] = True
                self.assertFalse(proof.export_receipt(receipt, directory))
                result = proof.main(["--finalize-cleanup", "--status", str(status), "--out", directory,
                                     "--sims", str(Path(directory) / "removed-simulators")])
                public = json.loads((Path(directory) / "screen-sharing-proof.json").read_text())
                self.assertEqual(result, status)
                self.assertEqual(public["passed"], status == 0)
                self.assertEqual(public["simulator_cleanup"], status == 0)
                self.assertEqual(public["cleanup"], status == 0)

    def test_simulator_cleanup_requires_absent_owned_device_set(self):
        for bound in (False, True):
            with self.subTest(bound=bound), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                sims = root / "simulators"
                sims.mkdir()
                (sims / "private-data").write_text("owned simulator residue")
                receipt = Rig().instance().run("Mac", "Phone", "abc")
                receipt["cleanup"] = True
                proof.export_receipt(receipt, root)
                args = ["--finalize-cleanup", "--status", "0", "--out", directory]
                if bound:
                    args += ["--sims", str(sims)]
                self.assertEqual(proof.main(args), 1)
                public = json.loads((root / "screen-sharing-proof.json").read_text())
                self.assertFalse(public["simulator_cleanup"])
                self.assertFalse(public["passed"])

    def test_export_excludes_raw_files_and_rejects_unknown_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "private.log").write_text("account secret")
            receipt = Rig().instance().run("Mac", "Phone", "abc")
            receipt["cleanup"] = True
            receipt["simulator_cleanup"] = True
            self.assertTrue(proof.export_receipt(receipt, root))
            with zipfile.ZipFile(root / "evidence.zip") as archive:
                self.assertEqual(archive.namelist(), ["screen-sharing-proof.json"])
                self.assertTrue(json.loads(archive.read(archive.namelist()[0]))["passed"])
            with self.assertRaises(proof.ProofFailure):
                proof.export_receipt({**receipt, "account": "private"}, root)

    def test_incomplete_receipt_cannot_export_success(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertFalse(proof.export_receipt({"passed": True, "start": True}, directory))

    def test_private_home_removal_is_required_before_cleanup_receipt(self):
        for failure in (None, "raises", "survives", "host_cleanup"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                work = Path(directory) / "private"
                work.mkdir()
                marker = work / "capture-lease"
                marker.write_text("owned lease")
                def remove_workspace(*_args, **_kwargs):
                    if failure == "raises": raise OSError("private cleanup failed")
                    if failure != "survives":
                        marker.unlink()
                        work.rmdir()
                host = MagicMock(cleanup_ok=failure != "host_cleanup")
                host.__enter__.return_value = host
                api = Mock(HostFailure=RuntimeError)
                api.Host.return_value = host
                api.fetch_app.return_value = (Path("/owned.app"), {})
                attempt = Mock(receipt={})
                attempt.run.return_value = Rig().instance().run("Mac", "Phone", "abc")
                out = Path(directory) / "receipt"
                with patch.object(proof, "host_module", return_value=api), \
                        patch.object(proof, "Phone"), patch.object(proof, "ScreenProof", return_value=attempt), \
                        patch.object(proof, "workspace_parent", return_value=work.parent), \
                        patch.object(proof.tempfile, "mkdtemp", return_value=str(work)), \
                        patch("shutil.rmtree", side_effect=remove_workspace) as remove, \
                        patch.dict(proof.os.environ, CMUX_UITEST_STACK_EMAIL="test", CMUX_UITEST_STACK_PASSWORD="test"):
                    result = proof.main(["--source-sha", "a" * 40, "--mac-job", "b" * 24,
                                         "--artifact-sha256", "c" * 64, "--sims", "/owned-sims",
                                         "--udid", "owned", "--viewer-name", "Phone", "--bundle-id", "owned",
                                         "--out", str(out)])
                public = json.loads((out / "screen-sharing-proof.json").read_text())
                self.assertEqual(public["cleanup"], failure is None)
                self.assertEqual(result, 0 if failure is None else 1)
                if failure == "host_cleanup":
                    remove.assert_not_called()
                    self.assertEqual(marker.read_text(), "owned lease")


class HostTests(unittest.TestCase):
    def setUp(self):
        self.host = proof.host_module()
        temporary = tempfile.TemporaryDirectory(prefix="ss-fixture-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.app = self.root / "owned.app"

    def test_parent_exit_does_not_leave_owned_group_children(self):
        proc = Mock(pid=123)
        proc.poll.return_value = 0
        with patch.object(self.host.os, "killpg") as kill, \
                patch.object(self.host.subprocess, "run", return_value=Mock(returncode=0, stdout="123 Z\n456 S\n")):
            self.host.stop(proc)
        self.assertEqual([call.args[0] for call in kill.call_args_list], [123, 123])
        self.assertEqual(proc.wait.call_count, 2)

    def test_unreadable_group_state_cannot_confirm_cleanup(self):
        proc = Mock(pid=123)
        proc.poll.return_value = 0
        with patch.object(self.host.os, "killpg"), \
                patch.object(self.host.subprocess, "run", return_value=Mock(returncode=1, stdout="")):
            with self.assertRaises(subprocess.SubprocessError):
                self.host.stop(proc)

    def test_permission_denied_signals_require_group_absence(self):
        for state in ("123 Z\n456 S\n", "123 S\n"):
            with self.subTest(state=state):
                proc = Mock(pid=123)
                with patch.object(self.host.os, "killpg", side_effect=PermissionError), \
                        patch.object(self.host.subprocess, "run", return_value=Mock(returncode=0, stdout=state)), \
                        patch.object(self.host.time, "monotonic", side_effect=[0, 0, 11, 11, 11]), \
                        patch.object(self.host.time, "sleep"):
                    if "123 S" in state:
                        with self.assertRaisesRegex(subprocess.SubprocessError, "owned_group_still_running"):
                            self.host.stop(proc)
                    else:
                        self.host.stop(proc)

    def test_protected_whole_host_admission_rejects_gui_only_or_other_workflow(self):
        admitted = dict(GITHUB_ACTIONS="true", GITHUB_REPOSITORY="manaflow-ai/cmuxterm-hq",
                        GITHUB_WORKFLOW_REF="manaflow-ai/cmuxterm-hq/.github/workflows/ios-screen-sharing-proof.yml@refs/heads/main",
                        GLAEDA_JOB_CLAIM="exclusive", GLAEDA_HOOK_SHA256="a" * 64,
                        GLAEDA_CAPTURE_LEASE_ID="b" * 24)
        self.host.require_admission(admitted)
        for key in admitted:
            with self.subTest(key=key), self.assertRaisesRegex(self.host.HostFailure, "host_admission_unverified"):
                self.host.require_admission({**admitted, key: ""})

    def test_staging_account_never_reaches_a_production_or_local_backend(self):
        bundle = "com.cmuxterm.app.debug.capabc"
        selection = dict(bundle_id=bundle, legacy_storage=False, auth_namespace="staging",
                         name="staging", stack_project_id="454ecd03-1db2-4050-845e-4ce5b0cd9895")
        for changed in ({"name": "prod"}, {"name": "local"}, {"stack_project_id": "other"}):
            with self.subTest(changed=changed), patch.object(self.host, "command", return_value=json.dumps({**selection, **changed})):
                with self.assertRaisesRegex(self.host.HostFailure, "host_staging_backend_unverified"):
                    self.host.identity_service(self.app, bundle, {})

    def test_freshness_checks_resolved_app_identity_namespace(self):
        bundle = "com.cmuxterm.app.debug.capabc"
        for legacy in (False, True):
            selection = dict(bundle_id=bundle, legacy_storage=legacy, auth_namespace="development", name="staging",
                             stack_project_id="454ecd03-1db2-4050-845e-4ce5b0cd9895", auth_storage_namespace="deliberately-different")
            with self.subTest(legacy=legacy), patch.object(self.host, "command", return_value=json.dumps(selection)) as command:
                service = self.host.identity_service(self.app, bundle, {"HOME": str(self.root / "owned")})
                self.assertEqual(service, bundle + ("" if legacy else ".cloud.development") + ".device-hub")
                self.assertEqual(command.call_args.kwargs["env"]["CMUX_BUNDLE_ID"], bundle)
                self.assertEqual(command.call_args.kwargs["env"]["HOME"], str(self.root / "owned"))
                self.assertEqual(command.call_args.args[0][-6:], ["--json", "cloud", "env", "get", "--backend", "staging"])

    def test_unknown_or_mismatched_namespace_fails_closed(self):
        valid = dict(bundle_id="cap", legacy_storage=False, auth_namespace="development")
        invalid = [[], {**valid, "bundle_id": "other"}, {**valid, "legacy_storage": "false"},
                   {**valid, "auth_namespace": ""}, {**valid, "auth_namespace": "bad/name"}]
        for selection in invalid:
            with self.subTest(selection=selection), patch.object(self.host, "command", return_value=json.dumps(selection)):
                with self.assertRaisesRegex(self.host.HostFailure, "host_cloud_namespace_unavailable"):
                    self.host.identity_service(self.app, "cap", {})

    def test_existing_cloud_device_identity_refuses_before_launch(self):
        bundle = "com.cmuxterm.app.debug.capabc"
        selected = dict(bundle_id=bundle, legacy_storage=False, auth_namespace="development",
                        name="staging", stack_project_id="454ecd03-1db2-4050-845e-4ce5b0cd9895")
        def run(argv, **_):
            # The raw bundle has no identity; the namespace used by the app does.
            return Mock(returncode=0 if bundle + ".cloud.development.device-hub" in argv else 44)
        def command(argv, **_):
            return json.dumps(selected) if "cloud" in argv else ""
        with tempfile.TemporaryDirectory(prefix="ss-") as work:
            host = self.host.Host(self.app,
                                  {"CFBundleIdentifier": bundle, "CFBundleExecutable": "cmux"},
                                  work, ("account", "password"))
            with patch.object(self.host, "command", side_effect=command), patch.object(self.host.subprocess, "run", side_effect=run), \
                    patch.object(self.host.subprocess, "Popen", side_effect=AssertionError("launched into an existing namespace")) as launch:
                with self.assertRaisesRegex(self.host.HostFailure, "host_namespace_not_fresh"):
                    host.__enter__()
                launch.assert_not_called()

    def test_partial_device_namespace_refuses_before_launch(self):
        bundle = "com.cmuxterm.app.debug.capabc"
        selected = dict(bundle_id=bundle, legacy_storage=False, auth_namespace="development",
                        name="staging", stack_project_id="454ecd03-1db2-4050-845e-4ce5b0cd9895")
        def run(argv, **_):
            # The ID was never committed, but the signing-key item survived.
            return Mock(returncode=44 if "device-id" in argv else 0)
        with tempfile.TemporaryDirectory(prefix="ss-") as work:
            host = self.host.Host(self.app,
                                  {"CFBundleIdentifier": bundle, "CFBundleExecutable": "cmux"},
                                  work, ("account", "password"))
            with patch.object(self.host, "command", return_value=json.dumps(selected)), \
                    patch.object(self.host.subprocess, "run", side_effect=run), \
                    patch.object(self.host.subprocess, "Popen", side_effect=AssertionError("launched into partial namespace")):
                with self.assertRaisesRegex(self.host.HostFailure, "host_namespace_not_fresh"):
                    host.__enter__()

    def test_artifact_requires_completed_verified_exact_source(self):
        source, digest = "a" * 40, "b" * 64
        job = dict(kind="cmux", state="done", source_digest=source,
                   source_tree_verified=True, artifact="sha256:" + digest, tag="capabc123")
        self.host.validate_job(job, source, digest)
        for field, value in (("state", "running"), ("source_digest", "c" * 40),
                             ("source_tree_verified", False), ("artifact", "sha256:" + "d" * 64),
                             ("tag", "next")):
            with self.subTest(field=field), self.assertRaises(self.host.HostFailure):
                self.host.validate_job({**job, field: value}, source, digest)

    def test_secure_enclave_failure_prevents_further_host_setup(self):
        with patch.object(self.host, "command", return_value="unavailable") as command:
            with self.assertRaisesRegex(self.host.HostFailure, "secure_enclave_unavailable"):
                self.host.preflight()
        self.assertEqual(command.call_count, 1)

    def make_host(self):
        instance = self.host.Host(self.app, {"CFBundleIdentifier": "owned"},
                                  str(self.root / "owned"), ("account", "password"))
        instance.proc, instance.probe, instance.log = Mock(), Mock(), Mock()
        instance.owns_auth = True
        instance.auth_prepared = instance.device_prepared = True
        instance.remote_attempted = instance.remote_prepared = True
        instance.lease = "a" * 24
        instance.namespace = "owned.cloud.development"
        return instance

    def test_long_durable_home_uses_short_owned_socket_and_removes_it_after_exit(self):
        with tempfile.TemporaryDirectory(prefix="ss-", dir="/tmp") as directory:
            short_root = Path(directory) / "socket"
            short_root.mkdir()
            instance = self.host.Host(Path("/owned.app"),
                                      {"CFBundleIdentifier": "owned", "CFBundleExecutable": "cmux"},
                                      Path("/protected") / ("x" * 140), ("account", "password"))
            env = {"HOME": str(instance.work / "home")}
            with patch.object(self.host.tempfile, "mkdtemp", return_value=str(short_root)), \
                    patch.object(self.host.subprocess, "Popen") as launch:
                instance._launch(env, instance.work / "home")
            self.assertEqual(env["HOME"], str(instance.work / "home"))
            self.assertEqual(env["CMUX_NEXT_SOCKET_PATH"], str(short_root / "host.sock"))
            self.assertTrue(launch.call_args.kwargs["start_new_session"])
            with patch.object(self.host, "stop"):
                instance.__exit__()
            self.assertTrue(instance.cleanup_ok)
            self.assertFalse(short_root.exists())

    def test_unverified_app_exit_preserves_owned_socket_directory(self):
        instance = self.make_host()
        instance.owns_auth = instance.auth_prepared = instance.device_prepared = False
        instance.remote_attempted = instance.remote_prepared = False
        instance.socket_root = Path("/owned-socket")
        with patch.object(self.host, "stop", side_effect=OSError("group remains")), \
                patch.object(self.host.shutil, "rmtree") as remove:
            instance.__exit__()
        remove.assert_not_called()
        self.assertFalse(instance.cleanup_ok)

    @staticmethod
    def capture_result(auth):
        return dict(ok=True, code="ok", verified_absent=True,
                    **(dict(keychain_absent=True, files_absent=True) if auth else
                       dict(identity_removed=0, relays_removed=0, hub_quiescent=True)))

    @staticmethod
    def remote_result(started=True, *, prepare=False):
        return dict(ok=True, code="ok" if started else "no_remote_started", lease_bound=True,
                    worker_started=started, identity_removed=3 if started and not prepare else 0, relays_removed=0,
                    verified_absent=True, worker_quiescent=True, worker_pid_exited=True, descendants_exited=True)

    def test_capture_binds_auth_and_device_to_their_exact_namespaces(self):
        instance = self.make_host()
        for auth, method, bundle in ((True, "debug.cloud.capture_prepare", "owned"),
                                      (False, "debug.device_hub", "owned.cloud.development")):
            with self.subTest(auth=auth), patch.object(self.host, "rpc", return_value=self.capture_result(auth)) as call:
                instance._capture("prepare", auth=auth)
                self.assertEqual(call.call_args.args[1], method)
                self.assertEqual(call.call_args.args[2]["bundle_id"], bundle)
                self.assertEqual(call.call_args.args[2]["lease_id"], instance.lease)

    def test_credentials_wait_for_all_namespace_claims(self):
        for refusal in (None, "auth", "device", "remote", "resume", "resume-account"):
            with self.subTest(refusal=refusal), tempfile.TemporaryDirectory(prefix="ss-") as directory:
                instance = self.host.Host(Path("/owned.app"),
                                          {"CFBundleIdentifier": "owned", "CFBundleExecutable": "cmux"},
                                          directory, ("account", "password"))
                launches, order = [], []
                def launch(env, _home):
                    launches.append(dict(env))
                    order.append("launch")
                    instance.proc = Mock()
                    instance.proc.poll.return_value = None
                def claim(phase, *, auth):
                    name = "auth" if auth else "device"
                    order.append(phase + "-" + name)
                    if phase == "prepare" and refusal == name:
                        raise self.host.HostFailure("host_namespace_prepare_failed")
                def remote_claim(phase):
                    order.append(phase + "-remote")
                    if phase == "prepare" and refusal == "remote":
                        raise self.host.HostFailure("host_remote_prepare_failed")
                def resume():
                    order.append("resume-remote")
                    if refusal == "resume":
                        raise self.host.HostFailure("host_remote_resume_failed")
                accounts = [{"signed_in": False},
                            {"signed_in": True, "user_id": "unexpected"} if refusal == "resume-account"
                            else {"signed_in": False}]
                with patch.object(self.host, "command", return_value=""), \
                        patch.object(self.host, "identity_service", return_value="owned.cloud.development.device-hub"), \
                        patch.object(self.host.subprocess, "run", return_value=Mock(returncode=44)), \
                        patch.object(instance, "_launch", side_effect=launch), \
                        patch.object(instance, "_account", side_effect=accounts), \
                        patch.object(instance, "_capture", side_effect=claim), \
                        patch.object(instance, "_remote_capture", side_effect=remote_claim), \
                        patch.object(instance, "_remote_resume", side_effect=resume, create=True), \
                        patch.object(instance, "hub", return_value={"signed_in": True, "this_device": "owned-device"}), \
                        patch.object(self.host, "rpc", return_value={"signed_in": True, "email": "account"}), \
                        patch.object(self.host, "stop", side_effect=lambda proc: order.append("stop")):
                    if refusal:
                        with self.assertRaises(self.host.HostFailure): instance.__enter__()
                    else:
                        instance.__enter__()
                if instance.log and not instance.log.closed: instance.log.close()
                self.assertNotIn("CMUX_UITEST_STACK_PASSWORD", launches[0])
                expected_launches = 2 if refusal in ("resume", "resume-account") else 1 if refusal else 3
                self.assertEqual(len(launches), expected_launches)
                for launch_env in launches[:-1] if not refusal else launches:
                    self.assertNotIn("CMUX_UITEST_STACK_PASSWORD", launch_env)
                if not refusal:
                    self.assertEqual(order, ["launch", "prepare-auth", "prepare-device", "prepare-remote", "stop",
                                             "launch", "resume-remote", "stop", "launch"])
                    self.assertEqual(launches[2]["CMUX_UITEST_STACK_PASSWORD"], "password")
                if refusal == "resume-account":
                    self.assertTrue(instance.account_mismatch)
                    self.assertNotIn("resume-remote", order)

    def test_capture_rejects_incomplete_or_wrongly_typed_absence_proof(self):
        instance = self.make_host()
        for auth, field, value in ((True, "files_absent", False), (True, "keychain_absent", None),
                                    (True, "verified_absent", None), (False, "identity_removed", True),
                                    (False, "relays_removed", -1), (False, "verified_absent", False),
                                    (False, "hub_quiescent", False), (False, "hub_quiescent", None)):
            with self.subTest(auth=auth, field=field), \
                    patch.object(self.host, "rpc", return_value={**self.capture_result(auth), field: value}):
                with self.assertRaisesRegex(self.host.HostFailure, "host_namespace_cleanup_failed"):
                    instance._capture("cleanup", auth=auth)

    def test_remote_resume_requires_exact_typed_lease_acknowledgement(self):
        instance = self.make_host()
        valid = {"ok": True, "code": "remote_capture_resumed", "lease_bound": True}
        invalid = [None, {}, {**valid, "extra": True}, {**valid, "code": "ok"}]
        invalid += [{k: v for k, v in valid.items() if k != field} for field in valid]
        invalid += [{**valid, field: value} for field in ("ok", "lease_bound") for value in (False, None, 1)]
        for result in invalid:
            with self.subTest(result=result), patch.object(self.host, "rpc", return_value=result):
                with self.assertRaisesRegex(self.host.HostFailure, "host_remote_resume_failed"):
                    instance._remote_resume()
        with patch.object(self.host, "rpc", return_value=valid) as call:
            instance._remote_resume()
            self.assertEqual(call.call_args.args[1:], ("debug.remote.capture_resume",
                {"lease_id": instance.lease, "bundle_id": "owned", "private_root": str(instance.work / "home")}))
            self.assertGreaterEqual(call.call_args.kwargs["timeout"], 80)

    def test_remote_claim_binds_lease_raw_bundle_and_private_home(self):
        instance = self.make_host()
        for phase in ("prepare", "cleanup"):
            for started in (True, False):
                with self.subTest(phase=phase, started=started), \
                        patch.object(self.host, "rpc", return_value=self.remote_result(started, prepare=phase == "prepare")) as call:
                    instance._remote_capture(phase)
                    self.assertEqual(call.call_args.args[1:], ("debug.remote.capture_" + phase,
                        {"lease_id": "a" * 24, "bundle_id": "owned", "private_root": str(instance.work / "home")}))

    def test_prepare_cannot_remove_preexisting_identity_or_relay_items(self):
        instance = self.make_host()
        for remote in (True, False):
            for field in ("identity_removed", "relays_removed"):
                result = self.remote_result(prepare=True) if remote else self.capture_result(False)
                with self.subTest(remote=remote, field=field), \
                        patch.object(self.host, "rpc", return_value={**result, field: 1}):
                    with self.assertRaises(self.host.HostFailure):
                        if remote: instance._remote_capture("prepare")
                        else: instance._capture("prepare", auth=False)

    def test_remote_cleanup_rejects_partial_exit_or_inconsistent_no_worker_proof(self):
        instance = self.make_host()
        invalid = [{key: value} for key in ("ok", "lease_bound", "verified_absent", "worker_quiescent",
                                           "worker_pid_exited", "descendants_exited") for value in (False, None, 1)]
        invalid += [{"identity_removed": True}, {"relays_removed": -1}, {"worker_started": 1},
                    {"worker_started": False}, {"code": "no_remote_started"},
                    {"code": "no_remote_started", "worker_started": False}, {"code": "unknown"}]
        for override in invalid:
            with self.subTest(override=override), \
                    patch.object(self.host, "rpc", return_value={**self.remote_result(), **override}):
                with self.assertRaisesRegex(self.host.HostFailure, "host_remote_cleanup_failed"):
                    instance._remote_capture("cleanup")

    def test_signout_is_read_back_before_owned_process_stop(self):
        instance = self.make_host()
        order = []
        def rpc(_socket, method, *_args, **_kwargs):
            order.append(method)
            if method == "debug.remote.capture_cleanup": return self.remote_result()
            if method.startswith("debug.cloud.capture_"): return self.capture_result(True)
            if method == "debug.device_hub": return self.capture_result(False)
            return {"ended": True} if method.endswith("end_session") else {"signed_in": False, "restoring": False}
        with patch.object(self.host, "rpc", side_effect=rpc), patch.object(self.host, "stop", side_effect=lambda p: order.append(p)):
            instance.__exit__()
        self.assertTrue(instance.cleanup_ok)
        self.assertEqual(order, [instance.probe, "debug.cloud.end_session", "auth.status",
                                 "debug.remote.capture_cleanup", "debug.cloud.capture_cleanup", "debug.device_hub", instance.proc])

    def test_failed_auth_absence_preserves_device_marker_and_stops_process(self):
        instance = self.make_host()
        def rpc(_socket, method, *_args, **_kwargs):
            if method == "debug.cloud.end_session": return {"ended": True}
            if method == "auth.status": return {"signed_in": False, "restoring": False}
            if method == "debug.remote.capture_cleanup": return self.remote_result()
            return {"ok": True}
        with patch.object(self.host, "rpc", side_effect=rpc) as call, patch.object(self.host, "stop") as stop:
            instance.__exit__()
        self.assertFalse(instance.cleanup_ok)
        self.assertNotIn("debug.device_hub", [c.args[1] for c in call.call_args_list])
        stop.assert_any_call(instance.proc)

    def test_failed_signout_still_stops_owned_app_and_fails_cleanup(self):
        instance = self.make_host()
        with patch.object(self.host, "rpc", side_effect=self.host.HostFailure("failure")), patch.object(self.host, "stop") as stop:
            instance.__exit__()
        self.assertFalse(instance.cleanup_ok)
        stop.assert_any_call(instance.proc)

    def test_remote_exit_must_precede_app_namespace_cleanup(self):
        for remote_ok in (True, False):
            with self.subTest(remote_ok=remote_ok):
                instance = self.make_host()
                instance.remote_prepared = True
                methods = []
                def rpc(_socket, method, *_args, **_kwargs):
                    methods.append(method)
                    if method == "debug.cloud.end_session": return {"ended": True}
                    if method == "auth.status": return {"signed_in": False, "restoring": False}
                    if method == "debug.remote.capture_cleanup":
                        return dict(ok=True, code="ok", lease_bound=True, worker_started=True,
                                    identity_removed=3, relays_removed=0, verified_absent=True,
                                    worker_quiescent=True, worker_pid_exited=True, descendants_exited=remote_ok)
                    return self.capture_result(method.startswith("debug.cloud.capture_"))
                with patch.object(self.host, "rpc", side_effect=rpc), patch.object(self.host, "stop"):
                    instance.__exit__()
                self.assertIn("debug.remote.capture_cleanup", methods)
                self.assertEqual(instance.cleanup_ok, remote_ok)
                if remote_ok:
                    self.assertLess(methods.index("debug.remote.capture_cleanup"), methods.index("debug.cloud.capture_cleanup"))
                else:
                    self.assertNotIn("debug.cloud.capture_cleanup", methods)
                    self.assertNotIn("debug.device_hub", methods)

    def test_preexisting_auth_is_never_signed_out(self):
        instance = self.make_host(); instance.owns_auth = False
        instance.auth_prepared = instance.device_prepared = False
        instance.remote_attempted = instance.remote_prepared = False
        with patch.object(self.host, "rpc") as rpc, patch.object(self.host, "stop"):
            instance.__exit__()
        rpc.assert_not_called()

    def test_shell_teardown_failure_invalidates_public_receipt(self):
        root = Path(__file__).resolve().parents[1]
        source = (root / "scripts/ci/cmux-next-ios-sim.sh").read_text()
        cleanup = source[source.index("cleanup() {"):source.index("trap cleanup EXIT")]
        for fails in (False, True):
            with self.subTest(fails=fails), tempfile.TemporaryDirectory() as directory:
                work = Path(directory)
                sims, out = work / "sims", work / "out"
                sims.mkdir()
                receipt = Rig().instance().run("Mac", "Phone", "abc")
                receipt["cleanup"] = True
                proof.export_receipt(receipt, out)
                script = ('set -euo pipefail\nmode=screen-proof\nsims="$1"\nout="$2"\n'
                          'xcodegen_dir=""\nwork=""\nxcrun() { return ' + str(int(fails)) + '; }\n'
                          + cleanup + '\ntrap cleanup EXIT\nexit 0\n')
                result = subprocess.run(["bash", "-c", script, "proof-cleanup", str(sims), str(out)],
                                        cwd=root, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, int(fails), result.stderr)
                with zipfile.ZipFile(out / "evidence.zip") as archive:
                    public = json.loads(archive.read("screen-sharing-proof.json"))
                self.assertEqual(public["passed"], not fails)
                self.assertFalse(sims.exists())

    def test_missing_cleanup_cannot_publish_green(self):
        receipt = Rig().instance().run("Mac", "Phone", "abc")
        with tempfile.TemporaryDirectory() as directory:
            self.assertFalse(proof.export_receipt(receipt, directory))

    def test_public_string_fields_cannot_contain_private_errors(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(proof.ProofFailure):
                proof.export_receipt({"error_code": "secret@example.test"}, directory)

    def test_safe_startup_errors_survive_public_receipt(self):
        for code in ("device_hub_configuration_timeout", "host_cloud_namespace_unavailable"):
            with self.subTest(code=code), tempfile.TemporaryDirectory() as directory:
                self.assertFalse(proof.export_receipt({"error_code": code}, directory))
                with zipfile.ZipFile(Path(directory) / "evidence.zip") as archive:
                    self.assertEqual(json.loads(archive.read("screen-sharing-proof.json"))["error_code"], code)


if __name__ == "__main__":
    unittest.main()
