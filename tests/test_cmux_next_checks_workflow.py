#!/usr/bin/env python3
"""The cmux-next checks job runs every check, then fails once with the list of reds.

The job used to stop at its first failing step. The god-files step failed on
cmux-tui Rust files, so the Swift god-type, concurrency, crash-safety, module
resource and string-table checks never ran and their reds stayed hidden. Each
check step now continues on error, and a final `if: always()` step reads every
check's `outcome` (its `conclusion` is success under continue-on-error) and
fails the job naming each red step. The cmux-tui Rust ratchet is its own step,
so it can never mask the Swift god-type check.
"""
from __future__ import annotations

import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-next.yml"
GODFILES = ROOT / "scripts/cmux-next/check-no-godfiles.sh"
JOB = "checks"


def steps() -> list[dict]:
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"][JOB]["steps"]


def is_setup(step: dict) -> bool:
    """Checkout and toolchain steps: an action, not a check script."""
    return "uses" in step


class ChecksJobStructure(unittest.TestCase):
    def split(self) -> tuple[list[dict], list[dict], dict]:
        all_steps = steps()
        aggregate = all_steps[-1]
        body = all_steps[:-1]
        return [s for s in body if is_setup(s)], [s for s in body if not is_setup(s)], aggregate

    def test_setup_steps_stop_the_job(self):
        setup, _, _ = self.split()
        self.assertTrue(setup, "the job checks out the repository")
        for step in setup:
            with self.subTest(step=step.get("name", step["uses"])):
                self.assertNotIn("continue-on-error", step)

    def test_every_check_step_has_an_id_and_continues_on_error(self):
        _, checks, _ = self.split()
        self.assertGreaterEqual(len(checks), 6)
        ids = [step.get("id") for step in checks]
        self.assertEqual(len(ids), len(set(ids)), ids)
        for step in checks:
            with self.subTest(step=step["name"]):
                self.assertTrue(step.get("id"), "a check step needs an id for the aggregate to read")
                self.assertIs(step.get("continue-on-error"), True)
                self.assertNotIn("if", step, "a check that may skip itself hides its result")

    def test_aggregate_reads_every_check_outcome(self):
        _, checks, aggregate = self.split()
        self.assertEqual(aggregate.get("if"), "always()")
        self.assertNotIn("continue-on-error", aggregate)
        text = yaml.safe_dump(aggregate)
        self.assertNotIn(".conclusion", text, "continue-on-error makes every conclusion success")
        read = re.findall(r"steps\.([A-Za-z0-9_-]+)\.outcome", text)
        self.assertEqual(sorted(read), sorted(step["id"] for step in checks))
        # Each outcome is listed with its step's name, so the summary names the red step.
        outcomes = aggregate["env"]["OUTCOMES"]
        for step in checks:
            with self.subTest(step=step["name"]):
                self.assertIn("${{ steps.%s.outcome }}|%s\n" % (step["id"], step["name"]), outcomes)
        self.assertIn("GITHUB_STEP_SUMMARY", aggregate["run"])
        self.assertIn("exit 1", aggregate["run"])

    def run_aggregate(self, outcomes: str) -> subprocess.CompletedProcess:
        _, _, aggregate = self.split()
        with tempfile.NamedTemporaryFile() as summary:
            return subprocess.run(
                ["bash", "-c", aggregate["run"]],
                env={**os.environ, "OUTCOMES": outcomes, "GITHUB_STEP_SUMMARY": summary.name},
                capture_output=True,
                text=True,
            )

    def test_aggregate_fails_closed_on_an_empty_outcome(self):
        # An id typo renders `${{ steps.x.outcome }}` as empty; that check never ran.
        for outcomes in ("|Lint\n", "|Crash safety\nsuccess|Lint\n"):
            with self.subTest(outcomes=outcomes):
                result = self.run_aggregate(outcomes)
                self.assertEqual(result.returncode, 1, result.stdout)
                name = outcomes.split("\n")[0].split("|")[1]
                self.assertIn("- %s (not run)" % name, result.stdout)

    def test_aggregate_passes_when_every_check_succeeds(self):
        result = self.run_aggregate("success|Lint\nsuccess|Crash safety\n")
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_package_conventions_lint_is_its_own_step(self):
        # test-ios.yml runs this lint only for pull requests, merge groups and
        # dispatches; direct pushes to feat-cmux-next skipped it, and a
        # namespace-type red (CloudLinkSocketPolicy) reached the base unseen.
        _, checks, _ = self.split()
        lint = [step for step in checks if "lint-ios-package-conventions.sh" in step["run"]]
        self.assertEqual(len(lint), 1, [step["name"] for step in checks])
        self.assertEqual(lint[0]["run"].strip(), "./scripts/lint-ios-package-conventions.sh")
        document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        # PyYAML reads the `on:` key as True.
        push_paths = document[True]["push"]["paths"]
        for path in ("Packages/macOS/**", "Packages/Shared/**", "Packages/iOS/**",
                     "scripts/lint-ios-package-conventions*", "scripts/lint_swift_namespaces.py",
                     "scripts/lint-namespace-types-*.txt", "scripts/swift_source_mask.py"):
            with self.subTest(path=path):
                self.assertIn(path, push_paths)

    def test_rust_ratchet_is_its_own_step(self):
        _, checks, _ = self.split()
        godfile_runs = [step["run"] for step in checks if "check-no-godfiles.sh" in step["run"]]
        self.assertEqual(len(godfile_runs), 2, godfile_runs)
        self.assertEqual(sum("--only swift" in run for run in godfile_runs), 1, godfile_runs)
        self.assertEqual(sum("--only rust" in run for run in godfile_runs), 1, godfile_runs)


