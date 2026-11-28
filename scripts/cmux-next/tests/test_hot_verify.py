#!/usr/bin/env python3
"""hot-verify.py plan: which live layers carry a change and whether it needs a build, on any host.

No app, no fleet, no network: a temporary cmux-shaped repository with a bare origin stands in for cmux, its
cmux-tui subtree id stands in for the published tree key, and every tree counts as published.

    python3 -I scripts/cmux-next/tests/test_hot_verify.py
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import re
import os
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

HERE = Path(__file__).resolve().parent
ENGINE = HERE.parent / "hot-verify.py"
_spec = importlib.util.spec_from_file_location("git_fixture_env", HERE.parents[2] / "tests" / "git_fixture_env.py")
git_fixture_env = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(git_fixture_env)

_spec = importlib.util.spec_from_file_location("hot_verify", ENGINE)
hv = importlib.util.module_from_spec(_spec)
sys.modules["hot_verify"] = hv
_spec.loader.exec_module(hv)

# cmuxterm-hq build-fleet/hot-verify MARKER, copied: the line the PR comment and the NOW metric read.
HQ_MARKER = r"<!-- cmux-hot-verify sha=([0-9a-f]{40}) app=(\S+) layers=([a-z,]+) source=(worktree|pr) -->"

BASE_FILES = {
    "webviews/src/web-abi.json": '{"abi": 3}\n',
    "webviews/src/app.tsx": "export const title = 'Home'\n",
    "cmux-tui/Cargo.toml": '[workspace]\nmembers = ["crates/*"]\n',
    "cmux-tui/crates/cmux-app-ffi/Cargo.toml": '[package]\nname = "cmux-app-ffi"\nversion = "0.0.0"\n',
    "cmux-tui/crates/cmux-app-ffi/src/lib.rs": "pub fn ffi() -> u32 { 1 }\n",
    "cmux-tui/crates/cmux-tui/Cargo.toml": '[package]\nname = "cmux-tui"\nversion = "0.0.0"\n',
    "cmux-tui/crates/cmux-tui/src/main.rs": "fn main() { println!(\"one\"); }\n",
    "Packages/macOS/CmuxNext/Sources/CmuxNextApp/App.swift":
        "struct App {\n    func title() -> String {\n        return \"one\"\n    }\n}\n",
    "cmux.xcodeproj/project.pbxproj": "// no build phase inputs\n",
    "docs/notes.md": "notes\n",
}


class Fixture:
    def __init__(self, root: Path):
        self.origin = root / "origin.git"
        self.repo = root / "repo"
        git_fixture_env.init_repo(self.origin, "--bare", "-q")
        git_fixture_env.init_repo(self.repo, "-q", "-b", "feat-cmux-next")
        self.git("remote", "add", "origin", str(self.origin))
        self.base = self.commit(BASE_FILES, "base")
        self.git("push", "-q", "origin", "HEAD:refs/heads/feat-cmux-next")
        self.git("fetch", "-q", "origin")

    def git(self, *args: str, cwd: Path | None = None) -> str:
        return subprocess.run(["git", "-C", str(cwd or self.repo), *args], check=True, capture_output=True,
                              text=True, env=git_fixture_env.fixture_env()).stdout.strip()

    def commit(self, files: dict, message: str, parent: str | None = None) -> str:
        if parent:
            self.git("checkout", "-q", "--detach", parent)
        for path, text in files.items():
            target = self.repo / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text)
        self.git("add", "-A")
        self.git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def change(self, files: dict) -> str:
        """A commit of FILES on the base, as a pull request's head."""
        return self.commit(files, "change", parent=self.base)


class PlanTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="hot-verify-test-")
        root = Path(self.tmp.name)
        self.env = {k: os.environ.get(k) for k in ("CMUX_HOT_APPLY_STATE_DIR", "CMUX_HOT_VERIFY_CACHE")}
        os.environ["CMUX_HOT_APPLY_STATE_DIR"] = str(root / "hot-apply")
        os.environ["CMUX_HOT_VERIFY_CACHE"] = str(root / "cache")
        self.fx = Fixture(root)
        h = hv.hot()
        self.saved = (h.tree_key, h.published)
        h.tree_key = lambda repo, sha: self.fx.git("rev-parse", f"{sha}:cmux-tui", cwd=Path(repo))
        h.published = lambda key: True

    def tearDown(self):
        h = hv.hot()
        h.tree_key, h.published = self.saved
        for key, value in self.env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        self.tmp.cleanup()

    def plan(self, head: str, base: str | None = None) -> dict:
        return hv.plan(self.fx.repo, f"sha:{head}", None, base or self.fx.base)

    def test_web_only(self):
        planned = self.plan(self.fx.change({"webviews/src/app.tsx": "export const title = 'Home 2'\n"}))
        self.assertEqual(planned["layers"], ["web"])
        self.assertFalse(planned["needs_build"])
        self.assertEqual(planned["build"], {})

    def test_daemon_only(self):
        planned = self.plan(self.fx.change({"cmux-tui/crates/cmux-tui/src/main.rs": "fn main() {}\n"}))
        self.assertEqual(planned["layers"], ["rust"])
        self.assertFalse(planned["needs_build"])

    def test_a_daemon_plan_says_whether_the_head_s_tree_is_published(self):
        # The worker builds the head's daemon (look --rust-binary-head) only when CI published none (a lane head).
        head = self.fx.change({"cmux-tui/crates/cmux-tui/src/main.rs": "fn main() {}\n"})
        self.assertTrue(self.plan(head)["tree_published"])
        hv.hot().published = lambda key: False
        self.assertFalse(self.plan(head)["tree_published"])

    def test_web_and_daemon(self):
        planned = self.plan(self.fx.change({"webviews/src/app.tsx": "export const title = 'x'\n",
                                            "cmux-tui/crates/cmux-tui/src/main.rs": "fn main() {}\n"}))
        self.assertEqual(planned["layers"], ["web", "rust"])
        self.assertFalse(planned["needs_build"])

    def advance_base(self, files: dict) -> str:
        """FILES merged on feat-cmux-next after the app's commit (the nightly lags the branch)."""
        tip = self.fx.commit(files, "merged after the nightly", parent=self.fx.base)
        self.fx.git("push", "-q", "origin", f"{tip}:refs/heads/feat-cmux-next")
        self.fx.git("fetch", "-q", "origin")
        return tip

    def land(self, files: dict, parent: str) -> str:
        """FILES landed on feat-cmux-next on top of PARENT (a PR's merge commit, looked at after it landed)."""
        landed = self.fx.commit(files, "landed", parent=parent)
        self.fx.git("push", "-q", "-f", "origin", f"{landed}:refs/heads/feat-cmux-next")
        self.fx.git("fetch", "-q", "origin")
        return landed

    def test_a_landed_commit_is_planned_from_its_first_parent(self):
        # A look at a PR's merge commit on feat-cmux-next (its tree published, the nightly behind it): the change is
        # the commit's own diff. Before, own == head, so the 33-file Swift drift since the nightly counted as it.
        tip = self.advance_base({"Packages/macOS/CmuxNext/Sources/CmuxNextApp/App.swift":
                                 "struct App {\n    func title() -> String {\n        return \"drift\"\n"
                                 "    }\n}\n"})
        landed = self.land({"webviews/src/app.tsx": "export const title = 'Home 4'\n"}, tip)
        planned = self.plan(landed)
        self.assertEqual(planned["layers"], ["web"])
        self.assertFalse(planned["needs_build"], planned["build"])
        self.assertEqual(planned["fork"], tip)
        self.assertTrue(any("behind" in note for note in planned["notes"]), planned["notes"])

    def test_a_landed_daemon_change_over_the_app_s_newer_rust_swaps_the_daemon(self):
        # The class a PR head cannot take ("Rust the app has and the change lacks", 8 of 90 looks on 2026-11-16):
        # the nightly carries cmux-tui changes the PR branched before. Its merge commit has both, so its daemon
        # takes the app's changes along.
        nightly = self.advance_base({"cmux-tui/crates/cmux-tui/src/main.rs": "fn main() { println!(\"night\"); }\n"})
        landed = self.land({"cmux-tui/crates/cmux-tui/src/main.rs": "fn main() { println!(\"mine\"); }\n"}, nightly)
        planned = self.plan(landed, base=nightly)
        self.assertEqual(planned["layers"], ["rust"])
        self.assertFalse(planned["needs_build"], planned["build"])

    def test_a_landed_commit_with_no_app_is_planned_from_its_first_parent(self):
        # The workflow's merged half plans the merge commit with no app: its merge base with feat-cmux-next is
        # itself, so head..head was empty and cmux#44971 (Rust in cmux-tui) planned as "nothing in the app changes".
        tip = self.advance_base({"docs/notes.md": "drift\n"})
        landed = self.land({"cmux-tui/crates/cmux-tui/src/main.rs": "fn main() { println!(\"mine\"); }\n"}, tip)
        planned = hv.plan(self.fx.repo, f"sha:{landed}", hv.NO_APP, None)
        self.assertEqual(planned["base"], tip)
        self.assertEqual(planned["fork"], tip)
        self.assertEqual(planned["layers"], ["rust"])
        self.assertFalse(planned["needs_build"], planned["build"])

    def test_a_branch_merged_in_as_second_parent_keeps_all_its_commits(self):
        # Review of the first-parent rule: 161 first-parent merges in 30 days landed real branches as second parents.
        # A look at such a branch's last commit after it landed must still count the branch's earlier Swift.
        tip = self.advance_base({"docs/notes.md": "drift\n"})
        swift = self.fx.commit({"Packages/macOS/CmuxNext/Sources/CmuxNextApp/App.swift":
                                "struct App {\n    func title() -> String {\n        return \"mine\"\n"
                                "    }\n}\n"}, "branch: swift", parent=self.fx.base)
        last = self.fx.commit({"webviews/src/app.tsx": "export const title = 'branch'\n"}, "branch: web", parent=swift)
        self.fx.git("checkout", "-q", "--detach", tip)
        self.fx.git("-c", "user.name=t", "-c", "user.email=t@t", "merge", "-q", "--no-ff", "-m", "merge branch", last)
        merged = self.fx.git("rev-parse", "HEAD")
        self.fx.git("push", "-q", "-f", "origin", f"{merged}:refs/heads/feat-cmux-next")
        self.fx.git("fetch", "-q", "origin")
        planned = self.plan(last)
        self.assertTrue(planned["needs_build"], planned)
        self.assertIn("Swift", planned["build"])

    def test_a_change_branched_after_the_app_is_planned_from_its_own_fork(self):
        # The fleet looked at cmux#43773 (4 Rust files) on a nightly 25 commits behind feat-cmux-next and said
        # "needs a build" for 33 Swift files merged after that nightly, none of them the PR's.
        tip = self.advance_base({"Packages/macOS/CmuxNext/Sources/CmuxNextApp/App.swift":
                                 "struct App {\n    func title() -> String {\n        return \"drift\"\n"
                                 "    }\n}\n"})
        head = self.fx.commit({"webviews/src/app.tsx": "export const title = 'Home 3'\n"}, "change", parent=tip)
        planned = self.plan(head)
        self.assertEqual(planned["layers"], ["web"])
        self.assertFalse(planned["needs_build"], planned["build"])
        self.assertEqual(planned["fork"], tip)
        self.assertTrue(any("behind" in note for note in planned["notes"]), planned["notes"])

    def test_the_change_s_own_swift_still_needs_a_build_after_drift(self):
        tip = self.advance_base({"docs/notes.md": "drift\n"})
        head = self.fx.commit({"Packages/macOS/CmuxNext/Sources/CmuxNextApp/App.swift":
                               "struct App {\n    func title() -> String {\n        return \"mine\"\n"
                               "    }\n}\n"}, "change", parent=tip)
        planned = self.plan(head)
        self.assertTrue(planned["needs_build"])
        self.assertIn("Swift", planned["build"])

    def test_a_daemon_change_after_rust_drift_swaps_the_daemon(self):
        # The change has the drift's cmux-tui changes (it forked later): not "Rust the app has and the change lacks".
        tip = self.advance_base({"cmux-tui/crates/cmux-tui/src/main.rs": "fn main() { println!(\"drift\"); }\n"})
        head = self.fx.commit({"cmux-tui/crates/cmux-tui/src/main.rs": "fn main() { println!(\"mine\"); }\n"},
                              "change", parent=tip)
        planned = self.plan(head)
        self.assertEqual(planned["layers"], ["rust"])
        self.assertFalse(planned["needs_build"], planned["build"])

    PIN = ('{"url": "https://github.com/manaflow-ai/cmux/releases/download/'
           'cmux-app-ffi-%s/CCmuxAppFFI.xcframework.zip", "checksum": "%s"}\n')

    def test_ffi_drift_under_the_same_pin_swaps_the_daemon(self):
        # cmux#44125's look (2026-11-16): the nightly 4dde96d6e699 and the PR's fork f2186cbc8970 both pinned
        # cmux-app-ffi-0a02f56030ef, yet 4 FFI source files in the 33 commits between them made it "need a build".
        # An app links its pinned release, so an app at the fork links the same library this one has.
        pin = self.PIN % ("a" * 40, "0" * 64)
        self.fx.base = self.fx.commit({hv.FFI_PIN_FILE: pin}, "pin", parent=self.fx.base)
        tip = self.advance_base({"cmux-tui/crates/cmux-app-ffi/src/lib.rs": "pub fn ffi() -> u32 { 2 }\n"})
        head = self.fx.commit({"cmux-tui/crates/cmux-tui/src/main.rs": "fn main() { println!(\"mine\"); }\n"},
                              "change", parent=tip)
        planned = self.plan(head)
        self.assertEqual(planned["layers"], ["rust"])
        self.assertFalse(planned["needs_build"], planned["build"])

    def test_ffi_drift_that_moves_the_pin_swaps_the_daemon_applied_onto_the_app(self):
        # Before cmuxterm-hq#13435 this needed a build; the change's own commits on the app's commit keep its pin.
        pin = self.PIN % ("a" * 40, "0" * 64)
        self.fx.base = self.fx.commit({hv.FFI_PIN_FILE: pin}, "pin", parent=self.fx.base)
        tip = self.advance_base({"cmux-tui/crates/cmux-app-ffi/src/lib.rs": "pub fn ffi() -> u32 { 2 }\n",
                                 hv.FFI_PIN_FILE: self.PIN % ("b" * 40, "1" * 64)})
        head = self.fx.commit({"cmux-tui/crates/cmux-tui/src/main.rs": "fn main() { println!(\"mine\"); }\n"},
                              "change", parent=tip)
        planned = self.plan(head)
        self.assert_onto_app(planned, self.fx.base, {hv.FFI_PIN_FILE: pin,
                                                     "cmux-tui/crates/cmux-app-ffi/src/lib.rs": "pub fn ffi() -> u32 { 1 }\n"})

    def test_a_repin_the_app_lacks_puts_the_fork_s_release_in_first(self):
        # 2026-11-17: 7 of the 8 Rust looks that failed planned `rust` here, then ended `hot-apply.py apply --parts
        # rust exited 3`: the NIGHTLY pinned an older app FFI release than the fork, and no FFI source changed in
        # the commits between, so the plan saw nothing while hot-apply held the daemon back for the repin.
        self.fx.base = self.fx.commit({hv.FFI_PIN_FILE: self.PIN % ("a" * 40, "0" * 64)}, "pin",
                                      parent=self.fx.base)
        tip = self.advance_base({hv.FFI_PIN_FILE: self.PIN % ("b" * 40, "1" * 64)})
        head = self.fx.commit({"cmux-tui/crates/cmux-tui/src/main.rs": "fn main() { println!(\"mine\"); }\n"},
                              "change", parent=tip)
        h = hv.hot()
        with unittest.mock.patch.object(h.ffi_part, "additive", return_value=[]):
            planned = self.plan(head)
        self.assertEqual(planned["layers"], ["rust"])
        self.assertFalse(planned["needs_build"], planned["build"])
        self.assertEqual(planned["ffi_baseline"]["source"], "b" * 40)
        self.assertEqual(planned["ffi_baseline"]["app_pin_source"], "a" * 40)
        with unittest.mock.patch.object(h.ffi_part, "additive", return_value=["drops ffi_old()"]):
            planned = self.plan(head)
        # The app cannot take the fork's release: since cmuxterm-hq#13435 the change's own commits go onto the app's
        # commit, which keeps the app's release, instead of needing a build.
        self.assert_onto_app(planned, self.fx.base, {hv.FFI_PIN_FILE: self.PIN % ("a" * 40, "0" * 64)})
        self.assertNotIn("ffi_baseline", planned)
        self.assertTrue(any("drops ffi_old()" in note for note in planned["notes"]), planned["notes"])

    def test_a_repin_the_app_lacks_with_rust_the_swift_build_reads_goes_onto_the_app(self):
        # Review of cmux#46195: the fork's release brings the library up, not what the Swift build reads itself;
        # hot-apply leaves that, then holds the daemon back, so the look would end in exit 3 again.
        self.fx.base = self.fx.commit({hv.FFI_PIN_FILE: self.PIN % ("a" * 40, "0" * 64)}, "pin",
                                      parent=self.fx.base)
        tip = self.advance_base({hv.FFI_PIN_FILE: self.PIN % ("b" * 40, "1" * 64)})
        head = self.fx.commit({"cmux-tui/crates/cmux-tui/src/main.rs": "fn main() { println!(\"mine\"); }\n"},
                              "change", parent=tip)
        h = hv.hot()
        with unittest.mock.patch.object(h.ffi_part, "additive", return_value=[]), \
                unittest.mock.patch.object(h, "swift_read_rust", return_value=["cmux-tui/include/cmux.h"]):
            planned = self.plan(head)
        # Since cmuxterm-hq#13435 the change's own commits go onto the app's commit instead: its header and pin.
        self.assert_onto_app(planned, self.fx.base, {hv.FFI_PIN_FILE: self.PIN % ("a" * 40, "0" * 64)})
        self.assertNotIn("ffi_baseline", planned)

    def test_a_repin_of_the_same_release_is_no_release_change(self):
        # Review of cmux#46195: a pin file that only rewrites the checksum names the library the app has; hot-apply
        # compares the release's commit, so the plan does too.
        self.fx.base = self.fx.commit({hv.FFI_PIN_FILE: self.PIN % ("a" * 40, "0" * 64)}, "pin",
                                      parent=self.fx.base)
        tip = self.advance_base({hv.FFI_PIN_FILE: self.PIN % ("a" * 40, "1" * 64)})
        head = self.fx.commit({"cmux-tui/crates/cmux-tui/src/main.rs": "fn main() { println!(\"mine\"); }\n"},
                              "change", parent=tip)
        planned = self.plan(head)
        self.assertEqual(planned["layers"], ["rust"], planned)
        self.assertFalse(planned["needs_build"], planned["build"])
        self.assertNotIn("ffi_baseline", planned)

    def test_a_change_branched_before_an_app_a_repin_ahead_goes_onto_the_app(self):
        # cmux#44876's look: the change forked before the NIGHTLY, which pinned a newer release; hot-apply holds the
        # daemon back (an older release does not go in), so the plan must not say `rust`.
        self.fx.base = self.fx.commit({hv.FFI_PIN_FILE: self.PIN % ("a" * 40, "0" * 64)}, "pin",
                                      parent=self.fx.base)
        self.fx.git("push", "-q", "-f", "origin", f"{self.fx.base}:refs/heads/feat-cmux-next")
        self.fx.git("fetch", "-q", "origin")
        head = self.fx.change({"cmux-tui/crates/cmux-tui/src/main.rs": "fn main() { println!(\"mine\"); }\n"})
        app = self.fx.commit({hv.FFI_PIN_FILE: self.PIN % ("b" * 40, "1" * 64)}, "repin", parent=self.fx.base)
        with unittest.mock.patch.object(hv.hot().ffi_part, "additive", return_value=["drops ffi_new()"]):
            planned = self.plan(head, base=app)
        # Since cmuxterm-hq#13435 the change's own commits go onto the app's commit: the app's newer release.
        self.assert_onto_app(planned, app, {hv.FFI_PIN_FILE: self.PIN % ("b" * 40, "1" * 64)})

    def test_a_checkout_without_the_xcode_project_reads_the_rules_root(self):
        # The 2026-11-18 swap-vs-dev-build sample planned from such a checkout: with no project file every cmux-tui
        # path read as a bundled helper's input, and 28-36% of PR heads "needed a build" (2-5% with the project).
        tree = Path(self.tmp.name) / "sparse"
        (tree / "cmux-tui").mkdir(parents=True)
        (tree / "cmux-tui/Cargo.toml").write_text("[workspace]\n")
        self.assertTrue(hv.needs_rules_root(tree))
        (tree / "cmux.xcodeproj").mkdir()
        (tree / "cmux.xcodeproj/project.pbxproj").write_text("// project\n")
        self.assertEqual(hv.needs_rules_root(tree), not (hv.ROOT / hv.ROUTE).is_file())

    def test_a_daemon_change_after_resource_drift_swaps_the_daemon(self):
        # The fleet's looks on cmux#43653 and cmux#43683 crashed here ("module 'hot_apply' has no attribute
        # 'NATIVE_IN_TUI'", removed by #43797): a resource, manifest or non-live Swift file in the commits the app
        # lacks lands in classify's rebuild bucket, which the FFI check read with that pattern.
        tip = self.advance_base({"Packages/macOS/CmuxNext/Sources/CmuxNextApp/Resources/Localizable.xcstrings":
                                 "{\"sourceLanguage\": \"en\", \"strings\": {}}\n"})
        head = self.fx.commit({"cmux-tui/crates/cmux-tui/src/main.rs": "fn main() { println!(\"mine\"); }\n"},
                              "change", parent=tip)
        planned = self.plan(head)
        self.assertEqual(planned["layers"], ["rust"])
        self.assertFalse(planned["needs_build"], planned["build"])

    def test_drift_that_changes_the_web_abi_still_needs_a_build(self):
        tip = self.advance_base({"webviews/src/web-abi.json": '{"abi": 4}\n'})
        head = self.fx.commit({"webviews/src/app.tsx": "export const title = 'x'\n"}, "change", parent=tip)
        planned = self.plan(head)
        self.assertTrue(planned["needs_build"])
        self.assertIn("web ABI", planned["build"])

    def test_swift_needs_build(self):
        planned = self.plan(self.fx.change({"Packages/macOS/CmuxNext/Sources/CmuxNextApp/App.swift":
                                            "struct App {\n    func title() -> String {\n        return \"two\"\n"
                                            "    }\n}\n"}))
        self.assertTrue(planned["needs_build"])
        self.assertIn("Swift", planned["build"])
        self.assertEqual(planned["layers"], [])

    def test_web_abi_file_needs_build(self):
        planned = self.plan(self.fx.change({"webviews/src/web-abi.json": '{"abi": 4}\n'}))
        self.assertTrue(planned["needs_build"])
        self.assertEqual(planned["build"]["web ABI"], ["webviews/src/web-abi.json"])
        self.assertNotIn("web", planned["layers"])

    def test_app_linked_rust_needs_build(self):
        planned = self.plan(self.fx.change({"cmux-tui/crates/cmux-app-ffi/src/lib.rs": "pub fn ffi() -> u32 { 2 }\n"}))
        self.assertTrue(planned["needs_build"])
        self.assertEqual(planned["build"]["Rust the app links (FFI)"], ["cmux-tui/crates/cmux-app-ffi/src/lib.rs"])
        self.assertNotIn("rust", planned["layers"])

    def test_rust_only_bundled_helpers_use_needs_build(self):
        # cmux#43713 review: a change to a crate only a bundled helper builds from (the diff sidecar, cmux-git)
        # moves the cmux-tui tree key, but hot-apply leaves the helper on the app's build; a daemon-only look
        # would show the change without it, so it is not hot.
        h = hv.hot()
        saved = h.helper_rust
        h.helper_rust = lambda repo, paths: [p for p in paths if "/cmux-git/" in p]
        try:
            planned = self.plan(self.fx.change({"cmux-tui/crates/cmux-git/src/lib.rs": "pub fn diff() {}\n"}))
        finally:
            h.helper_rust = saved
        self.assertTrue(planned["needs_build"])
        self.assertEqual(planned["build"]["Rust only bundled helpers use"], ["cmux-tui/crates/cmux-git/src/lib.rs"])

    def test_docs_only_has_no_layer(self):
        planned = self.plan(self.fx.change({"docs/notes.md": "more notes\n"}))
        self.assertEqual(planned["layers"], [])
        self.assertFalse(planned["needs_build"])

    def assert_onto_app(self, planned: dict, app: str, files: dict) -> str:
        """PLANNED swaps in the daemon of the change's own commits applied onto APP: a commit whose parent is APP
        and whose FILES read as given (the app's other Rust, the change's own)."""
        self.assertEqual(planned["layers"], ["rust"])
        self.assertFalse(planned["needs_build"], planned["build"])
        onto = planned["daemon_from"]
        self.assertRegex(onto, r"^[0-9a-f]{40}$")
        self.assertEqual(self.fx.git("rev-parse", f"{onto}^1"), app)
        for path, text in files.items():
            self.assertEqual(self.fx.git("show", f"{onto}:{path}") + "\n", text, path)
        self.assertEqual(planned["tree_key"], hv.hot().tree_key(self.fx.repo, onto))
        self.assertEqual(planned["head"], planned["marker_sha"])
        self.assertTrue(any("applied onto the app's commit" in note for note in planned["notes"]), planned["notes"])
        return onto

    def test_rust_branched_before_newer_app_rust_swaps_the_daemon_applied_onto_the_app(self):
        # cmuxterm-hq#13435: 73 of 132 needs-build steps in a week were this class, and none for the PR's own paths.
        head = self.fx.change({"cmux-tui/crates/cmux-tui/src/main.rs": "fn main() {}\n"})
        newer = '[package]\nname = "cmux-tui"\nversion = "1.0.0"\n'
        app = self.fx.commit({"cmux-tui/crates/cmux-tui/Cargo.toml": newer}, "the app's newer Rust",
                             parent=self.fx.base)
        planned = self.plan(head, base=app)
        self.assertEqual(planned["fork"], self.fx.base)
        onto = self.assert_onto_app(planned, app, {"cmux-tui/crates/cmux-tui/Cargo.toml": newer,
                                                   "cmux-tui/crates/cmux-tui/src/main.rs": "fn main() {}\n"})
        self.assertEqual(self.plan(head, base=app)["daemon_from"], onto, "the same change plans the same commit")

    def test_rust_branched_before_conflicting_app_rust_still_needs_a_build(self):
        head = self.fx.change({"cmux-tui/crates/cmux-tui/src/main.rs": "fn main() { println!(\"mine\"); }\n"})
        app = self.fx.commit({"cmux-tui/crates/cmux-tui/src/main.rs": "fn main() { println!(\"theirs\"); }\n"},
                             "the app's newer Rust", parent=self.fx.base)
        planned = self.plan(head, base=app)
        self.assertTrue(planned["needs_build"])
        self.assertIn("Rust the app has and the change lacks", planned["build"])
        self.assertNotIn("daemon_from", planned)
        self.assertTrue(any("do not apply cleanly" in note for note in planned["notes"]), planned["notes"])

    def test_ffi_drift_swaps_the_daemon_applied_onto_the_app(self):
        # cmuxterm-hq#13435: 59 of 132. The head's daemon would speak FFI changes merged after the nightly; the
        # change's own commits applied onto the nightly's commit speak the FFI the nightly links.
        tip = self.advance_base({"cmux-tui/crates/cmux-app-ffi/src/lib.rs": "pub fn ffi() -> u32 { 2 }\n"})
        head = self.fx.commit({"cmux-tui/crates/cmux-tui/src/main.rs": "fn main() { println!(\"mine\"); }\n"},
                              "change", parent=tip)
        planned = self.plan(head)
        self.assert_onto_app(planned, self.fx.base, {
            "cmux-tui/crates/cmux-app-ffi/src/lib.rs": "pub fn ffi() -> u32 { 1 }\n",
            "cmux-tui/crates/cmux-tui/src/main.rs": "fn main() { println!(\"mine\"); }\n"})

    def test_the_change_s_own_ffi_still_needs_a_build_after_drift(self):
        tip = self.advance_base({"cmux-tui/crates/cmux-tui/src/main.rs": "fn main() { println!(\"drift\"); }\n",
                                 "cmux-tui/crates/cmux-app-ffi/src/lib.rs": "pub fn ffi() -> u32 { 2 }\n"})
        head = self.fx.commit({"cmux-tui/crates/cmux-app-ffi/src/lib.rs": "pub fn ffi() -> u32 { 3 }\n"},
                              "change", parent=tip)
        planned = self.plan(head)
        self.assertTrue(planned["needs_build"])
        self.assertIn("Rust the app links (FFI)", planned["build"])
        self.assertNotIn("rust", planned["layers"])

    def test_web_branched_before_the_app_stays_hot(self):
        head = self.fx.change({"webviews/src/app.tsx": "export const title = 'y'\n"})
        app = self.fx.commit({"cmux-tui/crates/cmux-tui/src/main.rs": "fn main() { /* newer */ }\n"},
                             "the app's newer Rust", parent=self.fx.base)
        planned = self.plan(head, base=app)
        self.assertEqual((planned["layers"], planned["needs_build"]), (["web"], False))

    def test_no_app_plans_against_the_merge_base(self):
        head = self.fx.change({"webviews/src/app.tsx": "export const title = 'z'\n"})
        planned = hv.plan(self.fx.repo, f"sha:{head}", hv.NO_APP, None)
        self.assertEqual(planned["base"], self.fx.base)
        self.assertEqual(planned["layers"], ["web"])

    def test_pr_source_fetches_the_head_with_git(self):
        head = self.fx.change({"webviews/src/app.tsx": "export const title = 'pr'\n"})
        self.fx.git("push", "-q", "origin", f"{head}:refs/pull/7/head")
        planned = hv.plan(self.fx.repo, "pr:7", hv.NO_APP, None)
        self.assertEqual((planned["head"], planned["source"], planned["pr"]), (head, "pr", 7))
        self.assertEqual(planned["layers"], ["web"])

    def test_dir_source_takes_the_working_tree(self):
        self.fx.git("checkout", "-q", "--detach", self.fx.base)
        (self.fx.repo / "webviews/src/app.tsx").write_text("export const title = 'edited'\n")
        planned = hv.plan(self.fx.repo, f"dir:{self.fx.repo}", hv.NO_APP, None)
        self.assertEqual(planned["source"], "worktree")
        self.assertNotEqual(planned["head"], self.fx.base)
        self.assertEqual(planned["layers"], ["web"])
        self.assertTrue(any("working tree has changes" in note for note in planned["notes"]))
        self.assertEqual(self.fx.git("status", "--porcelain"), "M webviews/src/app.tsx")  # nothing staged

    def test_a_clone_with_no_working_tree_reads_the_rules_from_feat_cmux_next(self):
        # The fleet's engine is an export of scripts/cmux-next over a blob-less clone with no checkout: the FFI
        # inputs come from a sparse worktree of origin/feat-cmux-next, so FFI-linked Rust still needs a build.
        ci = HERE.parents[1] / "ci"
        tools = {f"scripts/ci/{name}": (ci / name).read_text() for name in
                 ("cmux_next_route.py", "app_ffi_pin.py", "select_package_tests.py", "gh_expressions.py")}
        tip = self.fx.commit(tools, "tools", parent=self.fx.base)
        self.fx.git("push", "-q", "origin", "HEAD:refs/heads/feat-cmux-next")
        ffi = self.fx.commit({"cmux-tui/crates/cmux-app-ffi/src/lib.rs": "pub fn ffi() -> u32 { 9 }\n"}, "ffi")
        daemon = self.fx.commit({"cmux-tui/crates/cmux-tui/src/main.rs": "fn main() {}\n"}, "daemon", parent=tip)
        self.fx.git("push", "-q", "origin", f"{ffi}:refs/pull/8/head", f"{daemon}:refs/pull/9/head")
        bare = Path(self.tmp.name) / "no-checkout"
        git_fixture_env.clone_repo(self.fx.origin, bare, "-q", "--no-checkout")
        h = hv.hot()
        root = h.ROOT
        try:
            planned = hv.plan(bare, "pr:8", None, tip)
            self.assertTrue(planned["needs_build"])
            self.assertIn("Rust the app links (FFI)", planned["build"])
            self.assertEqual(hv.plan(bare, "pr:9", None, tip)["layers"], ["rust"])
            self.assertTrue((Path(os.environ["CMUX_HOT_VERIFY_CACHE"]) / "rules" / tip / hv.ROUTE).is_file())
        finally:
            h.ROOT = root

    def test_bad_sources_are_usage_errors(self):
        for source in ("pr:x", "sha:zz", "branch:main"):
            with self.assertRaises(hv.Usage):
                hv.resolve_source(self.fx.repo, source)

    def cli(self, *args: str) -> tuple[int, str]:
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = hv.main(list(args))
        return code, out.getvalue()

    def test_json_form(self):
        head = self.fx.change({"webviews/src/app.tsx": "export const title = 'j'\n"})
        code, text = self.cli("plan", "--source", f"sha:{head}", "--repo", str(self.fx.repo), "--base",
                              self.fx.base, "--json")
        self.assertEqual(code, 0)
        planned = json.loads(text)
        for key in ("layers", "needs_build", "build", "notes", "head", "base", "marker_sha"):
            self.assertIn(key, planned)
        self.assertEqual((planned["head"], planned["marker_sha"]), (head, head))

    def test_text_form_reads_as_hq_parses_it(self):
        head = self.fx.change({"Packages/macOS/CmuxNext/Sources/CmuxNextApp/App.swift": "struct App { let x = 1 }\n"})
        code, text = self.cli("plan", "--source", f"sha:{head}", "--repo", str(self.fx.repo), "--base", self.fx.base)
        self.assertEqual(code, 0)
        lines = text.splitlines()
        self.assertIn("layers: none", lines)
        self.assertIn("needs_build: true", lines)
        # cmuxterm-hq ci-client.py hot_verify_parse, line for line.
        parsed = {"layers": None, "needs_build": None}
        for line in lines:
            key, _, value = line.partition(":")
            if key.strip() == "layers":
                parsed["layers"] = [p for p in value.strip().split(",") if p and p != "none"]
            elif key.strip() == "needs_build":
                parsed["needs_build"] = value.strip() == "true"
        self.assertEqual(parsed, {"layers": [], "needs_build": True})

    def test_look_on_a_change_that_needs_a_build_exits_3_with_a_receipt(self):
        head = self.fx.change({"cmux-tui/crates/cmux-app-ffi/src/lib.rs": "pub fn ffi() -> u32 { 3 }\n"})
        app = Path(self.tmp.name) / "cmux NIGHTLY.app"
        (app / "Contents").mkdir(parents=True)
        import plistlib
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CMUXCommit": self.fx.base,
                                                                  "CFBundleVersion": "1"}))
        out = Path(self.tmp.name) / "look"
        code, _ = self.cli("look", "--source", f"sha:{head}", "--app", str(app), "--repo", str(self.fx.repo),
                           "--out", str(out), "--no-video")
        self.assertEqual(code, 3)
        receipt = json.loads((out / "receipt.json").read_text())
        self.assertEqual(receipt["schema"], 1)
        self.assertIsNone(receipt["marker"])
        self.assertTrue(receipt["plan"]["needs_build"])
        self.assertIn("plan", receipt["phases"])

    def fake_app(self, commit: str) -> Path:
        import plistlib
        app = Path(self.tmp.name) / "cmux NIGHTLY.app"
        (app / "Contents").mkdir(parents=True, exist_ok=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CMUXCommit": commit, "CFBundleVersion": "1"}))
        return app

    def test_run_on_uncarried_app_change_exits_3_with_its_plan_and_makes_no_copy(self):
        """A resource or manifest change still needs a complete build and makes no copy."""
        head = self.fx.change({"Packages/macOS/CmuxNext/Resources/Info.plist": "plist\n"})
        app = self.fake_app(self.fx.base)
        made = []
        with unittest.mock.patch.object(hv.Side, "run", lambda side, *a, **k: made.append(a) or ""):
            code, text = self.cli("run", "--source", f"sha:{head}", "--app", str(app), "--repo", str(self.fx.repo),
                                  "--side", "try-test")
        self.assertEqual(code, 3)
        result = json.loads(text.strip().splitlines()[-1])
        self.assertTrue(result["plan"]["needs_build"])
        self.assertTrue(any("Swift" in why for why in result["plan"]["build"]), result["plan"]["build"])
        self.assertEqual((result["side"], result["copy"]), ("try-test", None))
        self.assertEqual(made, [])

    def test_swift_app_fallback_is_only_for_the_carried_swift_layer(self):
        self.assertTrue(hv.can_build_swift_app({"needs_build": True, "build": {"Swift": ["App.swift"]}}))
        self.assertFalse(hv.can_build_swift_app({
            "needs_build": True,
            "build": {"Swift, resources or manifests": ["Resources/Info.plist"]},
        }))
        self.assertFalse(hv.can_build_swift_app({
            "needs_build": True,
            "build": {"Swift": ["App.swift"], "Rust the app links (FFI)": ["pin.json"]},
        }))
        self.assertTrue(hv.can_build_swift_app({
            "needs_build": True, "build": {"Swift, resources or manifests": ["App.swift"]},
        }))
        self.assertFalse(hv.can_build_swift_app({
            "needs_build": True, "build": {"Swift, resources or manifests": ["Packages/App/Package.swift"]},
        }))

    def test_fleet_zip_fallback_preserves_app_archive_with_ditto(self):
        scratch = Path(self.tmp.name) / "zip-fallback"
        calls = []

        def run(argv, **kwargs):
            calls.append(argv)
            if argv[1:3] == ["build", "cmux"]:
                return subprocess.CompletedProcess(argv, 0, '{"id":"zip-job"}', "")
            if "--bundle" in argv:
                (Path(argv[3]) / "partial").write_text("partial")
                return subprocess.CompletedProcess(argv, 3, "", "no bundle")
            if argv[0] == "ditto":
                bundle = Path(argv[-1])
                self.assertFalse((bundle / "partial").exists())
                app = bundle / "cmux DEV.app/Contents"
                app.mkdir(parents=True)
                (app / "Info.plist").write_text("plist")
            return subprocess.CompletedProcess(argv, 0, "", "")

        with unittest.mock.patch.object(hv, "_ci_client", return_value="/fake/cmux-ci"), \
                unittest.mock.patch.object(hv.subprocess, "run", side_effect=run):
            app = hv.build_swift_app(self.fx.repo, {"head": self.fx.base}, f"sha:{self.fx.base}", scratch)
        self.assertEqual(app.name, "cmux DEV.app")
        self.assertEqual(calls[-1][:3], ["ditto", "-x", "-k"])

    def test_fleet_artifact_selects_outer_app_not_embedded_helpers(self):
        bundle = Path(self.tmp.name) / "bundle"
        outer = bundle / "App.app"
        contents = outer / "Contents"
        nested = contents / "Frameworks/Helper.app/Contents"
        nested.mkdir(parents=True)
        (nested / "Info.plist").write_text("plist")
        (contents / "Info.plist").write_text("plist")
        self.assertEqual(hv._artifact_app(bundle), outer)

    def test_failed_fleet_steps_say_why_instead_of_crashing(self):
        scratch = Path(self.tmp.name) / "scratch"

        def fails_on(step, code, out):
            def run(argv, **kwargs):
                if argv[1] == step:
                    return subprocess.CompletedProcess(argv, code, out, "")
                if argv[1:3] == ["build", "cmux"]:
                    return subprocess.CompletedProcess(argv, 0, '{"id":"job-9"}', "")
                return subprocess.CompletedProcess(argv, 0, "", "")
            return run

        for step, code, out, said in (("build", 1, "builder refused\n", "builder refused"),
                                      ("build", 0, "not json", "no job id: not json"),
                                      ("wait", 4, "job timed out\n", "job timed out"),
                                      ("artifact", 2, "no artifact\n", "cmux-ci artifact job-9: no artifact"),
                                      # A step that failed and said nothing: each of the 3 messages says so, and
                                      # does not end at its colon.
                                      ("build", 1, "", "app-try:%s: no output" % self.fx.base),
                                      ("build", 0, "", "no job id: no output"),
                                      ("artifact", 2, "", "cmux-ci artifact job-9: no output")):
            with self.subTest(step=step, code=code), \
                    unittest.mock.patch.object(hv, "_ci_client", return_value="/fake/cmux-ci"), \
                    unittest.mock.patch.object(hv.subprocess, "run", side_effect=fails_on(step, code, out)):
                with self.assertRaises(hv.LookError) as raised:
                    hv.build_swift_app(self.fx.repo, {"head": self.fx.base}, f"sha:{self.fx.base}", scratch)
                self.assertIn(said, str(raised.exception))

    def test_swift_app_fallback_builds_a_clean_ref_with_cmux_ci(self):
        head = self.fx.change({"Packages/macOS/CmuxNext/Sources/CmuxNextApp/App.swift": "struct App { let x = 3 }\n"})
        scratch = Path(self.tmp.name) / "scratch"
        planned = {"head": head}
        ci = "/fake/cmux-ci"
        calls = []

        def run(argv, **kwargs):
            calls.append((argv, kwargs))
            if argv[1:3] == ["build", "cmux"]:
                return subprocess.CompletedProcess(argv, 0, '{"id":"job-1"}\n', "")
            if argv[1] == "wait":
                return subprocess.CompletedProcess(argv, 0, "done\n", "")
            bundle = Path(argv[3])
            app = bundle / "cmux DEV.app/Contents"
            (app / "Resources").mkdir(parents=True)
            (app / "Info.plist").write_bytes(b"plist")
            return subprocess.CompletedProcess(argv, 0, "", "")

        with unittest.mock.patch.object(hv, "_ci_client", return_value=ci), \
                unittest.mock.patch.object(hv.subprocess, "run", side_effect=run):
            built = hv.build_swift_app(self.fx.repo, planned, f"sha:{head}", scratch)
        self.assertEqual(built.name, "cmux DEV.app")
        self.assertEqual(calls[0][0], [ci, "build", "cmux", "--builder", "linux", "--backend-mode", "local",
                                      "--tag", f"app-try-{head[:12]}", "--ref", head, "--workspace", f"app-try:{head}"])
        self.assertEqual(calls[0][1]["cwd"], self.fx.repo)
        self.assertEqual(calls[1][0], [ci, "wait", "--timeout", str(hv.APPLY_SECONDS), "job-1"])

    def test_swift_app_fallback_uses_the_exact_dirty_working_tree(self):
        head = self.fx.change({"Packages/macOS/CmuxNext/Sources/CmuxNextApp/App.swift": "struct App { let x = 5 }\n"})
        (self.fx.repo / "Packages/macOS/CmuxNext/Sources/CmuxNextApp/App.swift").write_text("struct App { let x = 6 }\n")
        scratch = Path(self.tmp.name) / "scratch"
        calls = []

        def run(argv, **kwargs):
            calls.append((argv, kwargs))
            if argv[1:3] == ["build", "cmux"]:
                return subprocess.CompletedProcess(argv, 0, '{"id":"job-2"}\n', "")
            if argv[1] == "wait":
                return subprocess.CompletedProcess(argv, 0, "done\n", "")
            bundle = Path(argv[3]); app = bundle / "cmux DEV.app/Contents"
            app.mkdir(parents=True); (app / "Info.plist").write_bytes(b"plist")
            return subprocess.CompletedProcess(argv, 0, "", "")

        planned = {"head": head}
        with unittest.mock.patch.object(hv, "_ci_client", return_value="/fake/cmux-ci"), \
                unittest.mock.patch.object(hv, "resolve_tree", return_value=self.fx.repo), \
                unittest.mock.patch.object(hv.subprocess, "run", side_effect=run):
            hv.build_swift_app(self.fx.repo, planned, f"dir:{self.fx.repo}", scratch)
        self.assertIn("--working-tree", calls[0][0])
        self.assertNotIn("--ref", calls[0][0])
        self.assertEqual(calls[0][1]["cwd"], self.fx.repo)

    def test_run_on_swift_uses_the_fleet_app_before_launch(self):
        self.assert_run_app_case(swift=True)

    def test_run_without_swift_keeps_scratch_for_live_overlays(self):
        self.assert_run_app_case(swift=False)

    def test_reusable_copy_only_when_nothing_of_the_last_try_stays(self):
        app = self.fake_app(self.fx.base)
        kept = {"try_from": str(app), "try_app": hv.app_info(app), "try_label": "cmux t", "try_layers": ["web"]}
        self.assertIsNone(hv.reusable_copy(kept, app, "cmux t", ["rust", "web"]))
        self.assertEqual(hv.reusable_copy(kept, app, "cmux t", ["rust"]), "the last try's web would stay")
        self.assertEqual(hv.reusable_copy({**kept, "try_from": "/other.app"}, app, "cmux t", ["web"]),
                         "another golden app")
        self.assertEqual(hv.reusable_copy({**kept, "try_app": {"built": "abc"}}, app, "cmux t", ["web"]),
                         "the golden app changed")
        self.assertEqual(hv.reusable_copy({k: v for k, v in kept.items() if k != "try_app"}, app, "cmux t",
                                          ["web"]), "the golden app changed")
        self.assertEqual(hv.reusable_copy(kept, app, "cmux u", ["web"]), "another label")

    def test_a_second_run_reuses_the_kept_copy(self):
        self.assert_run_app_case(swift=False, kept=True)

    def test_a_second_run_from_another_app_clones_afresh(self):
        self.assert_run_app_case(swift=False, kept=True, kept_from="/Applications/cmux OLD.app")

    def assert_run_app_case(self, swift, kept=False, kept_from=None):
        app = self.fake_app(self.fx.base)
        abi = app / hv.hot().APP_ABI
        abi.parent.mkdir(parents=True, exist_ok=True)
        abi.write_text('{"abi": 3}\n')
        files = {"webviews/src/app.tsx": "export const title = 'new'\n"}
        if swift:
            files["Packages/macOS/CmuxNext/Sources/CmuxNextApp/App.swift"] = "struct App { let x = 4 }\n"
        head = self.fx.change(files)
        built = Path(self.tmp.name) / "cmux DEV.app"
        (built / "Contents").mkdir(parents=True)
        calls = []

        tmp = self.tmp.name
        class FakeSide:
            def __init__(self, name):
                self.name = name

            def exists(self):
                return kept

            def state(self):
                return {"try_from": kept_from or str(app), "try_app": hv.app_info(app), "try_label": "cmux try-test",
                        "try_layers": ["web"]}

            def run(self, *args, **kwargs):
                calls.append(args)
                return "try-test: pid 123" if args[0] == "launch" else ""

            def remember(self, **fields):
                calls.append(("remember", fields))

            def socket(self):
                return "/tmp/try-test.sock"

            def app(self):
                return Path(tmp) / "try-test.app"

            def stop(self):
                return []

        scratch_paths = []

        def apply_overlay(rules, planned, src_tree, side, scratch, settle=True):
            self.assertIsInstance(scratch, Path)
            self.assertTrue(scratch.is_dir())
            (scratch / "overlay-input").write_text("payload")
            scratch_paths.append(scratch)
            return {"how": "test overlay"}

        with unittest.mock.patch.object(hv, "Side", FakeSide), \
                unittest.mock.patch.object(hv, "build_swift_app", return_value=built) as app_build, \
                unittest.mock.patch.object(hv, "rules_for", return_value=self.fx.repo), \
                unittest.mock.patch.object(hv, "resolve_tree", return_value=None), \
                unittest.mock.patch.object(hv, "apply_web", side_effect=apply_overlay) as apply_web, \
                unittest.mock.patch.object(hv, "control_socket", return_value="/tmp/try-test.sock"), \
                unittest.mock.patch.object(hv.sys, "platform", "darwin"):
            code, text = self.cli("run", "--source", f"sha:{head}", "--app", str(app),
                                  "--repo", str(self.fx.repo), "--side", "try-test")
        self.assertEqual(code, 0)
        result = json.loads(text.strip().splitlines()[-1])
        if swift:
            self.assertEqual(result["applied"]["app"]["how"], "fleet app build (re-sealed side instance)")
            self.assertEqual(calls[0][:3], ("make", "--from", str(built)))
            app_build.assert_called_once()
            apply_web.assert_not_called()
        elif kept and not kept_from:
            self.assertTrue(result["copy_reused"])
            self.assertNotIn("make", [c[0] for c in calls])
            self.assertNotIn("remove", [c[0] for c in calls])
            self.assertEqual(calls[0][0], "remember")
            self.assertEqual(calls[0][1]["try_layers"], ["web"])
            apply_web.assert_called_once()
        elif kept:
            self.assertFalse(result["copy_reused"])
            self.assertEqual(result["remade_because"], "another golden app")
            self.assertEqual(calls[0][:2], ("remove", "--keep-sign-in"))
            self.assertEqual(calls[1][:3], ("make", "--from", str(app)))
        else:
            self.assertEqual(calls[0][:3], ("make", "--from", str(app)))
            app_build.assert_not_called()
            apply_web.assert_called_once()
            self.assertFalse(scratch_paths[0].exists())

    def test_run_needs_an_app(self):
        code, _ = self.cli("run", "--source", f"dir:{self.fx.repo}", "--app", hv.NO_APP, "--repo", str(self.fx.repo),
                           "--side", "try-test")
        self.assertEqual(code, 2)

    def test_extract_keeps_the_swapped_code_as_a_branch_and_a_patch(self):
        self.fx.git("checkout", "-q", "--detach", self.fx.base)
        (self.fx.repo / "webviews/src/app.tsx").write_text("export const title = 'kept'\n")
        head = hv.resolve_source(self.fx.repo, f"dir:{self.fx.repo}")["head"]
        state = {"try_head": head, "try_fork": self.fx.base, "try_repo": str(self.fx.repo)}
        out = Path(self.tmp.name) / "kept.patch"
        with unittest.mock.patch.object(hv.Side, "exists", lambda side: True), \
                unittest.mock.patch.object(hv.Side, "state", lambda side: state):
            code, text = self.cli("extract", "--side", "try-test", "--out", str(out))
        self.assertEqual(code, 0)
        result = json.loads(text.strip().splitlines()[-1])
        self.assertEqual(result["branch"], "cmux-try/try-test")
        self.assertEqual(self.fx.git("rev-parse", "refs/heads/cmux-try/try-test"), head)
        self.assertEqual(result["files"], ["webviews/src/app.tsx"])
        self.assertIn("+export const title = 'kept'", out.read_text())
        self.assertEqual(self.fx.git("status", "--porcelain"), "M webviews/src/app.tsx")  # working tree as it was

    def test_extract_without_a_run_is_a_usage_error(self):
        with unittest.mock.patch.object(hv.Side, "exists", lambda side: True), \
                unittest.mock.patch.object(hv.Side, "state", lambda side: {}):
            code, _ = self.cli("extract", "--side", "try-test")
        self.assertEqual(code, 2)

    def test_stop_remove_deletes_the_copy(self):
        calls = []
        with unittest.mock.patch.object(hv.Side, "stop", lambda side: []), \
                unittest.mock.patch.object(hv.Side, "exists", lambda side: True), \
                unittest.mock.patch.object(hv.Side, "run", lambda side, *a, **k: calls.append(a) or ""):
            self.assertEqual(self.cli("stop", "--side", "try-test", "--remove")[0], 0)
            self.assertEqual(calls, [("remove",)])
            calls.clear()
            self.assertEqual(self.cli("stop", "--side", "try-test")[0], 0)
            self.assertEqual(calls, [])


class ApplyRustTest(unittest.TestCase):
    """apply_rust over a plan whose daemon is the change applied onto the app's commit (daemon_from)."""

    HEAD, ONTO = "1" * 40, "2" * 40

    class StubSide:
        def __init__(self, root: Path):
            self.root = root

        def app(self) -> Path:
            return self.root / "copy.app"

        def dir(self) -> Path:
            return self.root / "side"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="hot-verify-apply-")
        self.root = Path(self.tmp.name)
        self.calls: list[list[str]] = []
        h = hv.hot()
        self.saved = h.published
        self.published = False
        h.published = lambda key: self.published

    def tearDown(self):
        hv.hot().published = self.saved
        self.tmp.cleanup()

    def apply(self, planned: dict, src_tree: Path | None = None, binary: Path | None = None,
              head_binary: Path | None = None) -> dict:
        def run(argv, **kw):
            self.calls.append([str(a) for a in argv])
            return subprocess.CompletedProcess(argv, 0, stdout='{"phases": {}}\n', stderr="")
        with unittest.mock.patch.object(hv.subprocess, "run", run), \
                unittest.mock.patch.object(hv.shutil, "which", lambda name: "/usr/bin/" + name):
            return hv.apply_rust(self.root, planned, src_tree, self.StubSide(self.root), self.root, binary,
                                 head_binary)

    def test_an_unpublished_head_takes_the_binary_built_from_the_head(self):
        # 2026-11-23: CI publishes no cmux-tui tree for a lane head, so a rust look of one failed on the fetch.
        built = self.root / "head-cmux-tui"
        applied = self.apply({"head": self.HEAD, "tree_key": "k"}, head_binary=built)
        (argv,) = self.calls
        self.assertIn(self.HEAD, argv)
        self.assertEqual(argv[argv.index("--binary") + 1], str(built))
        self.assertEqual(applied["how"], "given binary built from the head")

    def test_a_published_head_tree_wins_over_a_head_binary(self):
        self.published = True
        applied = self.apply({"head": self.HEAD, "tree_key": "k"}, head_binary=self.root / "head-cmux-tui")
        (argv,) = self.calls
        self.assertNotIn("--binary", argv)
        self.assertEqual(applied["how"], "published tree build")

    def test_a_head_binary_never_goes_in_for_a_daemon_onto_the_app(self):
        with self.assertRaisesRegex(hv.LookError, "--rust-binary"):
            self.apply({"head": self.HEAD, "daemon_from": self.ONTO, "tree_key": "k"},
                       head_binary=self.root / "head-cmux-tui")
        self.assertEqual(self.calls, [])

    def test_an_unbuilt_daemon_onto_the_app_is_never_the_head_s(self):
        planned = {"head": self.HEAD, "daemon_from": self.ONTO, "tree_key": "k"}
        with self.assertRaisesRegex(hv.LookError, "--rust-binary"):
            self.apply(planned)
        self.assertEqual(self.calls, [], "neither the head's published daemon nor a build of the head's tree")

    def test_a_given_binary_goes_in_for_the_commit_onto_the_app(self):
        binary = self.root / "cmux-tui"
        applied = self.apply({"head": self.HEAD, "daemon_from": self.ONTO, "tree_key": "k"}, binary=binary)
        (argv,) = self.calls
        self.assertIn(self.ONTO, argv)
        self.assertNotIn(self.HEAD, argv)
        self.assertEqual(argv[argv.index("--binary") + 1], str(binary))
        self.assertEqual(applied["how"], "given binary of the change applied onto the app's commit")

    def test_a_published_daemon_onto_the_app_is_fetched_by_its_commit(self):
        self.published = True
        self.apply({"head": self.HEAD, "daemon_from": self.ONTO, "tree_key": "k"})
        (argv,) = self.calls
        self.assertIn(self.ONTO, argv)
        self.assertNotIn("--binary", argv)

    def test_a_working_tree_is_not_built_for_a_daemon_onto_the_app(self):
        # A dir: source's working tree is the head's: building it would bring the skew back.
        tree = self.root / "tree"
        (tree / "cmux-tui").mkdir(parents=True)
        (tree / "cmux-tui/Cargo.toml").write_text("[workspace]\n")
        with self.assertRaisesRegex(hv.LookError, "--rust-binary"):
            self.apply({"head": self.HEAD, "daemon_from": self.ONTO, "tree_key": "k"}, src_tree=tree)
        self.assertFalse(any(argv[0] == "cargo" for argv in self.calls))

    def test_a_given_binary_without_daemon_from_is_refused(self):
        # Review: a binary the worker built for its plan's daemon_from, given to a look whose own plan has none,
        # would go in labelled as the head's daemon.
        with self.assertRaisesRegex(hv.LookError, "daemon_from"):
            self.apply({"head": self.HEAD, "tree_key": "k"}, binary=self.root / "cmux-tui")
        self.assertEqual(self.calls, [])

    def test_a_plan_without_daemon_from_applies_the_head_as_before(self):
        self.published = True
        self.apply({"head": self.HEAD, "tree_key": "k"})
        (argv,) = self.calls
        self.assertIn(self.HEAD, argv)

    def test_the_copy_s_acpmux_daemons_take_the_change_and_the_receipt_says_which(self):
        # 2026-11-21 hot-swap end to end: an acpmux change's look left the copy's acpmux daemon on the old build,
        # and the look's receipt kept only hot-apply's phases, so nothing said so.
        self.published = True
        left = [{"home": "/h/old", "pid": 7, "why": "its launch environment is unreadable"}]
        stdout = json.dumps({"phases": {"swap": 1.0}, "steps": {
            "rust": {"to": "x", "acpmux_left_on_old_build": left},
            "acpmux": [{"home": "/h/new", "from_pid": 5, "pid": 6}]}}) + "\n"

        def run(argv, **kw):
            self.calls.append([str(a) for a in argv])
            return subprocess.CompletedProcess(argv, 0, stdout=stdout, stderr="")
        with unittest.mock.patch.object(hv.subprocess, "run", run):
            applied = hv.apply_rust(self.root, {"head": self.HEAD, "tree_key": "k"}, None,
                                    self.StubSide(self.root), self.root)
        for planned in ({"head": self.HEAD, "tree_key": "k"}, {"head": self.HEAD, "daemon_from": self.ONTO,
                                                               "tree_key": "k"}):
            self.calls.clear()
            self.apply(planned)
            (argv,) = self.calls
            self.assertIn("--restart-acpmux", argv)
        self.assertEqual(applied["acpmux"], [{"home": "/h/new", "from_pid": 5, "pid": 6}])
        self.assertEqual(applied["acpmux_left_on_old_build"], left)
        self.assertEqual(applied["phases"], {"swap": 1.0})


