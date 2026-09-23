#!/usr/bin/env python3
"""Regression coverage for the persistent-Mac compile-admission pilot."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
ROUTE = ROOT / "scripts/ci/persistent_mac_route.py"
CI = ROOT / ".github/workflows/ci.yml"
MACOS_CI = ROOT / ".github/workflows/ci-macos.yml"
PRODUCER = ROOT / ".github/workflows/persistent-macos-compile.yml"
ROUTER = ROOT / ".github/workflows/persistent-macos-router.yml"
PROFILE = ROOT / "glaeda.apple.json"
DRIVER = ROOT / "scripts/ci/run-persistent-mac-compile.py"


spec = importlib.util.spec_from_file_location("persistent_mac_route", ROUTE)
route = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(route)


driver_spec = importlib.util.spec_from_file_location("persistent_mac_driver", DRIVER)
driver = importlib.util.module_from_spec(driver_spec)
assert driver_spec.loader is not None
driver_spec.loader.exec_module(driver)


HEAD_SHA = "a" * 40
SOURCE_SHA = "b" * 40
SOURCE_PARENT1 = "c" * 40
SOURCE_TREE = "d" * 40


def args(**overrides):
    values = {
        "selector": "pilot",
        "event_name": "pull_request",
        "head_repository": "manaflow-ai/cmux",
        "repository": "manaflow-ai/cmux",
        "author_association": "MEMBER",
        "cohort": "13198,feature/persistent",
        "pr_number": "13198",
        "head_ref": "feature/persistent",
        "head_sha": HEAD_SHA,
        "source_sha": SOURCE_SHA,
        "source_parent1": SOURCE_PARENT1,
        "source_tree": SOURCE_TREE,
    }
    values.update(overrides)
    return argparse.Namespace(**values)


def live_pull_request(**overrides):
    """The live GitHub observation that matches the request envelope exactly."""
    payload = {
        "state": "open",
        "author_association": "MEMBER",
        "head": {"sha": HEAD_SHA, "repo": {"full_name": "manaflow-ai/cmux"}},
        "base": {"sha": SOURCE_PARENT1},
        "merge_commit_sha": SOURCE_SHA,
    }
    payload.update(overrides)
    return payload


class FakeGitHub:
    """Serves canned `gh api` payloads and records the exact paths requested."""

    def __init__(self, payloads: dict[str, object]):
        self.payloads = payloads
        self.paths: list[str] = []

    def api(self, path: str, *, method: str = "GET") -> object:
        self.paths.append(path)
        try:
            return self.payloads[path]
        except KeyError:  # pragma: no cover - a miss is always a test bug
            raise AssertionError(f"unexpected API read: {path}") from None


class RoutingTests(unittest.TestCase):
    def test_retry_wait_retries_with_bounded_backoff_without_fixed_sleep(self):
        current = [0.0]
        waits = []
        probes = []

        def clock():
            return current[0]

        def wait(delay):
            waits.append(delay)
            current[0] += delay
            return False

        waiter = route.RetryWait(clock=clock, wait=wait)

        def probe():
            probes.append(current[0])
            return (len(probes) == 3, "ready" if len(probes) == 3 else None)

        self.assertEqual(waiter.until(10.0, probe), "ready")
        self.assertEqual(len(probes), 3)
        self.assertEqual(waits, [0.5, 1.0])

    def test_retry_wait_is_cancellation_aware(self):
        waiter = route.RetryWait()
        waiter.cancel()
        with self.assertRaises(route.RetryCancelled):
            waiter.until(route.now() + 10, lambda: (False, None))

    def test_cancelled_router_retries_until_owned_producer_is_observable(self):
        current = [0.0]
        waits = []

        def clock():
            return current[0]

        def wait(delay):
            waits.append(delay)
            current[0] += delay
            return False

        waiter = route.RetryWait(clock=clock, wait=wait)
        api = object()
        with (
            mock.patch.object(
                route,
                "matching_run",
                side_effect=[None, {"id": 77}],
            ) as matching,
            mock.patch.object(route, "cancel") as cancel,
        ):
            run_id = route.cancel_owned_producer(
                api,
                "request",
                None,
                True,
                waiter,
                5.0,
            )

        self.assertEqual(run_id, 77)
        self.assertEqual(matching.call_count, 2)
        self.assertEqual(waits, [0.25])
        cancel.assert_called_once_with(api, 77)

    def test_ready_only_contract_is_explicit(self):
        source = ROUTE.read_text()
        self.assertIn('"--ready-only"', source)
        self.assertIn("args.ready_only and not args.observe_only", source)
        self.assertIn('if args.ready_only:', source)
        self.assertIn('"producer_not_ready"', source)
        self.assertIn("selected = compile_job(api, run_id)", source)
        self.assertIn('selected.get("status") != "completed"', source)

    def test_only_trusted_same_repository_maintainers_are_eligible(self):
        self.assertEqual(route.eligibility(args()), (True, "pilot"))
        self.assertEqual(route.eligibility(args(author_association="OWNER")), (True, "pilot"))
        # COLLABORATOR routes no further than the producer would admit it.
        self.assertEqual(
            route.eligibility(args(author_association="COLLABORATOR")),
            (False, "untrusted_author"),
        )
        self.assertEqual(
            route.eligibility(args(head_repository="someone/cmux")),
            (False, "untrusted_repository"),
        )
        self.assertEqual(
            route.eligibility(args(author_association="CONTRIBUTOR")),
            (False, "untrusted_author"),
        )
        self.assertEqual(
            route.eligibility(args(event_name="merge_group")),
            (False, "event_not_pull_request"),
        )

    def test_selector_and_cohort_are_reversible(self):
        for selector in ("", "0", "off", "false"):
            self.assertEqual(route.eligibility(args(selector=selector)), (False, "selector_off"))
        self.assertEqual(
            route.eligibility(args(pr_number="99", head_ref="other")),
            (False, "outside_pilot_cohort"),
        )
        self.assertEqual(route.eligibility(args(selector="all", cohort="")), (True, "all"))
        self.assertEqual(
            route.eligibility(args(selector="unexpected")),
            (False, "invalid_selector"),
        )

    def test_route_budget_always_fits_controller_window(self):
        self.assertTrue(route.valid_budget(90, 480))
        self.assertTrue(route.valid_budget(120, 480))
        self.assertFalse(route.valid_budget(121, 480))
        self.assertFalse(route.valid_budget(120, 481))
        self.assertFalse(route.valid_budget(120, 500))

    def test_live_reverification_accepts_only_the_exact_requested_source(self):
        # The route request artifact is published by the PR-side `changes` job,
        # so by the time the default-branch router reads it the pull request may
        # already have moved. `verify_live_request` is the whole defence: it
        # re-reads the live PR and refuses to spend an owned-Mac allocation on
        # anything but the exact commit, tree, base and author it was asked for.
        paths = {
            f"pulls/{args().pr_number}": live_pull_request(),
            f"git/commits/{SOURCE_SHA}": {"tree": {"sha": SOURCE_TREE}},
        }
        api = FakeGitHub(paths)
        self.assertEqual(route.verify_live_request(api, args()), (True, "verified"))
        self.assertEqual(
            api.paths,
            [f"pulls/{args().pr_number}", f"git/commits/{SOURCE_SHA}"],
        )

        # Each stale or untrusted observation names itself, so the hosted
        # fallback reason in the metrics says which invariant moved.
        stale = {
            "pr_closed": live_pull_request(state="closed"),
            "untrusted_repository": live_pull_request(
                head={"sha": HEAD_SHA, "repo": {"full_name": "someone/cmux"}}
            ),
            "untrusted_author": live_pull_request(author_association="COLLABORATOR"),
            "head_changed": live_pull_request(
                head={"sha": "e" * 40, "repo": {"full_name": "manaflow-ai/cmux"}}
            ),
            "base_changed": live_pull_request(base={"sha": "f" * 40}),
            "merge_changed": live_pull_request(merge_commit_sha="0" * 40),
        }
        for reason, payload in stale.items():
            with self.subTest(reason=reason):
                api = FakeGitHub({f"pulls/{args().pr_number}": payload})
                self.assertEqual(route.verify_live_request(api, args()), (False, reason))
                # A refused PR observation never costs a second API read.
                self.assertEqual(api.paths, [f"pulls/{args().pr_number}"])

        # A merge commit that kept its SHA but not its tree is still stale.
        api = FakeGitHub(
            {
                f"pulls/{args().pr_number}": live_pull_request(),
                f"git/commits/{SOURCE_SHA}": {"tree": {"sha": "9" * 40}},
            }
        )
        self.assertEqual(route.verify_live_request(api, args()), (False, "tree_changed"))

        for commit in ({}, {"tree": {}}, "not-a-commit"):
            with self.subTest(commit=commit):
                api = FakeGitHub(
                    {
                        f"pulls/{args().pr_number}": live_pull_request(),
                        f"git/commits/{SOURCE_SHA}": commit,
                    }
                )
                self.assertEqual(
                    route.verify_live_request(api, args()), (False, "tree_changed")
                )

        # An unreadable PR body is a refusal, not a crash and not a pass.
        for payload in ([], "", None):
            with self.subTest(payload=payload):
                api = FakeGitHub({f"pulls/{args().pr_number}": payload})
                self.assertEqual(
                    route.verify_live_request(api, args()), (False, "pr_observation_invalid")
                )

        # Repository comparison is case-insensitive, matching `eligibility`.
        api = FakeGitHub(
            {
                f"pulls/{args().pr_number}": live_pull_request(
                    head={"sha": HEAD_SHA, "repo": {"full_name": "Manaflow-AI/CMUX"}}
                ),
                f"git/commits/{SOURCE_SHA}": {"tree": {"sha": SOURCE_TREE}},
            }
        )
        self.assertEqual(route.verify_live_request(api, args()), (True, "verified"))

    def test_producer_discovery_requires_the_exact_dispatch_title_on_main(self):
        # The producer is found by its run-name, so a run dispatched from any
        # other ref, or for any other request, must never be adopted: its
        # artifact would be a compile of source this router did not verify.
        request_id = "4242-1"
        title = f"persistent-mac-compile-{request_id}"
        listing = "actions/workflows/persistent-macos-compile.yml/runs?event=workflow_dispatch&per_page=50"

        def api_for(runs):
            return FakeGitHub({listing: {"workflow_runs": runs}})

        self.assertIsNone(route.matching_run(api_for([]), request_id))
        self.assertIsNone(
            route.matching_run(
                api_for([{"id": 1, "display_title": title, "head_branch": "attacker"}]),
                request_id,
            )
        )
        self.assertIsNone(
            route.matching_run(
                api_for(
                    [
                        {
                            "id": 1,
                            "display_title": "persistent-mac-compile-9999-1",
                            "head_branch": "main",
                        }
                    ]
                ),
                request_id,
            )
        )

        # A redispatch of the same request adopts the newest run.
        newest = route.matching_run(
            api_for(
                [
                    {"id": 10, "display_title": title, "head_branch": "main"},
                    {"id": 30, "display_title": title, "head_branch": "main"},
                    {"id": 20, "display_title": title, "head_branch": "main"},
                    {"id": 40, "display_title": title, "head_branch": "topic"},
                ]
            ),
            request_id,
        )
        self.assertIsNotNone(newest)
        self.assertEqual(newest["id"], 30)

    def test_output_helpers_record_hosted_fallback_and_persistent_success(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            output.touch()
            self.assertEqual(route.fallback(output, "queue_timeout", producer_run_id=42), 0)
            values = dict(line.split("=", 1) for line in output.read_text().splitlines())
            self.assertEqual(values["use_persistent"], "false")
            self.assertEqual(values["fallback_reason"], "queue_timeout")
            self.assertEqual(values["producer_run_id"], "42")

            output.write_text("")
            self.assertEqual(
                route.success(
                    output,
                    run_id=43,
                    artifact_id=99,
                    queue_seconds=1.25,
                    allocated_seconds=31.5,
                ),
                0,
            )
            values = dict(line.split("=", 1) for line in output.read_text().splitlines())
            self.assertEqual(values["use_persistent"], "true")
            self.assertEqual(values["producer_run_id"], "43")
            self.assertEqual(values["artifact_id"], "99")
            self.assertEqual(values["queue_to_start_seconds"], "1.25")
            self.assertEqual(values["producer_allocated_seconds"], "31.5")


class StateRetentionTests(unittest.TestCase):
    def test_quarantine_pruning_keeps_only_newest_owned_store(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            glaeda = project / ".glaeda"
            glaeda.mkdir()
            old = []
            for index in range(3):
                path = glaeda / f"apple-build-quarantine-run-{index}"
                path.mkdir()
                (path / "marker").write_text(str(index))
                os_time = 1_000_000_000 + index
                path.touch()
                import os
                os.utime(path, ns=(os_time, os_time))
                old.append(path)
            unrelated = glaeda / "unrelated"
            unrelated.mkdir()

            driver.prune_quarantine_stores(project)

            remaining = sorted(glaeda.glob("apple-build-quarantine-*"))
            self.assertEqual(len(remaining), driver.QUARANTINE_RETAINED_STORES)
            self.assertEqual(remaining[0].name, old[-1].name)
            self.assertTrue(unrelated.is_dir())

    @staticmethod
    def _cache_generation(root: Path, index: int, mtime: int) -> Path:
        """A fake Glaeda cache generation: a 64-hex key holding a DerivedData tree."""
        path = root / f"{index:064x}"
        (path / "derived_data" / "Build" / "Products" / "Debug").mkdir(parents=True)
        (path / "derived_data" / "cmux-build.log").write_text(str(index))
        os.utime(path, ns=(mtime, mtime))
        return path

    def test_cache_pruning_keeps_the_current_and_most_recent_generations(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            cache = project / ".glaeda" / "apple-build" / "cache"
            cache.mkdir(parents=True)
            # index 0 is oldest, index 5 newest; the current run uses the oldest,
            # which must survive precisely because it is the one in use.
            generations = [
                self._cache_generation(cache, index, 1_000_000_000 + index)
                for index in range(6)
            ]
            current = generations[0]
            # Neither of these is a cache key, so neither may ever be a candidate.
            stray_file = cache / "README"
            stray_file.write_text("not a generation")
            stray_dir = cache / "scratch"
            stray_dir.mkdir()

            pruned = driver.prune_cache_generations(project, keep_key=current.name)

            survivors = {path.name for path in cache.iterdir()}
            expected = {
                current.name,
                generations[-1].name,
                generations[-2].name,
                stray_file.name,
                stray_dir.name,
            }
            self.assertEqual(survivors, expected)
            self.assertEqual(
                sorted(pruned),
                sorted(path.name for path in generations[1:-2]),
            )
            self.assertTrue((current / "derived_data" / "cmux-build.log").is_file())
            self.assertEqual(
                len(survivors) - 2, driver.CACHE_RETAINED_GENERATIONS
            )

    def test_cache_pruning_never_evicts_the_generation_in_use(self):
        """Even as the least recently used generation, the current key survives."""
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            cache = project / ".glaeda" / "apple-build" / "cache"
            cache.mkdir(parents=True)
            generations = [
                self._cache_generation(cache, index, 1_000_000_000 + index)
                for index in range(driver.CACHE_RETAINED_GENERATIONS + 2)
            ]
            oldest = generations[0]

            driver.prune_cache_generations(project, keep_key=oldest.name)

            self.assertTrue(oldest.is_dir())
            self.assertTrue((oldest / "derived_data" / "cmux-build.log").is_file())

    def test_cache_pruning_is_a_noop_below_the_retention_bound(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            cache = project / ".glaeda" / "apple-build" / "cache"
            cache.mkdir(parents=True)
            generations = [
                self._cache_generation(cache, index, 1_000_000_000 + index)
                for index in range(driver.CACHE_RETAINED_GENERATIONS)
            ]

            self.assertEqual(
                driver.prune_cache_generations(project, keep_key=generations[0].name), []
            )
            self.assertEqual(
                {path.name for path in cache.iterdir()},
                {path.name for path in generations},
            )

    def test_cache_pruning_tolerates_an_absent_cache_root(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(driver.prune_cache_generations(Path(directory)), [])

    def test_cache_pruning_unlinks_generation_symlinks_without_following_them(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            cache = project / ".glaeda" / "apple-build" / "cache"
            cache.mkdir(parents=True)
            outside = project / "outside"
            (outside / "derived_data").mkdir(parents=True)
            (outside / "derived_data" / "treasure").write_text("keep me")
            # Oldest entry is a symlink out of the cache root.
            link = cache / f"{0:064x}"
            link.symlink_to(outside, target_is_directory=True)
            os.utime(link, ns=(1_000_000_000, 1_000_000_000), follow_symlinks=False)
            newer = [
                self._cache_generation(cache, index, 1_000_000_100 + index)
                for index in range(1, driver.CACHE_RETAINED_GENERATIONS + 2)
            ]

            pruned = driver.prune_cache_generations(project, keep_key=newer[-1].name)

            self.assertIn(link.name, pruned)
            self.assertFalse(link.is_symlink())
            self.assertTrue((outside / "derived_data" / "treasure").is_file())

    def test_driver_prunes_cache_generations_after_a_verified_compile(self):
        source = DRIVER.read_text()
        prune = source.index("    pruned_cache_generations = prune_cache_generations(")
        self.assertIn("os.utime(resolved_cache)", source[:prune])
        # Eviction must follow every check that proves the current generation.
        for guard in (
            'raise Refusal("Glaeda cache locator escaped the project cache root")',
            'raise Refusal("Glaeda DerivedData escaped the admitted cache generation")',
            'raise Refusal("native compile completed without the admission log/products")',
        ):
            self.assertLess(source.index(guard), prune)
        self.assertIn('"pruned_cache_generations": pruned_cache_generations', source)


class WorkflowContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ci = CI.read_text()
        cls.macos_ci = MACOS_CI.read_text()
        cls.producer = PRODUCER.read_text()
        cls.router = ROUTER.read_text()
        cls.driver = DRIVER.read_text()
        cls.profile = json.loads(PROFILE.read_text())

    @staticmethod
    def _python_association_set(source: str) -> set[str]:
        """Every Python set literal of author associations found in `source`."""
        found: list[set[str]] = []
        for literal in re.findall(r"\{[^{}]*\}", source):
            names = re.findall(r"\"([A-Z][A-Z_]+)\"", literal)
            if "MEMBER" in names or "OWNER" in names or "COLLABORATOR" in names:
                found.append(set(names))
        if not found:
            raise AssertionError("no author-association set literal found")
        if any(names != found[0] for names in found):
            raise AssertionError(f"author-association sets disagree within one file: {found}")
        return found[0]

    @staticmethod
    def _workflow_gate_association_set(gate: str) -> set[str]:
        """Associations admitted by a `github.event.pull_request` workflow gate."""
        names = set(
            re.findall(r"github\.event\.pull_request\.author_association == '([A-Z_]+)'", gate)
        )
        if not names:
            raise AssertionError("no author-association gate found")
        return names

    def test_every_author_association_gate_matches_the_producer(self):
        """The producer refuses anything it is not shown; no gate ahead of it may be wider.

        A routing gate wider than the producer's `authorize` job still fails
        safe, but it dispatches a producer that is certain to refuse -- wasting
        an owned-Mac allocation and reporting producer_failure instead of
        falling straight through to the hosted path. Each set below is derived
        from its own source file so the four cannot drift apart again.
        """
        producer_gate = self.producer.split("  authorize:", 1)[1].split("\n  compile:", 1)[0]
        producer = self._python_association_set(producer_gate)
        self.assertTrue(producer, "producer admitted no author association")

        router_script = self._python_association_set(ROUTE.read_text())
        self.assertEqual(router_script, producer)
        self.assertEqual(set(route.TRUSTED_AUTHOR_ASSOCIATIONS), producer)

        request_gate = self.ci.split("      - name: Publish persistent Mac route request", 1)[1]
        request_gate = request_gate.split("\n        env:", 1)[0]
        self.assertEqual(self._workflow_gate_association_set(request_gate), producer)

        observe_gate = self.macos_ci.split(
            "      - name: Observe persistent Mac compile candidate", 1
        )[1].split("\n        env:", 1)[0]
        self.assertEqual(self._workflow_gate_association_set(observe_gate), producer)

    def test_producer_is_manual_dedicated_and_credential_minimized(self):
        self.assertIn("  workflow_dispatch:", self.producer)
        for trigger in ("pull_request:", "pull_request_target:", "push:", "schedule:", "merge_group:"):
            self.assertNotIn(f"  {trigger}", self.producer)
        self.assertEqual(
            self.producer.count("      group: cmux-persistent-compile"),
            1,
        )
        self.assertEqual(self.producer.split("on:", 1)[1].split("permissions:", 1)[0].count("  workflow_dispatch:"), 1)
        self.assertIn("\npermissions: {}\n", self.producer)
        self.assertIn("      labels: [self-hosted, macOS, ARM64, cmux-persistent-macos-compile]", self.producer)
        self.assertIn("  compile:", self.producer)
        compile_block = self.producer.split("  compile:", 1)[1]
        self.assertIn("    permissions: {}", compile_block)
        self.assertNotIn("secrets.", self.producer)
        self.assertNotIn("actions/checkout@", self.producer)
        self.assertRegex(self.producer, r"(?m)^      GLAEDA_REF: [a-f0-9]{40}$")

    def test_dispatch_authority_is_default_branch_only(self):
        self.assertIn("  workflow_run:", self.router)
        self.assertIn("    workflows: [CI]", self.router)
        # `requested` fires once per CI run. `in_progress` fires again for every
        # CI job that starts, and each of those notifications created a router
        # run that the job condition then skipped. Match the whole trigger block,
        # so `types: [requested, in_progress]` cannot satisfy this.
        self.assertIn(
            "on:\n  workflow_run:\n    workflows: [CI]\n    types: [requested]\n",
            self.router,
        )
        self.assertNotIn("in_progress]", self.router)
        self.assertIn("\npermissions: {}\n", self.router)
        self.assertIn("      actions: write", self.router)
        self.assertIn("          ref: main", self.router)
        self.assertIn("persistent-mac-route-request-", self.router)
        # Attaching at `requested` means the wait starts before CI has a job, so
        # it has to outlast CI's queue and end on its own when CI finishes
        # without publishing a request.
        self.assertIn("deadline=$(( $(date +%s) + 600 ))", self.router)
        self.assertIn('if [ "$status" = "completed" ]; then', self.router)
        # The wait and the bounded compile that follows it both have to fit
        # inside the job, or the router is killed after dispatching an owned Mac.
        self.assertIn("    timeout-minutes: 25", self.router)
        # One `requested` notification is the only one: a transient API error
        # must not end the route.
        self.assertIn('per_page=100" 2>/dev/null || true)', self.router)
        # A fork can never satisfy the request envelope, so it must not hold a
        # runner for the length of the wait.
        self.assertIn(
            "github.event.workflow_run.head_repository.full_name == github.repository",
            self.router,
        )
        self.assertNotIn("actions: write", self.ci)
        admission = self.macos_ci.split("  macos-compile-admission:", 1)[1].split(
            "  app-host-unit-tests:", 1
        )[0]
        self.assertNotIn("  persistent-mac-compile-route:", self.ci)
        self.assertIn("      actions: read", admission)
        self.assertIn("      pull-requests: read", admission)
        self.assertIn("--observe-only", admission)
        self.assertIn("--ready-only", admission)
        self.assertNotIn("--queue-seconds \"$queue_seconds\"", admission.split("Observe persistent Mac compile candidate", 1)[1].split("Download persistent Mac compile product", 1)[0])

    def test_ci_routes_only_trusted_prs_and_preserves_hosted_fallback(self):
        admission = self.macos_ci.split("  macos-compile-admission:", 1)[1].split(
            "  app-host-unit-tests:", 1
        )[0]
        self.assertIn("vars.CI_PERSISTENT_MAC_COMPILE", admission)
        self.assertIn("persistent-mac-route-request-", self.ci)
        self.assertIn("source_identity_valid: ${{ steps.source-identity.outputs.valid }}", self.ci)
        self.assertIn("steps.source-identity.outputs.valid == 'true'", self.ci)
        self.assertIn("inputs.source_identity_valid == 'true'", admission)
        self.assertIn("github.event.pull_request.head.repo.full_name == github.repository", admission)
        self.assertIn("github.event.pull_request.author_association == 'MEMBER'", admission)
        self.assertIn("github.event.pull_request.author_association == 'OWNER'", admission)
        self.assertNotIn("github.event.pull_request.author_association == 'COLLABORATOR'", admission)
        self.assertNotIn("- persistent-mac-compile-route", admission)
        self.assertIn("steps.persistent-restore.outputs.hit != 'true'", admission)
        self.assertIn("actions/download-artifact@37930b1c2abaa49bbe596cd826c3c89aef350131", admission)
        self.assertIn("run-id: ${{ steps.persistent-route.outputs.producer_run_id }}", admission)

    def test_stale_pull_request_rerun_is_rejected_before_compile_setup(self):
        admission = self.macos_ci.split("  macos-compile-admission:", 1)[1].split(
            "  app-host-unit-tests:", 1
        )[0]
        guard_start = admission.index("      - name: Reject stale pull request rerun")
        guard = admission[guard_start:].split("\n      - name:", 1)[0]
        self.assertIn("if: ${{ github.event_name == 'pull_request' }}", guard)
        self.assertIn('gh api "repos/$GITHUB_REPOSITORY/actions/runs/$RUN_ID"', guard)
        self.assertIn('gh api "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER"', guard)
        self.assertIn('current_head" != "$run_head"', guard)
        self.assertIn("continuing with normal CI", guard)
        self.assertIn("exit 1", guard)
        self.assertLess(guard_start, admission.index("      - name: Start compile admission timers"))
        self.assertLess(guard_start, admission.index("      - name: Clear stale git locks"))
        self.assertLess(guard_start, admission.index("      - name: Checkout"))


    def test_admission_total_does_not_double_count_route_observation(self):
        admission = self.macos_ci.split("  macos-compile-admission:", 1)[1].split(
            "  app-host-unit-tests:", 1
        )[0]
        self.assertIn(
            '"total_macos_compile_admission_seconds": number("ADMISSION_SECONDS")',
            admission,
        )
        self.assertNotIn(
            '(number("ROUTE_WALL_SECONDS") or 0.0) + (number("ADMISSION_SECONDS") or 0.0)',
            admission,
        )

    def _admission_step(self, name: str) -> str:
        admission = self.macos_ci.split("  macos-compile-admission:", 1)[1].split(
            "  app-host-unit-tests:", 1
        )[0]
        start = admission.index(f"      - name: {name}")
        return admission[start:].split("\n      - name:", 1)[0]

    def test_refused_persistent_product_leaves_no_bytes_for_the_fallback_compile(self):
        """A refused product must not become the fallback compile's input.

        Every identity check in this step runs *after* the archive has been expanded
        into `CMUX_COMPILE_ADMISSION_DERIVED_DATA` and relocated by
        `app_host_test_products.py restore`. The step is `continue-on-error`, and the
        compile steps that replace it are gated only on
        `steps.persistent-restore.outputs.hit != 'true'` -- they run in that same
        DerivedData. So a refusal that leaves the tree in place hands unvalidated
        producer output to the compile that was supposed to replace it.

        `reuse_app_host_products.py` already states this rule for the artifact path
        ("a miss never leaves partial products in DerivedData") and removes the tree
        on any error. The owned-Mac path needs the same property, and it needs it
        armed before the first byte is written rather than on individual error paths.
        """
        step = self._admission_step("Revalidate persistent Mac compile product")
        self.assertIn("continue-on-error: true", step)
        self.assertIn('rm -rf "$CMUX_COMPILE_ADMISSION_DERIVED_DATA"', step)
        self.assertLess(
            step.index("trap "),
            step.index('tar -xzf "$archive"'),
            "cleanup must be armed before anything is extracted",
        )
        # The cleanup must key off this step reaching its own success, not off the
        # shell merely exiting: `set -e` aborts inside the identity checks exit
        # non-zero, but so would a later unrelated failure after a genuine hit.
        self.assertIn("revalidated=true", step)
        self.assertLess(
            step.index("revalidated=true"),
            step.index('echo "hit=true"'),
            "success must be recorded before the hit is published",
        )

    def test_persistent_product_revalidation_retains_admission_checks(self):
        admission = self.macos_ci.split("  macos-compile-admission:", 1)[1].split(
            "  app-host-unit-tests:", 1
        )[0]
        self.assertIn("persistent producer source identity mismatch", admission)
        self.assertIn("Package.resolved identity mismatch", admission)
        self.assertIn("submodule identity mismatch", admission)
        self.assertIn("Xcode identity mismatch", admission)
        self.assertIn("macOS SDK build mismatch", admission)
        self.assertIn("python3 scripts/swift_warning_budget.py", admission)
        self.assertIn("python3 tests/test_cli_version_memory_guard.py", admission)
        self.assertIn("python3 tests/test_cli_contract_help.py", admission)
        self.assertIn("macos-compile-admission-metrics-", admission)
        self.assertIn('"classification": classification', admission)

    def test_glaeda_profile_owns_native_cache_paths_but_not_result_authority(self):
        profile = self.profile["profiles"]["ci-compile-admission"]
        self.assertEqual(profile["engine"], "script")
        self.assertEqual(
            self.profile["cache_policies"]["ci-compile-admission"],
            "native",
        )
        self.assertEqual(
            self.profile["preparations"]["ci-compile-admission"]["engine"],
            "xcode",
        )
        self.assertIn("{derived_data}", profile["arguments"])
        self.assertIn("{source_packages}", profile["arguments"])
        self.assertIn("{module_cache}", profile["environment"]["CMUX_CI_MODULE_CACHE_PATH"])
        self.assertEqual(profile["arguments"][-1], "{derived_data}/persistent-build-aggregate.log")
        self.assertNotEqual(profile["arguments"][-1], "{derived_data}/cmux-build.log")
        self.assertIn("--expected-commit", self.driver)
        self.assertIn("--expected-tree", self.driver)
        self.assertIn("require_clean=True", self.driver)
        self.assertIn("Package.resolved changed during package readiness", self.driver)
        self.assertIn('"cold-reset"', self.driver)
        self.assertIn('"partially-warm"', self.driver)
        self.assertIn('"hot"', self.driver)


if __name__ == "__main__":
    unittest.main()
