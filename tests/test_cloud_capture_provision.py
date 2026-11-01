#!/usr/bin/env python3
"""cloud_capture_provision.py and sealed_secrets.py: find-or-create, rotation, sealing, and `put`'s key check.

Run by hand (tests/test-execution.toml lane manual): python3 tests/test_cloud_capture_provision.py.
The sealing round trip needs the system libsodium and is skipped without it.
"""
from __future__ import annotations

import base64
import contextlib
import ctypes
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import cloud_capture_provision as provision  # noqa: E402
import sealed_secrets  # noqa: E402

PASSWORD = "test-password-not-real-0123456789abcdef"

try:
    SODIUM = sealed_secrets.sodium()
except sealed_secrets.SealError:
    SODIUM = None


def keypair():
    pk, sk = ctypes.create_string_buffer(32), ctypes.create_string_buffer(32)
    assert SODIUM.crypto_box_keypair(pk, sk) == 0
    return base64.b64encode(pk.raw).decode(), pk.raw, sk.raw


def open_sealed(value_b64, pk, sk):
    box = base64.b64decode(value_b64)
    out = ctypes.create_string_buffer(len(box) - sealed_secrets.SEALBYTES)
    assert SODIUM.crypto_box_seal_open(out, box, ctypes.c_ulonglong(len(box)), pk, sk) == 0
    return out.raw.decode()


class FakeStack:
    """The Stack REST endpoints the script uses, recording each request."""

    def __init__(self, users=(), sign_in_ok=True):
        self.users = {u["id"]: dict(u) for u in users}
        self.sign_in_ok = sign_in_ok
        self.requests = []

    def __call__(self, method, url, headers, body, timeout=None):
        path = url.removeprefix(provision.STACK_API)
        self.requests.append((method, path, headers, body))
        if path.startswith("/users?"):
            return 200, {}, {"items": list(self.users.values())}
        if method == "POST" and path == "/users":
            user = {"id": "user-new", "primary_email": body["primary_email"],
                    "client_read_only_metadata": body["client_read_only_metadata"], "password": body["password"]}
            self.users[user["id"]] = user
            return 201, {}, user
        if path.startswith("/users/"):
            user = self.users[path.split("/")[2]]
            if method == "PATCH":
                user.update(body)
                return 200, {}, user
            return 200, {}, user
        if path == "/auth/password/sign-in":
            ok = self.sign_in_ok and any(str(u.get("primary_email")).lower() == body["email"].lower() and u.get("password") == body["password"]
                                         for u in self.users.values())
            return (200, {}, {"access_token": "a", "refresh_token": "r"}) if ok else (400, {}, None)
        raise AssertionError(f"unexpected {method} {path}")


def stack(fake):
    return provision.Stack(provision.STAGING_PROJECT_ID, "server-key", "client-key", transport=fake)


