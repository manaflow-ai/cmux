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

    def __init__(self, users=(), sign_in_ok=True, memberships=()):
        self.users = {u["id"]: dict(u) for u in users}
        self.sign_in_ok = sign_in_ok
        self.memberships = set(memberships)  # (team id, user id)
        self.requests = []

    def __call__(self, method, url, headers, body, timeout=None):
        path = url.removeprefix(provision.STACK_API)
        self.requests.append((method, path, headers, body))
        if method == "GET" and path.startswith("/teams?user_id="):
            user = provision.urllib.parse.unquote(path.split("=", 1)[1])
            return 200, {}, {"items": [{"id": t} for t, u in sorted(self.memberships) if u == user]}
        if path.startswith("/team-memberships/"):
            team, user = (provision.urllib.parse.unquote(p) for p in path.split("/")[2:4])
            if method == "POST":
                if (team, user) in self.memberships:
                    return 409, {"x-stack-known-error": "TEAM_MEMBERSHIP_ALREADY_EXISTS"}, None
                self.memberships.add((team, user))
                return 201, {}, {}
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


def stack(fake, project=provision.STAGING_PROJECT_ID):
    return provision.Stack(project, "server-key", "client-key", transport=fake, expected_project=project)


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

    def test_the_guest_target_makes_a_named_second_account_under_its_own_secret_names(self):
        fake = FakeStack([{"id": "user-1", "primary_email": "cmux-cloud-capture-journey@manaflow.dev",
                           "password": "journey-password", "client_read_only_metadata": {"cmuxVmPlan": "pro"}}])
        key, pk, sk = keypair()
        target = provision.TARGETS["journey-guest"]
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "bundle.json"
            action = provision.provision(stack(fake), out, log=lambda _: None, lib=SODIUM, key_id="42", key=key,
                                         make_password=lambda: PASSWORD, target=target)
            bundle = json.loads(out.read_text())
        self.assertEqual(action, "created")
        self.assertEqual(fake.users["user-1"]["password"], "journey-password")  # the owner account is untouched
        created = [r for r in fake.requests if r[0] == "POST" and r[1] == "/users"][0][3]
        self.assertEqual(created["primary_email"], "cmux-cloud-capture-guest@manaflow.dev")
        self.assertIs(created["primary_email_verified"], True)
        self.assertEqual(created["display_name"], "Capture Guest")
        self.assertTrue(created["profile_image_url"].startswith("https://"))
        self.assertEqual((bundle["repo"], bundle["environment"]), ("manaflow-ai/cmux", "cmux-next-vm-image-dev"))
        self.assertEqual(sorted(bundle["secrets"]),
                         ["CMUX_DOGFOOD_GUEST_STACK_EMAIL", "CMUX_DOGFOOD_GUEST_STACK_PASSWORD"])
        self.assertEqual(open_sealed(bundle["secrets"]["CMUX_DOGFOOD_GUEST_STACK_PASSWORD"], pk, sk), PASSWORD)
        self.assertEqual(target.project, provision.STAGING_PROJECT_ID)
        self.assertTrue(provision.GRANT_ONLY_EMAIL.fullmatch(target.email))

    def test_rotating_the_guest_keeps_its_name_and_image(self):
        fake = FakeStack([{"id": "user-2", "primary_email": "cmux-cloud-capture-guest@manaflow.dev", "password": "old",
                           "display_name": "renamed", "client_read_only_metadata": {}}])
        key, _, _ = keypair()
        with tempfile.TemporaryDirectory() as tmp:
            action = provision.provision(stack(fake), Path(tmp) / "b.json", log=lambda _: None, lib=SODIUM,
                                         key_id="42", key=key, make_password=lambda: PASSWORD,
                                         target=provision.TARGETS["journey-guest"])
        self.assertEqual(action, "rotated")
        patch = [r for r in fake.requests if r[0] == "PATCH"][0][3]
        self.assertEqual(patch["display_name"], "Capture Guest")
        self.assertIn("profile_image_url", patch)
        self.assertIs(patch["primary_email_verified"], True)

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

    @unittest.skipIf(SODIUM is None, "needs the system libsodium")
    def test_the_production_team_target_has_its_own_account_sealed_beside_the_probes(self):
        # cmuxterm-hq's cloud-chat-replies-production-team row (cmuxterm-hq#8541): a second production account that
        # joins a shared team. The hourly probe's account must stay in no shared team, so it is never this one.
        probe = provision.TARGETS["production"]
        fake = FakeStack([{"id": "user-1", "primary_email": probe.email, "password": "probe-password",
                           "client_read_only_metadata": {"cmuxVmPlan": "pro"}}])
        key, pk, sk = keypair()
        target = provision.TARGETS["production-team"]
        self.assertEqual(target.project, provision.PRODUCTION_PROJECT_ID)
        self.assertNotIn(target.email, [t.email for n, t in provision.TARGETS.items() if n != "production-team"])
        prod = provision.Stack(provision.PRODUCTION_PROJECT_ID, "server-key", "client-key", transport=fake,
                               expected_project=provision.PRODUCTION_PROJECT_ID)
        logs = []
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "bundle.json"
            action = provision.provision(prod, out, log=logs.append, lib=SODIUM, key_id="42", key=key,
                                         make_password=lambda: PASSWORD, target=target)
            bundle = json.loads(out.read_text())
        self.assertEqual(action, "created")
        self.assertEqual(fake.users["user-1"]["password"], "probe-password")  # the probe's account is untouched
        created = [r for r in fake.requests if r[0] == "POST" and r[1] == "/users"]
        self.assertEqual(created[0][3]["primary_email"], "cmux-cloud-capture-prod-team@manaflow.dev")
        self.assertEqual(created[0][3]["client_read_only_metadata"], {"cmuxVmPlan": "pro"})
        self.assertIs(created[0][3]["primary_email_verified"], True)  # a team invitation needs a verified email
        self.assertEqual((bundle["repo"], bundle["environment"]), ("manaflow-ai/cmuxterm-hq", "cloud-capture"))
        self.assertEqual(sorted(bundle["secrets"]),
                         ["CLOUD_PROBE_PRODUCTION_TEAM_STACK_EMAIL", "CLOUD_PROBE_PRODUCTION_TEAM_STACK_PASSWORD"])
        self.assertEqual(open_sealed(bundle["secrets"]["CLOUD_PROBE_PRODUCTION_TEAM_STACK_PASSWORD"], pk, sk), PASSWORD)
        self.assertIn("production test account", logs[-1])

    def test_the_workflow_offers_production_team_with_the_production_key_and_no_grant_only(self):
        text = (ROOT / ".github" / "workflows" / "cloud-capture-provision.yml").read_text()
        options = next(line for line in text.splitlines() if line.strip().startswith("options:"))
        self.assertIn("production-team", options)
        environment = next(line for line in text.splitlines() if line.strip().startswith("environment:"))
        self.assertIn("inputs.target == 'production-team'", environment)  # the production project's server key
        grant = text.split("- name: Grant the operator plan only", 1)[1].split("- name:", 1)[0]
        self.assertIn("inputs.target != 'production-team'", grant)

    def test_the_platform_targets_seal_to_cmux_platform_repository_secrets_with_their_own_accounts(self):
        key, pk, sk = keypair()
        for name, project, email, secrets in (
                ("platform-staging", provision.STAGING_PROJECT_ID, "cmux-cloud-capture-platform@manaflow.dev",
                 ["CMUX_DOGFOOD_STACK_EMAIL", "CMUX_DOGFOOD_STACK_PASSWORD"]),
                ("platform-production", provision.PRODUCTION_PROJECT_ID, "cmux-cloud-capture-platform-prod@manaflow.dev",
                 ["CMUX_JOURNEY_PROD_STACK_EMAIL", "CMUX_JOURNEY_PROD_STACK_PASSWORD"])):
            target = provision.TARGETS[name]
            self.assertEqual(target.project, project)
            # Its own account: never one another target rotates.
            self.assertNotIn(email, [t.email for n, t in provision.TARGETS.items() if n != name])
            fake = FakeStack()
            logs = []
            with tempfile.TemporaryDirectory() as tmp:
                out = Path(tmp) / "bundle.json"
                provision.provision(stack(fake, project), out, log=logs.append, lib=SODIUM, key_id="42", key=key,
                                    make_password=lambda: PASSWORD, target=target)
                bundle = sealed_secrets.read_bundle(out)
            created = [r for r in fake.requests if r[0] == "POST" and r[1] == "/users"]
            self.assertEqual(created[0][3]["primary_email"], email)
            self.assertEqual((bundle["repo"], bundle["environment"]), ("manaflow-ai/cmux-platform", None))
            self.assertEqual(sorted(bundle["secrets"]), secrets)
            self.assertEqual(open_sealed(bundle["secrets"][secrets[1]], pk, sk), PASSWORD)
            self.assertIn("manaflow-ai/cmux-platform repository secrets", logs[-1])

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