class PublishedPullRequestWebTest(unittest.TestCase):
    """look --pr N: a pull request's web layer comes from the bundles CI published for its head."""

    HEAD = "92019c2684f5a22820837a020c520a9122f57b5a"  # cmux#45917's head, on no branch once it merged
    KEY = "8c95ee2270c26fe36d1c127cdc1061570026b045223f1d160c23b4a7f9b316ff"

    def pointer(self, url):
        return {"head": self.HEAD, "key": self.KEY} if url.endswith("/pr/45917/latest.json") else None

    def test_a_merged_head_on_no_branch_on_a_worker_with_no_bun_looks_from_its_published_layer(self):
        # 2026-11-18 own looks: cmux#45917 (cmux18) ended "is on no branch of origin" and cmux#46028 (cmux21)
        # "no bun here serves its webviews"; both heads' pointers named them. Neither check runs on that path.
        planned = {"head": self.HEAD, "pr": 45917, "layers": ["web"]}
        ran = []

        def run(argv, **_kw):
            ran.append(Path(argv[0]).name)
            return subprocess.CompletedProcess(argv, 0, "", "")

        side = unittest.mock.Mock(env=lambda: {})
        with unittest.mock.patch.object(hv, "fetch_json", side_effect=self.pointer), \
                unittest.mock.patch.object(hv.shutil, "which", side_effect=AssertionError("asked for bun")), \
                unittest.mock.patch.object(hv, "git", side_effect=AssertionError("checked the branches")), \
                unittest.mock.patch.object(hv.subprocess, "run", side_effect=run), \
                unittest.mock.patch.object(hv.time, "sleep"):
            done = hv.apply_web(Path("/nonexistent"), planned, None, side, Path("/nonexistent"))
        self.assertEqual(done, {"how": "published bundles", "key": self.KEY})
        self.assertEqual(ran, ["fetch-web-bundles.sh", "web-overlay.sh"])

    def test_a_squash_merged_head_with_no_published_layer_is_landed_code_not_a_fork(self):
        # cmux#62289 (2026-11-27): head 19e26fb9 is an ancestor of nothing once squashed and its branch is deleted,
        # so apply_web raised "is on no branch of origin" and the look kept only the default scene.
        planned = {"head": self.HEAD, "pr": 62289}

        def run(argv, **_kw):
            if "merge-base" in argv:
                return subprocess.CompletedProcess(argv, 1, "", "")
            if "log" in argv:
                return subprocess.CompletedProcess(argv, 0, "Fix hat deck (#62289)\n", "")
            return subprocess.CompletedProcess(argv, 0, "", "")

        side = unittest.mock.Mock(env=lambda: {})
        with unittest.mock.patch.object(hv, "published_web_key", return_value=None), \
                unittest.mock.patch.object(hv.shutil, "which", return_value="/bin/bun"), \
                unittest.mock.patch.object(hv, "git", return_value=""), \
                unittest.mock.patch.object(hv, "base_tip", return_value="origin/feat-cmux-next"), \
                unittest.mock.patch.object(hv, "web_checkout", return_value=Path("/tree")), \
                unittest.mock.patch.object(hv, "free_port", return_value=1), \
                unittest.mock.patch.object(hv.subprocess, "run", side_effect=run):
            done = hv.apply_web(Path("/nonexistent"), planned, None, side, Path("/nonexistent"))
        self.assertEqual(done["how"], "dev server")

    def test_a_head_of_a_pr_not_on_the_base_still_stops(self):
        planned = {"head": self.HEAD, "pr": 62289}

        def run(argv, **_kw):
            return subprocess.CompletedProcess(argv, 1 if "merge-base" in argv else 0, "", "")

        side = unittest.mock.Mock(env=lambda: {})
        with unittest.mock.patch.object(hv, "published_web_key", return_value=None), \
                unittest.mock.patch.object(hv.shutil, "which", return_value="/bin/bun"), \
                unittest.mock.patch.object(hv, "git", return_value=""), \
                unittest.mock.patch.object(hv, "base_tip", return_value="origin/feat-cmux-next"), \
                unittest.mock.patch.object(hv.subprocess, "run", side_effect=run):
            with self.assertRaises(hv.LookError):
                hv.apply_web(Path("/nonexistent"), planned, None, side, Path("/nonexistent"))

    def test_stop_ends_a_dev_server_still_starting_before_server_off(self):
        side = hv.Side("t")
        order = []
        with unittest.mock.patch.object(hv.Side, "exists", return_value=True), \
                unittest.mock.patch.object(hv.Side, "state", return_value={"dev_server": True,
                                                                           "dev_server_starter_pid": 99}), \
                unittest.mock.patch.object(hv.Side, "env", return_value={}), \
                unittest.mock.patch.object(hv.Side, "run", return_value=""), \
                unittest.mock.patch.object(hv.Side, "remember") as remember, \
                unittest.mock.patch.object(hv, "starting_dev_server", return_value=True), \
                unittest.mock.patch.object(hv.os, "killpg", side_effect=lambda pid, sig: order.append(("kill", pid))), \
                unittest.mock.patch.object(hv.subprocess, "run",
                                           side_effect=lambda argv, **_kw: order.append(tuple(argv[1:3]))):
            self.assertEqual(side.stop(), [])
        self.assertEqual(order, [("kill", 99), ("server", "off")])
        self.assertIsNone(remember.call_args.kwargs["dev_server_starter_pid"])

    def test_a_pointer_for_another_head_is_not_used(self):
        planned = {"head": "1" * 40, "pr": 45917}
        with unittest.mock.patch.object(hv, "fetch_json", side_effect=self.pointer), \
                unittest.mock.patch.object(hv.hot(), "web_key", return_value="f" * 64):
            self.assertIsNone(hv.published_web_key(Path("/nonexistent"), planned))


