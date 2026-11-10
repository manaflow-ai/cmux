#!/usr/bin/env python3
"""The deltas jobs' build checkout has .xcode-version in every state of the kept clone.

generate-nightly-deltas and republish-nightly-deltas check out only scripts/ and the root files
of the build ref (one step, one YAML anchor), then generate-nightly-deltas runs "Select Xcode",
which reads the root .xcode-version. On the one-mini nightly (vars.CI_NIGHTLY_MINI) the signer,
the publisher, the warm builder and the deltas jobs share one runner and one kept clone.

Runs 42819750253 (13:09Z) and 42829570644 (14:26Z) of 2026-11-10, runner cmux-lawrence-2:
actions/checkout ran `git sparse-checkout set scripts` in a clone where the signer's pattern
checkout had left core.sparseCheckout=true with no cone setting in .git/config. git then keeps
the mode it finds, so `scripts` was one non-cone pattern, no root file was checked out, and
"Select Xcode" failed: "Cannot read the required Xcode version: .../.xcode-version is missing".
The job has continue-on-error, so the nightly was green and published no Sparkle delta.

This test makes each state the kept clone can have, with the git commands of actions/checkout
v6.0.2 (src/git-source-provider.ts, git-directory-helper.ts and git-command-manager.ts at
de0fac2e4500, in their order) for the `with:` of the workflow's own steps. Then it runs the
deltas job's checkout the same way and the job's own "Select Xcode" step (the real
scripts/select-ci-xcode.sh, with stand-ins for the Xcode tools).

Run it yourself after changing that checkout step or a sparse checkout of a job that can share
its runner: python3 tests/test_nightly_deltas_kept_clone.py (about 5 s, git only, no Mac).
"""
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
JOBS = yaml.safe_load((ROOT / ".github/workflows/nightly.yml").read_text())["jobs"]
DELTAS_JOBS = ("generate-nightly-deltas", "republish-nightly-deltas")
CHECKOUT = "Checkout build ref"
# The form of the two failed runs, as their logs print it ("sparse-checkout: scripts",
# "sparse-checkout-cone-mode: true"). A run of an older workflow commit still uses it.
FAILED_RUN_FORM = {"filter": "blob:none", "sparse-checkout": "scripts\n"}
# The first pool in scripts/ci/xcode-pins.txt: the macOS major and the Xcode the stand-ins report.
MACOS, XCODE = next(line.split()[:2] for line in (ROOT / "scripts/ci/xcode-pins.txt").read_text().splitlines()
                    if line.strip() and not line.startswith("#"))

OLD_TREE = {
    ".xcode-version": (ROOT / ".xcode-version").read_text(),
    "README.md": "cmux\n",
    "scripts/select-ci-xcode.sh": (ROOT / "scripts/select-ci-xcode.sh").read_text(),
    "scripts/ci/xcode-pins.txt": (ROOT / "scripts/ci/xcode-pins.txt").read_text(),
    "scripts/sparkle_generate_deltas.sh": "#!/usr/bin/env bash\necho build 1\n",
    "Sources/App.swift": "let build = 1\n",
    "webviews/scripts/build.mjs": "export {}\n",
    "cmux-next-ios/verify/evidence.txt": "evidence\n",
}
NEW_TREE = {**OLD_TREE, "scripts/sparkle_generate_deltas.sh": "#!/usr/bin/env bash\necho build 2\n",
            "scripts/ci/new-step.sh": "#!/usr/bin/env bash\n", "Sources/App.swift": "let build = 2\n"}
# The deltas jobs read scripts/ and the root files of the build checkout. What the checkout is sparse for:
# the app sources and the 470 MB of media stay out of the tree. A scripts/ directory below the root is
# not the root's scripts/ (the old form, read as the one pattern `scripts`, took each of them).
LEFT_OUT = ("Sources/App.swift", "cmux-next-ios/verify/evidence.txt", "webviews/scripts/build.mjs")

