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

    def test_the_journey_target_makes_its_own_account_sealed_to_the_journey_environment(self):
        fake = FakeStack([{"id": "user-1", "primary_email": provision.EMAIL, "password": "capture-password",
                           "client_read_only_metadata": {"cmuxVmPlan": "pro"}}])
        key, pk, sk = keypair()
        target = provision.TARGETS["journey"]
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "bundle.json"
            action = provision.provision(stack(fake), out, log=lambda _: None, lib=SODIUM, key_id="42", key=key,
                                         make_password=lambda: PASSWORD, target=target)
            bundle = json.loads(out.read_text())
        self.assertEqual(action, "created")
        self.assertEqual(fake.users["user-1"]["password"], "capture-password")  # the capture account is untouched
        created = [r for r in fake.requests if r[0] == "POST" and r[1] == "/users"]
        self.assertEqual(created[0][3]["primary_email"], "cmux-cloud-capture-journey@manaflow.dev")
        self.assertEqual(bundle["repo"], "manaflow-ai/cmux")
        self.assertEqual(bundle["environment"], "cmux-next-vm-image-dev")
        self.assertEqual(sorted(bundle["secrets"]), ["CMUX_DOGFOOD_STACK_EMAIL", "CMUX_DOGFOOD_STACK_PASSWORD"])
        self.assertEqual(open_sealed(bundle["secrets"]["CMUX_DOGFOOD_STACK_PASSWORD"], pk, sk), PASSWORD)
        self.assertTrue(provision.GRANT_ONLY_EMAIL.fullmatch(target.email))

    @unittest.skipIf(SODIUM is None, "needs the system libsodium")
    def test_the_production_target_makes_its_account_in_the_production_project(self):
        fake = FakeStack()
        key, pk, sk = keypair()
        target = provision.TARGETS["production"]
        prod = provision.Stack(provision.PRODUCTION_PROJECT_ID, "server-key", "client-key", transport=fake,
                               expected_project=provision.PRODUCTION_PROJECT_ID)
        lines = []
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "bundle.json"
            action = provision.provision(prod, out, log=lines.append, lib=SODIUM, key_id="42", key=key,
                                         make_password=lambda: PASSWORD, target=target)
            bundle = json.loads(out.read_text())
        self.assertEqual(action, "created")
        self.assertTrue(all(r[2]["x-stack-project-id"] == provision.PRODUCTION_PROJECT_ID for r in fake.requests))
        created = [r for r in fake.requests if r[0] == "POST" and r[1] == "/users"]
        self.assertEqual(created[0][3]["primary_email"], "cmux-cloud-capture-prod@manaflow.dev")
        self.assertEqual(created[0][3]["client_read_only_metadata"], {"cmuxVmPlan": "pro"})
        self.assertEqual((bundle["repo"], bundle["environment"]), ("manaflow-ai/cmuxterm-hq", "cloud-capture"))
        self.assertEqual(sorted(bundle["secrets"]),
                         ["CLOUD_PROBE_PRODUCTION_STACK_EMAIL", "CLOUD_PROBE_PRODUCTION_STACK_PASSWORD"])
        self.assertEqual(open_sealed(bundle["secrets"]["CLOUD_PROBE_PRODUCTION_STACK_PASSWORD"], pk, sk), PASSWORD)
        self.assertIn("production test account", lines[0])
        self.assertIn("Stack user id user-new", lines[0])
        self.assertNotIn(PASSWORD, lines[0])

    @unittest.skipIf(SODIUM is None, "needs the system libsodium")
    def test_the_production_journey_target_has_its_own_account_sealed_to_the_journey_environment(self):
        probe = provision.TARGETS["production"]
        fake = FakeStack([{"id": "user-1", "primary_email": probe.email, "password": "probe-password",
                           "client_read_only_metadata": {"cmuxVmPlan": "pro"}}])
        key, pk, sk = keypair()
        target = provision.TARGETS["journey-production"]
        prod = provision.Stack(provision.PRODUCTION_PROJECT_ID, "server-key", "client-key", transport=fake,
                               expected_project=provision.PRODUCTION_PROJECT_ID)
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "bundle.json"
            action = provision.provision(prod, out, log=lambda _: None, lib=SODIUM, key_id="42", key=key,
                                         make_password=lambda: PASSWORD, target=target)
            bundle = json.loads(out.read_text())
        self.assertEqual(action, "created")
        self.assertEqual(fake.users["user-1"]["password"], "probe-password")  # the probe's account is untouched
        self.assertTrue(all(r[2]["x-stack-project-id"] == provision.PRODUCTION_PROJECT_ID for r in fake.requests))
        created = [r for r in fake.requests if r[0] == "POST" and r[1] == "/users"]
        self.assertEqual(created[0][3]["primary_email"], "cmux-cloud-capture-journey-prod@manaflow.dev")
        self.assertEqual((bundle["repo"], bundle["environment"]), ("manaflow-ai/cmux", "cmux-next-cloud-journey"))
        self.assertEqual(sorted(bundle["secrets"]), ["CMUX_DOGFOOD_STACK_EMAIL", "CMUX_DOGFOOD_STACK_PASSWORD"])
        self.assertEqual(open_sealed(bundle["secrets"]["CMUX_DOGFOOD_STACK_PASSWORD"], pk, sk), PASSWORD)

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


