#!/usr/bin/env python3
"""cmux-next guards' vt-link-graph steps (static-checks job), run as the workflow runs them, fails a pull
request whose package-notices.json libghostty-vt texts are for another
ghostty-next commit than vt-link-graph.json.

#19508 moved the ghostty-next gitlink and package-notices.json, and the graph
followed only with #19662 seven hours later: every release-path dogfood
package-distributions job failed in package_notices.py generate meanwhile, and
so does every branch cut in that window. The job checked only the graph
against the gitlink; this runs each of its steps in a sparse clone of this
checkout, with the notices on base and with them one commit behind.
"""
import json
import subprocess
import sys
import tempfile
import unittest
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
WORKFLOW = ROOT / ".github/workflows/cmux-next-guards.yml"
NOTICES = "cmux-tui/dist/notices/package-notices.json"
SPARSE = [
    "/scripts/cmux-next/notices/",
    "/cmux-tui/dist/",
    "/cmux-tui/build-support/notices/",
    "/cmux-tui/rust-toolchain.toml",
    # test_check_bundle_notices.py reads the repository notices (83cb35f5b2bd).
    "/THIRD_PARTY_LICENSES.md",
]
OTHER_COMMIT = "673a6369c4ba43cddcc94ff67361872824ffa528"


# The vt-link-graph checks, steps of cmux-next guards' static-checks job (which runs other static checks too).
VT_STEPS = (
    "vt-link-graph.json is for the libghostty-vt gitlink",
    "package-notices.json covers vt-link-graph.json",
    "The nightly's Ghostty license checks pass on fixtures",
)


def job_scripts() -> list[str]:
    job = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["static-checks"]
    steps = {step.get("name"): step for step in job["steps"]}
    missing = [name for name in VT_STEPS if "run" not in steps.get(name, {})]
    if missing:
        raise AssertionError(f"static-checks has no run step {missing}")
    return [steps[name]["run"] for name in VT_STEPS]


# The clone's source must send filtered packs: a blob-less clone of a local repository is refused otherwise.
UPLOAD_PACK = "git -c uploadpack.allowFilter=true -c uploadpack.allowAnySHA1InWant=true upload-pack"


class Checkout:
    """A sparse clone of a checkout's HEAD: git objects for the gitlink and build.rs, the notices files on disk.

    A repository of its own, never one that borrows the source's objects: under car guards the source is
    the job's checkout, blob-less (actions/checkout's filter: blob:none) and shared with every test running
    beside this one. `git clone --shared` of it failed as soon as one of those tests (an older
    test_ci_owned_pool_sources.py) wrote .git/shallow there: clone ignores --shared/--local for a shallow
    source, packs every reachable object through upload-pack instead, and upload-pack may not fetch the
    blobs the source never had ("could not fetch ... from promisor remote", cmux#40871). So this is a
    depth-1, blob-less clone of HEAD over file://, the source as its promisor: it needs only HEAD's
    commit and trees, and the blobs the sparse checkout and the steps read, which any checkout of HEAD
    holds, shallow, partial or neither.
    """

    def __init__(self, source: Path = ROOT):
        self.temporary = tempfile.TemporaryDirectory()
        self.path = Path(self.temporary.name) / "repo"
        # The source's own HEAD, so uncommitted notices edits are not what runs.
        head = subprocess.run(["git", "-C", str(source), "rev-parse", "HEAD"], check=True, capture_output=True,
                              text=True).stdout.strip()
        git_fixture_env.clone_repo(source.as_uri(), self.path, "--no-checkout", "--depth=1", "--filter=blob:none",
                                   f"--upload-pack={UPLOAD_PACK}")
        # clone does not keep --upload-pack: the lazy blob fetches below need it too.
        subprocess.run(["git", "-C", str(self.path), "config", "remote.origin.uploadpack", UPLOAD_PACK], check=True)
        subprocess.run(["git", "-C", str(self.path), "sparse-checkout", "set", "--no-cone", *SPARSE], check=True)
        subprocess.run(["git", "-C", str(self.path), "checkout", "-q", "--detach", head], check=True)

    def set_notices_commit(self, commit: str):
        path = self.path / NOTICES
        data = json.loads(path.read_text(encoding="utf-8"))
        data["libghostty_vt"]["commit"] = commit
        path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")

    def run_job(self) -> subprocess.CompletedProcess:
        output = []
        for script in job_scripts():
            result = subprocess.run(["bash", "-e", "-c", script], cwd=self.path, capture_output=True, text=True,
                                    timeout=120)
            output.append(result.stdout + result.stderr)
            if result.returncode != 0:
                return subprocess.CompletedProcess(script, result.returncode, "".join(output), "")
        return subprocess.CompletedProcess("job", 0, "".join(output), "")

    def close(self):
        self.temporary.cleanup()