class GodfileScopes(unittest.TestCase):
    """`--only swift` and `--only rust` each check their half, at unchanged budgets."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        repo = Path(cls.tmp.name)
        package = repo / "Packages/macOS/CmuxNext"
        (package / "Sources/Fixture").mkdir(parents=True)
        (package / "Tests").mkdir()
        # A 401-line Swift file (limit 400) and a 1001-line Swift type (limit 1000).
        (package / "Sources/Fixture/Wide.swift").write_text("let wide = 0\n" * 401)
        body = "".join(f"    let field{i} = {i}\n" for i in range(997))
        (package / "Sources/Fixture/Huge.swift").write_text("struct Huge {\n" + body + "}\n")
        (package / "Sources/Fixture/HugeMore.swift").write_text("extension Huge {\n}\n")
        rust = repo / "cmux-tui/crates/fixture/src"
        rust.mkdir(parents=True)
        # Rust budgets: 1000 lines, 60 fns; tests 1500 lines, 120 fns.
        (rust / "long.rs").write_text("// x\n" * 1001)
        (rust / "at_budget.rs").write_text("// x\n" * 1000)
        (rust / "many_fns.rs").write_text("fn f() {}\n" * 61)
        (rust / "tests.rs").write_text("fn t() {}\n" * 120 + "// x\n" * 1380)
        git = ["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
        subprocess.run([*git, "init", "-q"], check=True)
        subprocess.run([*git, "add", "."], check=True)
        subprocess.run([*git, "commit", "-qm", "fixture"], check=True)
        cls.package = package

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_check(self, *args: str) -> subprocess.CompletedProcess:
        env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        return subprocess.run(["bash", str(GODFILES), *args, str(self.package)],
                              capture_output=True, text=True, env=env, timeout=120)

    def test_swift_scope_reports_only_swift(self):
        result = self.run_check("--only", "swift")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("Wide.swift has 401 lines (limit 400)", result.stdout)
        self.assertIn("type Fixture/Huge spans 1001 lines", result.stdout)
        self.assertNotIn("cmux-tui/", result.stdout)

    def test_rust_scope_reports_only_rust_at_unchanged_budgets(self):
        result = self.run_check("--only", "rust")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertNotIn(".swift", result.stdout)
        self.assertNotIn("god type", result.stdout)
        self.assertIn("long.rs has 1001 lines, 0 fns (limit 1000 lines, 60 fns", result.stdout)
        self.assertIn("many_fns.rs has 61 lines, 61 fns (limit 1000 lines, 60 fns", result.stdout)
        self.assertNotIn("at_budget.rs", result.stdout)
        self.assertNotIn("fixture/src/tests.rs", result.stdout)
        # Baseline entries of the other half are not reported as gone.
        self.assertNotIn("swift-type", result.stdout)

    def test_unscoped_run_still_checks_both(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("Wide.swift", result.stdout)
        self.assertIn("long.rs", result.stdout)

    def test_scope_cannot_rewrite_the_baseline(self):
        # A scoped baseline rewrite would drop the other half's entries.
        result = self.run_check("--update-baseline", "--only", "rust")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--only", result.stdout + result.stderr)

    def test_unknown_scope_is_rejected(self):
        result = self.run_check("--only", "go")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)


class PathRoutingStructure(unittest.TestCase):
    def test_path_route_gates_each_mac_job_on_its_tier(self):
        """tests/test_cmux_next_route.py covers which paths reach which tier."""
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        route = jobs["path_route"]
        for output in ("native", "macos", "scheme", "generated", "swift", "daemon", "full", "swift_filter", "swift_targets"):
            self.assertIn(output, route["outputs"])
        self.assertIn("scripts/ci/cmux_next_route.py", route["steps"][-1]["run"])
        self.assertIn("needs.path_route.outputs.macos", jobs["macos-placement"]["if"])
        self.assertIn("needs.path_route.outputs.swift == 'true'", jobs["swift-test"]["if"])
        self.assertIn("needs.path_route.outputs.daemon == 'true'", jobs["daemon-test"]["if"])
        self.assertIn("needs.path_route.outputs.generated == 'true'", jobs["generated-files"]["if"])
        self.assertIn("needs.path_route.outputs.native", jobs["release-compile"]["if"])
        self.assertIn("needs.path_route.outputs.scheme == 'true'", jobs["cmux-scheme-compile"]["if"])

    def test_package_tests_never_wait_for_the_cmux_tui_tree(self):
        """#17470's swift test spent 13 of 29 minutes waiting for the base tree."""
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        swift = jobs["swift-test"]
        self.assertNotIn("same-tree-cmux-tui", swift["needs"])
        self.assertFalse([step for step in swift["steps"] if "pin-cmux-tui.sh" in step.get("run", "")])
        self.assertIn("SWIFT_FILTER", swift["env"])

    def test_generated_files_are_checked_outside_the_package_tests(self):
        """a925bd9 went red when PRs that skipped swift test landed a stale export."""
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        runs = " ".join(step.get("run", "") for step in jobs["generated-files"]["steps"])
        self.assertIn("check-action-surfaces.sh", runs)
        self.assertIn("ci-target-graph.py --check", runs)
        self.assertNotIn("same-tree-cmux-tui", jobs["generated-files"]["needs"])
        swift_runs = " ".join(step.get("run", "") for step in jobs["swift-test"]["steps"])
        self.assertNotIn("check-action-surfaces.sh", swift_runs)

    def test_autofix_pushes_only_generated_paths_of_same_repository_prs(self):
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        autofix = jobs["generated-autofix"]
        self.assertIn("head.repo.full_name == github.repository", autofix["if"])
        self.assertNotIn("vars.", str(autofix["runs-on"]))
        run = autofix["steps"][-1]["run"]
        self.assertIn("plans/cmux-next/*.json|plans/cmux-next/*.md|Packages/macOS/CmuxNext/ci-target-graph.json) ;;", run)
        self.assertIn('"$current" != "$HEAD_SHA"', run)
        self.assertNotIn("--force", run)
        # Never a bot push to a protected branch.
        self.assertIn("github.event.pull_request.head.ref != 'main'", autofix["if"])
        # The regenerated files are copied onto the head, not patched against
        # the merge commit, whose context the head may not have.
        self.assertNotIn("git apply \"$patch\"", run)
        self.assertIn("git add", run)

    def test_the_tree_gate_pins_an_unpublished_tree_itself(self):
        """Publisher run 37505519359 failed and its retry was replaced by a newer push; lanes
        pushed cmux-tui-pin-* branches by hand until the gate does it (pin-cmux-tui.sh)."""
        gate = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["same-tree-cmux-tui"]
        self.assertEqual(gate["permissions"], {"actions": "write", "contents": "write"})
        wait = next(step for step in gate["steps"] if step.get("id") == "wait")
        self.assertIn("github.event.pull_request.head.repo.full_name == github.repository", wait["env"]["CMUX_TUI_TREE_AUTOPIN"])
        self.assertEqual(wait["env"]["CMUX_TUI_TREE_RUN_CHECK_SECONDS"], "120")
        # A pull request watches its base commit, the merge's first parent.
        self.assertIn('CMUX_TUI_TREE_PUBLISHER_SHA="$(git rev-parse HEAD^1)"', wait["run"])
        self.assertIn("scripts/cmux-next/pin-cmux-tui.sh wait", wait["run"])
        checkout = gate["steps"][0]
        self.assertGreaterEqual(checkout["with"]["fetch-depth"], 2)

    def test_red_push_runs_name_their_pull_requests(self):
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        attribution = jobs["push-attribution"]
        self.assertIn("failure()", attribution["if"])
        self.assertIn("github.event_name == 'push'", attribution["if"])
        for job_id in ("checks", "generated-files", "swift-test", "daemon-test", "release-compile", "cmux-scheme-compile"):
            self.assertIn(job_id, attribution["needs"])

    def test_push_head_preflight_skips_superseded_macos_jobs(self):
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        preflight = jobs["push-head-preflight"]
        self.assertIn("github.sha", preflight["steps"][0]["env"]["SHA"])
        self.assertIn("git", preflight["steps"][0]["run"])
        self.assertIn("ls-remote", preflight["steps"][0]["run"])
        self.assertIn("current", preflight["outputs"])
        for job_id in ("macos-placement", "swift-test", "daemon-test", "generated-files", "release-compile", "cmux-scheme-compile"):
            job = jobs[job_id]
            needs = job["needs"] if isinstance(job["needs"], list) else [job["needs"]]
            with self.subTest(job=job_id):
                self.assertIn("push-head-preflight", needs)
                self.assertIn("needs.push-head-preflight.outputs.current == 'true'", job["if"])

    def test_current_feat_push_still_requests_nightly_next(self):
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        nightly = jobs["request-nightly-next"]
        self.assertEqual(nightly["needs"], "release-compile")
        self.assertIn("github.ref == 'refs/heads/feat-cmux-next'", nightly["if"])
        self.assertIn("needs.release-compile.result == 'success'", nightly["if"])
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("group: cmux-next-${{ github.event.pull_request.number || github.run_id }}", text)
        self.assertIn("cancel-in-progress: ${{ github.event_name == 'pull_request' }}", text)

    def test_branch_lookup_uses_git_https_basic_auth_and_a_timeout(self):
        for filename, job_id in (("cmux-next.yml", "push-head-preflight"),
                                 ("cmux-tui-artifacts.yml", "tree-preflight")):
            document = yaml.safe_load((WORKFLOW.parent / filename).read_text())
            script = document["jobs"][job_id]["steps"][-1]["run"]
            with self.subTest(workflow=filename):
                self.assertIn("Authorization: Basic", script)
                self.assertIn("x-access-token:%s", script)
                self.assertIn("timeout 15 git", script)
                self.assertNotIn("Authorization: Bearer", script)


