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

    def test_run_on_swift_exits_3_with_its_plan_and_makes_no_copy(self):
        """`cmux app try .` reads the last stdout line: a change that needs a build says why, and no copy is made."""
        head = self.fx.change({"Packages/macOS/CmuxNext/Sources/CmuxNextApp/App.swift": "struct App { let x = 2 }\n"})
        app = self.fake_app(self.fx.base)
        made = []
        with unittest.mock.patch.object(hv.Side, "run", lambda side, *a, **k: made.append(a) or ""):
            code, text = self.cli("run", "--source", f"sha:{head}", "--app", str(app), "--repo", str(self.fx.repo),
                                  "--side", "try-test")
        self.assertEqual(code, 3)
        result = json.loads(text.strip().splitlines()[-1])
        self.assertTrue(result["plan"]["needs_build"])
        self.assertTrue(any(why.startswith("Swift") for why in result["plan"]["build"]), result["plan"]["build"])
        self.assertEqual((result["side"], result["copy"]), ("try-test", None))
        self.assertEqual(made, [])

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

    def apply(self, planned: dict, src_tree: Path | None = None, binary: Path | None = None) -> dict:
        def run(argv, **kw):
            self.calls.append([str(a) for a in argv])
            return subprocess.CompletedProcess(argv, 0, stdout='{"phases": {}}\n', stderr="")
        with unittest.mock.patch.object(hv.subprocess, "run", run), \
                unittest.mock.patch.object(hv.shutil, "which", lambda name: "/usr/bin/" + name):
            return hv.apply_rust(self.root, planned, src_tree, self.StubSide(self.root), self.root, binary)

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

    def test_a_pointer_for_another_head_is_not_used(self):
        planned = {"head": "1" * 40, "pr": 45917}
        with unittest.mock.patch.object(hv, "fetch_json", side_effect=self.pointer), \
                unittest.mock.patch.object(hv.hot(), "web_key", return_value="f" * 64):
            self.assertIsNone(hv.published_web_key(Path("/nonexistent"), planned))


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


if __name__ == "__main__":
    unittest.main()
