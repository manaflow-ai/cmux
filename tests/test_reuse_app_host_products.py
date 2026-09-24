#!/usr/bin/env python3
"""Exercise cross-run artifact reuse through real archives and product relocation."""
import base64
import hashlib
import io
import json
import os
import re
from unittest import mock
import shutil
import sys
import tarfile
import subprocess
import unittest
import zipfile
from pathlib import Path
from urllib.parse import parse_qs

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts/ci"))
import reuse_app_host_products as reuse
from test_app_host_test_products import TestProductHandoff


class ReuseProducts(TestProductHandoff):
    def setUp(self):
        super().setUp()
        self.contract = {
            "product_inputs": {
                "schema": "cmux-app-host-product-inputs/v2",
                "algorithm": "a" * 64,
                "source": "b" * 64,
                "recipe": "c" * 64,
                "e2e_recipe": "d" * 64,
            },
            "xcode": "same-xcode",
            "sdk": "same-sdk",
            "os": "same-os",
            "architecture": "arm64",
            "tools": {"rustc": "rustc 1.0", "cargo": "cargo 1.0"},
            "environment": {"RUSTFLAGS": "", "SDKROOT": ""},
            "runner": "macos-arm64",
        }
        self.api = FakeGitHub(self.contract)
        self.api.archive = self.producer.parent / "artifact.zip"
        self.seal()

    def package(self, derived, archive_path):
        root = derived / "Build/Products"
        archive = derived.parent / "app-host-products.tar.gz"
        with tarfile.open(archive, "w:gz", dereference=True) as tar:
            tar.add(root, arcname="Build/Products")
        with zipfile.ZipFile(archive_path, "w") as z:
            z.write(archive, "app-host-products.tar.gz")
        return "sha256:" + hashlib.sha256(archive_path.read_bytes()).hexdigest()

    def seal(self):
        reuse.products.stamp(self.producer, self.identity)
        root = self.producer / "Build/Products"
        (root / reuse.RECEIPT).write_text(json.dumps({
            "contract": self.contract,
            "revision": self.identity["revision"],
            "run_id": str(self.api.run["id"]),
            "run_attempt": str(self.api.run["run_attempt"]),
        }))
        self.api.artifact["digest"] = self.package(self.producer, self.api.archive)

    def restore_reuse(self, *, current_run="13", current_attempt="1",
                      revision="def456", destination=None, report=None):
        current = {**self.identity, "revision": revision, "checkout": "/queue/work/cmux"}

        def product_identity(api, source_revision):
            return api.product_identities[source_revision]

        with mock.patch.object(
            reuse,
            "github_product_identity",
            side_effect=product_identity,
        ):
            return reuse.restore(
                self.api,
                self.contract,
                destination or self.consumer,
                current_run,
                current,
                current_attempt,
                report,
            )

    def test_other_commit_same_product_inputs_reuses_and_relocates_without_test_result(self):
        # The full run failed tests, while compilation itself succeeded.
        self.api.run["conclusion"] = "failure"
        self.assertTrue(self.restore_reuse())
        receipt = json.loads((self.consumer / "Build/Products" / reuse.products.RECEIPT).read_text())
        self.assertEqual(receipt["revision"], "def456")
        provenance = json.loads((self.consumer / "Build/Products/cmux-original-producer.json").read_text())
        self.assertEqual(provenance["revision"], "abc123")
        value = __import__('plistlib').loads(next((self.consumer / "Build/Products").glob('cmux-unit_*.xctestrun')).read_bytes())
        target = list(reuse.products.targets(value))[0]
        self.assertEqual(target['EnvironmentVariables']['SOURCE'], '/queue/work/cmux/fixtures')
        self.assertTrue(Path(target['DependentProductPaths'][0]).exists())

    def test_fork_wrong_workflow_and_failed_compile_are_misses(self):
        for field, value in [('event', 'workflow_dispatch'), ('path', '.github/workflows/untrusted.yml'),
                             ('head_repository', {'full_name': 'fork/cmux'})]:
            with self.subTest(field=field):
                old = self.api.run[field]
                self.api.run[field] = value
                self.assertFalse(self.restore_reuse())
                self.api.run[field] = old
        self.api.job['conclusion'] = 'failure'
        self.assertFalse(self.restore_reuse())

    def test_expired_missing_digest_current_run_are_misses(self):
        self.api.artifact['expired'] = True
        self.assertFalse(self.restore_reuse())
        self.api.artifact['expired'] = False
        self.api.artifact['workflow_run']['id'] = 13
        self.assertFalse(self.restore_reuse())
        self.api.artifact['workflow_run']['id'] = 12
        self.api.artifact.pop('digest')
        self.assertFalse(self.restore_reuse())

    def test_build_contract_changes_do_not_reuse(self):
        cases = {
            "xcode": {**self.contract, "xcode": "different-xcode"},
            "sdk": {**self.contract, "sdk": "different-sdk"},
            "tooling": {**self.contract, "tools": {**self.contract["tools"], "rustc": "rustc 2.0"}},
            "environment": {**self.contract, "environment": {**self.contract["environment"], "RUSTFLAGS": "-Dwarnings"}},
        }
        for name, changed in cases.items():
            with self.subTest(name=name):
                original = self.contract
                self.contract = changed
                self.assertFalse(self.restore_reuse())
                self.contract = original

    def test_product_identity_separates_orchestration_from_product_inputs(self):
        identity = reuse.product_inputs
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/ci-macos.yml").read_text()
        admission = identity._job_block(workflow, identity.MACOS_ADMISSION_JOB)

        def mutate_admission(old: str, new: str) -> str:
            changed = admission.replace(old, new, 1)
            self.assertNotEqual(admission, changed, old)
            return workflow.replace(admission, changed, 1)

        base = [
            f"100644 blob {'1' * 40}\tSources/App.swift",
            f"100644 blob {'2' * 40}\tscripts/ci/compile-app-host-test-product.sh",
            f"100644 blob {'3' * 40}\tscripts/ci/persistent_mac_route.py",
            f"100644 blob {'4' * 40}\t.github/workflows/ci-macos.yml",
        ]
        admission_only = [
            f"100644 blob {'1' * 40}\tSources/App.swift",
            f"100644 blob {'2' * 40}\tscripts/ci/compile-app-host-test-product.sh",
            f"100644 blob {'5' * 40}\tscripts/ci/persistent_mac_route.py",
            f"100644 blob {'6' * 40}\t.github/workflows/ci-macos.yml",
        ]
        base_identity = identity.identity_from_tree_lines(base, workflow)
        orchestration_workflow = workflow.replace(
            "name: CI macOS\n",
            "name: CI macOS orchestration-only\n",
            1,
        )
        self.assertEqual(
            base_identity,
            identity.identity_from_tree_lines(base, orchestration_workflow),
        )
        # Mutating an explicitly orchestration-only step must not change product identity.
        metrics_admission = admission.replace(
            "      - name: Record compiled-product reuse metrics\n",
            "      - name: Record compiled-product reuse metrics\n        # metrics-only edit\n",
            1,
        )
        self.assertNotEqual(admission, metrics_admission)
        orchestration_workflow = orchestration_workflow.replace(
            admission,
            metrics_admission,
            1,
        )
        self.assertEqual(
            base_identity,
            identity.identity_from_tree_lines(admission_only, orchestration_workflow),
        )

        changed_product_env = mutate_admission(
            '      CMUX_SKIP_ZIG_BUILD: "1"\n',
            '      CMUX_SKIP_ZIG_BUILD: "0"\n',
        )
        self.assertNotEqual(
            base_identity,
            identity.identity_from_tree_lines(base, changed_product_env),
        )

        changed_cache_env = mutate_admission(
            '      CMUX_NODE_PRODUCT_CACHE_WAIT_SECONDS: ${{ vars.CMUX_NODE_PRODUCT_CACHE_WAIT_SECONDS }}\n',
            '      CMUX_NODE_PRODUCT_CACHE_WAIT_SECONDS: "999"\n',
        )
        self.assertEqual(
            base_identity,
            identity.identity_from_tree_lines(base, changed_cache_env),
        )

        changed_defaults = mutate_admission(
            "    steps:\n",
            "    defaults:\n      run:\n        shell: bash\n    steps:\n",
        )
        self.assertNotEqual(
            base_identity,
            identity.identity_from_tree_lines(base, changed_defaults),
        )

        unclassified_job_key = mutate_admission(
            "    timeout-minutes: 75\n",
            "    timeout-minutes: 75\n    container: future-image\n",
        )
        with self.assertRaisesRegex(ValueError, "unclassified.*container"):
            identity.identity_from_tree_lines(base, unclassified_job_key)

        unknown_product_step = mutate_admission(
            "      - name: Validate Swift warning budget\n",
            "      - name: Future product mutation\n        run: touch product\n\n"
            "      - name: Validate Swift warning budget\n",
        )
        self.assertNotEqual(
            base_identity,
            identity.identity_from_tree_lines(base, unknown_product_step),
        )

        duplicate_step = mutate_admission(
            "      - name: Validate Swift warning budget\n",
            "      - name: Compile app-host test product\n",
        )
        with self.assertRaisesRegex(ValueError, "not unique"):
            identity.identity_from_tree_lines(base, duplicate_step)

        changed_source = list(base)
        changed_source[0] = f"100644 blob {'7' * 40}\tSources/App.swift"
        self.assertNotEqual(
            base_identity,
            identity.identity_from_tree_lines(changed_source, workflow),
        )

        changed_helper = list(base)
        changed_helper[1] = (
            f"100644 blob {'8' * 40}\tscripts/ci/compile-app-host-test-product.sh"
        )
        self.assertNotEqual(
            base_identity,
            identity.identity_from_tree_lines(changed_helper, workflow),
        )

        changed_recipe = mutate_admission(
            "scripts/ci/compile-app-host-test-product.sh canonical-build \\",
            "scripts/ci/compile-app-host-test-product.sh canonical-build --changed \\",
        )
        self.assertNotEqual(
            base_identity,
            identity.identity_from_tree_lines(base, changed_recipe),
        )

        changed_ghostty_selection = mutate_admission(
            'echo "sha=$(git -C ghostty rev-parse HEAD)"',
            'echo "sha=$(git rev-parse HEAD:ghostty)"',
        )
        self.assertNotEqual(
            base_identity,
            identity.identity_from_tree_lines(base, changed_ghostty_selection),
        )

        self.assertFalse(identity.reaches_product(".github/workflows/ci-macos.yml"))
        self.assertFalse(identity.reaches_product("scripts/ci/persistent_mac_route.py"))
        for path in (
            "workers/presence/src/index.ts",
            "config/iroh/managed-relay-catalog.json",
            "vercel.json",
            ".vercelignore",
            "cmux-browser/src/main.ts",
            "daemon/remote/cmd/cmuxd-remote/cli.go",
        ):
            self.assertFalse(identity.reaches_product(path), path)
        self.assertTrue(identity.reaches_product("config/IrohRelayPolicyProduction.xcconfig"))
        self.assertTrue(identity.reaches_product("scripts/ci/compile-app-host-test-product.sh"))
        self.assertTrue(identity.reaches_product("cmuxTests/WorkspaceTests.swift"))

    def test_developer_tooling_outside_the_build_does_not_reach_product(self):
        """Editing these must not force a compile: no build or macOS lane reads them."""
        identity = reuse.product_inputs
        tooling = (
            ".claude/commands/review.md",
            "agent-chat/server.ts",
            "agent-chat/src/components/Chat.tsx",
            "scripts/git-hooks/pre-commit",
            "scripts/benchmark-dev-fleet-warm-slots.py",
            "scripts/check-pbxproj.sh",
            "scripts/check-test-determinism.py",
            "scripts/dev-fleet-warm-slot.py",
            "scripts/install-git-hooks.sh",
            "scripts/merge-xcstrings.py",
            "scripts/normalize-pbxproj.py",
            "scripts/prune_nightly_release_assets.py",
        )
        for path in tooling:
            self.assertFalse(identity.reaches_product(path), path)

        # Neighbours that the build does read stay product inputs.
        for path in (
            "scripts/build-app-bundled-resources.sh",
            "scripts/build-plain-text-paste-worker.sh",
            "scripts/setup.sh",
            "skills/cmux-cua/SKILL.md",
            ".gitattributes",
        ):
            self.assertTrue(identity.reaches_product(path), path)

        # Drift guard: if the Xcode project, the compile script, or either
        # product workflow starts naming one of these, it is a build input again.
        root = Path(__file__).resolve().parents[1]
        readers = {
            name: (root / name).read_text()
            for name in (
                "cmux.xcodeproj/project.pbxproj",
                "scripts/ci/compile-app-host-test-product.sh",
                "scripts/build-app-bundled-resources.sh",
                ".github/workflows/ci-macos.yml",
                ".github/workflows/test-e2e.yml",
            )
        }
        # Check the module's own lists, not the samples above, so a reader
        # naming any file under an excluded prefix fails here too.
        needles = sorted(identity.NON_PRODUCT_TOOLING) + list(identity.NON_PRODUCT_TOOLING_PREFIXES)
        for needle in needles:
            for name, text in readers.items():
                self.assertNotIn(needle, text, f"{name} reads {needle}")

    def test_product_identity_binds_the_e2e_build_recipe(self):
        identity = reuse.product_inputs
        root = Path(__file__).resolve().parents[1]
        workflow = (root / ".github/workflows/ci-macos.yml").read_text()
        e2e_workflow = (root / ".github/workflows/test-e2e.yml").read_text()
        tree = [f"100644 blob {'1' * 40}\tSources/App.swift"]

        base = identity.identity_from_tree_lines(tree, workflow, e2e_workflow)

        changed_env = e2e_workflow.replace(
            '      CMUX_SKIP_ZIG_BUILD: "1"\n',
            '      CMUX_SKIP_ZIG_BUILD: "1"\n'
            '      XCODE_XCCONFIG_FILE: /tmp/override.xcconfig\n',
            1,
        )
        self.assertNotEqual(
            base,
            identity.identity_from_tree_lines(tree, workflow, changed_env),
        )

        changed_step = e2e_workflow.replace(
            "      - name: Build the app-host and UI test product\n",
            "      - name: Future product mutation\n"
            "        run: touch Sources/App.swift\n\n"
            "      - name: Build the app-host and UI test product\n",
            1,
        )
        self.assertNotEqual(
            base,
            identity.identity_from_tree_lines(tree, workflow, changed_step),
        )

    def test_e2e_identity_binds_the_helpers_its_build_job_runs(self):
        identity = reuse.product_inputs
        root = Path(__file__).resolve().parents[1]
        workflow = (root / ".github/workflows/ci-macos.yml").read_text()
        e2e_workflow = (root / ".github/workflows/test-e2e.yml").read_text()
        source = f"100644 blob {'1' * 40}\tSources/App.swift"
        helper = "scripts/ci/e2e_warm_derived_data.py"
        base = identity.identity_from_tree_lines([source, f"100644 blob {'2' * 40}\t{helper}"], workflow, e2e_workflow)
        edited = identity.identity_from_tree_lines([source, f"100644 blob {'3' * 40}\t{helper}"], workflow, e2e_workflow)

        # Only the E2E component moves: the compile-admission identity does not.
        self.assertNotEqual(base["e2e_recipe"], edited["e2e_recipe"])
        self.assertEqual({k: v for k, v in base.items() if k != "e2e_recipe"},
                         {k: v for k, v in edited.items() if k != "e2e_recipe"})
        # A scripts/ci file the build job never names changes nothing.
        unrelated = identity.identity_from_tree_lines(
            [source, f"100644 blob {'2' * 40}\t{helper}", f"100644 blob {'4' * 40}\tscripts/ci/queue_janitor.py"],
            workflow, e2e_workflow,
        )
        self.assertEqual(base, unrelated)

    def test_bundled_paste_worker_source_reaches_product(self):
        """cmux.xcodeproj compiles this into the bundle, so reuse must see it."""
        identity = reuse.product_inputs
        # The "Build Plain Text Paste Worker" phase declares main.m as an input
        # and emits bin/cmux-paste-text-worker into the app-host bundle, which
        # PlainPastePTYFixture and the paste startup suites execute. The rest of
        # workers/ is Cloudflare Worker source and stays excluded.
        self.assertTrue(identity.reaches_product("workers/cmux-paste-text/main.m"))
        self.assertFalse(identity.reaches_product("workers/presence/src/index.ts"))

        # Assert the named build phase declares it, not merely that the path
        # appears somewhere in the project file: only the inputPaths entry is
        # evidence that the worker is compiled into the bundle.
        project = (Path(__file__).resolve().parents[1] / "cmux.xcodeproj/project.pbxproj").read_text()
        phase = project.split("name = \"Build Plain Text Paste Worker\"", 1)
        self.assertEqual(len(phase), 2, "Build Plain Text Paste Worker phase is missing")
        declaration = phase[0].rsplit("isa = PBXShellScriptBuildPhase", 1)[-1]
        self.assertIn("$(SRCROOT)/workers/cmux-paste-text/main.m", declaration)
        self.assertIn("inputPaths", declaration)
        self.assertIn("cmux-paste-text-worker", phase[1].split("};", 1)[0])

        # A commit that only touches the worker must change the fingerprint.
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/ci-macos.yml").read_text()
        base = ["100644 blob 1111111111111111111111111111111111111111\tworkers/cmux-paste-text/main.m"]
        changed = ["100644 blob 2222222222222222222222222222222222222222\tworkers/cmux-paste-text/main.m"]
        self.assertNotEqual(
            identity.identity_from_tree_lines(base, workflow),
            identity.identity_from_tree_lines(changed, workflow),
        )

    def test_github_product_identity_is_recomputed_from_git_objects(self):
        root = Path(__file__).resolve().parents[1]
        workflow = (root / ".github/workflows/ci-macos.yml").read_text()
        e2e_workflow = (root / ".github/workflows/test-e2e.yml").read_text()
        entries = [
            {"path": "Sources/App.swift", "mode": "100644", "type": "blob", "sha": "1" * 40},
            {
                "path": ".github/workflows/ci-macos.yml",
                "mode": "100644",
                "type": "blob",
                "sha": "2" * 40,
            },
            {
                "path": ".github/workflows/test-e2e.yml",
                "mode": "100644",
                "type": "blob",
                "sha": "4" * 40,
            },
        ]

        class GitObjects:
            def get(self, path):
                if path == "git/commits/abc123":
                    return {"tree": {"sha": "3" * 40}}
                if path == f"git/trees/{'3' * 40}?recursive=1":
                    return {"truncated": False, "tree": entries}
                if path == f"git/blobs/{'2' * 40}":
                    return {
                        "encoding": "base64",
                        "content": base64.b64encode(workflow.encode()).decode(),
                    }
                if path == f"git/blobs/{'4' * 40}":
                    return {
                        "encoding": "base64",
                        "content": base64.b64encode(e2e_workflow.encode()).decode(),
                    }
                raise AssertionError(path)

        actual = reuse.github_product_identity(GitObjects(), "abc123")
        expected = reuse.product_inputs.identity_from_tree_lines(
            reuse.product_inputs.github_tree_lines(entries),
            workflow,
            e2e_workflow,
        )
        self.assertEqual(actual, expected)

    def test_changed_product_inputs_are_a_miss(self):
        original = self.api.product_identities["abc123"]
        self.api.product_identities["abc123"] = {
            **original,
            "source": "d" * 64,
        }
        self.assertFalse(self.restore_reuse())
        self.api.product_identities["abc123"] = original

    def test_actual_source_and_run_provenance_must_match(self):
        original_identity = self.api.product_identities["abc123"]
        self.api.product_identities["abc123"] = {
            **original_identity,
            "recipe": "d" * 64,
        }
        self.assertFalse(self.restore_reuse())
        self.assertFalse(self.consumer.exists())
        self.api.product_identities["abc123"] = original_identity
        root = self.producer / "Build/Products"
        receipt = json.loads((root / reuse.RECEIPT).read_text())
        receipt["run_id"] = "999"
        (root / reuse.RECEIPT).write_text(json.dumps(receipt))
        self.api.artifact["digest"] = self.package(self.producer, self.api.archive)
        self.assertFalse(self.restore_reuse())
        self.assertFalse(self.consumer.exists())

    def test_malformed_api_fields_are_normal_misses(self):
        cases = (
            ("consumer_head", "consumer_revision_invalid"),
            ("producer_head", "producer_revision_invalid"),
            ("digest", "artifact_digest_missing"),
            ("size", "artifact_size_invalid"),
        )
        for name, expected in cases:
            with self.subTest(name=name):
                report = {}
                if name == "consumer_head":
                    old = self.api.consumer_run["head_sha"]
                    self.api.consumer_run["head_sha"] = None
                elif name == "producer_head":
                    old = self.api.run["head_sha"]
                    self.api.run["head_sha"] = None
                elif name == "digest":
                    old = self.api.artifact["digest"]
                    self.api.artifact["digest"] = None
                else:
                    old = self.api.artifact["size_in_bytes"]
                    self.api.artifact["size_in_bytes"] = None
                try:
                    self.assertFalse(self.restore_reuse(report=report))
                    self.assertIn(expected, report["miss_reasons"])
                    self.assertFalse(self.consumer.exists())
                finally:
                    if name == "consumer_head":
                        self.api.consumer_run["head_sha"] = old
                    elif name == "producer_head":
                        self.api.run["head_sha"] = old
                    elif name == "digest":
                        self.api.artifact["digest"] = old
                    else:
                        self.api.artifact["size_in_bytes"] = old

    def pull_request_checkout(self, branch):
        """Reproduce the checkout a pull request run actually gets.

        `actions/checkout` with no `ref:` fetches `github.sha` at the default
        depth of one, so the working tree is the ephemeral merge of the pull
        request head into the base, in a shallow repository. Clone the same way
        here: a shallow HEAD has no walkable parents, which is the difference
        between reading the commit object and asking for `HEAD^2`.
        """
        root = Path(self.temp.name) / "git"
        source = root / "source"

        def git(*args, cwd=source):
            return subprocess.check_output(
                ["git", "-c", "user.email=ci@cmux.test", "-c", "user.name=cmux ci", *args],
                cwd=cwd, text=True).strip()

        if not source.exists():
            source.mkdir(parents=True)
            git("init", "-q", "-b", "main", ".")
            git("commit", "-q", "--allow-empty", "-m", "base")
            self.base_revision = git("rev-parse", "HEAD")
            # Not "head": on a case-insensitive filesystem refs/heads/head and
            # .git/HEAD are the same path, so every later "head" argument is an
            # ambiguous refname and these tests cannot run on macOS at all.
            git("checkout", "-q", "-b", "pull-request-head")
            git("commit", "-q", "--allow-empty", "-m", "pull request head")
            self.head_revision = git("rev-parse", "HEAD")
            git("checkout", "-q", "main")
            git("merge", "-q", "--no-ff", "pull-request-head", "-m", "merge pull request")
            # The same two commits merged the other way, leaving the pull
            # request head in the first-parent position.
            git("checkout", "-q", "-b", "reversed", "pull-request-head")
            git("merge", "-q", "--no-ff", "main", "-m", "merge base")
        checkout = root / branch
        git("clone", "-q", "--depth", "1", "--branch", branch, "--no-local",
            source.as_uri(), str(checkout), cwd=root)
        self.addCleanup(os.chdir, os.getcwd())
        os.chdir(checkout)
        return git("rev-parse", "HEAD", cwd=checkout)

    def test_pull_request_merge_checkout_is_bound_to_the_attested_head(self):
        """A pull request consumer reuses instead of reporting a mismatch.

        The run's `head_sha` is the pull request head while the checkout is the
        merge commit, so an exact revision comparison rejects every pull request
        run before any producer is considered.
        """
        revision = self.pull_request_checkout("main")
        self.api.consumer_run["head_sha"] = self.head_revision
        self.api.product_identities[self.head_revision] = self.contract["product_inputs"]
        report = {}
        self.assertTrue(self.restore_reuse(revision=revision, report=report))
        self.assertNotIn("consumer_revision_mismatch", report["miss_reasons"])
        self.assertEqual(report["reason"], "hit")

    def test_checkout_outside_the_attested_head_stays_a_miss(self):
        """Only a merge of the attested head counts as that head's checkout."""
        cases = (
            # A merge commit that does not have the attested head as a parent.
            ("main", "base_revision"),
            # The attested head as first parent: the pull request with the base
            # merged into it, not the pull request merged for testing.
            ("reversed", "head_revision"),
            # A non-merge checkout still has to be the attested commit itself.
            ("pull-request-head", "base_revision"),
        )
        for branch, attribute in cases:
            with self.subTest(branch=branch):
                revision = self.pull_request_checkout(branch)
                attested = getattr(self, attribute)
                self.api.consumer_run["head_sha"] = attested
                self.api.product_identities[attested] = self.contract["product_inputs"]
                report = {}
                self.assertFalse(self.restore_reuse(revision=revision, report=report))
                self.assertIn("consumer_revision_mismatch", report["miss_reasons"])
                self.assertFalse(self.consumer.exists())

    def test_merge_group_checkout_still_requires_an_exact_revision(self):
        """Merge queue runs check out the attested commit, so nothing relaxes."""
        revision = self.pull_request_checkout("main")
        for run in (self.api.run, self.api.consumer_run):
            run["event"] = "merge_group"
            run.pop("pull_requests", None)
        self.api.consumer_run["head_sha"] = self.head_revision
        self.api.product_identities[self.head_revision] = self.contract["product_inputs"]
        report = {}
        self.assertFalse(self.restore_reuse(revision=revision, report=report))
        self.assertIn("consumer_revision_mismatch", report["miss_reasons"])

    def valid_schema2_upstream(self):
        """Build a complete prior-hop provenance record for validation tests."""
        producer = {
            "run_id": "10",
            "run_attempt": "1",
            "run_url": "https://github.com/manaflow-ai/cmux/actions/runs/10",
            "revision": "abc123",
            "artifact_id": 40,
            "artifact_digest": "sha256:" + "a" * 64,
        }
        return {
            "schema": 2,
            "original_producer": dict(producer),
            "immediate_producer": dict(producer),
            "consumer": {"run_id": "11", "run_attempt": "1", "revision": "abc123"},
            "restore_route": "github_artifact",
            "metrics": {
                "compile_seconds_avoided": 600.0,
                "lookup_seconds": 1.0,
                "transfer_seconds": 2.0,
                "restore_seconds": 3.0,
                "total_reuse_seconds": 6.0,
                "macos_runner_minutes_saved": 9.9,
            },
            "candidate_misses": [],
            "run_url": producer["run_url"],
            "revision": producer["revision"],
            "artifact_id": producer["artifact_id"],
            "artifact_digest": producer["artifact_digest"],
            "consumer_revision": "abc123",
            "upstream": None,
        }

    def seal_at(self, revision):
        """Re-seal the producer archive as a run that checked out `revision`."""
        self.identity = {**self.identity, "revision": revision}
        self.seal()

    def test_pull_request_producer_sealed_at_its_merge_commit_is_reusable(self):
        """A pull request producer seals the merge commit it checked out.

        `reuse_app_host_products.py seal` records `git rev-parse HEAD`, which
        on a pull request run is the ephemeral merge commit, while the run's
        `head_sha` is the pull request head. Requiring those two to be equal
        rejected every pull request producer, and only after its archive had
        already been downloaded and expanded.
        """
        merge = "aaa111bbb222"
        self.api.commit_parents[merge] = ["base999", self.api.run["head_sha"]]
        self.api.product_identities[merge] = self.contract["product_inputs"]
        self.seal_at(merge)
        report = {}
        self.assertTrue(self.restore_reuse(report=report))
        self.assertNotIn("product_provenance_invalid", report["miss_reasons"])
        self.assertEqual(report["reason"], "hit")
        provenance = json.loads(
            (self.consumer / "Build/Products/cmux-original-producer.json").read_text())
        self.assertEqual(provenance["revision"], merge)

    def test_producer_revision_outside_the_attested_head_stays_a_miss(self):
        """Only a merge of the producer's attested head vouches for its archive."""
        merge = "aaa111bbb222"
        cases = {
            # The attested head is not a parent of the sealed revision at all.
            "unrelated_merge": (["base999", "other77"], "pull_request", True),
            # The attested head as first parent: the base merged into the pull
            # request, not the pull request merged for testing.
            "reversed_merge": ([self.api.run["head_sha"], "base999"],
                               "pull_request", True),
            # An octopus merge never names a single tested head.
            "octopus_merge": (["base999", self.api.run["head_sha"], "third33"],
                              "pull_request", True),
            # Merge queue runs check out the attested commit, so nothing relaxes.
            "merge_group": (["base999", self.api.run["head_sha"]],
                            "merge_group", True),
            # A well-formed merge whose tree carries different product inputs.
            "foreign_product_inputs": (["base999", self.api.run["head_sha"]],
                                       "pull_request", False),
        }
        for name, (parents, event, same_inputs) in cases.items():
            with self.subTest(case=name):
                self.setUp()
                self.api.commit_parents[merge] = parents
                self.api.product_identities[merge] = (
                    self.contract["product_inputs"] if same_inputs
                    else {**self.contract["product_inputs"], "source": "9" * 64})
                if event == "merge_group":
                    for run in (self.api.run, self.api.consumer_run):
                        run["event"] = event
                        run.pop("pull_requests", None)
                self.seal_at(merge)
                report = {}
                self.assertFalse(self.restore_reuse(report=report))
                self.assertIn("product_provenance_invalid", report["miss_reasons"])
                self.assertFalse(self.consumer.exists())

    def install_upstream(self, provenance):
        """Embed provenance in the producer archive and refresh its outer digest."""
        root = self.producer / "Build/Products"
        (root / "cmux-original-producer.json").write_text(json.dumps(provenance))
        self.api.artifact["digest"] = self.package(self.producer, self.api.archive)

    def test_malformed_receipt_revision_is_a_normal_miss(self):
        root = self.producer / "Build/Products"
        receipt = json.loads((root / reuse.RECEIPT).read_text())
        receipt["revision"] = None
        (root / reuse.RECEIPT).write_text(json.dumps(receipt))
        self.api.artifact["digest"] = self.package(self.producer, self.api.archive)
        report = {}
        self.assertFalse(self.restore_reuse(report=report))
        self.assertIn("product_provenance_invalid", report["miss_reasons"])
        self.assertFalse(self.consumer.exists())

    def test_malformed_schema2_upstream_provenance_is_a_miss(self):
        cases = {
            "empty_original_producer": lambda value: value.__setitem__("original_producer", {}),
            "nan_compile_metric": lambda value: value["metrics"].__setitem__(
                "compile_seconds_avoided", float("nan")),
            "negative_restore_metric": lambda value: value["metrics"].__setitem__(
                "restore_seconds", -1),
        }
        for name, mutate in cases.items():
            with self.subTest(name=name):
                provenance = self.valid_schema2_upstream()
                mutate(provenance)
                self.install_upstream(provenance)
                report = {}
                self.assertFalse(self.restore_reuse(report=report))
                self.assertIn("product_provenance_invalid", report["miss_reasons"])
                self.assertFalse(self.consumer.exists())
                (self.producer / "Build/Products/cmux-original-producer.json").unlink()
                self.seal()

    def test_valid_legacy_upstream_provenance_remains_eligible(self):
        legacy = {
            "run_url": "https://github.com/manaflow-ai/cmux/actions/runs/9",
            "revision": "abc123",
            "artifact_id": 39,
            "consumer_revision": "abc123",
            "upstream": None,
        }
        self.install_upstream(legacy)
        self.assertTrue(self.restore_reuse())
        provenance = json.loads(
            (self.consumer / "Build/Products/cmux-original-producer.json").read_text())
        self.assertEqual(provenance["upstream"], legacy)
        self.assertEqual(provenance["original_producer"]["run_id"], "12")

    def test_corrupt_archive_never_populates_consumer(self):
        self.api.archive.write_bytes(b'corrupt')
        self.assertFalse(self.restore_reuse())
        self.assertFalse(self.consumer.exists())

    def test_invalid_candidate_does_not_hide_later_valid_archive(self):
        original_download = self.api.download
        for failure in ('download', 'archive', 'receipt'):
            with self.subTest(failure=failure):
                bad = {**self.api.artifact, 'id': 41}
                if failure == 'archive':
                    bad['digest'] = 'sha256:' + hashlib.sha256(b'corrupt').hexdigest()
                bad_run = {**self.api.run, 'id': 99} if failure == 'receipt' else self.api.run
                def download(artifact_id, target, size):
                    if artifact_id == 41 and failure == 'download':
                        raise OSError('candidate unavailable')
                    if artifact_id == 41 and failure == 'archive':
                        target.write_bytes(b'corrupt')
                    else:
                        original_download(42, target, size)
                with mock.patch.object(reuse, 'select', return_value=[
                        (bad, bad_run), (self.api.artifact, self.api.run)]), \
                        mock.patch.object(self.api, 'download', side_effect=download) as calls:
                    self.assertTrue(self.restore_reuse())
                    self.assertEqual([call.args[0] for call in calls.call_args_list], [41, 42])
                provenance = json.loads((self.consumer / 'Build/Products/cmux-original-producer.json').read_text())
                self.assertEqual(provenance['artifact_id'], 42)
                shutil.rmtree(self.consumer)

    def test_failure_after_relocation_aborts_without_trying_another_candidate(self):
        original_restore = reuse.products.restore
        def restore(derived, identity):
            if derived == self.consumer:
                raise ValueError('consumer relocation failed')
            return original_restore(derived, identity)
        with mock.patch.object(reuse, 'select', return_value=[
                (self.api.artifact, self.api.run), (self.api.artifact, self.api.run)]), \
                mock.patch.object(reuse.products, 'restore', side_effect=restore), \
                mock.patch.object(self.api, 'download', wraps=self.api.download) as download:
            with self.assertRaisesRegex(ValueError, 'consumer relocation failed'):
                self.restore_reuse()
            self.assertEqual(download.call_count, 1)

    def test_attempt_suffixed_artifact_remains_discoverable(self):
        self.assertTrue(self.api.artifact['name'].endswith('-1'))
        self.assertTrue(self.restore_reuse())

    def test_successful_exact_rerun_reuses_prior_attempt(self):
        self.api.run.update({"id": 13, "run_attempt": 1, "head_sha": "abc123"})
        self.api.consumer_run.update({"id": 13, "run_attempt": 2, "head_sha": "abc123"})
        self.api.artifact["workflow_run"]["id"] = 13
        self.api.artifact["name"] = reuse.PREFIX + reuse.key(self.contract) + "-1"
        self.seal()
        report = {}
        with mock.patch.object(
                reuse.time, "monotonic",
                side_effect=[100.0, 101.0, 102.0, 104.0, 105.0, 108.0, 109.0]):
            self.assertTrue(self.restore_reuse(
                current_run="13", current_attempt="2", revision="abc123", report=report))
        self.assertEqual(report["reason"], "hit")
        self.assertEqual(report["compile_seconds_avoided"], 600.0)
        self.assertEqual(report["lookup_seconds"], 1.0)
        self.assertEqual(report["transfer_seconds"], 2.0)
        self.assertEqual(report["restore_seconds"], 3.0)
        self.assertEqual(report["total_reuse_seconds"], 9.0)
        self.assertEqual(report["macos_runner_minutes_saved"], 9.85)

    def test_oversize_compressed_artifact_is_rejected_without_download(self):
        with mock.patch.object(reuse, 'MAX_ARCHIVE_BYTES', 1), \
                mock.patch.object(self.api, 'download') as download:
            self.assertFalse(self.restore_reuse())
            download.assert_not_called()

    def test_valid_digest_with_corrupt_tar_is_rejected(self):
        with zipfile.ZipFile(self.api.archive, 'w') as z:
            z.writestr('app-host-products.tar.gz', b'corrupt')
        self.api.artifact['digest'] = 'sha256:' + hashlib.sha256(self.api.archive.read_bytes()).hexdigest()
        self.assertFalse(self.restore_reuse())
        self.assertFalse(self.consumer.exists())

    def test_archive_expansion_is_bounded(self):
        for limit in ('MAX_MEMBER_BYTES', 'MAX_EXPANDED_BYTES', 'MAX_MEMBERS', 'MAX_TAR_BYTES'):
            with self.subTest(limit=limit), mock.patch.object(reuse, limit, 1, create=True):
                self.assertFalse(self.restore_reuse())
                self.assertFalse(self.consumer.exists())

    def test_unrelated_producer_inputs_rejected_before_download(self):
        original = self.api.product_identities["abc123"]
        self.api.product_identities["abc123"] = {
            **original,
            "source": "e" * 64,
        }
        with mock.patch.object(self.api, "download", wraps=self.api.download) as download:
            self.assertFalse(self.restore_reuse())
            download.assert_not_called()
        self.api.product_identities["abc123"] = original

    def test_completed_compile_can_be_used_while_other_tests_run(self):
        self.api.run['status'] = 'in_progress'
        self.assertTrue(self.restore_reuse())

    def test_api_failure_cli_falls_back_to_compile(self):
        output = self.producer.parent / "github-output"
        env = {
            "GITHUB_OUTPUT": str(output),
            "GITHUB_EVENT_NAME": "merge_group",
            "GITHUB_REPOSITORY": self.api.repository,
            "GITHUB_RUN_ID": "13",
            "GITHUB_RUN_ATTEMPT": "1",
        }
        with mock.patch.dict(os.environ, env), mock.patch.object(
                sys, "argv", ["reuse", "restore", str(self.consumer)]), \
                mock.patch.object(reuse, "contract", return_value=self.contract), \
                mock.patch.object(reuse.products, "identity", return_value=self.identity), \
                mock.patch.object(reuse.GitHub, "get", side_effect=OSError("API unavailable")):
            reuse.main()
        outputs = dict(line.split("=", 1) for line in output.read_text().splitlines())
        self.assertEqual(outputs["hit"], "false")
        self.assertEqual(outputs["reason"], "miss")
        self.assertEqual(outputs["miss_reasons"], "consumer_provenance_unavailable")
        self.assertFalse(self.consumer.exists())


    def dispatch_consumer(self):
        """Make the consumer an E2E dispatch.

        Its `head_sha` names the workflow definition's ref, never the revision
        under test, because that arrives as a workflow input.
        """
        self.api.consumer_run.update({
            "path": ".github/workflows/test-e2e.yml",
            "event": "workflow_dispatch",
            "pull_requests": [],
            "head_sha": "aaa999",
        })

    def dispatch_producer(self):
        self.api.run.update({
            "path": ".github/workflows/test-e2e.yml",
            "event": "workflow_dispatch",
            # GitHub associates same-repo dispatches with an open PR. Keeping
            # this populated makes the dispatch->PR prohibition exercise the
            # event matrix instead of failing earlier on PR-number mismatch.
            "pull_requests": [{"number": 7}],
            "head_sha": "aaa999",
        })
        self.api.product_identities["aaa999"] = self.contract["product_inputs"]
        self.api.job = {
            "name": "build",
            "conclusion": "success",
            "status": "completed",
            "steps": [{
                "name": "Build the app-host and UI test product",
                "conclusion": "success",
                "status": "completed",
                "started_at": "2026-09-21T08:00:00Z",
                "completed_at": "2026-09-21T08:10:00Z",
            }],
        }

    def test_a_dispatch_adopts_the_product_ci_already_compiled(self):
        # `head_sha` here is "aaa999", which has no product identity at all, so
        # a hit proves the dispatch was admitted on its checkout instead.
        self.dispatch_consumer()
        report = {}
        self.assertTrue(self.restore_reuse(report=report))
        self.assertEqual(report["reason"], "hit")
        self.assertEqual(report["producer_run_id"], "12")

    def test_a_dispatch_checkout_must_still_match_githubs_copy(self):
        self.dispatch_consumer()
        self.api.product_identities["def456"] = {
            **self.contract["product_inputs"], "source": "z" * 64,
        }
        self.assertFalse(self.restore_reuse())
        self.assertFalse(self.consumer.exists())

    def test_one_dispatch_adopts_an_earlier_dispatch_product(self):
        # Two dispatches of the same revision on the same pool compile the same
        # product; the second should download the first one instead.
        self.dispatch_consumer()
        self.dispatch_producer()
        report = {}
        self.assertTrue(self.restore_reuse(report=report))
        self.assertEqual(report["reason"], "hit")
        # Found through the E2E lane's own compile job and step names.
        self.assertEqual(report["compile_seconds_avoided"], 600.0)

    def test_a_dispatch_producer_cannot_seal_a_revision_it_did_not_build(self):
        # Nothing binds a dispatch producer's run to what it compiled, so the
        # sealed revision is re-fingerprinted against GitHub. A receipt naming
        # a revision whose tree carries other product inputs is a miss, and the
        # products never reach the consumer's DerivedData.
        self.dispatch_consumer()
        self.dispatch_producer()
        self.api.product_identities["abc123"] = {
            **self.contract["product_inputs"], "source": "z" * 64,
        }
        self.assertFalse(self.restore_reuse())
        self.assertFalse(self.consumer.exists())

    def test_a_dispatch_producer_recipe_must_match_the_workflow_github_ran(self):
        self.dispatch_consumer()
        self.dispatch_producer()
        self.api.product_identities["aaa999"] = {
            **self.contract["product_inputs"],
            "e2e_recipe": "f" * 64,
        }
        report = {}
        with mock.patch.object(self.api, "download") as download:
            self.assertFalse(self.restore_reuse(report=report))
            download.assert_not_called()
        self.assertIn("producer_recipe_mismatch", report["miss_reasons"])
        self.assertFalse(self.consumer.exists())

    def test_ci_never_adopts_a_dispatch_product(self):
        # Trust runs one way: a dispatch compiles a dispatcher-chosen revision,
        # so CI's own lanes must not pick its products up.
        self.dispatch_producer()
        self.assertFalse(self.restore_reuse())
        self.assertFalse(self.consumer.exists())

    def test_products_are_read_over_parallel_range_requests(self):
        # A single `gh api .../zip` stream sustained about 2 MB/s, so every
        # ~900 MB candidate hit its budget and the job compiled instead --
        # invisibly, because a miss looks exactly like a normal build.
        target = self.producer.parent / "probe.zip"
        with mock.patch.object(reuse.parallel, "download_zip") as download_zip, \
                mock.patch.object(reuse.subprocess, "run") as run:
            reuse.GitHub("manaflow-ai/cmux").download(42, target, 979844748)
        download_zip.assert_called_once_with("manaflow-ai/cmux", 42, target, 979844748)
        run.assert_not_called()

    def test_restore_passes_the_listed_artifact_size_to_the_transport(self):
        with mock.patch.object(self.api, "download", wraps=self.api.download) as download:
            self.assertTrue(self.restore_reuse())
        self.assertEqual(download.call_args.args[2], self.api.artifact["size_in_bytes"])

    def test_a_failed_transfer_is_a_miss_not_a_crash(self):
        for error in (reuse.parallel.TransportError("parallel download deadline exceeded"),
                      OSError("connection reset"),
                      reuse.http.client.IncompleteRead(b"partial"),
                      EOFError("stream ended"),
                      ValueError("size must be positive")):
            with self.subTest(error=type(error).__name__):
                with mock.patch.object(type(self.api), "download", side_effect=error):
                    report = {}
                    self.assertFalse(self.restore_reuse(report=report))
                self.assertIn("artifact_download_error", report["miss_reasons"])
                self.assertFalse(self.consumer.exists())

    def test_product_archives_carry_no_appledouble_entries(self):
        # macOS tar adds Build/._Products for Xcode's xattrs unless
        # COPYFILE_DISABLE is set; unpack() rejects that as an unscoped path,
        # so every product packed without it was a silent miss.
        root = Path(__file__).resolve().parents[1] / ".github/workflows"
        packers = [
            (path.name, line.strip())
            for path in sorted(root.glob("*.yml"))
            for line in path.read_text().splitlines()
            if re.search(r"\btar -c\w*\b.*\bBuild/Products\b", line)
        ]
        self.assertTrue(packers)
        for name, line in packers:
            with self.subTest(workflow=name):
                self.assertTrue(line.startswith("COPYFILE_DISABLE=1 tar "), line)

    def test_each_event_is_trusted_only_from_its_own_workflow(self):
        for event, path, trusted in (
            ("pull_request", ".github/workflows/ci.yml", True),
            ("pull_request", ".github/workflows/test-e2e.yml", False),
            ("merge_group", ".github/workflows/ci.yml", True),
            ("workflow_dispatch", ".github/workflows/test-e2e.yml", True),
            ("workflow_dispatch", ".github/workflows/ci.yml", False),
            ("schedule", ".github/workflows/nightly.yml", False),
        ):
            with self.subTest(event=event, path=path):
                run = {
                    "event": event,
                    "path": path,
                    "head_repository": {"full_name": self.api.repository},
                }
                self.assertEqual(
                    reuse.trusted_ci_run(run, self.api.repository), trusted
                )

    def test_dispatch_pairs_extend_the_matrix_in_one_direction(self):
        ci = {
            "path": ".github/workflows/ci.yml",
            "head_repository": {"full_name": self.api.repository},
            "pull_requests": [{"number": 7}],
        }
        dispatch = {
            "path": ".github/workflows/test-e2e.yml",
            "head_repository": {"full_name": self.api.repository},
            "event": "workflow_dispatch",
            "pull_requests": [{"number": 7}],
        }
        for name, producer, consumer, expected in (
            ("pr_to_dispatch", {**ci, "event": "pull_request"}, dispatch, True),
            ("merge_group_to_dispatch", {**ci, "event": "merge_group"}, dispatch, True),
            ("dispatch_to_dispatch", dispatch, dispatch, True),
            ("dispatch_to_pr", dispatch, {**ci, "event": "pull_request"}, False),
            ("dispatch_to_merge_group", dispatch, {**ci, "event": "merge_group"}, False),
        ):
            with self.subTest(name=name):
                self.assertEqual(
                    reuse.permitted_pair(producer, consumer, self.api.repository),
                    expected,
                )

    def test_permitted_producer_consumer_matrix(self):
        base = {
            "path": ".github/workflows/ci.yml",
            "head_repository": {"full_name": self.api.repository},
            "pull_requests": [{"number": 7}],
        }
        cases = [
            ("pr_same_pr", {**base, "event": "pull_request"},
             {**base, "event": "pull_request"}, True),
            ("pr_other_pr", {**base, "event": "pull_request", "pull_requests": [{"number": 8}]},
             {**base, "event": "pull_request"}, False),
            ("merge_group_to_pr", {**base, "event": "merge_group"},
             {**base, "event": "pull_request"}, False),
            ("pr_to_merge_group", {**base, "event": "pull_request"},
             {**base, "event": "merge_group"}, True),
            ("merge_group_to_merge_group", {**base, "event": "merge_group"},
             {**base, "event": "merge_group"}, True),
        ]
        for name, producer, consumer, expected in cases:
            with self.subTest(name=name):
                self.assertEqual(
                    reuse.permitted_pair(producer, consumer, self.api.repository),
                    expected,
                )
        fork = {**base, "event": "pull_request",
                "head_repository": {"full_name": "fork/cmux"}}
        self.assertFalse(reuse.permitted_pair(fork, {**base, "event": "pull_request"},
                                              self.api.repository))
        self.assertFalse(reuse.permitted_pair({**base, "event": "pull_request"}, fork,
                                              self.api.repository))

    def test_failed_producer_compile_is_a_miss(self):
        self.api.job["conclusion"] = "failure"
        self.assertFalse(self.restore_reuse())
        self.assertFalse(self.consumer.exists())

    def test_wrong_repository_provenance_is_a_miss(self):
        self.api.run["head_repository"] = {"full_name": "other/cmux"}
        self.assertFalse(self.restore_reuse())
        self.assertFalse(self.consumer.exists())

    def test_expired_and_missing_artifacts_are_misses(self):
        self.api.artifact["expired"] = True
        self.assertFalse(self.restore_reuse())
        self.api.artifact["expired"] = False
        self.api.artifacts = []
        self.assertFalse(self.restore_reuse())

    def test_candidate_lookup_is_bounded(self):
        original_get = self.api.get
        artifact_queries = []
        def no_matches(path):
            if path.startswith("actions/artifacts?"):
                artifact_queries.append(path)
                return {"artifacts": [{"name": "unrelated"} for _ in range(100)]}
            return original_get(path)
        with mock.patch.object(self.api, "get", side_effect=no_matches):
            self.assertFalse(self.restore_reuse())
        # One exact-name request per plausible producer attempt, never a page scan.
        self.assertEqual(
            artifact_queries,
            [f"actions/artifacts?name={reuse.artifact_name(self.contract, attempt)}&per_page=100"
             for attempt in (1, 2, 3)],
        )

        prefix = reuse.PREFIX + reuse.key(self.contract) + "-1"
        candidates = [
            {"id": 100 + index, "name": prefix, "size_in_bytes": 100,
             "expired": False, "digest": self.api.artifact["digest"],
             "workflow_run": {"id": 20 + index}}
            for index in range(7)
        ]
        attempts = []
        def six_candidates(path):
            if path.startswith("actions/artifacts?"):
                return {"artifacts": candidates}
            if path.startswith("actions/runs/") and "/attempts/" in path and "/jobs?" not in path:
                attempts.append(path)
                return {
                    **self.api.run,
                    "id": int(path.split("/")[2]),
                    "run_attempt": 1,
                    "head_repository": {"full_name": "other/cmux"},
                }
            return original_get(path)
        with mock.patch.object(self.api, "get", side_effect=six_candidates):
            self.assertFalse(self.restore_reuse())
        self.assertEqual(len(attempts), 6)

    def test_exact_name_lookup_finds_artifact_outside_recent_listing_window(self):
        # Retention is days, while the newest few hundred repository artifacts
        # span minutes. An artifact this old is reachable by name only.
        self.api.artifact["created_at"] = "2026-09-19T08:00:00Z"
        self.assertTrue(self.restore_reuse())
        self.assertEqual(
            self.api.artifact_queries,
            [f"actions/artifacts?name={reuse.artifact_name(self.contract, attempt)}&per_page=100"
             for attempt in (1, 2, 3)],
        )

    def test_earlier_producer_attempt_is_reachable_by_name(self):
        self.api.run["run_attempt"] = 2
        self.api.artifact["name"] = reuse.artifact_name(self.contract, 2)
        self.seal()
        self.assertTrue(self.restore_reuse())

    def test_artifact_of_another_contract_is_never_a_candidate(self):
        self.api.artifact["name"] = reuse.PREFIX + "0" * 64 + "-1"
        report = {}
        with mock.patch.object(self.api, "download") as download:
            self.assertFalse(self.restore_reuse(report=report))
            download.assert_not_called()
        self.assertIn("no_matching_contract_artifact", report["miss_reasons"])
        self.assertFalse(self.consumer.exists())

    def test_named_candidate_still_requires_producer_validation(self):
        cases = {
            "untrusted_producer": (
                lambda: self.api.run.update({"head_repository": {"full_name": "fork/cmux"}}),
                "producer_consumer_pair_disallowed",
            ),
            "failed_compile": (
                lambda: self.api.job.update({"conclusion": "failure"}),
                "producer_compile_unsuccessful",
            ),
            "product_inputs_changed": (
                lambda: self.api.product_identities.__setitem__(
                    "abc123", {**self.contract["product_inputs"], "source": "f" * 64}),
                "producer_product_inputs_mismatch",
            ),
            "oversize_archive": (
                lambda: self.api.artifact.update({"size_in_bytes": reuse.MAX_ARCHIVE_BYTES + 1}),
                "artifact_oversize",
            ),
            "expired_artifact": (
                lambda: self.api.artifact.update({"expired": True}),
                "artifact_expired",
            ),
            "missing_digest": (
                lambda: self.api.artifact.pop("digest"),
                "artifact_digest_missing",
            ),
        }
        for name, (mutate, expected) in cases.items():
            with self.subTest(name=name):
                self.setUp()
                mutate()
                report = {}
                with mock.patch.object(self.api, "download") as download:
                    self.assertFalse(self.restore_reuse(report=report))
                    download.assert_not_called()
                self.assertIn(expected, report["miss_reasons"])
                self.assertFalse(self.consumer.exists())

    def test_artifact_listing_errors_are_misses_not_failures(self):
        original_get = self.api.get
        cases = {
            "api_error": subprocess.CalledProcessError(1, "gh"),
            "transport_error": OSError("artifact listing unavailable"),
            "invalid_json": ValueError("no JSON object could be decoded"),
        }
        for name, error in cases.items():
            with self.subTest(name=name):
                def failing(path, error=error):
                    if path.startswith("actions/artifacts?"):
                        raise error
                    return original_get(path)
                report = {}
                with mock.patch.object(self.api, "get", side_effect=failing), \
                        mock.patch.object(self.api, "download") as download:
                    self.assertFalse(self.restore_reuse(report=report))
                    download.assert_not_called()
                self.assertIn("artifact_listing_unavailable", report["miss_reasons"])
                self.assertIn("no_matching_contract_artifact", report["miss_reasons"])
                self.assertFalse(self.consumer.exists())

        def malformed(path):
            if path.startswith("actions/artifacts?"):
                return {"artifacts": "not-a-list"}
            return original_get(path)
        report = {}
        with mock.patch.object(self.api, "get", side_effect=malformed):
            self.assertFalse(self.restore_reuse(report=report))
        self.assertIn("artifact_listing_invalid", report["miss_reasons"])
        self.assertFalse(self.consumer.exists())

    def test_multi_hop_reuse_preserves_original_producer(self):
        first_report = {}
        self.assertTrue(self.restore_reuse(report=first_report))
        first_provenance = json.loads(
            (self.consumer / "Build/Products/cmux-original-producer.json").read_text())
        self.assertEqual(first_provenance["original_producer"]["run_id"], "12")
        self.assertEqual(first_provenance["immediate_producer"]["run_id"], "12")

        root = self.consumer / "Build/Products"
        (root / reuse.RECEIPT).write_text(json.dumps({
            "contract": self.contract,
            "revision": "def456",
            "run_id": "13",
            "run_attempt": "1",
        }))
        second_archive = self.consumer.parent / "second-artifact.zip"
        self.api.archive = second_archive
        self.api.artifact.update({
            "id": 43,
            "name": reuse.PREFIX + reuse.key(self.contract) + "-1",
            "workflow_run": {"id": 13},
            "expired": False,
        })
        self.api.artifact["digest"] = self.package(self.consumer, second_archive)
        self.api.run.update({
            "id": 13,
            "run_attempt": 1,
            "head_sha": "def456",
            "event": "pull_request",
            "pull_requests": [{"number": 7}],
        })
        # This producer reused the original product, so its compile step was skipped
        # even though the compile-admission job itself completed successfully.
        self.api.job["steps"] = []
        self.api.consumer_run.update({
            "id": 15,
            "run_attempt": 1,
            "head_sha": "fed789",
            "event": "merge_group",
            "pull_requests": [],
        })
        self.api.product_identities["fed789"] = self.contract["product_inputs"]
        second = self.consumer.parent / "second-consumer" / "derived"
        second_report = {}
        self.assertTrue(self.restore_reuse(
            current_run="15",
            revision="fed789",
            destination=second,
            report=second_report,
        ))
        provenance = json.loads(
            (second / "Build/Products/cmux-original-producer.json").read_text())
        self.assertEqual(provenance["original_producer"]["run_id"], "12")
        self.assertEqual(provenance["original_producer"]["revision"], "abc123")
        self.assertEqual(provenance["immediate_producer"]["run_id"], "13")
        self.assertEqual(provenance["immediate_producer"]["revision"], "def456")
        self.assertEqual(provenance["consumer"]["run_id"], "15")
        self.assertEqual(provenance["consumer"]["revision"], "fed789")
        self.assertEqual(provenance["restore_route"], "github_artifact")
        self.assertEqual(provenance["metrics"]["compile_seconds_avoided"], 600.0)
        self.assertEqual(second_report["compile_seconds_avoided"], 600.0)


    def test_tar_cannot_escape_staging(self):
        tarbytes = io.BytesIO()
        with tarfile.open(fileobj=tarbytes, mode='w:gz') as tar:
            member = tarfile.TarInfo('../escape')
            member.size = 1
            tar.addfile(member, io.BytesIO(b'x'))
        with zipfile.ZipFile(self.api.archive, 'w') as z:
            z.writestr('app-host-products.tar.gz', tarbytes.getvalue())
        self.api.artifact['digest'] = 'sha256:' + hashlib.sha256(self.api.archive.read_bytes()).hexdigest()
        self.assertFalse(self.restore_reuse())
        self.assertFalse((self.producer.parent / 'escape').exists())


