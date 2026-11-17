#!/usr/bin/env python3
"""The warm nightly-next builder's checkout gives the whole tree, whatever the job before it left.

On the one-mini nightly (vars.CI_NIGHTLY_MINI) one runner has the builder label and the signing
label, so build-nightly-app, the signer and the deltas jobs share one kept workspace. The signer
and the deltas jobs check out sparse with actions/checkout. The step "Checkout build ref (warm
nightly-next builder)" then ran `checkout --force`, `clean` and `reset --hard` and never turned the
sparse checkout off, so the build tree had only the files the last sparse job kept.

Run 42833135477 (2026-11-10, runner cmux-lawrence-2): republish-nightly-deltas ran
`git sparse-checkout set scripts` at 14:28:28Z, build-nightly-app's warm checkout ran at
14:29:38Z, and "Select Xcode" failed at 14:29:40Z: "Cannot read the required Xcode version:
.../_work/cmux/cmux/.xcode-version is missing".

Why `sparse-checkout: scripts` hid the root files there (cone mode keeps them): the signer's
non-cone checkout writes core.sparseCheckout=true in .git/config, and `git sparse-checkout set`
with sparse checkout already on keeps the mode it finds, so "scripts" became a non-cone pattern.
Why a full actions/checkout in between did not repair it: its `git sparse-checkout disable` writes
false in config.worktree, then it unsets extensions.worktreeConfig, so .git/config's true wins
again and its `checkout --force` hides the files again (the resume job at 14:27:27Z: "Updating
files: 100% (45191/45191)" = the 45150 files outside the pattern plus 41 changed inside it).

This test runs the step's own `run:` text from nightly.yml in a temp workspace whose origin is a
local repository. Each workspace state is made with the git commands actions/checkout v6.0.2
printed in those job logs, from the `with:` of the workflow's own sparse checkout steps.

Run 42940891027 (2026-11-11, ultra1-glaeda-nightly-only-xl-2): the warm checkout's `git clean -ffdxq`
failed with hundreds of "failed to remove .build/go-path/pkg/mod/gvisor.dev/...: Permission denied".
The build before it compiled acpmux in the clone: scripts/ci/tailnet-go.sh set GOFLAGS empty and
GOMODCACHE under .build/go-path, Go writes its module cache read-only, so `git clean` could not
remove it and `set -e` ended the step. The "Go module cache" tests make that cache with this
machine's `go` through the helper (skipped with no Go 1.21 or later) and run the step after it.

Run it yourself after changing the warm checkout step, a sparse checkout of a job that can share
its runner, or tailnet-go.sh: python3 tests/test_nightly_warm_checkout_sparse.py (about 5 s, git
and go only, no network, no Mac).
"""
from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

import yaml
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/nightly.yml"
JOBS = yaml.safe_load(WORKFLOW.read_text())["jobs"]
WARM_STEP = "Checkout build ref (warm nightly-next builder)"
LEAN_PATTERNS = json.loads((ROOT / ".github/checkout-lean.json").read_text())["sparse_checkout"]
KEPT_TARGET = "cmux-tui/target/release/kept.o"
TAILNET_GO = ROOT / "scripts/ci/tailnet-go.sh"
GO_PATH = ".build/go-path"

OLD_TREE = {
    ".xcode-version": "26.6\n",
    "scripts/select-ci-xcode.sh": "#!/usr/bin/env bash\n",
    "scripts/ci/git_fetch_retry.py": (ROOT / "scripts/ci/git_fetch_retry.py").read_text(),
    "Sources/App.swift": "let build = 1\n",
    "webviews/scripts/build.mjs": "export {}\n",
    "cmux-next-ios/verify/evidence.txt": "evidence\n",
}
NEW_TREE = {**OLD_TREE, "Sources/App.swift": "let build = 2\n", "Sources/New.swift": "let added = true\n",
            "scripts/ci/new-step.sh": "#!/usr/bin/env bash\n"}


def step(job: str, name: str) -> dict:
    return next(s for s in JOBS[job]["steps"] if s.get("name") == name)