COMPANY_TEAM = "d13acd51-c77d-438a-9610-5369455e2a2f"


def team_calls(fake):
    return [(m, p) for m, p, _, _ in fake.requests if p.startswith("/teams") or p.startswith("/team-memberships")]


def prod_stack(fake):
    return provision.Stack(provision.PRODUCTION_PROJECT_ID, "server-key", "client-key", transport=fake,
                           expected_project=provision.PRODUCTION_PROJECT_ID)


@unittest.skipIf(SODIUM is None, "libsodium is not installed")
class CompanyTeam(unittest.TestCase):
    """The production-team account is a member of the company team "cmux" in the production Stack project, added
    with the server key, so nobody has to invite it by hand (and nobody's own account stands in for it)."""

    TEAM_EMAIL = "cmux-cloud-capture-prod-team@manaflow.dev"

    def run_provision(self, fake, target="production-team"):
        key, _, _ = keypair()
        logs = []
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "bundle.json"
            try:
                provision.provision(prod_stack(fake) if provision.TARGETS[target].project ==
                                    provision.PRODUCTION_PROJECT_ID else stack(fake), out, log=logs.append,
                                    lib=SODIUM, key_id="42", key=key, make_password=lambda: PASSWORD,
                                    target=provision.TARGETS[target])
            finally:
                wrote = out.exists()
        return logs, wrote

    def test_only_the_production_team_target_names_the_company_team(self):
        self.assertEqual(provision.COMPANY_TEAM_ID, COMPANY_TEAM)
        self.assertEqual(provision.TARGETS["production-team"].team_id, COMPANY_TEAM)
        others = {n: t.team_id for n, t in provision.TARGETS.items() if n != "production-team"}
        self.assertEqual(others, {n: None for n in others})  # the hourly probe's account stays in no team

    def test_provisioning_adds_the_account_to_the_company_team_and_reads_it_back(self):
        fake = FakeStack()
        logs, wrote = self.run_provision(fake)
        self.assertTrue(wrote)
        self.assertIn((COMPANY_TEAM, "user-new"), fake.memberships)
        self.assertEqual(team_calls(fake), [("GET", "/teams?user_id=user-new"),
                                            ("POST", f"/team-memberships/{COMPANY_TEAM}/user-new"),
                                            ("GET", "/teams?user_id=user-new")])
        post = [r for r in fake.requests if r[0] == "POST" and r[1].startswith("/team-memberships/")][0]
        self.assertEqual(post[2]["x-stack-access-type"], "server")
        self.assertEqual(post[3], {})
        self.assertTrue(any(f"member of the company team {COMPANY_TEAM}" in line for line in logs))

    def test_an_existing_member_is_not_added_again(self):
        fake = FakeStack([{"id": "u9", "primary_email": self.TEAM_EMAIL, "password": "old",
                           "client_read_only_metadata": {}}], memberships=[(COMPANY_TEAM, "u9")])
        _, wrote = self.run_provision(fake)
        self.assertTrue(wrote)
        self.assertEqual(team_calls(fake), [("GET", "/teams?user_id=u9"), ("GET", "/teams?user_id=u9")])

    def test_a_membership_added_meanwhile_counts_as_added(self):
        class Racing(FakeStack):
            def __call__(self, method, url, headers, body, timeout=None):
                if method == "POST" and "/team-memberships/" in url:
                    self.memberships.add((COMPANY_TEAM, "user-new"))
                return super().__call__(method, url, headers, body, timeout)
        fake = Racing()
        _, wrote = self.run_provision(fake)
        self.assertTrue(wrote)
        self.assertIn((COMPANY_TEAM, "user-new"), fake.memberships)

    def test_a_membership_that_does_not_read_back_fails_and_writes_no_bundle(self):
        class Forgetful(FakeStack):
            def __call__(self, method, url, headers, body, timeout=None):
                answer = super().__call__(method, url, headers, body, timeout)
                self.memberships.clear()
                return answer
        with self.assertRaisesRegex(provision.ProvisionError, "not a member of the company team"):
            self.run_provision(Forgetful())

    def test_a_refused_membership_names_its_status(self):
        class Refusing(FakeStack):
            def __call__(self, method, url, headers, body, timeout=None):
                if method == "POST" and "/team-memberships/" in url:
                    self.requests.append((method, url, headers, body))
                    return 404, {"x-stack-known-error": "TEAM_NOT_FOUND"}, None
                return super().__call__(method, url, headers, body, timeout)
        with self.assertRaisesRegex(provision.ProvisionError, r"HTTP 404 \(TEAM_NOT_FOUND\)"):
            self.run_provision(Refusing())

    def test_no_other_target_touches_a_team(self):
        for name in ("production", "journey-production", "capture"):
            fake = FakeStack()
            self.run_provision(fake, name)
            self.assertEqual(team_calls(fake), [], name)