NIGHTLY_FEED_XML = """<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"
     xmlns:cmux="https://cmux.com/xml-namespaces/cmux"><channel>
<item><title>1.0.0-nightly.2</title><sparkle:shortVersionString>1.0.0-nightly.2</sparkle:shortVersionString>
<enclosure url="https://files-next.cmux.com/nightly-next/n2.dmg" length="1" type="application/octet-stream"/>
<cmux:sourceCommit>{nightly}</cmux:sourceCommit></item>
<item><title>no commit</title><enclosure url="https://files-next.cmux.com/nightly-next/n0.dmg"/></item>
</channel></rss>"""
TIP_FEED_XML = """<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel>
<item><title>1.0.0-tip.9</title><sparkle:shortVersionString>1.0.0-tip.9</sparkle:shortVersionString>
<sparkle:fullReleaseNotesLink>https://github.com/manaflow-ai/cmux/commit/{tip}</sparkle:fullReleaseNotesLink>
<enclosure url="https://files.cmux.com/nightly-next/tip/t9.dmg" length="1" type="application/octet-stream"/></item>
<item><title>plain http</title>
<sparkle:fullReleaseNotesLink>https://github.com/manaflow-ai/cmux/commit/{tip}</sparkle:fullReleaseNotesLink>
<enclosure url="http://example.com/t.dmg"/></item>
</channel></rss>"""