class ContractParity(unittest.TestCase):
    """PR compile admission and E2E dispatches must name one product alike.

    The artifact name is the hash of `contract()`, so any control one lane
    hashes differently from the other gives the same compiled revision two
    names, and the E2E lane can never find what a pull request compiled.
    """

    ROOT = Path(__file__).resolve().parents[1]
    # Setup steps that put a tool `contract()` fingerprints on PATH, matched
    # against what a step executes: its `uses` action, or a `run` command.
    TOOL_SETUP = {
        "rust": re.compile(r"^(?:(?:bash|sh)\s+)?(?:\S*/)?install-rust-ci\.sh(?:\s|;|$)"),
        "bun": re.compile(r"^oven-sh/setup-bun@"),
        "zig": re.compile(r"^(?:(?:bash|sh)\s+)?(?:\S*/)?install-zig-ci\.sh(?:\s|;|$)"),
        "node": re.compile(r"^actions/setup-node@"),
        "go": re.compile(r"^actions/setup-go@"),
    }

    def jobs(self):
        import yaml
        identity = reuse.product_inputs
        admission = yaml.safe_load((self.ROOT / identity.CI_WORKFLOW).read_text())
        e2e = yaml.safe_load((self.ROOT / identity.E2E_WORKFLOW).read_text())
        return {"admission": admission["jobs"][identity.MACOS_ADMISSION_JOB],
                "e2e": e2e["jobs"][identity.E2E_BUILD_JOB]}

    def job_env(self, job):
        # As a step sees them: YAML `true` reaches it as the string "true".
        return {name: str(value).lower() if isinstance(value, bool) else str(value)
                for name, value in job.get("env", {}).items()}

    def executed(self, step):
        """What a step runs: its action, and each non-comment line of `run`."""
        lines = [step["uses"]] if "uses" in step else []
        lines += [line.strip() for line in str(step.get("run", "")).splitlines()
                  if line.strip() and not line.strip().startswith("#")]
        return lines

    def tools(self, steps):
        return {tool for step in steps for line in self.executed(step)
                for tool, pattern in self.TOOL_SETUP.items() if pattern.search(line)}

    def tools_before_key(self, job):
        steps = job["steps"]
        key_step = next(index for index, step in enumerate(steps)
                        if any("reuse_app_host_products.py key" in line
                               for line in self.executed(step)))
        return self.tools(steps[:key_step])

    def test_tool_scan_counts_what_a_step_runs_not_what_it_mentions(self):
        self.assertEqual(self.tools([
            {"name": "Note", "run": "# ./scripts/install-zig-ci.sh is not needed\necho oven-sh/setup-bun"},
            {"name": "Echo", "run": 'echo "installing via ./scripts/install-rust-ci.sh"'},
        ]), set())
        self.assertEqual(self.tools([
            {"name": "Setup Bun", "uses": "oven-sh/setup-bun@0c5077e51419868618aeaa5fe8019c62421857d6"},
            {"name": "Install zig", "run": "set -e\n./scripts/install-zig-ci.sh"},
            {"name": "Install Rust", "run": "bash scripts/install-rust-ci.sh --profile ci"},
        ]), {"bun", "zig", "rust"})
        self.assertEqual(self.job_env({"env": {"A": True, "B": 1}}), {"A": "true", "B": "1"})

    def contract_with(self, environ, xcode="Xcode 26.6\nBuild version 17F113"):
        answers = {"xcodebuild": xcode, "xcrun": "25F70", "sw_vers": "25D125"}
        with mock.patch.dict(os.environ, environ, clear=True), \
                mock.patch.object(reuse, "read", side_effect=lambda *args: answers[args[0]]), \
                mock.patch.object(reuse.shutil, "which", return_value=None), \
                mock.patch.object(reuse.product_inputs, "local_identity", return_value={"source": "s"}):
            return reuse.contract()

    def test_contract_names_the_selected_xcode_not_its_selector(self):
        # Admission pins Xcode by path; an E2E dispatch picks the same Xcode by
        # its SDK. Both select Xcode 26.6, so both must name one product.
        pinned = self.contract_with({
            "CMUX_CI_XCODE_APP": "/Applications/Xcode_26.6.app",
            "CMUX_CI_REQUIRED_MACOS_SDK_MAJOR": "26",
            "CMUX_SKIP_ZIG_BUILD": "1",
        })
        selected = self.contract_with({"CMUX_SKIP_ZIG_BUILD": "1"})
        self.assertEqual(reuse.key(pinned), reuse.key(selected))
        # What was selected still separates products.
        other_xcode = self.contract_with(
            {"CMUX_SKIP_ZIG_BUILD": "1"}, xcode="Xcode 26.7\nBuild version 17G1")
        self.assertNotEqual(reuse.key(selected), reuse.key(other_xcode))
        # A real build control still does too.
        zig_built = self.contract_with({"CMUX_SKIP_ZIG_BUILD": ""})
        self.assertNotEqual(reuse.key(selected), reuse.key(zig_built))

    def test_both_lanes_set_every_hashed_build_control_alike(self):
        envs = {name: self.job_env(job) for name, job in self.jobs().items()}
        for control in reuse.CONTRACT_ENVIRONMENT:
            with self.subTest(control=control):
                self.assertEqual(envs["admission"].get(control), envs["e2e"].get(control))

    def test_both_lanes_install_the_same_fingerprinted_tools_before_keying(self):
        tools = {name: self.tools_before_key(job) for name, job in self.jobs().items()}
        self.assertIn("rust", tools["admission"])
        self.assertEqual(tools["admission"], tools["e2e"])