STAND_INS = {
    "sw_vers": f'echo "{MACOS}.0"',
    "xcode-select": "exit 0",
    "xcodebuild": f'echo "Xcode {XCODE}"',
    "xcrun": 'case "$*" in *--show-sdk-version*) echo "26.0" ;; *) echo "$DEVELOPER_DIR/SDKs/MacOSX.sdk" ;; esac',
}


def step(job: str, name: str) -> dict:
    return next(s for s in JOBS[job]["steps"] if s.get("name") == name)


class DeltasCheckoutTest(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.temp = Path(temp.name).resolve()
        self.env = {
            "PATH": f"{self.temp / 'bin'}{os.pathsep}{os.environ['PATH']}", "HOME": str(self.temp / "home"),
            "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0",
            "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
        }
        for folder in ("bin", "home", f"Applications/Xcode_{XCODE}.app/Contents/Developer"):
            (self.temp / folder).mkdir(parents=True)
        for name, body in STAND_INS.items():
            (self.temp / "bin" / name).write_text(f"#!/bin/sh\n{body}\n")
            (self.temp / "bin" / name).chmod(0o755)
        self.origin = self.temp / "origin"
        self.git(self.temp, "init", "-q", "-b", "main", str(self.origin))
        # github.com serves a commit by its SHA and a blob:none fetch; a local origin needs both switched on.
        self.git(self.origin, "config", "uploadpack.allowAnySHA1InWant", "true")
        self.git(self.origin, "config", "uploadpack.allowFilter", "true")
        self.old = self.commit(OLD_TREE, "the build before")
        self.new = self.commit(NEW_TREE, "the build the deltas are for")
        self.ws = self.temp / "ws"
        self.ws.mkdir()

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
            path.chmod(0o755 if name.endswith(".sh") else 0o644)
        self.git(self.origin, "add", "-A")
        self.git(self.origin, "commit", "-qm", message)
        return self.git(self.origin, "rev-parse", "HEAD")

    def actions_checkout(self, options: dict, sha: str) -> None:
        """actions/checkout v6.0.2 into the workspace for a step's `with:` and a commit SHA as `ref`."""
        url = f"file://{self.origin}"
        if (self.ws / ".git").is_dir() and self.git(self.ws, "config", "--local", "--get", "remote.origin.url") == url:
            # git-directory-helper.ts prepareExistingDirectory: a kept clone is cleaned and reset, never removed.
            # (It first leaves any branch; a workspace of actions/checkout with a SHA `ref` is always detached.)
            self.git(self.ws, "clean", "-ffdx")
            self.git(self.ws, "reset", "--hard", "HEAD", check=False)  # no HEAD yet in a clone a step only made
        else:
            for entry in self.ws.iterdir():
                shutil.rmtree(entry) if entry.is_dir() else entry.unlink()
            self.git(self.ws, "init", str(self.ws))
            self.git(self.ws, "remote", "add", "origin", url)
        self.git(self.ws, "config", "--local", "gc.auto", "0")
        patterns = [line.strip() for line in str(options.get("sparse-checkout") or "").splitlines() if line.strip()]
        fetch_filter = options.get("filter") or ("blob:none" if patterns else None)
        self.git(self.ws, "-c", "protocol.version=2", "fetch", "--no-tags", "--prune", "--no-recurse-submodules",
                 *([f"--filter={fetch_filter}"] if fetch_filter else []),
                 f"--depth={options.get('fetch-depth', 1)}", "origin", sha)
        if not patterns:
            # git-command-manager.ts disableSparseCheckout.
            self.git(self.ws, "sparse-checkout", "disable")
            self.git(self.ws, "config", "--local", "--unset-all", "extensions.worktreeConfig", check=False)
        elif options.get("sparse-checkout-cone-mode", True):
            # sparseCheckout.
            self.git(self.ws, "sparse-checkout", "set", *patterns)
        else:
            # sparseCheckoutNonConeMode: the patterns are added to the file, after what an earlier job left.
            self.git(self.ws, "config", "core.sparseCheckout", "true")
            listed = self.ws / self.git(self.ws, "rev-parse", "--git-path", "info/sparse-checkout")
            listed.parent.mkdir(parents=True, exist_ok=True)
            with listed.open("a") as handle:
                handle.write("\n" + "\n".join(patterns) + "\n")
        self.git(self.ws, "checkout", "--progress", "--force", sha)

    def whole_tree(self, sha: str) -> None:
        """What the warm nightly-next build leaves (tests/test_nightly_warm_checkout_sparse.py): no sparse setting."""
        self.git(self.temp, "init", "-q", str(self.ws))
        self.git(self.ws, "remote", "add", "origin", f"file://{self.origin}")
        self.git(self.ws, "fetch", "-q", "--no-tags", "origin", sha)
        self.git(self.ws, "checkout", "-q", "--force", "--detach", sha)

    def signer(self, sha: str) -> None:
        self.actions_checkout(step("build-sign-notarize-nightly", "Checkout build ref")["with"], sha)

    def publisher(self, sha: str) -> None:
        self.actions_checkout(step("publish-nightly", "Checkout publish ref")["with"], sha)

    def full_checkout(self, sha: str) -> None:
        self.actions_checkout(step("recover-nightly-next-notarization", "Checkout")["with"], sha)

    def tracked(self) -> dict[str, str]:
        """The tracked files that are in the tree, with their text."""
        names = [line[2:] for line in self.git(self.ws, "ls-files", "-t").splitlines() if not line.startswith("S ")]
        return {name: (self.ws / name).read_text() for name in names if (self.ws / name).is_file()}

    def select_xcode(self, job: str) -> subprocess.CompletedProcess:
        """The job's own "Select Xcode" step. The runner's default for a `run:` with no `shell:` is `bash -e`."""
        script = self.temp / "select-xcode-step.sh"
        script.write_text(step(job, "Select Xcode")["run"])
        env = {**self.env, "CMUX_XCODE_APPLICATIONS_DIR": str(self.temp / "Applications"),
               "GITHUB_ENV": str(self.temp / "github-env"), "GITHUB_REPOSITORY_OWNER": "manaflow-ai", "RUNNER_NAME": "test"}
        return subprocess.run(["bash", "-e", str(script)], cwd=self.ws, env=env, capture_output=True, text=True)

    def assert_the_job_can_run(self, state: str, job: str = "generate-nightly-deltas", build: str = "new",
                               left_out: tuple[str, ...] = LEFT_OUT) -> None:
        sha, want = (self.new, NEW_TREE) if build == "new" else (self.old, OLD_TREE)
        self.actions_checkout(step(job, CHECKOUT)["with"], sha)
        self.assertEqual(self.git(self.ws, "rev-parse", "HEAD"), sha)
        tree = self.tracked()
        selected = self.select_xcode("generate-nightly-deltas")
        self.assertEqual(selected.returncode, 0, f"{state}: Select Xcode failed after the checkout of {job}; "
                         f"tree: {sorted(tree)}\n{selected.stdout}\n{selected.stderr}")
        self.assertIn(f"Xcode {XCODE}", selected.stdout)
        self.assertTrue(".xcode-version" in tree, f"{state}: the checkout of {job} has no .xcode-version; tree: {sorted(tree)}")
        read = [name for name in want if "/" not in name or name.startswith("scripts/")]
        self.assertEqual({name: tree.get(name) for name in read}, {name: want[name] for name in read},
                         f"{state}: scripts/ and the root files are not those of the build commit")
        for name in left_out:
            self.assertFalse(name in tree, f"{state}: the checkout of {job} wrote {name}, which the job never reads")

    # -- the states the kept clone can have before a deltas job ----------------------------------

    def test_after_the_signer(self) -> None:
        # Each nightly on the one mini: the sign run's signer, then its deltas job.
        self.whole_tree(self.old)
        self.signer(self.new)
        self.assert_the_job_can_run("after the signer")

    def test_after_the_signer_and_the_publisher(self) -> None:
        self.whole_tree(self.old)
        self.signer(self.new)
        self.publisher(self.new)
        self.assert_the_job_can_run("after the signer and the publisher")

    def test_after_the_signer_of_a_newer_build(self) -> None:
        # The 13:09Z run: HEAD was at the commit of a newer build when the deltas job started.
        self.whole_tree(self.old)
        self.signer(self.new)
        self.assert_the_job_can_run("after the signer of a newer build", build="old")

    def test_republish_after_generate_in_one_nightly(self) -> None:
        # republish-nightly-deltas finds the clone as generate-nightly-deltas left it (no owned-Mac clean on this host).
        self.whole_tree(self.old)
        self.signer(self.new)
        self.assert_the_job_can_run("after the signer", "generate-nightly-deltas")
        self.assert_the_job_can_run("after generate-nightly-deltas", "republish-nightly-deltas")

    def test_the_nightly_after_a_nightly(self) -> None:
        # Signer, both deltas jobs, then the next nightly's signer and deltas job, with no warm build between.
        self.whole_tree(self.old)
        for job in ("build-sign-notarize-nightly", *DELTAS_JOBS, "build-sign-notarize-nightly"):
            self.actions_checkout(step(job, CHECKOUT)["with"], self.old)
        self.assert_the_job_can_run("the second nightly in one kept clone")

    def test_after_a_full_checkout_that_stayed_sparse(self) -> None:
        # A full actions/checkout does not take the signer's setting out of .git/config.
        self.whole_tree(self.old)
        self.signer(self.old)
        self.full_checkout(self.old)
        self.assert_the_job_can_run("after the signer and a full checkout")

    def test_after_a_deltas_job_of_the_failed_runs(self) -> None:
        # The first nightly with this checkout: the clone has the pattern file of the old form.
        self.whole_tree(self.old)
        self.signer(self.old)
        self.actions_checkout(FAILED_RUN_FORM, self.old)
        self.assertFalse((self.ws / ".xcode-version").exists(), "the state of the failed runs: no root files")
        # The old form's one pattern `scripts` stays in the pattern file (actions/checkout adds to the file), and
        # git takes the nearest directory a pattern names, so the scripts/ directories below the root stay in the
        # tree until the warm build removes the file. More files than the job reads, none missing.
        self.assert_the_job_can_run("after a deltas job of the old form", left_out=LEFT_OUT[:2])
        self.assertIn("webviews/scripts/build.mjs", self.tracked())

    def test_after_a_cone_mode_job(self) -> None:
        # The old form in a clone with no sparse setting is cone mode, kept in config.worktree.
        self.whole_tree(self.old)
        self.actions_checkout(FAILED_RUN_FORM, self.old)
        self.assertIn("sparsecheckoutcone = true", (self.ws / ".git/config.worktree").read_text().lower())
        self.assert_the_job_can_run("after a cone-mode job")

    def test_after_a_cone_mode_job_and_the_signer(self) -> None:
        self.whole_tree(self.old)
        self.actions_checkout(FAILED_RUN_FORM, self.old)
        self.signer(self.new)
        self.assert_the_job_can_run("after a cone-mode job and the signer")

    # -- the states that worked before stay as they were -----------------------------------------

    def test_after_the_warm_build(self) -> None:
        self.whole_tree(self.old)
        self.assert_the_job_can_run("after the warm build")

    def test_a_fresh_workspace(self) -> None:
        # A hosted runner, or an owned Mac after "Clean this job's workdir on an owned Mac".
        for job in DELTAS_JOBS:
            with self.subTest(job=job):
                shutil.rmtree(self.ws)
                self.ws.mkdir()
                self.assert_the_job_can_run("fresh", job)

    # -- the job after it ------------------------------------------------------------------------

    def test_the_signer_after_it_gets_its_whole_tree(self) -> None:
        self.whole_tree(self.old)
        self.signer(self.old)
        self.assert_the_job_can_run("after the signer")
        self.signer(self.new)
        tree = self.tracked()
        want = {name: text for name, text in NEW_TREE.items() if not name.startswith("cmux-next-ios/verify/")}
        self.assertEqual(tree, want, "the signer after a deltas job does not get its tree")

    def test_both_jobs_share_one_checkout(self) -> None:
        self.assertEqual(step(DELTAS_JOBS[0], CHECKOUT), step(DELTAS_JOBS[1], CHECKOUT))


if __name__ == "__main__":
    unittest.main()