class GrantOnly(unittest.TestCase):
    OWNER = "cmux-cloud-capture-owner3@manaflow.dev"

    def test_an_existing_capture_account_gets_only_the_plan_grant_and_a_verified_email(self):
        fake = FakeStack([{"id": "u1", "primary_email": self.OWNER, "password": PASSWORD, "primary_email_verified": False,
                           "client_read_only_metadata": {"cmuxPlan": "free", "keep": 1}}])
        provision.grant_only(stack(fake), self.OWNER, log=lambda _: None)
        self.assertEqual(fake.users["u1"]["client_read_only_metadata"], {"cmuxPlan": "free", "keep": 1, "cmuxVmPlan": "pro"})
        self.assertIs(fake.users["u1"]["primary_email_verified"], True)
        self.assertEqual(fake.users["u1"]["password"], PASSWORD)
        patches = [body for method, _, _, body in fake.requests if method == "PATCH"]
        self.assertEqual(patches, [{"client_read_only_metadata": {"cmuxPlan": "free", "keep": 1, "cmuxVmPlan": "pro"},
                                    "primary_email_verified": True}])

    def test_an_email_that_does_not_read_back_verified_fails(self):
        class Unverifiable(FakeStack):
            def __call__(self, method, url, headers, body, timeout=None):
                if method == "PATCH" and body:
                    body = {k: v for k, v in body.items() if k != "primary_email_verified"}
                return super().__call__(method, url, headers, body, timeout)
        fake = Unverifiable([{"id": "u1", "primary_email": self.OWNER, "primary_email_verified": False}])
        with self.assertRaisesRegex(provision.ProvisionError, "verified"):
            provision.grant_only(stack(fake), self.OWNER, log=lambda _: None)

    def test_a_missing_account_is_never_created(self):
        fake = FakeStack()
        with self.assertRaises(provision.ProvisionError):
            provision.grant_only(stack(fake), self.OWNER, log=lambda _: None)
        self.assertFalse([r for r in fake.requests if r[0] in ("POST", "PATCH")])

    def test_any_other_email_is_refused_before_any_request(self):
        for email in ("someone@manaflow.dev", "cmux-cloud-capture@manaflow.dev.evil.com", "cmux-cloud-capture@gmail.com"):
            fake = FakeStack()
            with self.assertRaises(provision.ProvisionError):
                provision.grant_only(stack(fake), email, log=lambda _: None)
            self.assertEqual(fake.requests, [])


    def test_an_empty_grant_only_never_falls_through_to_provisioning(self):
        env = {"NEXT_PUBLIC_STACK_PROJECT_ID": provision.STAGING_PROJECT_ID, "STACK_SECRET_SERVER_KEY": "k",
               "NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY": "c"}
        with mock.patch.dict(os.environ, env), mock.patch.object(provision, "provision") as rotate, \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(provision.main(["--grant-only", ""]), 1)
        rotate.assert_not_called()


class Guards(unittest.TestCase):
    def test_another_stack_project_is_refused_before_any_request(self):
        fake = FakeStack()
        with self.assertRaisesRegex(provision.ProvisionError, "not the target's project"):
            provision.Stack("some-production-project", "server-key", "client-key", transport=fake)
        self.assertEqual(fake.requests, [])

    def test_the_production_key_never_serves_a_staging_target(self):
        fake = FakeStack()
        prod = provision.Stack(provision.PRODUCTION_PROJECT_ID, "server-key", "client-key", transport=fake,
                               expected_project=provision.PRODUCTION_PROJECT_ID)
        with tempfile.TemporaryDirectory() as tmp, \
                self.assertRaisesRegex(provision.ProvisionError, "not the target's project"):
            provision.provision(prod, Path(tmp) / "b.json", log=lambda _: None, lib=SODIUM, key_id="42", key="k",
                                make_password=lambda: PASSWORD, target=provision.TARGETS["capture"])
        self.assertEqual(fake.requests, [])

    def test_main_binds_the_server_key_to_the_target_project(self):
        env = {"NEXT_PUBLIC_STACK_PROJECT_ID": provision.STAGING_PROJECT_ID, "STACK_SECRET_SERVER_KEY": "k",
               "NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY": "c"}
        with mock.patch.dict(os.environ, env), mock.patch.object(provision, "provision") as rotate, \
                contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(provision.main(["--target", "production", "--out", "/nonexistent/b.json"]), 1)
        rotate.assert_not_called()
        self.assertIn("not the target's project", out.getvalue())

    def test_grant_only_never_runs_against_production(self):
        env = {"NEXT_PUBLIC_STACK_PROJECT_ID": provision.PRODUCTION_PROJECT_ID, "STACK_SECRET_SERVER_KEY": "k",
               "NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY": "c"}
        with mock.patch.dict(os.environ, env), mock.patch.object(provision, "grant_only") as grant, \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(provision.main(["--target", "production", "--grant-only",
                                             "cmux-cloud-capture-prod@manaflow.dev"]), 1)
        grant.assert_not_called()

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