class TeamOnly(unittest.TestCase):
    TEAM_EMAIL = CompanyTeam.TEAM_EMAIL

    def test_an_existing_account_joins_without_a_rotation(self):
        fake = FakeStack([{"id": "u9", "primary_email": self.TEAM_EMAIL, "password": "kept",
                           "client_read_only_metadata": {}}])
        provision.team_only(prod_stack(fake), provision.TARGETS["production-team"], log=lambda _: None)
        self.assertIn((COMPANY_TEAM, "u9"), fake.memberships)
        self.assertEqual(fake.users["u9"]["password"], "kept")
        self.assertFalse([r for r in fake.requests if r[0] == "PATCH" or r[1] == "/auth/password/sign-in"])

    def test_a_missing_account_is_never_created(self):
        fake = FakeStack()
        with self.assertRaisesRegex(provision.ProvisionError, "never creates"):
            provision.team_only(prod_stack(fake), provision.TARGETS["production-team"], log=lambda _: None)
        self.assertFalse([r for r in fake.requests if r[0] in ("POST", "PATCH")])

    def test_a_target_with_no_team_is_refused_before_any_request(self):
        fake = FakeStack()
        with self.assertRaisesRegex(provision.ProvisionError, "no company team"):
            provision.team_only(prod_stack(fake), provision.TARGETS["production"], log=lambda _: None)
        self.assertEqual(fake.requests, [])

    def test_main_runs_team_only_without_writing_a_bundle(self):
        env = {"NEXT_PUBLIC_STACK_PROJECT_ID": provision.PRODUCTION_PROJECT_ID, "STACK_SECRET_SERVER_KEY": "k",
               "NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY": "c"}
        with mock.patch.dict(os.environ, env), mock.patch.object(provision, "team_only") as join, \
                mock.patch.object(provision, "provision") as rotate, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(provision.main(["--target", "production-team", "--team-only"]), 0)
        rotate.assert_not_called()
        self.assertIs(join.call_args.args[1], provision.TARGETS["production-team"])

    def test_the_workflow_offers_team_only_with_the_production_key_and_no_rotation(self):
        text = (ROOT / ".github" / "workflows" / "cloud-capture-provision.yml").read_text()
        self.assertIn("team_only:", text.split("permissions:", 1)[0])
        step = text.split("- name: Join the company team only", 1)[1].split("- name:", 1)[0]
        self.assertIn("inputs.team_only", step)
        self.assertIn('--target "$TARGET" --team-only', step)
        self.assertIn("secrets.STACK_SECRET_SERVER_KEY", step)
        for name in ("Provision and seal", "Upload the sealed bundle (ciphertext only)", "libsodium"):
            guard = text.split(f"- name: {name}", 1)[1].split("\n", 2)[1]
            self.assertIn("!inputs.team_only", guard, name)