class FakeGitHub:
    repository = "manaflow-ai/cmux"

    def __init__(self, contract):
        self.product_identities = {
            "abc123": contract["product_inputs"],
            "def456": contract["product_inputs"],
        }
        self.artifact = {
            "id": 42,
            "name": reuse.PREFIX + reuse.key(contract) + "-1",
            "size_in_bytes": 100,
            "expired": False,
            "workflow_run": {"id": 12},
        }
        self.artifacts = [self.artifact]
        self.artifact_queries = []
        # Parent revisions GitHub reports for a commit, so a pull request
        # producer's ephemeral merge commit can be bound to its attested head.
        self.commit_parents = {}
        self.run = {
            "id": 12,
            "path": ".github/workflows/ci.yml",
            "event": "pull_request",
            "head_repository": {"full_name": self.repository},
            "pull_requests": [{"number": 7}],
            "run_attempt": 1,
            "head_sha": "abc123",
            "html_url": "https://github.com/manaflow-ai/cmux/actions/runs/12",
        }
        self.consumer_run = {
            "id": 13,
            "path": ".github/workflows/ci.yml",
            "event": "pull_request",
            "head_repository": {"full_name": self.repository},
            "pull_requests": [{"number": 7}],
            "run_attempt": 1,
            "head_sha": "def456",
            "html_url": "https://github.com/manaflow-ai/cmux/actions/runs/13",
        }
        self.job = {
            "name": "macOS compile admission",
            "conclusion": "success",
            "status": "completed",
            "steps": [{
                "name": "Compile app-host test product",
                "conclusion": "success",
                "status": "completed",
                "started_at": "2026-09-21T08:00:00Z",
                "completed_at": "2026-09-21T08:10:00Z",
            }],
        }

    def get(self, path):
        if path.startswith("actions/artifacts?"):
            query = parse_qs(path.split("?", 1)[1])
            self.artifact_queries.append(path)
            # The real endpoint returns only exact name matches when `name` is
            # given; an unfiltered listing would reach just the newest few
            # hundred artifacts of a fast-churning repository.
            names = query.get("name")
            if not names:
                raise AssertionError(f"unfiltered artifact listing: {path}")
            return {"artifacts": [a for a in self.artifacts if a.get("name") == names[0]]}
        if path == f"actions/runs/{self.consumer_run['id']}":
            return self.consumer_run
        match = __import__("re").fullmatch(r"actions/runs/(\d+)/attempts/(\d+)", path)
        if match:
            run_id, attempt = map(int, match.groups())
            if run_id == int(self.run["id"]) and attempt == int(self.run["run_attempt"]):
                return self.run
            raise OSError("attempt unavailable")
        match = __import__("re").fullmatch(
            r"actions/runs/(\d+)/attempts/(\d+)/jobs\?per_page=100&page=(\d+)", path)
        if match:
            run_id, attempt, _ = map(int, match.groups())
            if run_id == int(self.run["id"]) and attempt == int(self.run["run_attempt"]):
                return {"jobs": [self.job]}
            raise OSError("jobs unavailable")
        if path.startswith("git/commits/"):
            revision = path[len("git/commits/"):]
            return {
                "tree": {"sha": "f" * 40},
                "parents": [{"sha": sha} for sha in self.commit_parents.get(revision, [])],
            }
        raise AssertionError(path)

    def download(self, artifact_id, target, size):
        assert artifact_id == self.artifact["id"]
        assert size == self.artifact["size_in_bytes"]
        shutil.copyfile(self.archive, target)


if __name__ == '__main__':
    unittest.main()