class PushPreflightBehavior(unittest.TestCase):
    """Execute the workflow shell with bounded fake network and git responses."""

    def run_preflight(self, *, artifacts=False, event="push", ref="refs/heads/feat-cmux-next",
                      remote="a" * 40, remote_tree_key="0" * 39 + "2", published=False,
                      missing="", malformed=False, fork=False):
        filename = "cmux-tui-artifacts.yml" if artifacts else "cmux-next.yml"
        workflow = yaml.safe_load((WORKFLOW.parent / filename).read_text())
        job_id = "tree-preflight" if artifacts else "push-head-preflight"
        script = workflow["jobs"][job_id]["steps"][-1]["run"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            git = root / "git"
            git.write_text('''#!/bin/bash
case "$*" in
  *ls-remote*) [[ -z "$REMOTE_SHA" ]] && exit 1; printf '%s\\trefs/heads/feat-cmux-next\\n' "$REMOTE_SHA" ;;
  *fetch*) touch "$REMOTE_FETCH_MARKER" ;;
  *diff*) exit 0 ;;
  *rev-parse*) printf '%040d\\n' 1 ;;
  *mktree*) cat >/dev/null; if [[ -e "$REMOTE_FETCH_MARKER" ]]; then printf '%s\\n' "$REMOTE_TREE_KEY"; else printf '%040d\\n' 2; fi ;;
  *) exit 1 ;;
esac
''')
            git.chmod(0o755)
            curl = root / "curl"
            curl.write_text('''#!/bin/bash
[[ "$PUBLISHED" == true ]] || exit 22
for arg in "$@"; do
  [[ "$arg" == https://* ]] && url="$arg"
done
[[ -z "$MISSING" || "$url" != *"$MISSING"* ]] || exit 22

if [[ "$url" == *completion.json* ]]; then
  args=("$@")
  for ((index=0; index<${#args[@]}; index++)); do
    arg="${args[index]}"
    if [[ "$arg" == -o ]]; then
      outfile="${args[index + 1]}"
      cat > "$outfile" <<'JSON'
{"key":"0000000000000000000000000000000000000002","binaries":{"cmux-tui-aarch64-apple-darwin":"0000000000000000000000000000000000000000000000000000000000000000","cmux-tui-app-host-aarch64-apple-darwin":"0000000000000000000000000000000000000000000000000000000000000000","cmux-tui-cloud-server-aarch64-apple-darwin":"0000000000000000000000000000000000000000000000000000000000000000"}}
JSON
      exit 0
    fi
  done
  exit 1
fi

[[ "$MALFORMED" != true ]] || { printf 'bad checksum\\n'; exit 0; }
printf '%064d  cmux-tui-aarch64-apple-darwin\\n' 3
''')
            curl.chmod(0o755)
            output = root / "output"
            env = {**os.environ, "PATH": f"{root}:{os.environ['PATH']}",
                   "GITHUB_OUTPUT": str(output), "RUNNER_TEMP": str(root), "EVENT_NAME": event, "REF": ref,
                   "SHA": "a" * 40, "SOURCE_COMMIT": "a" * 40,
                   "REMOTE_SHA": remote, "PUBLISHED": str(published).lower(),
                   "REMOTE_TREE_KEY": remote_tree_key, "REMOTE_FETCH_MARKER": str(root / "remote-fetched"),
                   "MISSING": missing, "MALFORMED": str(malformed).lower(),
                   "HEAD_REPOSITORY": "outside/fork" if fork else "manaflow-ai/cmux",
                   "REPOSITORY": "manaflow-ai/cmux", "SERVER_URL": "https://github.com",
                   "GH_TOKEN": "fixture", "RUN_ID": "123"}
            result = subprocess.run(["bash", "-c", script], env=env, text=True,
                                    capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return dict(line.split("=", 1) for line in output.read_text().splitlines())

    def test_current_push_keeps_native_compile(self):
        self.assertEqual(self.run_preflight()["current"], "true")

    def test_superseded_push_skips_native_compile(self):
        self.assertEqual(self.run_preflight(remote="b" * 40)["current"], "false")

    def test_ref_lookup_failure_keeps_current_compile_enabled(self):
        self.assertEqual(self.run_preflight(remote="")["current"], "true")

    def test_pr_and_dispatch_are_never_superseded(self):
        for event in ("pull_request", "workflow_dispatch"):
            with self.subTest(event=event):
                self.assertEqual(self.run_preflight(event=event, remote="b" * 40)["current"], "true")

    def test_published_tree_skips_mac_build_and_daemon_tests(self):
        output = self.run_preflight(artifacts=True, published=True)
        self.assertEqual(output["tree_ready"], "true")
        self.assertEqual(output["run_macos"], "false")

    def test_partial_tree_requires_companion_repair(self):
        for missing in ("app-host", "cloud-server", "app-host-aarch64-apple-darwin?", "cloud-server-aarch64-apple-darwin?"):
            with self.subTest(missing=missing):
                output = self.run_preflight(artifacts=True, published=True, missing=missing)
                self.assertEqual(output["tree_ready"], "false")
                self.assertEqual(output["run_macos"], "true")

    def test_malformed_tree_checksum_requires_repair(self):
        output = self.run_preflight(artifacts=True, published=True, malformed=True)
        self.assertEqual(output["tree_ready"], "false")
        self.assertEqual(output["run_macos"], "true")

    def test_new_tree_schedules_mac_build_and_daemon_tests(self):
        self.assertEqual(self.run_preflight(artifacts=True)["run_macos"], "true")

    def test_same_tree_superseded_push_keeps_missing_tree_build(self):
        output = self.run_preflight(artifacts=True, remote="b" * 40)
        self.assertEqual(output["run_macos"], "true")
        self.assertEqual(output["superseded"], "false")

    def test_same_tree_superseded_push_skips_complete_tree_build(self):
        output = self.run_preflight(artifacts=True, remote="b" * 40, published=True)
        self.assertEqual(output["run_macos"], "false")
        self.assertEqual(output["superseded"], "true")

    def test_distinct_tree_superseded_push_keeps_missing_tree_build(self):
        output = self.run_preflight(artifacts=True, remote="b" * 40, remote_tree_key="3" * 40)
        self.assertEqual(output["run_macos"], "true")
        self.assertEqual(output["superseded"], "false")

    def test_main_keeps_commit_and_latest_publication(self):
        self.assertEqual(self.run_preflight(artifacts=True, ref="refs/heads/main",
                                            published=True)["run_macos"], "true")

    def test_manual_republish_keeps_commit_artifacts_enabled(self):
        self.assertEqual(self.run_preflight(artifacts=True, event="workflow_dispatch",
                                            ref="refs/heads/cmux-tui-pin-repair",
                                            published=True)["run_macos"], "true")

    def test_pin_push_keeps_commit_artifacts_enabled(self):
        self.assertEqual(self.run_preflight(artifacts=True, ref="refs/heads/cmux-tui-pin-repair",
                                            published=True)["run_macos"], "true")

    def test_fork_never_schedules_trusted_build(self):
        self.assertEqual(self.run_preflight(artifacts=True, event="pull_request_target",
                                            fork=True)["run_macos"], "false")


RESET_STALE_SUBMODULES = "scripts/ci/reset-stale-submodules.sh"


def can_run_on_owned_runner(job: dict) -> bool:
    """A runs-on that reads a repository variable can resolve to a mini (glaeda-*)."""
    return "vars." in str(job.get("runs-on", ""))


class ReusedWorkspaceSubmodules(unittest.TestCase):
    """A reused mini workspace keeps the previous job's submodule checkouts.

    actions/checkout with `submodules: false` moves the superproject but leaves
    ghostty at the last branch's commit, so pin-cmux-tui.sh fetch saw ` M ghostty`
    and refused the checkout (run 37198483749). Every such checkout on a job
    that can run on a mini is followed at once by the reset step.
    """

    def test_every_submodule_free_checkout_on_an_owned_runner_resets_submodules(self):
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        checked = []
        for job_id, job in jobs.items():
            if not can_run_on_owned_runner(job):
                continue
            job_steps = job.get("steps", [])
            for index, step in enumerate(job_steps):
                if not str(step.get("uses", "")).startswith("actions/checkout@"):
                    continue
                if str(step.get("with", {}).get("submodules", False)).lower() in ("true", "recursive"):
                    continue
                checked.append(job_id)
                with self.subTest(job=job_id):
                    following = job_steps[index + 1] if index + 1 < len(job_steps) else {}
                    self.assertIn(RESET_STALE_SUBMODULES, following.get("run", ""),
                                  "the step after checkout must drop stale submodule checkouts")
        self.assertEqual(sorted(checked), ["cmux-scheme-compile", "daemon-test", "generated-files", "release-compile",
                                           "same-tree-cmux-tui", "swift-test"])



class SupersededCommitIsNotRed(unittest.TestCase):
    """A superseded commit's cmux-next run skips the jobs that need its tree.

    Queued cmux-tui artifacts runs of an older branch head are superseded by
    design, so that commit's same-tree cmux-tui is never published. The gate
    job runs `pin-cmux-tui.sh wait` on a Linux runner (no macOS runner waits
    for a tree) and reports superseded=true; every job that fetches the tree
    then ends skipped, not failed. A real publish failure fails the gate.
    """

    GATE = "same-tree-cmux-tui"

    def jobs(self) -> dict:
        return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]

    def test_the_gate_waits_for_the_tree_and_reports_superseded(self):
        gate = self.jobs().get(self.GATE)
        self.assertIsNotNone(gate, f"no {self.GATE} job")
        self.assertEqual(gate.get("outputs", {}).get("superseded"), "${{ steps.wait.outputs.superseded }}")
        runs = [step for step in gate["steps"] if "pin-cmux-tui.sh wait" in step.get("run", "")]
        self.assertEqual(len(runs), 1)
        self.assertEqual(runs[0].get("id"), "wait")
        self.assertIn("ubuntu", gate["runs-on"])
        self.assertNotIn("macos", gate["runs-on"])

    def test_every_tree_fetching_job_skips_a_superseded_commit(self):
        fetching = {
            name: job for name, job in self.jobs().items()
            if any("pin-cmux-tui.sh fetch" in step.get("run", "") for step in job.get("steps", []))
        }
        self.assertTrue(fetching)
        for name, job in fetching.items():
            with self.subTest(job=name):
                self.assertIn(self.GATE, job["needs"])
                condition = " ".join(job["if"].split())
                self.assertIn(f"needs.{self.GATE}.result == 'success'", condition)
                self.assertIn(f"needs.{self.GATE}.outputs.superseded != 'true'", condition)


if __name__ == "__main__":
    unittest.main()