class ProbeTeamStack(FakeStack):
    """FakeStack plus the team records --probe-teams reads and writes (metadata, members, create, delete)."""

    def __init__(self, users=(), memberships=(), teams=()):
        super().__init__(users, memberships=memberships)
        self.team_records = {t["id"]: dict(t) for t in teams}
        self.made = 0

    def __call__(self, method, url, headers, body, timeout=None):
        path = url.removeprefix(provision.STACK_API)
        if method == "GET" and path.startswith("/teams?user_id="):
            self.requests.append((method, path, headers, body))
            user = provision.urllib.parse.unquote(path.split("=", 1)[1])
            return 200, {}, {"items": [dict(self.team_records.get(t, {"id": t}))
                                       for t, u in sorted(self.memberships) if u == user]}
        if path == "/teams" and method == "POST":
            self.requests.append((method, path, headers, body))
            self.made += 1
            team = {"id": f"team-new-{self.made}", "display_name": body["display_name"],
                    "server_metadata": body["server_metadata"], "client_read_only_metadata": {}}
            self.team_records[team["id"]] = team
            return 201, {}, team
        if path.startswith("/teams/"):
            self.requests.append((method, path, headers, body))
            team_id = provision.urllib.parse.unquote(path.split("/")[2])
            if method == "DELETE":
                self.team_records.pop(team_id, None)
                self.memberships = {(t, u) for t, u in self.memberships if t != team_id}
                return 200, {}, {}
            team = self.team_records[team_id]
            if method == "PATCH":
                team.update(body)
            return 200, {}, team
        if method == "GET" and path.startswith("/team-member-profiles?team_id="):
            self.requests.append((method, path, headers, body))
            team_id = provision.urllib.parse.unquote(path.split("=", 1)[1])
            return 200, {}, {"items": [{"user_id": u} for t, u in sorted(self.memberships) if t == team_id]}
        return super().__call__(method, url, headers, body, timeout)


