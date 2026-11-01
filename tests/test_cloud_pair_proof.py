"""Proof guardrails, not a substitute for the real fleet UI run."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    "cloud_pair_proof", Path(__file__).resolve().parents[1] / "scripts/ci/cmux_next_cloud_pair_proof.py")
proof = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(proof)


def manifest():
    return dict(owner_user_id="test-user", stack_project_id="test-project", machine_id="real-machine",
                team_id="team_test", machine_name="Proof machine", session_id="real-session",
                session_name="Proof chat", history_reply="previous assistant marker",
                prompt="Reply with proof- then {nonce}, joined without spaces.", expected_reply="proof-{nonce}")


class ManifestTests(unittest.TestCase):
    def test_runner_input_cannot_enter_the_artifact_tree(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(proof.ProofFailure):
                proof.read_proof(Path(directory, "input.json"), artifact_root=directory)

    def test_accepts_private_owned_input_without_modifying_it(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory, "input.json")
            file.write_text(json.dumps(manifest()))
            file.chmod(0o600)
            before = file.read_bytes()
            self.assertEqual(proof.read_proof(file), manifest())
            self.assertEqual(file.read_bytes(), before)

    def test_rejects_public_file_and_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory, "input.json")
            file.write_text(json.dumps(manifest()))
            file.chmod(0o644)
            with self.assertRaises(proof.ProofFailure):
                proof.read_proof(file)
            file.chmod(0o600)
            link = Path(directory, "link.json")
            link.symlink_to(file)
            with self.assertRaises(OSError):
                proof.read_proof(link)

    def test_rejects_credentials_or_missing_identity_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory, "input.json")
            for field in ("access_token", "owner_user_id"):
                value = manifest()
                if field == "access_token":
                    value[field] = "must-never-be-used"
                else:
                    del value[field]
                file.write_text(json.dumps(value))
                file.chmod(0o600)
                with self.assertRaises(proof.ProofFailure) as failure:
                    proof.read_proof(file)
                self.assertNotIn("must-never-be-used", str(failure.exception))

    def test_fresh_challenge_cannot_be_satisfied_by_prompt_echo(self):
        prompt, expected = proof.challenge(manifest(), "unique-123")
        self.assertIn("unique-123", prompt)
        self.assertEqual(expected, "proof-unique-123")
        self.assertNotIn(expected, prompt)
        unsafe = manifest() | {"prompt": "Say proof-{nonce}"}
        with self.assertRaises(proof.ProofFailure):
            proof.challenge(unsafe, "unique-123")

    def test_static_expected_reply_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory, "input.json")
            file.write_text(json.dumps(manifest() | {"expected_reply": "old history"}))
            file.chmod(0o600)
            with self.assertRaises(proof.ProofFailure):
                proof.read_proof(file)


class UIProofTests(unittest.TestCase):
    def test_offscreen_copy_is_excluded_and_partial_control_is_visible(self):
        bounds = {"x": 0, "y": 0, "width": 400, "height": 800}
        self.assertFalse(proof.visible({"frame": {"x": 10, "y": 900, "width": 20, "height": 20}}, bounds))
        self.assertTrue(proof.visible({"frame": {"x": 10, "y": 790, "width": 20, "height": 20}}, bounds))

    def test_ambiguous_controls_fail_instead_of_choosing_a_machine(self):
        with self.assertRaises(proof.ProofFailure):
            proof.unique([{"AXLabel": "same name"}, {"AXLabel": "same name"}], "machine")

    def test_prompt_visibility_without_assistant_copy_is_not_success(self):
        class UI(proof.PhoneUI):
            def tree(self):
                return [{"AXLabel": "fresh-answer", "type": "StaticText"}]

            def wait(self, check, what, seconds=60):
                if not check():
                    raise proof.ProofFailure(what)
                return True

        with self.assertRaises(proof.ProofFailure):
            UI([], "sim", "bundle", {}).reply("fresh-answer")

    def test_visible_marker_and_wrong_assistant_clipboard_cannot_pass(self):
        class UI(proof.PhoneUI):
            def tree(self):
                return [{"AXLabel": "fresh-answer", "type": "StaticText"},
                        {"AXLabel": "Copy", "type": "Button", "frame": {"x": 1, "y": 50, "width": 20, "height": 20}}]

            def copy(self, button):
                return "old assistant reply"

            def wait(self, check, what, seconds=60):
                if not check():
                    raise proof.ProofFailure(what)
                return True

        with self.assertRaises(proof.ProofFailure):
            UI([], "sim", "bundle", {}).reply("fresh-answer")

    def test_account_mismatch_fails_before_ui_commands(self):
        with self.assertRaisesRegex(proof.ProofFailure, "owner does not match"):
            proof.run_cloud_leg(manifest(), root="unused", mac_env={}, email="test@example.invalid",
                                rpc=lambda method: {"signed_in": True, "user_id": "wrong-account"}, phone_log=None,
                                simctl=[], udid="unused", bundle="unused", phone_env={}, rig_name="unused",
                                work="unused", out="unused", shot=None, note=None)


if __name__ == "__main__":
    unittest.main()