@unittest.skipIf(SODIUM is None, "libsodium is not installed")
class Provision(unittest.TestCase):
    def run_provision(self, fake):
        key, pk, sk = keypair()
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "bundle.json"
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                action = provision.provision(stack(fake), out, lib=SODIUM, key_id="42", key=key,
                                             make_password=lambda: PASSWORD)
            bundle = json.loads(out.read_text())
        return action, bundle, pk, sk, stdout.getvalue()

    def test_a_missing_account_is_created_with_the_pro_plan_and_sealed(self):
        fake = FakeStack()
        action, bundle, pk, sk, stdout = self.run_provision(fake)
        self.assertEqual(action, "created")
        created = [r for r in fake.requests if r[0] == "POST" and r[1] == "/users"]
        self.assertEqual(len(created), 1)
        self.assertEqual(created[0][3]["client_read_only_metadata"], {"cmuxVmPlan": "pro"})
        self.assertEqual(bundle["repo"], "manaflow-ai/cmuxterm-hq")
        self.assertEqual(bundle["environment"], "cloud-capture")
        self.assertEqual(bundle["key_id"], "42")
        self.assertEqual(open_sealed(bundle["secrets"]["CLOUD_CAPTURE_STACK_PASSWORD"], pk, sk), PASSWORD)
        self.assertEqual(open_sealed(bundle["secrets"]["CLOUD_CAPTURE_STACK_EMAIL"], pk, sk), provision.EMAIL)
        # The plaintext appears nowhere but inside the sealed boxes.
        self.assertNotIn(PASSWORD, json.dumps(bundle))
        self.assertNotIn(PASSWORD, stdout)

    def test_an_existing_account_is_rotated_keeping_other_metadata(self):
        fake = FakeStack([{"id": "user-1", "primary_email": provision.EMAIL.upper(), "password": "old",
                           "client_read_only_metadata": {"other": 1, "cmuxVmPlan": "free"}}])
        action, bundle, pk, sk, _ = self.run_provision(fake)
        self.assertEqual(action, "rotated")
        self.assertFalse([r for r in fake.requests if r[0] == "POST" and r[1] == "/users"])
        patch = [r for r in fake.requests if r[0] == "PATCH"]
        self.assertEqual(patch[0][1], "/users/user-1")
        self.assertEqual(patch[0][3]["client_read_only_metadata"], {"other": 1, "cmuxVmPlan": "pro"})
        self.assertEqual(patch[0][3]["password"], PASSWORD)
        self.assertEqual(open_sealed(bundle["secrets"]["CLOUD_CAPTURE_STACK_PASSWORD"], pk, sk), PASSWORD)

    def test_a_password_that_does_not_sign_in_writes_no_bundle(self):
        key, _, _ = keypair()
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "bundle.json"
            with self.assertRaisesRegex(provision.ProvisionError, "did not sign in"):
                provision.provision(stack(FakeStack(sign_in_ok=False)), out, log=lambda _: None, lib=SODIUM,
                                    key_id="42", key=key, make_password=lambda: PASSWORD)
            self.assertFalse(out.exists())

    def test_two_accounts_with_the_email_refuse(self):
        users = [{"id": f"u{i}", "primary_email": provision.EMAIL} for i in range(2)]
        with self.assertRaisesRegex(provision.ProvisionError, "refusing to pick"):
            stack(FakeStack(users)).find(provision.EMAIL)


class Guards(unittest.TestCase):
    def test_another_stack_project_is_refused_before_any_request(self):
        fake = FakeStack()
        with self.assertRaisesRegex(provision.ProvisionError, "not the staging project"):
            provision.Stack("some-production-project", "server-key", "client-key", transport=fake)
        self.assertEqual(fake.requests, [])

    def test_stack_errors_name_the_status_never_the_body(self):
        def transport(method, url, headers, body, timeout=None):
            return 500, {"x-stack-known-error": "SOMETHING"}, {"secret": "body-detail"}
        with self.assertRaises(provision.ProvisionError) as caught:
            stack(transport).find(provision.EMAIL)
        self.assertIn("HTTP 500 (SOMETHING)", str(caught.exception))
        self.assertNotIn("body-detail", str(caught.exception))

    def test_requests_go_only_to_stack_and_never_follow_a_redirect(self):
        with self.assertRaisesRegex(provision.ProvisionError, "outside Stack's API host"):
            provision.http("GET", "https://example.com/api/v1/users", {}, None)
        with self.assertRaisesRegex(provision.ProvisionError, "outside Stack's API host"):
            provision.http("GET", "http://api.stack-auth.com/api/v1/users", {}, None)
        request = provision.urllib.request.Request(provision.STACK_API + "/users")
        self.assertIsNone(provision.NoRedirect().redirect_request(request, None, 302, "Found", {},
                                                                  "https://elsewhere.example/"))
        self.assertTrue(any(isinstance(h, provision.NoRedirect) for h in provision.OPENER.handlers))

    def test_a_redirect_answer_is_an_error_naming_only_its_status(self):
        def transport(method, url, headers, body, timeout=None):
            return 302, {"location": "https://elsewhere.example/"}, None
        with self.assertRaisesRegex(provision.ProvisionError, "HTTP 302"):
            stack(transport).find(provision.EMAIL)

    def test_the_password_is_masked_in_actions_logs(self):
        stdout = io.StringIO()
        with mock.patch.dict(os.environ, {"GITHUB_ACTIONS": "true"}), contextlib.redirect_stdout(stdout):
            password = provision.new_password()
        self.assertEqual(stdout.getvalue(), f"::add-mask::{password}\n")
        self.assertGreaterEqual(len(password), 43)