class ProbeTeams(unittest.TestCase):
    """--probe-teams: the staging capture account alone in N probe teams with the team grant, for cmuxterm-hq
    platform_probe.py's "teams" spread (3x10 needs 2 more teams than its own, 5x10 needs 4)."""

    def capture(self):
        return {"id": "cap", "primary_email": provision.CAPTURE.email, "password": "kept",
                "client_read_only_metadata": {provision.PLAN_KEY: "pro"}}

    def run_teams(self, fake, count=4):
        logs = []
        ids = provision.probe_teams(stack(fake), count, log=logs.append)
        return ids, logs

    def probe_records(self, fake):
        return {t["id"]: t for t in fake.team_records.values() if provision.probe_slot(t)}

    def test_four_teams_are_made_named_marked_joined_and_granted(self):
        fake = ProbeTeamStack([self.capture()])
        ids, logs = self.run_teams(fake)
        self.assertEqual(sorted(ids), [1, 2, 3, 4])
        for slot, team_id in ids.items():
            team = fake.team_records[team_id]
            self.assertEqual(team["display_name"], f"cmux probe team {slot} (test accounts only)")
            self.assertEqual(provision.probe_slot(team), slot)
            self.assertEqual(team["client_read_only_metadata"], {"cmuxVmPlan": "team"})
            self.assertEqual({u for t, u in fake.memberships if t == team_id}, {"cap"})
        posts = [r for r in fake.requests if r[0] == "POST" and r[1] == "/teams"]
        self.assertEqual(len(posts), 4)
        self.assertTrue(all("creator_user_id" not in r[3] for r in posts))  # no creator defaults for anyone
        joins = [r for r in fake.requests if r[0] == "POST" and r[1].startswith("/team-memberships/")]
        self.assertTrue(all(r[3] == {} for r in joins))
        self.assertEqual(fake.users["cap"]["password"], "kept")  # no rotation
        self.assertFalse([r for r in fake.requests if r[1].startswith("/users/") or r[1] == "/auth/password/sign-in"])
        self.assertTrue(any("is in its own team and 4 probe team(s)" in line for line in logs))

    def test_a_rerun_finds_the_teams_and_makes_none(self):
        fake = ProbeTeamStack([self.capture()])
        first, _ = self.run_teams(fake)
        fake.requests.clear()
        second, logs = self.run_teams(fake)
        self.assertEqual(first, second)
        self.assertEqual(len(self.probe_records(fake)), 4)
        self.assertFalse([r for r in fake.requests if r[0] in ("POST", "PATCH", "DELETE")])
        self.assertTrue(all("found" in line for line in logs if line.startswith("probe team ")))

    def test_growing_from_two_to_four_makes_only_the_missing_slots(self):
        fake = ProbeTeamStack([self.capture()])
        two, _ = self.run_teams(fake, 2)
        four, _ = self.run_teams(fake, 4)
        self.assertEqual({k: four[k] for k in (1, 2)}, two)
        self.assertEqual(len(self.probe_records(fake)), 4)

    def test_fewer_than_exist_leaves_the_others(self):
        fake = ProbeTeamStack([self.capture()])
        self.run_teams(fake, 4)
        ids, logs = self.run_teams(fake, 2)
        self.assertEqual(sorted(ids), [1, 2])
        self.assertEqual(len(self.probe_records(fake)), 4)
        self.assertTrue(any("slot(s) 3, 4 above 2 are left" in line for line in logs))

    def test_an_ungranted_existing_team_gets_the_grant_keeping_its_metadata(self):
        team = {"id": "t1", "display_name": provision.probe_team_name(1), "client_read_only_metadata": {"other": 1},
                "server_metadata": {provision.PROBE_TEAM_KEY: {"slot": 1}}}
        fake = ProbeTeamStack([self.capture()], memberships=[("t1", "cap")], teams=[team])
        ids, _ = self.run_teams(fake, 1)
        self.assertEqual(ids, {1: "t1"})
        self.assertEqual(fake.team_records["t1"]["client_read_only_metadata"], {"other": 1, "cmuxVmPlan": "team"})

    def test_a_team_holding_a_person_is_refused_and_not_granted(self):
        team = {"id": "t1", "display_name": provision.probe_team_name(1), "client_read_only_metadata": {},
                "server_metadata": {provision.PROBE_TEAM_KEY: {"slot": 1}}}
        fake = ProbeTeamStack([self.capture()], memberships=[("t1", "cap"), ("t1", "person")], teams=[team])
        with self.assertRaisesRegex(provision.ProvisionError, "only test accounts"):
            self.run_teams(fake, 1)
        self.assertFalse([r for r in fake.requests if r[0] in ("POST", "PATCH", "DELETE")])

    def test_other_teams_of_the_account_are_never_touched(self):
        other = {"id": "shared", "display_name": "someone's team", "client_read_only_metadata": {},
                 "server_metadata": {}}
        fake = ProbeTeamStack([self.capture()], memberships=[("shared", "cap")], teams=[other])
        self.run_teams(fake, 1)
        self.assertFalse([r for r in fake.requests if "shared" in r[1] and r[0] != "GET"])
        self.assertFalse([r for r in fake.requests if r[1] == "/team-member-profiles?team_id=shared"])

    def test_two_teams_in_one_slot_are_refused(self):
        teams = [{"id": t, "server_metadata": {provision.PROBE_TEAM_KEY: {"slot": 1}}} for t in ("a", "b")]
        fake = ProbeTeamStack([self.capture()], memberships=[("a", "cap"), ("b", "cap")], teams=teams)
        with self.assertRaisesRegex(provision.ProvisionError, "two probe teams claim slot 1"):
            self.run_teams(fake, 1)

    def test_a_team_the_account_could_not_join_is_deleted(self):
        class Refusing(ProbeTeamStack):
            def __call__(self, method, url, headers, body, timeout=None):
                if method == "POST" and "/team-memberships/" in url:
                    return 404, {"x-stack-known-error": "TEAM_NOT_FOUND"}, None
                return super().__call__(method, url, headers, body, timeout)
        fake = Refusing([self.capture()])
        with self.assertRaisesRegex(provision.ProvisionError, "HTTP 404"):
            self.run_teams(fake, 1)
        self.assertEqual(fake.team_records, {})

    def test_a_join_lost_to_a_transport_error_is_deleted_so_a_retry_leaves_one_team_in_the_slot(self):
        # A transport failure (no HTTP status at all) on the join is a failed join too: a URLError before the request
        # reaches Stack leaves an empty team no membership search finds, and a timeout whose request did land leaves a
        # joined one. Either way the team is deleted, so the retry that follows makes the slot's only team.
        class Flaky(ProbeTeamStack):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, **kwargs)
                self.failures = [provision.urllib.error.URLError("connection reset"), TimeoutError("timed out")]

            def __call__(self, method, url, headers, body, timeout=None):
                if method == "POST" and "/team-memberships/" in url and self.failures:
                    error = self.failures.pop(0)
                    if isinstance(error, TimeoutError):  # Stack added the membership; only its answer was lost
                        super().__call__(method, url, headers, body, timeout)
                    raise error
                return super().__call__(method, url, headers, body, timeout)
        fake = Flaky([self.capture()])
        with self.assertRaises(provision.urllib.error.URLError):
            self.run_teams(fake, 1)
        with self.assertRaises(TimeoutError):
            self.run_teams(fake, 1)
        ids, _ = self.run_teams(fake, 1)
        claims = [t for t in fake.team_records.values() if provision.probe_slot(t) == 1]
        self.assertEqual([t["id"] for t in claims], [ids[1]])
        self.assertEqual({t for t, u in fake.memberships if u == "cap"}, {ids[1]})
        self.assertEqual(len([r for r in fake.requests if r[0] == "DELETE"]), 2)

    def test_a_delete_lost_to_a_transport_error_warns_and_the_join_error_stands(self):
        class Unreachable(ProbeTeamStack):
            def __call__(self, method, url, headers, body, timeout=None):
                if method == "POST" and "/team-memberships/" in url:
                    raise provision.urllib.error.URLError("join unreachable")
                if method == "DELETE":
                    raise TimeoutError("delete timed out")
                return super().__call__(method, url, headers, body, timeout)
        fake = Unreachable([self.capture()])
        logs = []
        with self.assertRaisesRegex(provision.urllib.error.URLError, "join unreachable"):
            provision.probe_teams(stack(fake), 1, log=logs.append)
        self.assertTrue(any("the join failed and so did its delete" in line for line in logs))

    def test_main_reports_a_transport_error_as_a_run_error(self):
        env = {"NEXT_PUBLIC_STACK_PROJECT_ID": provision.STAGING_PROJECT_ID, "STACK_SECRET_SERVER_KEY": "s",
               "NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY": "c"}
        out = io.StringIO()
        with mock.patch.dict(os.environ, env), contextlib.redirect_stdout(out), \
                mock.patch.object(provision, "probe_teams", side_effect=TimeoutError("timed out")):
            self.assertEqual(provision.main(["--probe-teams", "1"]), 1)
        self.assertIn("::error::cloud capture provision: TimeoutError: timed out", out.getvalue())

    def test_a_missing_account_is_never_created(self):
        fake = ProbeTeamStack()
        with self.assertRaisesRegex(provision.ProvisionError, "never creates"):
            self.run_teams(fake, 2)
        self.assertFalse([r for r in fake.requests if r[0] != "GET"])

    def test_only_the_capture_target_in_staging_with_a_sane_count(self):
        fake = ProbeTeamStack([self.capture()])
        for count in (0, 10, True, "4"):
            with self.assertRaisesRegex(provision.ProvisionError, "count from 1 to 9"):
                provision.probe_teams(stack(fake), count, log=lambda _: None)
        with self.assertRaisesRegex(provision.ProvisionError, "only the capture target"):
            provision.probe_teams(stack(fake), 2, log=lambda _: None, target=provision.TARGETS["journey"])
        with self.assertRaisesRegex(provision.ProvisionError, "only the capture target"):
            provision.probe_teams(prod_stack(fake), 2, log=lambda _: None, target=provision.TARGETS["production"])
        self.assertEqual(fake.requests, [])

    def test_main_runs_probe_teams_for_capture_only(self):
        env = {"NEXT_PUBLIC_STACK_PROJECT_ID": provision.STAGING_PROJECT_ID, "STACK_SECRET_SERVER_KEY": "k",
               "NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY": "c"}
        with mock.patch.dict(os.environ, env), mock.patch.object(provision, "probe_teams") as teams, \
                mock.patch.object(provision, "provision") as rotate, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(provision.main(["--probe-teams", "4"]), 0)
            self.assertEqual(provision.main(["--target", "journey", "--probe-teams", "4"]), 1)
        rotate.assert_not_called()
        self.assertEqual(teams.call_count, 1)
        self.assertEqual(teams.call_args.args[1], 4)
        self.assertIs(teams.call_args.kwargs["target"], provision.CAPTURE)

    def test_no_target_gains_a_team_id(self):
        # cmux-tui carrier/fault_tests.rs pins PROBE_ACCOUNTS to the targets without team_id; the capture account
        # stays one of them because its probe teams hold only test accounts.
        self.assertIsNone(provision.TARGETS[provision.PROBE_TEAM_TARGET].team_id)

    def test_the_workflow_offers_probe_teams_in_staging_with_no_rotation(self):
        text = (ROOT / ".github" / "workflows" / "cloud-capture-provision.yml").read_text()
        self.assertIn("probe_teams:", text.split("permissions:", 1)[0])
        step = text.split("- name: Make the probe teams only", 1)[1].split("- name:", 1)[0]
        self.assertIn("inputs.probe_teams > 0", step)
        self.assertIn('--target "$TARGET" --probe-teams "$PROBE_TEAMS"', step)
        self.assertIn("secrets.STACK_SECRET_SERVER_KEY", step)
        for name in ("Provision and seal", "Upload the sealed bundle (ciphertext only)", "libsodium",
                     "Grant the operator plan only", "Join the company team only"):
            guard = text.split(f"- name: {name}", 1)[1].split("\n", 2)[1]
            self.assertIn("inputs.probe_teams == 0", guard, name)


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

    def test_a_bundle_with_no_environment_goes_to_the_repository_secrets(self):
        bundle = self.BUNDLE | {"environment": None}
        calls, run = self.fake_gh({"key_id": "42", "key": self.BUNDLE["key"]})
        sealed_secrets.put(bundle, run=run, log=lambda _: None)
        self.assertEqual(calls[0][-1], "repos/o/r/actions/secrets/public-key")
        self.assertEqual(calls[1][:5], ["gh", "api", "-X", "PUT", "repos/o/r/actions/secrets/A_SECRET"])
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "b.json"
            path.write_text(json.dumps(bundle))
            self.assertIsNone(sealed_secrets.read_bundle(path)["environment"])
            path.write_text(json.dumps(self.BUNDLE | {"environment": ""}))
            with self.assertRaisesRegex(sealed_secrets.SealError, "environment is not valid"):
                sealed_secrets.read_bundle(path)

    def test_a_bundle_with_a_short_value_is_not_a_sealed_box(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "b.json"
            path.write_text(json.dumps(self.BUNDLE | {"secrets": {"A": base64.b64encode(b"x").decode()}}))
            with self.assertRaisesRegex(sealed_secrets.SealError, "not a sealed box"):
                sealed_secrets.read_bundle(path)


if __name__ == "__main__":
    unittest.main()
