#!/usr/bin/env python3
"""The warm nightly-next checkout reads GitHub only with the release App's token, never anonymously.

Run 45744507889 (11-26, job "nightly-next-one") failed in "Checkout build ref (warm nightly-next
builder)": its anonymous curl of raw.githubusercontent.com for git_fetch_retry.py got 429 four times and
its anonymous `git fetch` got 403, GitHub's unauthenticated per-IP limit, shared by every job on the Mac.

So the step takes the helper from local objects only, and every github.com transfer it still makes (the
build commit the mirror lacks, submodules a warm slot lacks) carries a read-only installation token of the
release App, minted for this checkout alone in nightly-next-one after the signing-runner claim. Never the
shared cmux-bot token, never the job's GITHUB_TOKEN, never anonymous: a job with no token (build-nightly-app,
whose environment holds no release App key) reads the mirror and refuses the GitHub fetch.

This test reads the steps from nightly.yml and runs the warm step's own `run:` text with the harness of
tests/test_nightly_warm_checkout_borrows_mirror.py (temp mirror, empty slot, local origin). Run it after
changing that step or the mint step: python3 tests/test_nightly_warm_checkout_app_token.py (a few seconds,
git only, no network, no Mac).
"""
from __future__ import annotations

import base64
import importlib.util
import os
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("warm_borrows_mirror", HERE / "test_nightly_warm_checkout_borrows_mirror.py")
harness = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(harness)

JOBS, WARM_STEP, step = harness.JOBS, harness.WARM_STEP, harness.step
MINT_STEP = "Mint the release App token for the warm checkout"
CLAIM = "bash .publish-tooling/scripts/ci/signing-runner-claim.sh"

# Ahead of git: log the auth header every top-level fetch from origin carries, then run git.
HEADER_LOG_GIT = """#!/bin/sh
case " $* " in *" fetch "*" origin "*) echo "origin-fetch: ${GIT_CONFIG_KEY_0:-none} ${GIT_CONFIG_VALUE_0:-none}" >> "$HEADER_LOG" ;; esac
exec "$INNER_GIT" "$@"
"""


class MintStep(unittest.TestCase):
    def steps(self) -> list[dict]:
        return JOBS["nightly-next-one"]["steps"]

    def test_the_helper_never_comes_from_raw_githubusercontent(self) -> None:
        for job in ("build-nightly-app", "nightly-next-one"):
            with self.subTest(job=job):
                script = "\n".join(line for line in step(job, WARM_STEP)["run"].splitlines()
                                    if not line.lstrip().startswith("#"))
                self.assertNotIn("raw.githubusercontent.com", script)
                self.assertNotIn("curl", script)

    def test_the_warm_checkout_reads_only_the_minted_token(self) -> None:
        self.assertEqual(step("build-nightly-app", WARM_STEP)["env"]["FETCH_TOKEN"], "${{ github.token }}")
        env = step("nightly-next-one", WARM_STEP)["env"]
        # The release App's token; the job's own only where no step minted one, never anonymous.
        self.assertEqual(env["FETCH_TOKEN"], "${{ steps.warm-fetch-token.outputs.token || github.token }}")
        for key, value in ((k, str(v)) for k, v in env.items() if k != "FETCH_TOKEN"):
            self.assertNotIn("GITHUB_TOKEN", value)
            self.assertNotIn("github.token", value)
            self.assertNotIn("CMUX_BOT", value.upper())

    def test_the_token_is_the_release_apps_read_only_one(self) -> None:
        mint = step("nightly-next-one", MINT_STEP)
        self.assertEqual(mint["id"], "warm-fetch-token")
        self.assertTrue(mint["uses"].startswith("actions/create-github-app-token@"))
        self.assertEqual(mint["with"]["app-id"], "${{ secrets.CMUX_RELEASE_APP_ID }}")
        self.assertEqual(mint["with"]["private-key"], "${{ secrets.CMUX_RELEASE_APP_KEY }}")
        self.assertEqual(mint["with"]["permission-contents"], "read")
        self.assertEqual(set(k for k in mint["with"] if k.startswith("permission-")), {"permission-contents"})

    def test_the_mint_comes_after_the_claim_and_before_the_checkout(self) -> None:
        names = [s.get("name") for s in self.steps()]
        claim = next(i for i, s in enumerate(self.steps()) if CLAIM in str(s.get("run", "")))
        self.assertLess(claim, names.index(MINT_STEP))
        self.assertEqual(names.index(MINT_STEP) + 1, names.index(WARM_STEP))
        # The claim's tooling checkout survives the warm step's clean.
        self.assertIn("-e /.publish-tooling/", step("nightly-next-one", WARM_STEP)["run"])

    def test_submodules_try_local_objects_with_https_refused_first(self) -> None:
        script = step("nightly-next-one", WARM_STEP)["run"]
        local = script.index("-c protocol.https.allow=never -c core.hooksPath=/dev/null submodule update --init --force --no-fetch")
        self.assertLess(local, script.index("submodule update --init --force --depth=1"))
        self.assertLess(script.index('elif [ -n "${FETCH_TOKEN:-}" ]; then'),
                        script.index("submodule update --init --force --depth=1"))