GRANT_ID = "5a5cb0e8-b92d-4a29-8a92-7a0d4e37d2ae"
GRANT_EMAIL = "owner@example.test"


class GrantPlanOnly(unittest.TestCase):
    def fake(self, **user):
        return FakeStack([{"id": GRANT_ID, "primary_email": GRANT_EMAIL, "password": "keep",
                           "client_read_only_metadata": {"other": 1}} | user])

    def test_grant_merges_the_plan_and_patches_only_metadata(self):
        fake, lines = self.fake(), []
        self.assertEqual(provision.grant_plan(stack(fake), GRANT_ID, GRANT_EMAIL.upper(), log=lines.append), "pro")
        self.assertEqual([(r[0], r[1]) for r in fake.requests],
                         [("GET", f"/users/{GRANT_ID}"), ("PATCH", f"/users/{GRANT_ID}"), ("GET", f"/users/{GRANT_ID}")])
        self.assertEqual(fake.requests[1][3], {"client_read_only_metadata": {"other": 1, "cmuxVmPlan": "pro"}})
        self.assertEqual(fake.users[GRANT_ID]["password"], "keep")
        self.assertFalse([r for r in fake.requests if "sign-in" in r[1]])
        self.assertEqual(lines[-1], f"GET /users/{GRANT_ID} HTTP 200; after cmuxVmPlan='pro'")
        self.assertIn("before cmuxVmPlan=None", lines[0])
        # Only status codes and the plan value: no email or other metadata in the log.
        self.assertNotIn(GRANT_EMAIL, "\n".join(lines))
        self.assertNotIn("other", "\n".join(lines))

    def test_a_mismatched_email_refuses_before_any_write(self):
        fake = self.fake()
        with self.assertRaisesRegex(provision.ProvisionError, "does not match"):
            provision.grant_plan(stack(fake), GRANT_ID, "someone-else@example.test", log=lambda _: None)
        self.assertEqual([r[0] for r in fake.requests], ["GET"])

    def test_a_bad_user_id_refuses_before_any_request(self):
        fake = self.fake()
        for bad in ("", "../users", GRANT_ID.upper(), GRANT_ID + "/x"):
            with self.assertRaisesRegex(provision.ProvisionError, "not a Stack user id"):
                provision.grant_plan(stack(fake), bad, GRANT_EMAIL, log=lambda _: None)
        self.assertEqual(fake.requests, [])

    def test_another_project_refuses(self):
        s = stack(self.fake())
        s.project_id = "some-production-project"
        with self.assertRaisesRegex(provision.ProvisionError, "not the staging project"):
            provision.grant_plan(s, GRANT_ID, GRANT_EMAIL, log=lambda _: None)
        self.assertEqual(s.transport.requests, [])

    def test_a_plan_that_does_not_read_back_fails(self):
        fake = self.fake()
        original = fake.__call__

        def transport(method, url, headers, body, timeout=None):
            if method == "PATCH":
                fake.requests.append((method, url, headers, body))
                return 200, {}, {}
            return original(method, url, headers, body, timeout)
        with self.assertRaisesRegex(provision.ProvisionError, "did not read back"):
            provision.grant_plan(stack(transport), GRANT_ID, GRANT_EMAIL, log=lambda _: None)

    def test_main_grant_mode_makes_no_password_and_writes_no_bundle(self):
        fake = self.fake()
        env = {"NEXT_PUBLIC_STACK_PROJECT_ID": provision.STAGING_PROJECT_ID, "STACK_SECRET_SERVER_KEY": "k",
               "NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY": "c"}
        stdout = io.StringIO()
        real = provision.Stack
        with mock.patch.dict(os.environ, env), \
                mock.patch.object(provision, "Stack", lambda p, s, c: real(p, s, c, transport=fake)), \
                mock.patch.object(provision, "new_password", side_effect=AssertionError("no password")), \
                mock.patch.object(provision, "provision", side_effect=AssertionError("no sealing")), \
                contextlib.redirect_stdout(stdout):
            code = provision.main(["--grant-plan-only", "--user-id", GRANT_ID, "--email", GRANT_EMAIL])
        self.assertEqual(code, 0)
        self.assertIn("after cmuxVmPlan='pro'", stdout.getvalue())

    def test_main_refuses_mixed_flags(self):
        for argv in (["--grant-plan-only", "--user-id", GRANT_ID],
                     ["--grant-plan-only", "--user-id", GRANT_ID, "--email", GRANT_EMAIL, "--out", "x"],
                     ["--out", "x", "--user-id", GRANT_ID], []):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                provision.main(argv)

    def test_workflow_skips_sealing_and_upload_in_grant_mode(self):
        text = (ROOT / ".github/workflows/cloud-capture-provision.yml").read_text()
        self.assertIn("grant_plan_user_id:", text)
        self.assertIn("grant_plan_email:", text)
        self.assertIn("if: github.ref == 'refs/heads/main'", text)
        # The inputs reach the script only through env, never interpolated into the shell line.
        self.assertIn('--grant-plan-only --user-id "$GRANT_USER_ID" --email "$GRANT_EMAIL"', text)
        for step in ("- name: Provision and seal", "- name: Upload the sealed bundle (ciphertext only)"):
            after = text.split(step, 1)[1].lstrip().splitlines()[0]
            self.assertEqual(after.strip(), "if: inputs.grant_plan_user_id == '' && inputs.grant_plan_email == ''", step)