class NoticesPairTests(unittest.TestCase):
    def checkout(self) -> Checkout:
        checkout = Checkout()
        self.addCleanup(checkout.close)
        return checkout

    def test_base_passes(self):
        result = self.checkout().run_job()
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_notices_for_another_ghostty_next_commit_fail(self):
        checkout = self.checkout()
        checkout.set_notices_commit(OTHER_COMMIT)
        result = checkout.run_job()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(f"package-notices.json has libghostty-vt texts for ghostty-next {OTHER_COMMIT}", result.stdout)



class BloblessShallowSourceTests(unittest.TestCase):
    """Checkout clones a source like car guards' checkout once a neighbour made it shallow (cmux#40871)."""

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.com", *args], check=True,
                              capture_output=True, text=True).stdout.strip()

    def test_a_blobless_shallow_source_clones(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            work = git_fixture_env.init_repo(tmp / "work", "-b", "main")
            license_file = work / "THIRD_PARTY_LICENSES.md"
            for number in range(3):
                license_file.write_text(f"licenses {number}\n")
                (work / "elsewhere.txt").write_text(f"not in the sparse set {number}\n")
                self.git("-C", str(work), "add", "-A")
                self.git("-C", str(work), "commit", "-q", "-m", f"c{number}")
            self.git("-C", str(work), "checkout", "-q", "-b", "side", "HEAD~1")
            (work / "side.txt").write_text("side\n")
            self.git("-C", str(work), "add", "-A")
            self.git("-C", str(work), "commit", "-q", "-m", "side")
            self.git("-C", str(work), "checkout", "-q", "main")
            origin = git_fixture_env.clone_repo(work, tmp / "origin.git", "--bare", "--no-local")
            self.git("-C", str(origin), "config", "uploadpack.allowFilter", "true")
            # The job's checkout: full history, blobs only for the commit it checked out.
            source = git_fixture_env.clone_repo(origin.as_uri(), tmp / "source", "--filter=blob:none")
            missing = self.git("-C", str(source), "rev-list", "--objects", "--all", "--missing=print")
            self.assertIn("?", missing, "the fixture source should miss old blobs, as a blob-less checkout does")
            # What test_ci_owned_pool_sources.py's --depth=1 fetch did to that checkout.
            self.git("-C", str(source), "fetch", "-q", "--depth=1", "--filter=blob:none", "origin",
                     "+refs/heads/side:refs/remotes/origin/side")
            self.assertEqual(self.git("-C", str(source), "rev-parse", "--is-shallow-repository"), "true")

            checkout = Checkout(source)
            self.addCleanup(checkout.close)
            self.assertEqual((checkout.path / "THIRD_PARTY_LICENSES.md").read_text(), "licenses 2\n")
            self.assertFalse((checkout.path / "elsewhere.txt").exists(), "outside the sparse set")
            self.assertEqual(self.git("-C", str(checkout.path), "show", "HEAD:elsewhere.txt"),
                             "not in the sparse set 2")


if __name__ == "__main__":
    sys.exit(unittest.main())