class WarmCheckoutTest(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.temp = Path(temp.name)
        self.env = git_fixture_env.fixture_env({
            "PATH": f"{self.temp / 'bin'}{os.pathsep}{os.environ['PATH']}", "HOME": str(self.temp / "home"),
            "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0",
            "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
        })
        for folder in ("bin", "home", "runner-temp"):
            (self.temp / folder).mkdir()
        # The step's helper download must not reach the network from a test.
        (self.temp / "bin/curl").write_text("#!/bin/sh\nexit 7\n")
        (self.temp / "bin/curl").chmod(0o755)
        self.origin = self.temp / "origin"
        self.git(self.temp, "init", "-q", "-b", "main", str(self.origin))
        self.git(self.origin, "config", "uploadpack.allowAnySHA1InWant", "true")
        self.old = self.commit(OLD_TREE, "the build before")
        self.new = self.commit(NEW_TREE, "the build to check out")
        self.ws = self.temp / "ws"

    # -- helpers ---------------------------------------------------------------------------------

    def git(self, cwd: Path, *args: str, check: bool = True) -> str:
        result = subprocess.run(["git", *args], cwd=cwd, env=self.env, capture_output=True, text=True)
        if check and result.returncode != 0:
            self.fail(f"git {' '.join(args)}: exit {result.returncode}\n{result.stderr}")
        return result.stdout.strip()

    def commit(self, tree: dict[str, str], message: str) -> str:
        for name, text in tree.items():
            path = self.origin / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        self.git(self.origin, "add", "-A")
        self.git(self.origin, "commit", "-qm", message)
        return self.git(self.origin, "rev-parse", "HEAD")

    def kept_workspace(self) -> None:
        """A workspace an earlier warm build left: the whole tree of the earlier build commit."""
        self.git(self.temp, "init", "-q", str(self.ws))
        self.git(self.ws, "remote", "add", "origin", str(self.origin))
        self.git(self.ws, "fetch", "-q", "--no-tags", "origin", self.old)
        self.git(self.ws, "checkout", "-q", "--force", "--detach", self.old)
        self.assertEqual(self.missing(OLD_TREE), [])

    def actions_checkout(self, options: dict | None, sha: str) -> None:
        """The sparse part of actions/checkout v6.0.2 for a step's `with:`, as its log prints it."""
        patterns = str((options or {}).get("sparse-checkout") or "").split()
        if not patterns:
            # Run 42831126892, job 129886034710 (a full checkout), 14:27:20Z.
            self.git(self.ws, "sparse-checkout", "disable")
            self.git(self.ws, "config", "--local", "--unset-all", "extensions.worktreeConfig", check=False)
        elif (options or {}).get("sparse-checkout-cone-mode", True):
            # Run 42829570644, job 129892001668 (`sparse-checkout: scripts`), 14:28:28Z.
            self.git(self.ws, "sparse-checkout", "set", *patterns)
        else:
            # The same job's .publish-tooling checkout (`sparse-checkout-cone-mode: false`), 14:28:30Z.
            self.git(self.ws, "config", "core.sparseCheckout", "true")
            listed = self.ws / self.git(self.ws, "rev-parse", "--git-path", "info/sparse-checkout")
            listed.parent.mkdir(parents=True, exist_ok=True)
            with listed.open("a") as handle:
                handle.write("\n" + "\n".join(patterns) + "\n")
        self.git(self.ws, "checkout", "--force", sha)

    def after_the_signer(self) -> None:
        options = step("build-sign-notarize-nightly", "Checkout build ref")["with"]
        self.assertEqual(options["sparse-checkout"].split(), LEAN_PATTERNS)
        self.actions_checkout(options, self.old)

    def after_the_deltas_job(self) -> None:
        self.actions_checkout(step("republish-nightly-deltas", "Checkout build ref")["with"], self.old)

    def missing(self, tree: dict[str, str]) -> list[str]:
        return sorted(name for name, text in tree.items()
                      if not (self.ws / name).is_file() or (self.ws / name).read_text() != text)

    def hidden(self) -> list[str]:
        """Index entries with the skip-worktree bit: the files a sparse checkout keeps out of the tree."""
        return [line[2:] for line in self.git(self.ws, "ls-files", "-t").splitlines() if line.startswith("S ")]

    def run_warm_step(self) -> subprocess.CompletedProcess:
        warm = step("build-nightly-app", WARM_STEP)
        self.assertEqual(warm["env"]["BUILD_SHA"], "${{ needs.resolve-nightly-cmux-tui-client.outputs.build_sha }}")
        self.ws.mkdir(exist_ok=True)
        # What the warm builder keeps between builds, and what an earlier job left behind.
        (self.ws / KEPT_TARGET).parent.mkdir(parents=True, exist_ok=True)
        (self.ws / KEPT_TARGET).write_text("object\n")
        (self.ws / "left-by-an-earlier-job.dmg").write_text("stale\n")
        script = self.temp / "runner-temp/warm-checkout.sh"
        script.write_text(warm["run"])
        env = {**self.env, "BUILD_SHA": self.new, "WORKFLOW_SHA": self.new, "REPO_URL": str(self.origin),
               "GITHUB_WORKSPACE": str(self.ws), "RUNNER_TEMP": str(self.temp / "runner-temp"), "GITHUB_REPOSITORY": "o/r"}
        # The runner's default for a `run:` step with no `shell:` is `bash -e {0}`.
        return subprocess.run(["bash", "-e", str(script)], cwd=self.temp, env=env, capture_output=True, text=True)

    def assert_whole_tree(self, state: str) -> None:
        result = self.run_warm_step()
        self.last_run = result
        self.assertEqual(result.returncode, 0, f"{state}: the warm checkout step failed\n{result.stdout}\n{result.stderr}")
        self.assertEqual(self.git(self.ws, "rev-parse", "HEAD"), self.new)
        self.assertEqual(self.missing(NEW_TREE), [], f"{state}: the build tree lacks these files of the build commit")
        self.assertTrue((self.ws / ".xcode-version").is_file(), f"{state}: Select Xcode cannot read .xcode-version")
        self.assertEqual(self.hidden(), [], f"{state}: the index still hides these files from the tree")
        # The fixture has no .gitignore, so the kept directory shows as untracked; the stale file is gone.
        self.assertEqual(self.git(self.ws, "status", "--porcelain"), f"?? {KEPT_TARGET.split('/', 1)[0]}/",
                         f"{state}: only the kept Rust target directory may be left beside the tree")
        self.assertTrue((self.ws / KEPT_TARGET).is_file(), f"{state}: the kept Rust target directory was removed")
        # Each part of the setting must be gone, not only enough of it for this checkout.
        self.assertFalse((self.ws / ".git/info/sparse-checkout").exists(), f"{state}: the pattern file is left")
        for config in ("config", "config.worktree"):
            path = self.ws / ".git" / config
            text = path.read_text(encoding="utf-8").lower() if path.is_file() else ""
            for key in ("sparsecheckout", "sparsecheckoutcone", "sparse = "):
                self.assertNotIn(key, text, f"{state}: .git/{config} still has a sparse checkout setting")
        # A full actions/checkout after this build (the unsigned-resume controls, the recovery job)
        # must get the whole tree too: nothing may be left that turns the sparse checkout on again.
        self.actions_checkout(None, self.new)
        self.assertEqual(self.missing(NEW_TREE), [],
                         f"{state}: a full actions/checkout after the warm build hid these files again")

    # -- the states the shared workspace can be in -----------------------------------------------

    def test_after_the_deltas_job_that_ran_after_the_signer(self) -> None:
        # The state of run 42833135477: signer, then `sparse-checkout: scripts`.
        self.kept_workspace()
        self.after_the_signer()
        self.after_the_deltas_job()
        self.assertFalse((self.ws / ".xcode-version").exists(), "the state of the failed run: no root files")
        self.assert_whole_tree("after the deltas job")

    def test_after_a_full_actions_checkout_that_stayed_sparse(self) -> None:
        # The state at 14:27:30Z: the resume job's full checkout ran between two deltas jobs.
        self.kept_workspace()
        self.after_the_signer()
        self.after_the_deltas_job()
        self.actions_checkout(step("build-nightly-app", "Checkout trusted unsigned-resume controls")["with"], self.old)
        self.assertFalse((self.ws / ".xcode-version").exists(), "the full checkout stays sparse in this state")
        self.assert_whole_tree("after a full actions/checkout")

    def test_after_the_signer(self) -> None:
        self.kept_workspace()
        self.after_the_signer()
        self.assertFalse((self.ws / "cmux-next-ios/verify/evidence.txt").exists())
        self.assert_whole_tree("after the signer")

    def test_after_a_cone_mode_sparse_checkout(self) -> None:
        # `sparse-checkout: scripts` in a workspace that was not sparse: cone mode, set in config.worktree.
        self.kept_workspace()
        self.after_the_deltas_job()
        self.assertTrue((self.ws / ".xcode-version").exists(), "cone mode keeps the root files")
        self.assertFalse((self.ws / "Sources/App.swift").exists())
        self.assert_whole_tree("after a cone-mode sparse checkout")

    def test_after_the_setting_was_removed_but_the_index_still_hides_files(self) -> None:
        self.kept_workspace()
        self.after_the_signer()
        self.after_the_deltas_job()
        self.git(self.ws, "config", "--local", "--unset-all", "core.sparseCheckout")
        self.assertIn(".xcode-version", self.hidden())
        self.assert_whole_tree("with the setting removed and the skip-worktree bits left")

    def test_a_build_of_the_commit_the_sparse_job_left(self) -> None:
        # A second build of one commit after its signer: HEAD does not move, the files must still come back.
        self.kept_workspace()
        self.after_the_signer()
        self.after_the_deltas_job()
        self.new, tree = self.old, OLD_TREE
        result = self.run_warm_step()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.missing(tree), [])
        self.assertEqual(self.hidden(), [])

    def test_the_log_says_the_clone_was_sparse(self) -> None:
        self.kept_workspace()
        self.after_the_signer()
        self.after_the_deltas_job()
        self.assert_whole_tree("after the deltas job")
        self.assertIn("the kept clone was sparse", self.last_run.stdout)

    # -- the states that worked before stay as they were -----------------------------------------

    def test_the_deltas_jobs_cone_checkout_keeps_the_root_files_after_the_signer(self) -> None:
        """Runs 42819750253 and 42829570644: generate-nightly-deltas itself had no .xcode-version."""
        forget = "Forget the kept clone's sparse-checkout mode"
        for job in ("generate-nightly-deltas", "republish-nightly-deltas"):
            names = [s.get("name") for s in JOBS[job]["steps"]]
            self.assertIn(forget, names, job)
            self.assertLess(names.index(forget), names.index("Checkout build ref"), job)
        self.kept_workspace()
        self.after_the_signer()
        done = subprocess.run(["bash", "-e", "-c", step("generate-nightly-deltas", forget)["run"]], cwd=self.ws,
                              text=True, capture_output=True, env={**os.environ, "GITHUB_WORKSPACE": str(self.ws)})
        self.assertEqual(done.returncode, 0, done.stderr)
        self.after_the_deltas_job()
        root_files = sorted(name for name in OLD_TREE if "/" not in name)
        self.assertTrue(root_files)
        self.assertEqual([name for name in root_files if not (self.ws / name).is_file()], [])

    def test_a_workspace_that_was_never_sparse(self) -> None:
        self.kept_workspace()
        self.assert_whole_tree("never sparse")
        self.assertNotIn("the kept clone was sparse", self.last_run.stdout)

    def test_a_fresh_workspace(self) -> None:
        self.assert_whole_tree("fresh")

    # -- the Go module cache an acpmux build leaves in .build -------------------------------------

    def read_only_folders(self) -> list[str]:
        return sorted(str(Path(folder).relative_to(self.ws)) for folder, _, _ in os.walk(self.ws / GO_PATH)
                      if not os.stat(folder).st_mode & stat.S_IWUSR)

    def make_writable(self) -> None:
        """TemporaryDirectory cannot remove a read-only tree that a red run leaves."""
        for folder, _, _ in os.walk(self.temp):
            os.chmod(folder, os.stat(folder).st_mode | stat.S_IRWXU)

    def module_proxy(self) -> str:
        """A file:// GOPROXY with one module, so `go mod download` needs no network."""
        versions = self.temp / "goproxy/example.com/m/@v"
        versions.mkdir(parents=True)
        (versions / "list").write_text("v1.0.0\n")
        (versions / "v1.0.0.info").write_text('{"Version":"v1.0.0","Time":"2026-11-11T00:00:00Z"}\n')
        (versions / "v1.0.0.mod").write_text("module example.com/m\n")
        with zipfile.ZipFile(versions / "v1.0.0.zip", "w") as archive:
            archive.writestr("example.com/m@v1.0.0/go.mod", "module example.com/m\n")
            archive.writestr("example.com/m@v1.0.0/pkg/m.go", "package pkg\n")
        return (self.temp / "goproxy").as_uri()

    def build_with_tailnet_go(self) -> str:
        """What build-acpmux.sh does in the clone: source the helper, then Go fetches modules. Returns GOFLAGS."""
        if shutil.which("go", path=self.env["PATH"]) is None:
            self.skipTest("no go on PATH")
        self.addCleanup(self.make_writable)
        # Only the module source differs from the builder: a local proxy, no checksum database.
        script = (
            'source "$1"\n'
            'ensure_tailnet_go "$2" >/dev/null || exit $?\n'
            'export GOPROXY="$3" GOSUMDB=off GOTOOLCHAIN=local\n'
            'cd "$2" && go mod download example.com/m@v1.0.0 || exit 4\n'
            'printf "%s\\n" "$GOMODCACHE" "$GOFLAGS"\n'
        )
        result = subprocess.run(["bash", "-c", script, "build", str(TAILNET_GO), str(self.ws), self.module_proxy()],
                                cwd=self.temp, env=self.env, capture_output=True, text=True)
        if result.returncode == 3:
            self.skipTest(f"tailnet-go.sh found no Go 1.21 or later here: {result.stderr.strip()}")
        self.assertEqual(result.returncode, 0, f"go mod download failed\n{result.stdout}\n{result.stderr}")
        cache, flags = result.stdout.splitlines()[-2:]  # an empty GOFLAGS is an empty last line
        self.assertEqual(cache, str(self.ws / GO_PATH / "pkg/mod"))
        self.assertTrue((self.ws / GO_PATH / "pkg/mod/example.com/m@v1.0.0/pkg/m.go").is_file())
        return flags

    def test_go_module_cache_tailnet_go_keeps_it_writable(self) -> None:
        self.kept_workspace()
        flags = self.build_with_tailnet_go()
        self.assertIn("-modcacherw", flags.split(), "tailnet-go.sh must export GOFLAGS=-modcacherw")
        self.assertEqual(self.read_only_folders(), [], "Go wrote read-only folders under .build/go-path")

    def test_go_module_cache_after_an_acpmux_build(self) -> None:
        # The state of run 42940891027: the build before compiled acpmux in this clone.
        self.kept_workspace()
        self.build_with_tailnet_go()
        self.assert_whole_tree("after an acpmux build")
        self.assertFalse((self.ws / GO_PATH).exists(), "git clean left the Go module cache")

    def test_go_module_cache_left_read_only_before_the_fix(self) -> None:
        # Clones on other builders can still hold a cache an older tailnet-go.sh wrote, in Go's own modes.
        self.addCleanup(self.make_writable)
        self.kept_workspace()
        cache = self.ws / GO_PATH
        source = cache / "pkg/mod/gvisor.dev/gvisor@v0.0.0/pkg/tcpip/stack.go"
        source.parent.mkdir(parents=True)
        source.write_text("package stack\n")
        source.chmod(0o444)
        folder = source.parent
        while folder != cache:
            folder.chmod(0o555)
            folder = folder.parent
        self.assertEqual(len(self.read_only_folders()), 6)
        self.assert_whole_tree("with a read-only module cache")
        self.assertFalse(cache.exists(), "git clean left the Go module cache")


if __name__ == "__main__":
    unittest.main()