class Put(unittest.TestCase):
    BUNDLE = {"version": 1, "repo": "o/r", "environment": "env", "key_id": "42",
              "key": base64.b64encode(b"k" * 32).decode(),
              "secrets": {"A_SECRET": base64.b64encode(b"x" * 60).decode()}}

    def fake_gh(self, live):
        calls = []

        def run(argv, capture_output, text):
            calls.append(argv)
            out = json.dumps(live) if argv[-1].endswith("/public-key") else ""
            return mock.Mock(returncode=0, stdout=out, stderr="")
        return calls, run

    def test_a_changed_live_key_writes_nothing(self):
        calls, run = self.fake_gh({"key_id": "43", "key": self.BUNDLE["key"]})
        with self.assertRaisesRegex(sealed_secrets.SealError, "nothing was written"):
            sealed_secrets.put(self.BUNDLE, run=run, log=lambda _: None)
        self.assertEqual(len(calls), 1)

    def test_a_matching_key_puts_each_secret_with_its_key_id(self):
        calls, run = self.fake_gh({"key_id": "42", "key": self.BUNDLE["key"]})
        sealed_secrets.put(self.BUNDLE, run=run, log=lambda _: None)
        self.assertEqual(calls[1][:5], ["gh", "api", "-X", "PUT", "repos/o/r/environments/env/secrets/A_SECRET"])
        self.assertIn("key_id=42", calls[1])

    def test_a_bundle_with_a_short_value_is_not_a_sealed_box(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "b.json"
            path.write_text(json.dumps(self.BUNDLE | {"secrets": {"A": base64.b64encode(b"x").decode()}}))
            with self.assertRaisesRegex(sealed_secrets.SealError, "not a sealed box"):
                sealed_secrets.read_bundle(path)


if __name__ == "__main__":
    unittest.main()