class GoldenCopyTest(unittest.TestCase):
    """`cmux app try .` copied only the installed NIGHTLY: a checkout at the feat-cmux-next tip exited 3 against a
    nightly 354 commits behind it whose app FFI pin the commits since had moved (2026-11-18). `run --pick` takes the
    nearest published build the tree goes into instead."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="hot-verify-golden-")
        self.root = Path(self.tmp.name)
        self.fx = Fixture(self.root)
        self.c1 = self.fx.commit({"docs/notes.md": "one\n"}, "c1", parent=self.fx.base)
        self.c2 = self.fx.commit({"docs/notes.md": "two\n"}, "c2")
        self.fx.git("push", "-q", "origin", f"{self.c2}:refs/heads/feat-cmux-next")
        self.fx.git("fetch", "-q", "origin")
        self.ahead = self.fx.commit({"docs/notes.md": "three\n"}, "after the tree")

    def tearDown(self):
        self.tmp.cleanup()

    def feeds(self, nightly: str, tip: str):
        texts = {hv.NIGHTLY_FEED: NIGHTLY_FEED_XML.format(nightly=nightly), hv.TIP_FEED: TIP_FEED_XML.format(tip=tip)}
        return unittest.mock.patch.object(hv, "fetch_text", side_effect=texts.get)

    def test_feeds_name_their_commits_both_ways(self):
        nightly = hv.appcast_builds(NIGHTLY_FEED_XML.format(nightly="abc1234"), "nightly")
        self.assertEqual([(b["commit"], b["label"]) for b in nightly], [("abc1234", "1.0.0-nightly.2")])
        tip = hv.appcast_builds(TIP_FEED_XML.format(tip="d" * 40), "tip")
        self.assertEqual([b["url"] for b in tip], ["https://files.cmux.com/nightly-next/tip/t9.dmg"])
        self.assertEqual(hv.appcast_builds("not xml", "tip"), [])

    def test_candidates_are_nearest_first_and_never_ahead_of_the_tree(self):
        with self.feeds(self.fx.base, self.c1), unittest.mock.patch.object(hv, "cmux_ci", return_value=None):
            found = hv.golden_candidates(self.fx.repo, self.c2, None, [])
        self.assertEqual([(b["kind"], b["commit"], b["behind"]) for b in found],
                         [("tip", self.c1, 1), ("nightly", self.fx.base, 2)])
        with self.feeds(self.ahead, self.c1), unittest.mock.patch.object(hv, "cmux_ci", return_value=None):
            found = hv.golden_candidates(self.fx.repo, self.c2, self.c1, [])
        self.assertEqual(found, [], "a build after the tree and the installed app's commit are not candidates")

    def test_a_nightly_wins_a_tie_with_a_dev_build(self):
        with self.feeds(self.c1, self.c1[:9]), unittest.mock.patch.object(hv, "cmux_ci", return_value=None):
            found = hv.golden_candidates(self.fx.repo, self.c2, None, [])
        self.assertEqual([b["kind"] for b in found], ["nightly"], "the same commit is one candidate")

    def test_the_nearest_finished_fleet_build(self):
        tool = self.root / "cmux-ci"
        jobs = {self.c1: [{"kind": "cmux", "state": "running", "artifact": "sha256:x", "id": "j0"},
                          {"kind": "cmux", "state": "done", "artifact": "sha256:y", "id": "j1", "tag": "ahead-c1"}]}
        tool.write_text("#!/usr/bin/env python3\nimport json, sys\n"
                        f"jobs = {json.dumps(jobs)}\nprint(json.dumps(jobs.get(sys.argv[3], [])))\n")
        tool.chmod(0o755)
        with unittest.mock.patch.object(hv, "cmux_ci", return_value=str(tool)):
            found = hv.fleet_build(self.fx.repo, self.c2, [])
        self.assertEqual(found, {"kind": "fleet", "commit": self.c1, "job": "j1", "label": "ahead-c1"})

    def test_pick_keeps_the_installed_app_when_it_fits_and_moves_off_it_when_it_does_not(self):
        app = self.root / "cmux NIGHTLY.app"
        (app / "Contents").mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(b"")

        def fake_plan(repo, source, the_app, base):
            commit = base or self.fx.base
            return {"head": self.c2, "base": commit, "fork": commit, "layers": ["rust"],
                    "needs_build": commit != self.c1 or self.fit_installed is False and the_app is not None,
                    "build": {} if commit == self.c1 else {"Rust the app links (FFI)": ["pin"]}, "notes": []}

        self.fit_installed = False
        found = [{"kind": "nightly", "commit": self.fx.base, "behind": 2, "identity": "nightly", "label": "n"},
                 {"kind": "fleet", "commit": self.c1, "behind": 1, "identity": "dev", "label": "ahead", "job": "j"}]
        with unittest.mock.patch.object(hv, "plan", side_effect=fake_plan), \
                unittest.mock.patch.object(hv, "golden_candidates", return_value=found):
            chosen = hv.pick_golden(self.fx.repo, "dir:.", app)
        self.assertEqual((chosen["kind"], chosen["commit"], chosen["job"]), ("fleet", self.c1, "j"))
        self.assertIn("1 commit behind", chosen["why"])
        self.assertIn("needs one (Rust the app links (FFI))", chosen["why"])
        self.assertEqual(len(chosen["tried"]), 2)
        with unittest.mock.patch.object(hv, "plan", side_effect=fake_plan), \
                unittest.mock.patch.object(hv, "golden_candidates", return_value=found[:1]):
            chosen = hv.pick_golden(self.fx.repo, "dir:.", app)
        self.assertEqual(chosen["kind"], "installed")
        self.assertTrue(chosen["plan"]["needs_build"])
        self.assertTrue(chosen["why"].startswith("no published build takes this tree"))

    def test_a_fleet_dev_build_is_stamped_with_its_commit(self):
        import plistlib
        app = self.root / "cmux DEV ahead.app"
        (app / "Contents").mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.cmuxterm.app.debug.x"}))
        hv.stamp_commit(app, self.c1)
        self.assertEqual(hv.app_info(app)["commit"], self.c1)
        hv.stamp_commit(app, self.c2)
        self.assertEqual(hv.app_info(app)["commit"], self.c1, "a commit the app names is kept")

    def test_apply_web_sleeps_for_no_page_reload(self):
        # A look waits for the reload on the window's own pixels (Repaint), never a fixed sleep in apply_web.
        tree = self.root / "tree"
        (tree / "webviews").mkdir(parents=True)
        side = unittest.mock.Mock(env=lambda: {})
        ok = subprocess.CompletedProcess([], 0, "", "")
        for settle, waits in ((False, []), (True, [])):
            slept = []
            with unittest.mock.patch.object(hv.shutil, "which", return_value="/bin/bun"), \
                    unittest.mock.patch.object(hv.subprocess, "run", return_value=ok), \
                    unittest.mock.patch.object(hv.time, "sleep", side_effect=slept.append):
                done = hv.apply_web(self.fx.repo, {"head": self.c2}, tree, side, self.root, settle=settle)
            self.assertEqual(done["how"], "dev server")
            self.assertEqual(slept, waits)

    def test_a_run_of_a_checkout_whose_web_is_published_takes_the_bundles_and_starts_its_server_behind(self):
        """team-dev-build-is-swap cut 3: `cmux app try dir:CHECKOUT` of a clone CI published the web of waits for
        no cold dev server; the server still starts, unwaited, so later edits hot reload."""
        tree = self.root / "tree"
        (tree / "scripts/cmux-next").mkdir(parents=True)
        (tree / "scripts/cmux-next/web-bundle-key.py").write_text("")
        key = "c" * 64
        cache = self.root / "cache"
        (cache / "web-bundles" / key).mkdir(parents=True)
        (cache / "web-bundles" / key / ".manifest.json").write_text("{}")
        side = unittest.mock.Mock(env=lambda: {}, name="t")
        side.name = "t"
        ran, slept = [], []

        def run(argv, **_kw):
            ran.append(Path(argv[1] if argv[0] == sys.executable else argv[0]).name)
            return subprocess.CompletedProcess(argv, 0, key + "\n" if argv[0] == sys.executable else "", "")

        with unittest.mock.patch.dict(os.environ, {"CMUX_HOT_VERIFY_CACHE": str(cache)}), \
                unittest.mock.patch.object(hv, "fetch_json", return_value={"key": key}), \
                unittest.mock.patch.object(hv.shutil, "which", return_value="/bin/bun"), \
                unittest.mock.patch.object(hv.subprocess, "run", side_effect=run), \
                unittest.mock.patch.object(hv.subprocess, "Popen") as popen, \
                unittest.mock.patch.object(hv.time, "sleep", side_effect=slept.append):
            popen.return_value.pid = 4242
            done = hv.apply_web(self.fx.repo, {"head": self.c2}, tree, side, self.root, settle=False)
        self.assertEqual(done, {"how": "published bundles", "key": key, "dev_server_starter_pid": 4242})
        self.assertEqual(ran, ["web-bundle-key.py", "web-overlay.sh"], "the cached bundles are not fetched again")
        self.assertEqual(slept, [])
        self.assertEqual(popen.call_args.args[0][1:4], ["server", "--local", "--worktree"])
        side.remember.assert_any_call(dev_server=True)
        side.remember.assert_called_with(dev_server_starter_pid=4242)

    def test_a_look_of_a_checkout_keeps_its_dev_server_first(self):
        tree = self.root / "tree"
        (tree / "webviews").mkdir(parents=True)
        side = unittest.mock.Mock(env=lambda: {})
        ok = subprocess.CompletedProcess([], 0, "", "")
        with unittest.mock.patch.object(hv, "tree_web_key", side_effect=AssertionError("keyed the tree")), \
                unittest.mock.patch.object(hv.shutil, "which", return_value="/bin/bun"), \
                unittest.mock.patch.object(hv.subprocess, "run", return_value=ok), \
                unittest.mock.patch.object(hv.time, "sleep"):
            self.assertEqual(hv.apply_web(self.fx.repo, {"head": self.c2}, tree, side, self.root)["how"], "dev server")

    def test_an_edited_or_unpublished_checkout_web_is_served_by_its_dev_server(self):
        tree = self.root / "tree"
        (tree / "scripts/cmux-next").mkdir(parents=True)
        (tree / "scripts/cmux-next/web-bundle-key.py").write_text("")
        done = subprocess.CompletedProcess([], 0, "d" * 64 + "\n", "")
        with unittest.mock.patch.object(hv.subprocess, "run", return_value=done), \
                unittest.mock.patch.object(hv, "fetch_json", return_value=None):
            self.assertIsNone(hv.tree_web_key(tree))
        self.assertIsNone(hv.tree_web_key(self.root / "no-script"))

    def test_no_published_daemon_and_no_cargo_says_so(self):
        """A fleet Mac (2026-11-19) has no cargo, and the tree's daemon was not published: hot-apply said only
        `exited 1: apply 4.0 s: key 3.2, plan 0.4, fetch 0.3`."""
        tree = self.root / "tree"
        (tree / "cmux-tui").mkdir(parents=True)
        side = unittest.mock.Mock(app=lambda: self.root / "copy.app", dir=lambda: self.root)
        with unittest.mock.patch.object(hv.shutil, "which", return_value=None), \
                unittest.mock.patch.object(hv.hot(), "published", return_value=False), \
                unittest.mock.patch.object(hv.subprocess, "run", side_effect=AssertionError("ran hot-apply")):
            with self.assertRaisesRegex(hv.LookError, "no cargo on this Mac"):
                hv.apply_rust(self.root, {"head": self.c2, "tree_key": "k" * 40}, tree, side, self.root)

    def test_a_local_cargo_build_says_how_long_first(self):
        tree = self.root / "tree"
        cold = hv.cargo_note("k" * 64, tree)
        self.assertIn("about 10 min (cold", cold)
        self.assertIn("cmux-ci build cmux", cold)
        (tree / "cmux-tui/target/release").mkdir(parents=True)
        (tree / "cmux-tui/target/release/cmux-tui").write_text("")
        self.assertIn("about 4 min (warm)", hv.cargo_note(None, tree))

    def test_cleanup_keeps_a_golden_app_another_try_is_cloning(self):
        """fetch_golden let the cache lock go before the try cloned its app, so another try's cleanup could delete
        the app mid-clone (review on #46939). A try now holds the app's in-use lock until its clone is made."""
        import fcntl
        root = self.root / "golden"
        root.mkdir()
        names = [f"nightly-{n:012d}" for n in range(hv.GOLDEN_KEEP + 1)]
        for age, name in enumerate(names):
            (root / name).mkdir()
            (root / name / hv.GOLDEN_READY).write_text("{}\n")
            os.utime(root / name, (1000 - age, 1000 - age))
        oldest = names[-1]
        held = contextlib.ExitStack()
        build = {"kind": "nightly", "commit": oldest.split("-", 1)[1]}
        with unittest.mock.patch.object(hv, "golden_root", return_value=root), \
                unittest.mock.patch.object(hv, "golden_app", side_effect=lambda p: p):
            self.assertEqual(hv.fetch_golden(build, held), root / oldest)
            # The held app is now the newest, and that fetch's cleanup left GOLDEN_KEEP apps. Add one and age the held
            # app, so it is the one past GOLDEN_KEEP.
            (root / "nightly-extra").mkdir()
            (root / "nightly-extra" / hv.GOLDEN_READY).write_text("{}\n")
            os.utime(root / oldest, (1, 1))
            other = {"kind": "nightly", "commit": names[0].split("-", 1)[1]}
            hv.fetch_golden(other)
            self.assertTrue((root / oldest).is_dir(), "an app a try holds is never removed")
            held.close()
            hv.fetch_golden(other)
            self.assertFalse((root / oldest).exists(), "once let go, the cleanup removes it")
        with hv.golden_use_lock(root, oldest) as free:
            fcntl.flock(free, fcntl.LOCK_EX | fcntl.LOCK_NB)


class MarkerTest(unittest.TestCase):
    def test_marker_matches_hq(self):
        import re
        head = "a" * 40
        for source in ("pr", "worktree"):
            line = hv.marker(head, "3f2a1b9c0", ["web", "rust"], source)
            self.assertRegex(line, "^" + HQ_MARKER + "$")
            self.assertEqual(re.fullmatch(HQ_MARKER, line).groups(), (head, "3f2a1b9c0", "web,rust", source))

    def test_marker_refuses_what_hq_cannot_read(self):
        with self.assertRaises(ValueError):
            hv.marker("abc", "x", ["web"], "pr")
        with self.assertRaises(ValueError):
            hv.marker("a" * 40, "x", [], "pr")
        self.assertIn("app=1.2-345", hv.marker("a" * 40, "1.2 345", ["web"], "pr"))


class WhyFailedTest(unittest.TestCase):
    # The stderr of `cargo build --release -p cmux-tui` that `cmux app try .` ran on cmux17 (2026-11-19), cut.
    ZIG_TOO_OLD = """warning: `cmux-supervise-core` (lib) generated 2 warnings
error: failed to run custom build command for `ghostty-vt-sys v0.1.0 (/Users/cmux/try-bench/bench/cmux-tui/crates/ghostty-vt-sys)`

Caused by:
  process didn't exit successfully: `.../build-script-build` (exit status: 101)
  --- stderr
  src/build/Config.zig:132:17: error: invalid builtin function: '@backingInt'
                  @backingInt(std.Target.wasm.Feature.simd128),
  build.zig:28:45: error: no field named 'root' in struct 'Build'
  src/build/zig.zig:13:9: error: Your Zig version v0.16.0 does not meet the required build version of v0.17.0
          @compileError(std.fmt.comptimePrint(
      4 reference(s) hidden; use '-freference-trace=6' to see all references

  thread 'main' (10585823) panicked at crates/ghostty-vt-sys/build.rs:148:9:
  zig build of libghostty-vt failed with exit status: 2
  note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace
warning: build failed, waiting for other jobs to finish...
"""

    def test_a_failed_build_says_its_cause_not_its_last_lines(self):
        old = self.ZIG_TOO_OLD.strip()[-300:]
        self.assertNotIn("Your Zig version", old)  # what the engine printed before
        said = hv.why_failed(self.ZIG_TOO_OLD, 300)
        self.assertIn("Your Zig version v0.16.0 does not meet the required build version of v0.17.0", said)
        self.assertIn("zig build of libghostty-vt failed", said)
        self.assertLessEqual(len(said), 300)

    def test_a_build_script_panic_keeps_its_message(self):
        out = ("error: failed to run custom build command for `ghostty-vt-sys v0.1.0`\n"
               "  thread 'main' panicked at crates/ghostty-vt-sys/build.rs:30:9:\n"
               "  ghostty-next is not a checkout of manaflow-ai/ghostty-next. Run `git submodule update --init "
               "ghostty-next` at the cmux repo root, or set CMUX_GHOSTTY_SRC to a manaflow-ai/ghostty-next checkout.\n"
               "  note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace\n"
               "warning: build failed, waiting for other jobs to finish...\n")
        self.assertIn("git submodule update --init ghostty-next", hv.why_failed(out, 300))

    def test_output_with_no_error_line_keeps_its_end(self):
        self.assertEqual(hv.why_failed("one\ntwo\nthree", 5), "three")
        self.assertEqual(hv.why_failed("", 300), "")
        self.assertEqual(hv.why_failed(None, 300), "")

    def test_rustc_and_git_errors_count(self):
        self.assertEqual(hv.why_failed("ok\nerror[E0425]: cannot find value `x`\n  --> a.rs:1:1", 300),
                         "error[E0425]: cannot find value `x`")
        self.assertEqual(hv.why_failed("fatal: not a git repository\n", 300), "fatal: not a git repository")

    def test_a_thrown_script_error_is_kept_beside_bun_s_summary(self):
        out = ("ENOENT: no such file or directory, scandir '/t/release-notes/next/highlights'\n"
               "    at generatedTips (/t/webviews/scripts/pages/gen-feature-tips.mjs:59:6)\n"
               "error: postinstall script from \"@cmux/webviews\" exited with 1\n")
        said = hv.why_failed(out, 300)
        self.assertIn("ENOENT: no such file or directory, scandir", said)
        self.assertIn("TypeError: x is not a function", hv.why_failed("a\nTypeError: x is not a function\nb", 300))

    def test_a_step_that_printed_nothing_still_says_why(self):
        done = subprocess.CompletedProcess(["web-overlay.sh"], 1, stdout="", stderr="")
        self.assertEqual(hv.why_exited(done), "exited 1 and printed nothing")
        done = subprocess.CompletedProcess(["web-overlay.sh"], 1, stdout="no webviews/ in /t\n", stderr="")
        self.assertEqual(hv.why_exited(done), "no webviews/ in /t")


class WidenSparseTest(unittest.TestCase):
    """`cmux app try .` from a wt checkout (sparse: /scripts/ and /webviews/ only) stopped at bun's postinstall,
    which read release-notes/ and schemas/ the checkout did not have (2026-11-22): the engine adds them."""

    def test_a_sparse_checkout_gets_what_its_web_reads_and_keeps_what_it_had(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / "repo"
            files = {"scripts/cmux-next/web-bundle-key.py": "import sys\nprint('webviews\\n:(glob)release-notes/next/*.md')\n",
                     "webviews/package.json": "{}\n", "release-notes/next/a.md": "x\n",
                     "schemas/gallery/fixtures.json": "{}\n", "docs/big.md": "x\n"}
            for name, text in files.items():
                (root / name).parent.mkdir(parents=True, exist_ok=True)
                (root / name).write_text(text)
            env = git_fixture_env.fixture_env()
            run = lambda *a: subprocess.run(["git", "-C", str(root), *a], check=True, capture_output=True, env=env)
            git_fixture_env.init_repo(root, "-q")
            run("add", "-A")
            run("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init")
            run("sparse-checkout", "set", "--no-cone", "/*", "!/*/", "/scripts/", "/webviews/")
            self.assertFalse((root / "release-notes/next/a.md").exists())
            with contextlib.redirect_stderr(io.StringIO()), unittest.mock.patch.dict(os.environ, env, clear=True):
                hv.widen_sparse(root)
            self.assertTrue((root / "release-notes/next/a.md").exists())
            self.assertTrue((root / "schemas/gallery/fixtures.json").exists())
            self.assertTrue((root / "webviews/package.json").exists())
            self.assertFalse((root / "docs/big.md").exists())

    def test_a_full_checkout_is_left_alone(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            git_fixture_env.init_repo(root, "-q")
            with unittest.mock.patch.object(hv.subprocess, "run", wraps=subprocess.run) as ran, \
                    unittest.mock.patch.dict(os.environ, git_fixture_env.fixture_env(), clear=True):
                hv.widen_sparse(root)
            self.assertFalse(any("web-bundle-key.py" in " ".join(map(str, c.args[0])) for c in ran.call_args_list))


class BrowserEngineTest(unittest.TestCase):
    """The copy starts on WebKit unless the steps file says chromium: a Chromium-default NEXT nightly turns
    uncapturable 10-25 s after launch (the kit's CHROMIUM_UNCAPTURABLE), which failed the first fleet look."""

    def test_steps_engine_defaults_to_webkit(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(hv.steps_engine(None), "webkit")
            path = Path(d) / "steps.json"
            path.write_text(json.dumps({"steps": [{"shot": "a"}]}))
            self.assertEqual(hv.steps_engine(str(path)), "webkit")
            path.write_text(json.dumps({"steps": [{"shot": "a"}], "engine": "chromium"}))
            self.assertEqual(hv.steps_engine(str(path)), "chromium")
            path.write_text(json.dumps({"steps": [{"shot": "a"}], "engine": "gecko"}))
            with self.assertRaises(hv.Usage):
                hv.steps_engine(str(path))

    def test_set_browser_engine_keeps_other_settings(self):
        with tempfile.TemporaryDirectory() as d:
            config = Path(d) / "config" / "cmux-next.json"
            hv.set_browser_engine(config, "webkit")
            self.assertEqual(json.loads(config.read_text()), {"browser": {"defaultEngine": "webkit"}})
            config.write_text(json.dumps({"browser": {"homePage": "x"}, "ui": {"density": "compact"}}))
            hv.set_browser_engine(config, "chromium")
            self.assertEqual(json.loads(config.read_text()),
                             {"browser": {"homePage": "x", "defaultEngine": "chromium"}, "ui": {"density": "compact"}})

    def test_set_browser_engine_never_overwrites_an_unreadable_file(self):
        with tempfile.TemporaryDirectory() as d:
            config = Path(d) / "cmux-next.json"
            config.write_text("{ // a comment\n}")
            with self.assertRaises(hv.LookError):
                hv.set_browser_engine(config, "webkit")
            self.assertEqual(config.read_text(), "{ // a comment\n}")


class ControlSocketTest(unittest.TestCase):
    """The copy's socket is the one side-instance.sh named, asked once: no scan of every cmux socket (each a 5 s
    timeout) while it launches."""

    def serve(self, path: str, pid: int):
        import socket
        import threading
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(path)
        server.listen(4)
        self.addCleanup(server.close)

        def answer():
            with contextlib.suppress(OSError):
                while True:
                    conn, _ = server.accept()
                    with conn:
                        conn.recv(1 << 16)
                        conn.sendall((json.dumps({"id": 1, "ok": True, "result": {"pid": pid}}) + "\n").encode())

        threading.Thread(target=answer, daemon=True).start()

    def test_named_socket_answering_with_the_pid(self):
        with tempfile.TemporaryDirectory(prefix="hv-") as d:
            sock = os.path.join(d, "c.sock")
            self.serve(sock, 4242)
            self.assertEqual(hv.control_socket(4242, sock), sock)
            self.assertIsNone(hv.control_socket(4243, sock))  # another app's socket at that path

    def test_no_socket_at_the_named_path_falls_back_to_the_scan(self):
        # An app older than CMUX_NEXT_SOCKET_PATH never makes the named socket; it puts one by its key hash.
        from unittest import mock
        with tempfile.TemporaryDirectory(prefix="hv-") as d:
            hashed = os.path.join(d, "cmux-abc.sock")
            self.serve(hashed, 4242)
            with mock.patch("glob.glob", lambda pattern: [hashed] if pattern.startswith("/tmp/") else []):
                self.assertEqual(hv.control_socket(4242, os.path.join(d, "missing.sock")), hashed)



class VideoTest(unittest.TestCase):
    """The look's video: with the kit, the kit's Recorder (CuaDriver's Screen Recording grant) records it, never
    record-window, which has no grant on a fleet worker (2026-11-15/16: every fleet look said "no Screen Recording
    grant" while CuaDriver held it on the same minis)."""

    class FakeRecorder:
        def __init__(self):
            self.process, self.calls = None, []

        @property
        def running(self):
            return self.process is not None

        def start(self, out, clip):
            self.calls.append(("start", clip))
            self.process = type("P", (), {"pid": 4242})()
            return {"clip": f"clips/{clip}.mp4", "recording": True}

        def stop(self, out):
            self.calls.append(("stop",))
            self.cap_at_stop = self.kit.MAX_CLIP_BYTES
            self.process = None
            dest = Path(out) / "clips" / f"{hv.LOOK_CLIP}.mp4"
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(b"\0" * 8192)
            return {"clip": f"clips/{hv.LOOK_CLIP}.mp4", "bytes": 8192}

        def close(self):
            self.calls.append(("close",))
            self.process = None

    def kit(self):
        """A stand-in for the kit module: its Recorder and the steps-clip cap (nightly_steps.MAX_CLIP_BYTES)."""
        recorder = self.FakeRecorder()
        kit = type("Kit", (), {"Recorder": staticmethod(lambda: recorder), "MAX_CLIP_BYTES": 30 << 20})()
        recorder.kit = kit
        return kit, recorder

    def test_a_look_lifts_the_steps_clip_cap_for_its_own_stop_only(self):
        kit, recorder = self.kit()
        with tempfile.TemporaryDirectory() as tmp:
            video = hv.Video(Path(tmp), kit)
            video.start(1)
            with unittest.mock.patch.object(hv, "window_frame", return_value=None), \
                    unittest.mock.patch.object(hv, "main_display_points", return_value=None):
                video.stop()
        self.assertEqual(recorder.cap_at_stop, hv.RAW_VIDEO_MAX_BYTES)
        self.assertEqual(kit.MAX_CLIP_BYTES, 30 << 20)

    def test_fit_video_keeps_a_video_that_fits(self):
        with tempfile.TemporaryDirectory() as tmp:
            mp4 = Path(tmp) / "video.mp4"
            mp4.write_bytes(b"x" * 100)
            hv.fit_video(mp4, most=100)
            self.assertEqual(mp4.stat().st_size, 100)

    def test_fit_video_removes_a_video_too_big_to_bring_back(self):
        with tempfile.TemporaryDirectory() as tmp:
            mp4 = Path(tmp) / "video.mp4"
            mp4.write_bytes(b"x" * (2 << 20))
            with unittest.mock.patch.object(hv.shutil, "which", return_value=None), \
                    unittest.mock.patch.object(hv, "crop_video", return_value="no frames"), \
                    self.assertRaisesRegex(hv.LookError, "over the 1 MiB a look brings back"):
                hv.fit_video(mp4, most=1 << 20)
            self.assertFalse(mp4.exists())

    def test_fit_video_shrinks_through_avfoundation_without_ffmpeg(self):
        """No display worker has ffmpeg: a video over the cap is scaled down by media/crop-video.swift instead."""
        calls = []

        def crop(mp4, box, scale, dest):
            calls.append((box, scale))
            dest.write_bytes(b"s" * (100 if scale <= 0.25 else 300))
            return None

        with tempfile.TemporaryDirectory() as tmp:
            mp4 = Path(tmp) / "video.mp4"
            mp4.write_bytes(b"x" * 1000)
            with unittest.mock.patch.object(hv.shutil, "which", return_value=None), \
                    unittest.mock.patch.object(hv, "crop_video", side_effect=crop):
                hv.fit_video(mp4, most=200)
            self.assertEqual(mp4.read_bytes(), b"s" * 100)
        self.assertEqual(calls, [((0.0, 0.0, 1.0, 1.0), 0.5), ((0.0, 0.0, 1.0, 1.0), 0.25)])

    def test_a_failed_move_is_a_look_error(self):
        kit, recorder = self.kit()
        with tempfile.TemporaryDirectory() as tmp:
            video = hv.Video(Path(tmp), kit)
            video.start(1)
            with unittest.mock.patch.object(hv, "window_frame", return_value=None), \
                    unittest.mock.patch.object(hv.os, "replace", side_effect=OSError("disk full")), \
                    self.assertRaisesRegex(hv.LookError, "did not become video.mp4"):
                video.stop()

    def test_the_kit_records_through_cua_driver_and_the_clip_becomes_video_mp4(self):
        kit, recorder = self.kit()
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            video = hv.Video(out, kit)
            self.assertEqual(video.name, "cua-driver")
            with unittest.mock.patch.object(hv.Video, "binary", side_effect=AssertionError("record-window ran")):
                self.assertEqual(video.start(123), 4242)
            self.assertTrue(video.running)
            with unittest.mock.patch.object(hv, "window_frame", return_value=None), \
                    unittest.mock.patch.object(hv, "main_display_points", return_value=(1920.0, 1080.0)):
                mp4 = video.stop()
            self.assertEqual(mp4, out / "video.mp4")
            self.assertTrue(mp4.is_file())
            self.assertFalse((out / "clips").exists())
            self.assertFalse(video.facts["window"])
            self.assertIn("display", video.facts)
            self.assertEqual(recorder.calls, [("start", hv.LOOK_CLIP), ("stop",)])

    def test_a_refused_start_is_a_look_error_naming_cua_driver(self):
        kit, recorder = self.kit()
        recorder.start = lambda out, clip: (_ for _ in ()).throw(RuntimeError("cua-driver start_recording: no"))
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(hv.LookError, "CuaDriver's recording did not start"):
                hv.Video(Path(tmp), kit).start(1)

    def test_abandon_closes_a_running_cua_recording(self):
        kit, recorder = self.kit()
        with tempfile.TemporaryDirectory() as tmp:
            video = hv.Video(Path(tmp), kit)
            video.start(1)
            video.abandon()
            self.assertFalse(video.running)
            self.assertIn(("close",), recorder.calls)

    def test_the_look_clip_name_is_one_a_steps_file_cannot_take(self):
        self.assertIsNone(hv.SHOT_NAME.fullmatch(hv.LOOK_CLIP))

    def test_without_a_kit_record_window_records(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(hv.Video(Path(tmp)).name, "record-window")

    def test_window_crop_is_in_the_videos_own_pixels(self):
        crop = hv.window_crop({"X": 480.0, "Y": 270.0, "Width": 960.0, "Height": 540.0}, (1920.0, 1080.0))
        self.assertEqual(crop, "crop=trunc(iw*0.5/2)*2:trunc(ih*0.5/2)*2:trunc(iw*0.25/2)*2:trunc(ih*0.25/2)*2")

    def test_window_crop_refuses_a_window_off_the_main_display(self):
        self.assertIsNone(hv.window_crop({"X": 2000.0, "Y": 0.0, "Width": 800.0, "Height": 600.0}, (1920.0, 1080.0)))
        self.assertIsNone(hv.window_crop({"X": -10.0, "Y": 0.0, "Width": 800.0, "Height": 600.0}, (1920.0, 1080.0)))
        self.assertIsNone(hv.window_crop(None, (1920.0, 1080.0)))
        self.assertIsNone(hv.window_crop({"X": 0.0, "Y": 0.0, "Width": 800.0, "Height": 600.0}, None))

    def fake_crop_tool(self, folder: Path, code: int = 0) -> tuple[Path, Path]:
        """A stand-in for the compiled media/crop-video.swift: it logs its argv and writes OUT (exit 0) or fails."""
        log = folder / "crop-args.json"
        tool = folder / "crop-video"
        tool.write_text("#!/usr/bin/env python3\nimport json, sys\n"
                        f"json.dump(sys.argv[1:], open({str(log)!r}, 'w'))\n"
                        + ("open(sys.argv[2], 'wb').write(b'window')\n" if code == 0 else
                           "sys.stderr.write('the export ended 4')\nsys.exit(1)\n"))
        tool.chmod(0o755)
        return tool, log

    def test_cut_to_window_without_ffmpeg_cuts_with_avfoundation(self):
        """2026-11-16: no display worker has ffmpeg, so every fleet look's video was the whole display, which showed
        other steps' system dialogs; the window is cut out by media/crop-video.swift (AVFoundation) instead."""
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            mp4 = folder / "video.mp4"
            mp4.write_bytes(b"display")
            tool, log = self.fake_crop_tool(folder)
            with unittest.mock.patch.object(hv.shutil, "which", return_value=None), \
                    unittest.mock.patch.object(hv, "swift_tool", return_value=tool) as compiled:
                why = hv.cut_to_window(mp4, {"X": 480.0, "Y": 270.0, "Width": 960.0, "Height": 540.0},
                                       (1920.0, 1080.0))
            self.assertIsNone(why)
            self.assertEqual(mp4.read_bytes(), b"window")
            compiled.assert_called_once_with(hv.HERE / "media/crop-video.swift")
            argv = json.loads(log.read_text())
            self.assertEqual(argv[0], str(mp4))
            self.assertEqual(argv[2:], ["0.250000", "0.250000", "0.500000", "0.500000", "1"])
            self.assertFalse((folder / ".video-window.mp4").exists())

    def test_cut_to_window_keeps_the_display_when_avfoundation_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            mp4 = folder / "video.mp4"
            mp4.write_bytes(b"display")
            tool, _ = self.fake_crop_tool(folder, code=1)
            with unittest.mock.patch.object(hv.shutil, "which", return_value=None), \
                    unittest.mock.patch.object(hv, "swift_tool", return_value=tool):
                why = hv.cut_to_window(mp4, {"X": 0.0, "Y": 0.0, "Width": 800.0, "Height": 600.0}, (1920.0, 1080.0))
            self.assertIn("AVFoundation could not cut the window out: the export ended 4", why)
            self.assertEqual(mp4.read_bytes(), b"display")
            self.assertFalse((folder / ".video-window.mp4").exists())

    def test_the_stopped_cua_video_is_the_window_without_ffmpeg(self):
        """The receipt says window: true when the AVFoundation cut ran (it said "no ffmpeg here" on every fleet look)."""
        kit, _ = self.kit()
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            tool, _ = self.fake_crop_tool(out)
            video = hv.Video(out, kit)
            video.start(123)
            with unittest.mock.patch.object(hv, "window_frame",
                                            return_value={"X": 0.0, "Y": 25.0, "Width": 1280.0, "Height": 800.0}), \
                    unittest.mock.patch.object(hv, "main_display_points", return_value=(1920.0, 1080.0)), \
                    unittest.mock.patch.object(hv.shutil, "which", return_value=None), \
                    unittest.mock.patch.object(hv, "swift_tool", return_value=tool):
                mp4 = video.stop()
            self.assertEqual(mp4.read_bytes(), b"window")
            self.assertEqual(video.facts, {"by": "cua-driver", "window": True})

    def test_every_swift_tool_source_is_a_literal_join_a_fleet_export_follows(self):
        """A fleet worker runs the engine from an export holding only the files its text joins to its folder as a
        literal (cmuxterm-hq build-fleet/ci-client.py hot_verify_refs: `HERE / "media/x.swift"`). A source path
        built from a name (f"media/{name}.swift") was not exported, so crop-video.swift was missing on the worker
        and the video stayed the whole display (2026-11-16, cmux19)."""
        import re
        text = ENGINE.read_text()
        calls = re.findall(r"swift_tool\(([^)]*)\)", text)
        sources = [c.split(",")[0].strip() for c in calls if not c.startswith("source")]
        self.assertGreaterEqual(len(sources), 2, calls)
        for source in sources:
            found = re.fullmatch(r'HERE / "(media/[\w.-]+\.swift)"', source)
            self.assertIsNotNone(found, f"swift_tool({source}): not a literal HERE join the export follows")
            self.assertTrue((ENGINE.parent / found.group(1)).is_file(), found.group(1))

    def test_the_looks_copy_has_a_neutral_shell(self):
        """The copy's terminals said `cmux@cmux23 ~ %`, and the privacy check withheld the new-tab shot and the video
        for the worker's name (2026-11-16): the look makes its copy with side-instance.sh --neutral-shell."""
        args = hv.side_make_args(Path("/Apps/cmux NIGHTLY.app"))
        self.assertEqual(args[:3], ["make", "--from", "/Apps/cmux NIGHTLY.app"])
        self.assertIn("--neutral-shell", args)


class LookKitErrorTest(unittest.TestCase):
    def test_a_kit_runtime_error_still_writes_a_failed_receipt(self):
        """The kit's window_shot raises a plain RuntimeError when CuaDriver is stopped or its grants are pending: the
        look ends EXIT_FAILED with a receipt naming it (the CI posts that), never an escaped error and no receipt
        (2026-11-22: 11 fleet looks on cmuxs-Mac-mini-3 and ultra2 posted nothing)."""
        class FakeSide:
            name = "look-test"

            def exists(self):
                return False

            def run(self, *args, **kwargs):
                return "look-test: pid 123" if args[0] == "launch" else ""

            def env(self):
                return {"CMUX_NEXT_CONFIG_FILE": "/nonexistent/config.json"}

            def socket(self):
                return "/tmp/look-test.sock"

            def stop(self):
                return []

        def shooter(kit):
            def shoot(pid, dest):
                raise RuntimeError("window 7; CuaDriver: daemon is not running")
            return shoot

        args = type("Args", (), {"kit": None, "state": None, "watch": False, "no_video": True, "source": "sha:x"})()
        planned = {"layers": ["web"], "head": "x"}
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "out"
            receipt = {"errors": [], "app": {}}
            with unittest.mock.patch.object(hv, "load_kit", return_value=object()), \
                    unittest.mock.patch.object(hv, "load_steps", return_value=[]), \
                    unittest.mock.patch.object(hv, "steps_engine", return_value="webkit"), \
                    unittest.mock.patch.object(hv, "Shooter", side_effect=shooter), \
                    unittest.mock.patch.object(hv, "rules_for", return_value=None), \
                    unittest.mock.patch.object(hv, "resolve_tree", return_value=None), \
                    unittest.mock.patch.object(hv, "set_browser_engine"), \
                    unittest.mock.patch.object(hv, "set_theme"), \
                    unittest.mock.patch.object(hv, "control_socket", return_value="/tmp/look-test.sock"), \
                    unittest.mock.patch.object(hv.time, "sleep"):
                code = hv.look(args, None, planned, FakeSide(), Path(tmp) / "app", out, receipt,
                               hv.hot().Phases(), 0.0)
            self.assertEqual(code, hv.EXIT_FAILED)
            written = json.loads((out / "receipt.json").read_text())
        self.assertIn("RuntimeError: window 7; CuaDriver: daemon is not running", written["errors"])



class LaunchBound(unittest.TestCase):
    """side-instance.sh launch waits for the Mac's memory budget before it opens the copy (Air Blue,
    2026-11-23): its bound covers that wait, so the launcher's own "budget stayed full" error reaches the
    person instead of a bare TimeoutExpired."""

    def test_the_launch_bound_covers_the_budget_wait(self):
        self.assertEqual(hv.launch_seconds({}), 1800 + hv.LAUNCH_SECONDS)
        self.assertEqual(hv.launch_seconds({"SIDE_INSTANCE_BUDGET_WAIT_S": "60"}), 60 + hv.LAUNCH_SECONDS)
        self.assertEqual(hv.launch_seconds({"SIDE_INSTANCE_BUDGET_WAIT_S": "0"}), hv.LAUNCH_SECONDS)
        self.assertEqual(hv.launch_seconds({"SIDE_INSTANCE_BUDGET_WAIT_S": "soon"}), 1800 + hv.LAUNCH_SECONDS)

    def test_every_launch_uses_the_budget_aware_bound(self):
        launches = re.findall(r'side\.run\("launch".*\)', ENGINE.read_text())
        self.assertGreaterEqual(len(launches), 2)
        for call in launches:
            self.assertIn("timeout=launch_seconds()", call)


if __name__ == "__main__":
    unittest.main()