class WarmCheckoutAppToken(unittest.TestCase):
    setUp = harness.WarmCheckoutBorrowsMirrorTest.setUp
    git = harness.WarmCheckoutBorrowsMirrorTest.git
    commit = harness.WarmCheckoutBorrowsMirrorTest.commit
    commit_after_mirror = harness.WarmCheckoutBorrowsMirrorTest.commit_after_mirror
    fetches = harness.WarmCheckoutBorrowsMirrorTest.fetches
    _run_warm_step = harness.WarmCheckoutBorrowsMirrorTest.run_warm_step

    def run_warm_step(self, **kwargs):
        self.header_log = self.temp / "headers.log"
        wrapper = self.temp / "header-git"
        wrapper.write_text(HEADER_LOG_GIT)
        wrapper.chmod(0o755)
        self.env = {**self.env, "HEADER_LOG": str(self.header_log), "INNER_GIT": harness.REAL_GIT}
        with mock.patch.object(harness, "REAL_GIT", str(wrapper)):
            return self._run_warm_step(**kwargs)

    def headers(self) -> list[str]:
        return self.header_log.read_text().splitlines() if self.header_log.exists() else []

    def test_a_fetch_from_github_carries_the_app_token(self) -> None:
        sha = self.commit_after_mirror()
        result = self.run_warm_step(sha=sha, FETCH_TOKEN="app-token-123")
        expected = base64.b64encode(b"x-access-token:app-token-123").decode()
        self.assertEqual(self.headers(), [f"origin-fetch: http.https://github.com/.extraheader AUTHORIZATION: basic {expected}"])
        encoded = base64.b64encode(b"x-access-token:app-token-123").decode()
        self.assertIn(f"::add-mask::{encoded}", result.stdout)
        self.assertIn(f"commit={sha} source=github", result.stdout)

    def test_without_a_token_the_step_refuses_github_instead_of_fetching_anonymously(self) -> None:
        result = self.run_warm_step(sha=self.commit_after_mirror(), FETCH_TOKEN="", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing an anonymous fetch from GitHub", result.stdout)
        self.assertEqual(self.fetches(), [], "the step fetched from origin with no token")

    def test_without_a_token_a_build_the_mirror_holds_still_checks_out(self) -> None:
        result = self.run_warm_step(FETCH_TOKEN="")
        self.assertEqual(self.fetches(), [])
        self.assertEqual(self.headers(), [])
        self.assertIn("source=mirror", result.stdout)

    def test_the_helper_comes_from_the_mirror_when_the_slot_lacks_the_workflow_commit(self) -> None:
        # curl is a stub that fails: a helper that still loads came from local objects.
        result = self.run_warm_step(sha=self.commit_after_mirror(), FETCH_TOKEN="t")
        self.assertNotIn("git_fetch_retry.py unavailable", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
