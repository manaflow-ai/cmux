#!/usr/bin/env python3
"""The fleet compile check compiles the test targets a change can break.

fleet/compile-check compiled only the app executable. On 2026-10-21 two pull
requests passed it and then broke feat-cmux-next's test build: #23360 put a
throwing call inside `#expect` without `try` in PaletteMenuVocabularyTests
(CmuxNextActionsTests), and #23163 added a FakeClient to CmuxNextAppTests that
missed a requirement #21258 had added. Every Mac job that builds tests was
still queued when they merged.

scripts/ci/compile_test_plan.py picks what the check compiles from the
changed files: the CmuxNext test targets that depend on a changed target (the
SwiftPM target graph cmux_next_route.py already reads), and the macOS-tested
local packages whose sources or path dependencies changed. package-test-lane.sh
`compile-tests MERGE_BASE` builds that plan on a fleet Mac, as the advisory
fleet-test-compile.yml check; fleet/compile-check stays the app compile.
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "compile_test_plan.py"
LANE = ROOT / "scripts" / "ci" / "package-test-lane.sh"
CMUXNEXT = "Packages/macOS/CmuxNext"

# #23360's diff against its base (ef40118cea25..4f867f5e57c2).
PR_23360 = [
    "Packages/macOS/CmuxNext/Sources/CmuxNextActions/ActionCatalog.xcstrings",
    "Packages/macOS/CmuxNext/Sources/CmuxNextActions/AppStoreActions.xcstrings",
    "Packages/macOS/CmuxNext/Sources/CmuxNextActions/Catalog/AppStoreActionCatalog.swift",
    "Packages/macOS/CmuxNext/Sources/CmuxNextActions/Catalog/BrowserActionCatalog.swift",
    "Packages/macOS/CmuxNext/Sources/CmuxNextActions/Catalog/CloudActionCatalog.swift",
    "Packages/macOS/CmuxNext/Sources/CmuxNextActions/Catalog/HistoryActionCatalog.swift",
    "Packages/macOS/CmuxNext/Sources/CmuxNextActions/Catalog/RemoteActionCatalog.swift",
    "Packages/macOS/CmuxNext/Sources/CmuxNextActions/Catalog/WorkspaceActionCatalog.swift",
    "Packages/macOS/CmuxNext/Sources/CmuxNextActions/HistoryActions.xcstrings",
    "Packages/macOS/CmuxNext/Sources/CmuxNextActions/RemoteActions.xcstrings",
    "Packages/macOS/CmuxNext/Tests/CmuxNextActionsTests/PaletteMenuVocabularyTests.swift",
    "plans/cmux-next/palette-audit.md",
]


def load():
    spec = importlib.util.spec_from_file_location("compile_test_plan", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules["compile_test_plan"] = module
    spec.loader.exec_module(module)
    return module


class CompileTestPlanTests(unittest.TestCase):
    def setUp(self) -> None:
        self.module = load()

    def plan(self, changed: list[str]) -> dict[str, list[str] | None]:
        return dict(self.module.plan(ROOT, changed))

    def test_pr_23360_compiles_the_test_target_it_broke(self) -> None:
        plan = self.plan(PR_23360)
        self.assertIn(CMUXNEXT, plan)
        targets = plan[CMUXNEXT]
        self.assertIsNotNone(targets, "a CmuxNextActions change is not every test target")
        self.assertIn("CmuxNextActionsTests", targets)
        # Test targets that depend on CmuxNextActions are reverse dependents: they compile too.
        self.assertIn("CmuxNextAppTests", targets)
        # One that does not reach CmuxNextActions stays out.
        graph = self.module.load_graph(ROOT)
        unrelated = [
            name for name, target in graph["targets"].items()
            if target["kind"] == "test" and "CmuxNextActions" not in self.module.closure(graph, {name})
            # A test that reads the changed files (CmuxNextDesignTests scans every Swift source for SF Symbol
            # names, #39966) is selected by them without depending on the module.
            and not any(self.module.matches(path, read) for read in target.get("reads", []) for path in PR_23360)
        ]
        self.assertTrue(unrelated, "every test target depends on CmuxNextActions; pick another fixture")
        self.assertFalse(set(unrelated) & set(targets), unrelated)
        self.assertEqual(targets, sorted(targets))

    def test_a_new_test_file_compiles_its_own_target(self) -> None:
        # #23163: the FakeClient in a new CmuxNextAppTests file.
        plan = self.plan([f"{CMUXNEXT}/Tests/CmuxNextAppTests/RemoteChildSessionsTests.swift"])
        self.assertEqual(plan, {CMUXNEXT: ["CmuxNextAppTests"]})

    def test_manifest_change_compiles_every_test_target(self) -> None:
        self.assertEqual(self.plan([f"{CMUXNEXT}/Package.swift"]), {CMUXNEXT: None})

    def test_local_package_change_compiles_it_and_its_dependents(self) -> None:
        plan = self.plan(["Packages/Shared/CMUXAuthCore/Sources/CMUXAuthCore/AuthTokens.swift"])
        # CmuxHomeRender, in the macOS package lane, uses CMUXAuthCore; so does CmuxNext. CMUXAuthCore and
        # CmuxAuthRuntime run on Linux (scripts/ci/swift-linux-packages.txt), so no macOS build compiles them here.
        self.assertIsNone(plan.get("Packages/Shared/CmuxHomeRender", "missing"))
        self.assertNotIn("Packages/Shared/CMUXAuthCore", plan)
        self.assertNotIn("Packages/Shared/CmuxAuthRuntime", plan)
        self.assertIn(CMUXNEXT, plan)
        self.assertTrue(plan[CMUXNEXT], "the CmuxNext test targets that use CMUXAuthCore")

    def test_packages_outside_the_macos_lanes_are_not_compiled(self) -> None:
        # A package outside the lane's PACKAGES builds in its own jobs, not with a macOS `swift build`.
        # (CmuxMobileSSH runs on Linux: scripts/ci/swift-linux-packages.txt.)
        plan = self.plan(["Packages/iOS/CmuxMobileSSH/Sources/CmuxMobileSSH/SSHStores.swift"])
        self.assertNotIn("Packages/iOS/CmuxMobileSSH", plan)

    def test_changes_that_compile_no_test_are_an_empty_plan(self) -> None:
        self.assertEqual(self.plan(["docs/ci/merge-freeze.md", "web/app/page.tsx", "README.md"]), {})
        self.assertEqual(self.plan([f"{CMUXNEXT}/README.md"]), {})
        # CI and app-host changes compile no package test: the advisory check queues no Mac.
        self.assertEqual(self.plan(["scripts/ci/cmux_next_route.py", "scripts/cmux-next/prepush-gate.py",
                                    "App/CmuxNextApp.swift", "webviews/src/app.tsx"]), {})

    def test_skip_package_leaves_cmuxnext_out_and_keeps_the_lane_packages(self) -> None:
        # The pull-request check skips CmuxNext: cmux-next.yml's swift test job builds its test targets.
        skip = frozenset({CMUXNEXT})
        self.assertEqual(dict(self.module.plan(ROOT, PR_23360, skip)), {})
        plan = dict(self.module.plan(ROOT, ["Packages/Shared/CMUXAuthCore/Sources/CMUXAuthCore/AuthTokens.swift"], skip))
        self.assertNotIn(CMUXNEXT, plan)
        self.assertIn("Packages/Shared/CmuxHomeRender", plan)
        # Without the skip (the tip compile, a hand-run compile-tests) CmuxNext stays.
        self.assertIn(CMUXNEXT, self.plan(PR_23360))

    def run_cli(self, changed_paths: list[str], *extra: str) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as scratch:
            changed = Path(scratch) / "changed.txt"
            changed.write_text("\n".join(changed_paths) + "\n", encoding="utf-8")
            return subprocess.run(
                [sys.executable, str(SCRIPT), "--root", str(ROOT), "--changed-files", str(changed), *extra],
                capture_output=True, text=True,
            )

    def test_cli_skip_package(self) -> None:
        done = self.run_cli(PR_23360, "--skip-package", CMUXNEXT)
        self.assertEqual((done.returncode, done.stdout), (0, ""), done.stderr)
        # A directory that is no local package is refused, so a typo never silently plans everything.
        done = self.run_cli(PR_23360, "--skip-package", "Packages/macOS/NoSuchPackage")
        self.assertEqual(done.returncode, 2, done.stdout + done.stderr)
        self.assertIn("not a local package directory", done.stderr)

    def test_cli_prints_one_line_per_package(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            changed = Path(scratch) / "changed.txt"
            changed.write_text("\n".join(PR_23360) + "\n", encoding="utf-8")
            done = subprocess.run(
                [sys.executable, str(SCRIPT), "--root", str(ROOT), "--changed-files", str(changed)],
                capture_output=True, text=True, check=True,
            )
        lines = done.stdout.splitlines()
        self.assertEqual(len(lines), 1, done.stdout)
        words = lines[0].split()
        self.assertEqual(words[0], CMUXNEXT)
        self.assertIn("CmuxNextActionsTests", words[1:])


class CompileTestsPhaseArgsTests(unittest.TestCase):
    """package-test-lane.sh compile-tests refuses a bad merge base before it builds anything."""

    def run_lane(self, *args: str) -> subprocess.CompletedProcess:
        env = {key: value for key, value in os.environ.items() if not key.startswith("GITHUB_")}
        return subprocess.run(["bash", str(LANE), "compile-tests", *args], cwd=ROOT, env=env,
                              capture_output=True, text=True, timeout=60)

    def test_needs_one_full_merge_base_sha(self) -> None:
        for args in ((), ("abc123",), ("A" * 40,), ("0" * 40, "extra"), ("0" * 40, "--skip-package="),
                     ("0" * 40, "--skip-package", CMUXNEXT)):
            done = self.run_lane(*args)
            self.assertEqual(done.returncode, 2, (args, done.stdout, done.stderr))
            self.assertIn("compile-tests MERGE_BASE_SHA", done.stderr)


MARKER = "compile-tests: a test target did not compile"

FAKE_SWIFT = r"""#!/usr/bin/env bash
echo "swift $*" >> "$FAKE_SEEN"
[ "$1" = build ] || exit 0
target=""
prev=""
for a in "$@"; do
  [ "$prev" = --target ] && target="$a"
  prev="$a"
done
case " $FAKE_BAD " in *" $target "*)
  [ -n "$target" ] && { echo "Tests/$target/T.swift:74:106: error: call can throw, but it is not marked with 'try'"; exit 1; } ;;
esac
case " $FAKE_REFUSED " in *" $target "*)
  [ -n "$target" ] && { echo "error: no target named '$target'"; exit 1; } ;;
esac
echo "Build complete!"
"""

FAKE_XCRUN = r"""#!/usr/bin/env bash
for a in "$@"; do
  [ "$a" = --show-sdk-path ] && { echo "$DEVELOPER_DIR/SDKs/MacOSX.sdk"; exit 0; }
done
exit 1
"""

# The plan comes from FAKE_PLAN (";" between packages), and one package's
# submodule setup fails when it is FAKE_BROKEN_SETUP.
FAKE_PLAN = r"""import os, sys
with open(os.environ["FAKE_SEEN"], "a") as seen:
    seen.write("plan " + " ".join(sys.argv[1:]) + "\n")
for line in os.environ.get("FAKE_PLAN", "").split(";"):
    if line.strip():
        print(line.strip())
"""

FAKE_SUBMODULES = r"""import os, sys
if sys.argv[2] == os.environ.get("FAKE_BROKEN_SETUP"):
    print("vendor/not-a-submodule")
"""


class CompileTestsPhaseTests(unittest.TestCase):
    """package-test-lane.sh compile-tests with a fake `swift`: what reaches red."""

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(subprocess.run, ["rm", "-rf", str(self.tmp)])
        repo = self.repo = self.tmp / "repo"
        bin_dir = self.bin = self.tmp / "bin"
        (repo / "scripts" / "ci").mkdir(parents=True)
        (repo / "scripts" / "cmux-next").mkdir(parents=True)
        (repo / "vendor" / "not-a-submodule").mkdir(parents=True)
        bin_dir.mkdir()
        for name in ("package-test-lane.sh", "swift-test-debug-info.sh", "swiftpm-binary-module-guard.sh"):
            (repo / "scripts" / "ci" / name).write_bytes((ROOT / "scripts" / "ci" / name).read_bytes())
        stale = ROOT / "scripts" / "cmux-next" / "stale-pcm-retry-needed.sh"
        (repo / "scripts" / "cmux-next" / stale.name).write_bytes(stale.read_bytes())
        (repo / "scripts" / "ci" / "compile_test_plan.py").write_text(FAKE_PLAN)
        (repo / "scripts" / "ci" / "swift_package_submodules.py").write_text(FAKE_SUBMODULES)
        for package in ("Alpha", "Beta"):
            pkg = repo / "Packages" / "macOS" / package
            pkg.mkdir(parents=True)
            (pkg / "Package.swift").write_text(
                f'// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: "{package}")\n')
        for name, text in (("swift", FAKE_SWIFT), ("xcrun", FAKE_XCRUN)):
            (bin_dir / name).write_text(text)
            (bin_dir / name).chmod(0o755)
        (bin_dir / "python3").symlink_to(sys.executable)
        self.dev = self.tmp / "Xcode.app" / "Contents" / "Developer"
        (self.dev / "SDKs" / "MacOSX.sdk").mkdir(parents=True)
        git = ["git", "-c", "user.email=t@t", "-c", "user.name=t", "-C", str(repo)]
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        subprocess.run([*git, "add", "-A"], check=True)
        subprocess.run([*git, "commit", "-qm", "base"], check=True)
        self.base = subprocess.run([*git, "rev-parse", "HEAD"], capture_output=True, text=True,
                                   check=True).stdout.strip()
        (repo / "Packages" / "macOS" / "Alpha" / "A.swift").write_text("let a = 1\n")
        subprocess.run([*git, "add", "-A"], check=True)
        subprocess.run([*git, "commit", "-qm", "change"], check=True)
        self.seen = self.tmp / "seen"

    def lane(self, plan: str, bad: str = "", refused: str = "", broken: str = "",
             extra: tuple[str, ...] = ()) -> subprocess.CompletedProcess:
        self.seen.write_text("")
        env = {key: value for key, value in os.environ.items() if not key.startswith("GITHUB_")}
        env.update(PATH=f"{self.bin}:{env['PATH']}", DEVELOPER_DIR=str(self.dev), RUNNER_TEMP=str(self.tmp),
                   FAKE_SEEN=str(self.seen), FAKE_PLAN=plan, FAKE_BAD=bad, FAKE_REFUSED=refused,
                   FAKE_BROKEN_SETUP=broken)
        return subprocess.run(["bash", "scripts/ci/package-test-lane.sh", "compile-tests", self.base, *extra],
                              cwd=self.repo, env=env, capture_output=True, text=True, timeout=120)

    def builds(self) -> list[str]:
        return [line for line in self.seen.read_text().splitlines() if line.startswith("swift build")]

    def test_every_target_compiles(self) -> None:
        done = self.lane("Packages/macOS/Alpha AlphaTests OtherTests;Packages/macOS/Beta")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("every planned test target compiled (3)", done.stdout)
        self.assertNotIn(MARKER, done.stdout)
        self.assertEqual(len(self.builds()), 3, self.builds())
        self.assertTrue(any("--build-tests" in b and "Beta" in b for b in self.builds()))

    def plan_calls(self) -> list[str]:
        return [line for line in self.seen.read_text().splitlines() if line.startswith("plan ")]

    def test_skip_package_reaches_the_plan(self) -> None:
        done = self.lane("Packages/macOS/Beta", extra=("--skip-package=Packages/macOS/CmuxNext",))
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        [call] = self.plan_calls()
        self.assertIn("--skip-package Packages/macOS/CmuxNext", call)
        # Without it the plan is asked for everything.
        self.lane("Packages/macOS/Beta")
        [call] = self.plan_calls()
        self.assertNotIn("--skip-package", call)

    def test_an_empty_plan_builds_nothing(self) -> None:
        done = self.lane("")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("nothing to compile", done.stdout)
        self.assertEqual(self.builds(), [])

    def test_a_target_that_does_not_compile_is_red(self) -> None:
        done = self.lane("Packages/macOS/Alpha AlphaTests BadTests;Packages/macOS/Beta", bad="BadTests")
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        self.assertIn(MARKER, done.stdout)
        self.assertIn("::error title=Test target did not compile::Packages/macOS/Alpha: BadTests", done.stdout)
        # A failing target does not stop the ones after it.
        self.assertTrue(any("Beta" in b for b in self.builds()), self.builds())

    def test_a_later_setup_failure_keeps_an_earlier_target_failure_red(self) -> None:
        # Beta's submodule setup fails after Alpha's BadTests did not compile:
        # the run ends early, but the failure marker must already be out.
        done = self.lane("Packages/macOS/Alpha BadTests;Packages/macOS/Beta", bad="BadTests",
                         broken="Packages/macOS/Beta")
        self.assertNotEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn(MARKER, done.stdout, done.stdout + done.stderr)

    def test_a_setup_failure_alone_is_no_verdict(self) -> None:
        done = self.lane("Packages/macOS/Alpha AlphaTests;Packages/macOS/Beta", broken="Packages/macOS/Beta")
        self.assertNotEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertNotIn(MARKER, done.stdout)

    def test_a_refused_target_falls_back_to_build_tests_once_per_package(self) -> None:
        done = self.lane("Packages/macOS/Alpha OneTests TwoTests ThreeTests", refused="OneTests TwoTests ThreeTests")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        whole = [b for b in self.builds() if "--build-tests" in b]
        self.assertEqual(len(whole), 1, self.builds())
        self.assertEqual(len([b for b in self.builds() if "--target" in b]), 1, self.builds())


WORKFLOW = ROOT / ".github" / "workflows" / "fleet-test-compile.yml"
STEP = "Compile the planned test targets through the gateway client"
READ_STEP = "Read the Linux pool's test-target compile"


def step_script(name: str = STEP) -> str:
    lines = WORKFLOW.read_text().splitlines()
    start = next(i for i, line in enumerate(lines) if line.strip() == f"- name: {name}")
    run = next(i for i in range(start, len(lines)) if lines[i].strip() == "run: |")
    indent = len(lines[run]) - len(lines[run].lstrip()) + 2
    body = []
    for line in lines[run + 1:]:
        if line.strip() and len(line) - len(line.lstrip()) < indent:
            break
        body.append(line[indent:])
    return "\n".join(body) + "\n"


class PullRequestCompilesCmuxNextTests(unittest.TestCase):
    """The pull-request check compiles CmuxNext's test targets again: cmux-next.yml's swift test job
    runs on a feat-cmux-next pull request never, with or without full-ci (#57353), so nothing else builds them on a PR."""

    def test_the_workflow_skips_no_package_in_either_plan(self) -> None:
        text = WORKFLOW.read_text()
        self.assertNotIn("SKIP:", text)
        self.assertIn('compile_test_plan.py --changed-files "$RUNNER_TEMP/changed.txt" > ', text)
        # The step compiles the plan's packages as they are: it skips none either.
        self.assertNotIn("--skip-package", step_script())

    def test_swift_test_never_runs_on_a_cmux_next_pull_request(self) -> None:
        # If swift test ran on a feat-cmux-next PR again, this check would compile CmuxNext twice.
        text = (ROOT / ".github" / "workflows" / "cmux-next.yml").read_text()
        job = re.split(r"\n  [A-Za-z0-9_-]+:[^\n]*\n", text.split("\n  swift-test:\n", 1)[1], maxsplit=1)[0]
        condition = re.search(r"^    if: (.*)$", job, re.M).group(1)
        self.assertNotIn("github.event.pull_request.head.repo.full_name == github.repository", condition)
        # #49046: a pull request into another base is not a cmux-next PR. #57353: one into feat-cmux-next
        # runs swift test after merge only, with or without full-ci (0 real catches in 30 days).
        self.assertIn("&& (github.event_name != 'pull_request' || !startsWith(github.event.pull_request.base.ref, 'feat-cmux-next'))",
                      condition)
        self.assertNotIn("'full-ci')", condition.replace("fromJSON('[\"full-ci\",\"ready-to-land\"]')", ""))

    def test_the_tip_compile_keeps_cmuxnext(self) -> None:
        tip = (ROOT / ".github" / "workflows" / "cmux-next-tip-test-compile.yml").read_text()
        self.assertNotIn("--skip-package", tip)
        self.assertNotIn("--skip-package", (ROOT / "scripts" / "ci" / "tip-test-compile.sh").read_text())


class PullRequestRunsOnlyWithFullCiTests(unittest.TestCase):
    """2026-11-21: the advisory check runs on a pull request only with full-ci; the tip compile catches the rest
    after the merge. Its gateway job held a Mac runner while it waited on the Linux pool."""

    def test_the_plan_needs_full_ci(self) -> None:
        plan = WORKFLOW.read_text().split("\n  plan:\n", 1)[1].split("\n  compile:\n", 1)[0]
        condition = re.search(r"^    if: (.*)$", plan, re.M).group(1)
        self.assertIn("(contains(github.event.pull_request.labels.*.name, 'full-ci') && (github.event.pull_request.base.ref != 'feat-cmux-next' || (github.event.action == 'labeled' && github.event.label.name == 'full-ci') || (vars.CI_FULL_CI_ONE_SHOT || '1') == '0'))", condition)
        # The compile job needs the plan, so a skipped plan skips it: no gateway runner is taken.
        job = WORKFLOW.read_text().split("\n  compile:\n", 1)[1]
        self.assertRegex(job, r"(?m)^    needs: plan$")
        self.assertNotIn("always()", job)

    def test_the_tip_compile_still_runs_after_every_merge(self) -> None:
        # 2026-11-21: in the post-merge batch (suite tip-test-compile), not on each push.
        tip = (ROOT / ".github" / "workflows" / "cmux-next-tip-test-compile.yml").read_text()
        self.assertIn("workflow_call:", tip)
        self.assertNotIn("full-ci", tip)
        suite = json.loads((ROOT / ".github" / "post-merge-batch.json").read_text())["suites"]["tip-test-compile"]
        self.assertEqual(suite["workflow"], "cmux-next-tip-test-compile.yml")
        self.assertIn("Packages/**", suite["paths"])


def job(name: str) -> str:
    text = WORKFLOW.read_text().split(f"\n  {name}:\n", 1)[1]
    return re.split(r"\n  [a-z][a-z-]*:\n", text, maxsplit=1)[0]


class ControllerReadTests(unittest.TestCase):
    """fleet-test-compile.yml's compile job runs on a Linux runner and reads the controller's test-target compile
    (fleet_compile_result.py --phase test-compile, the base's copy): pass is green, fail red, anything else a
    warning and a verdict of none that lets the gateway fallback run (2026-11-25)."""

    def read(self, word: str, needed: str = "true", packages: str = "CmuxNext CmuxUpdater",
             reader: bool = True, phase_aware: bool = True) -> tuple[subprocess.CompletedProcess, list[str], str]:
        with tempfile.TemporaryDirectory() as scratch:
            work = Path(scratch)
            argv = work / "argv"
            out = work / "out"
            if reader:
                (work / "scripts" / "ci").mkdir(parents=True)
                marker = '"test-compile"' if phase_aware else '"app-debug"'
                (work / "scripts" / "ci" / "fleet_compile_result.py").write_text(
                    f"# {marker}\nimport sys\nopen({str(argv)!r}, 'w').write('\\n'.join(sys.argv[1:]))\n"
                    f"print('fleet compile result for {'a' * 40}: {word} (because)', file=sys.stderr)\n"
                    f"print({word!r})\n")
            env = {key: value for key, value in os.environ.items() if not key.startswith("GITHUB_")}
            env.update(NEEDED=needed, REF="a" * 40, PR="12", PACKAGES=packages, RUNNER_TEMP=scratch,
                       GITHUB_OUTPUT=str(out), GITHUB_REPOSITORY="manaflow-ai/cmux")
            done = subprocess.run(["bash", "-c", step_script(READ_STEP)], cwd=work, env=env, capture_output=True,
                                  text=True, timeout=60)
            return (done, argv.read_text().splitlines() if argv.exists() else [],
                    out.read_text() if out.exists() else "")

    def test_pass_is_green_and_names_the_package_set(self) -> None:
        done, argv, out = self.read("pass")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertNotIn("::", done.stdout)
        self.assertEqual(out, "verdict=pass\n")
        self.assertEqual(argv[argv.index("--phase") + 1], "test-compile")
        self.assertEqual(argv[argv.index("--packages") + 1], "CmuxNext,CmuxUpdater")
        self.assertEqual(argv[argv.index("--pr") + 1], "12")
        self.assertEqual(argv[argv.index("--sha") + 1], "a" * 40)

    def test_fail_is_red_with_its_reason(self) -> None:
        done, _, out = self.read("fail")
        self.assertEqual(done.returncode, 1, done.stdout)
        self.assertIn("::error", done.stdout)
        self.assertIn("because", done.stdout)
        self.assertEqual(out, "verdict=fail\n")

    def test_no_verdict_warns_and_hands_to_the_fallback(self) -> None:
        for kw in ({"word": "none"}, {"word": "pending"}, {"word": "pass", "reader": False},
                   {"word": "pass", "phase_aware": False}, {"word": "pass", "packages": ""},
                   {"word": "pass", "packages": "../x"}):
            with self.subTest(**kw):
                done, _, out = self.read(**kw)
                self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
                self.assertIn("::warning", done.stdout)
                self.assertNotIn("::error", done.stdout)
                self.assertEqual(out, "verdict=none\n")

    def test_no_plan_reads_nothing(self) -> None:
        done, argv, out = self.read("fail", needed="false")
        self.assertEqual(done.returncode, 0)
        self.assertEqual(argv, [])
        self.assertEqual(out, "verdict=skip\n")

    def test_it_runs_on_linux_with_the_base_reader(self) -> None:
        compile_job = job("compile")
        runs_on = re.search(r"^    runs-on: (.*)$", compile_job, re.M).group(1)
        self.assertNotIn("GATEWAY", runs_on)
        self.assertNotIn("vars.CI_TEST_COMPILE_GATEWAY", compile_job)
        self.assertIn("'cmux-linux'", runs_on)
        self.assertIn("ref: ${{ github.event.pull_request.base.sha || github.sha }}", compile_job)
        self.assertIn("REF: ${{ github.event.pull_request.head.sha || github.sha }}", compile_job)
        minutes = int(re.search(r"^    timeout-minutes: (\d+)$", compile_job, re.M).group(1))
        wait = int(re.search(r"--wait (\d+)", compile_job).group(1))
        self.assertGreaterEqual(minutes * 60, wait + 600, (minutes, wait))


class AdvisoryVerdictTests(unittest.TestCase):
    """fleet-test-compile.yml's gateway fallback: red only for a test target that does not compile (the pool's
    exit 1); anything else is no verdict. It compiles on the Linux pool, never as a Mac step (2026-11-15: 5 to 9
    Mac compile-tests steps at once held the owned minis' side-std listeners offline on CPU load)."""

    def verdict(self, status: int, output: str = "", needed: str = "true", client: bool = True,
                packages: str = "CmuxNext CmuxUpdater") -> tuple[subprocess.CompletedProcess, list[str]]:
        with tempfile.TemporaryDirectory() as scratch:
            fake = Path(scratch) / "cmux-ci"
            argv = Path(scratch) / "argv"
            if client:
                fake.write_text(f"#!/usr/bin/env bash\nprintf '%s\\n' \"$@\" > {argv}\n"
                                f"cat <<'OUT'\n{output}\nOUT\nexit {status}\n")
                fake.chmod(0o755)
            env = {key: value for key, value in os.environ.items() if not key.startswith("GITHUB_")}
            env.update(NEEDED=needed, REF="a" * 40, PACKAGES=packages, RUNNER_TEMP=scratch, RUNNER_NAME="gateway",
                       CMUX_CI_CLIENT=str(fake))
            done = subprocess.run(["bash", "-c", step_script()], env=env, capture_output=True, text=True, timeout=60)
            return done, (argv.read_text().splitlines() if argv.exists() else [])

    def assert_green(self, done, warned: bool) -> None:
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertNotIn("::error", done.stdout)
        self.assertEqual("::warning" in done.stdout, warned, done.stdout)

    def test_it_compiles_each_planned_package_on_the_pool(self) -> None:
        done, argv = self.verdict(0, "compile check CmuxNext: passed (490 s)")
        self.assert_green(done, warned=False)
        self.assertEqual(argv[:3], ["compile-check", "--ref", "a" * 40])
        self.assertEqual([argv[i + 1] for i, word in enumerate(argv) if word == "--package"], ["CmuxNext", "CmuxUpdater"])
        self.assertNotIn("run", argv)
        self.assertNotIn("package-test-lane.sh", WORKFLOW.read_text().split("\n  compile:\n", 1)[1])

    def test_exit_codes_map_to_red_warning_or_green(self) -> None:
        red, _ = self.verdict(1, "compile check CmuxNext: failed (120 s)")
        self.assertEqual(red.returncode, 1, red.stdout)
        self.assertIn("::error", red.stdout)
        # No pool VM (69), a queue or setup failure (75), a timeout (124) or the client itself: a warning, never red.
        for status in (2, 69, 75, 124, 137):
            with self.subTest(status=status):
                self.assert_green(self.verdict(status, "compile check CmuxNext: no verdict")[0], warned=True)

    def test_no_client_is_green(self) -> None:
        self.assert_green(self.verdict(0, client=False)[0], warned=True)

    def test_a_package_name_that_is_not_a_directory_name_is_no_verdict(self) -> None:
        for packages in ("", "../x", "Alpha;rm"):
            with self.subTest(packages=packages):
                done, argv = self.verdict(1, packages=packages)
                self.assert_green(done, warned=True)
                self.assertEqual(argv, [])

    def test_the_plan_output_names_package_directories(self) -> None:
        plan = WORKFLOW.read_text().split("\n  plan:\n", 1)[1].split("\n  compile:\n", 1)[0]
        self.assertIn("packages: ${{ steps.plan.outputs.packages }}", plan)
        line = next(l.strip() for l in plan.splitlines() if l.strip().startswith('echo "packages='))
        with tempfile.TemporaryDirectory() as scratch:
            (Path(scratch) / "plan.txt").write_text(
                "Packages/macOS/CmuxNext CmuxNextActionsTests\nPackages/Shared/CmuxUpdater\n\n")
            out = Path(scratch) / "out"
            subprocess.run(["bash", "-c", line], env={**os.environ, "RUNNER_TEMP": scratch, "GITHUB_OUTPUT": str(out)},
                           check=True, timeout=30)
            self.assertEqual(out.read_text(), "packages=CmuxNext CmuxUpdater\n")

    def test_advisory_fallback_keeps_its_separate_enable_switch(self) -> None:
        # #54437 froze gateway labels (#61222: they read the unified mac-gateway label). The advisory fallback now shares that runner,
        # but only its own enable switch can queue it after a missing Linux verdict.
        text = WORKFLOW.read_text()
        self.assertNotIn("CI_COMPILE_CHECK_GATEWAY", text.split("\njobs:\n", 1)[1])
        fallback = job("mac-fallback")
        runs_on = re.search(r"^    runs-on: (.*)$", fallback, re.M).group(1)
        condition = re.search(r"^    if: (.*)$", fallback, re.M).group(1)
        self.assertEqual(
            runs_on.split(" #", 1)[0],
            "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'mac-gateway' }}",
        )
        self.assertIn("needs.compile.outputs.verdict == 'none'", condition)
        self.assertIn("vars.CI_TEST_COMPILE_GATEWAY != ''", condition)
        self.assertIn("::warning title=mac fallback::", fallback)

    def test_the_job_outlasts_the_client_so_a_slow_fleet_never_reads_red(self) -> None:
        # A GitHub job timeout concludes as a failure: the client's queue and run
        # timeouts must end first, with room for the client to report.
        fallback = job("mac-fallback")
        minutes = int(re.search(r"^    timeout-minutes: (\d+)$", fallback, re.M).group(1))
        queue = int(re.search(r"--queue-timeout (\d+)", fallback).group(1))
        run = int(re.search(r"--timeout (\d+)", fallback).group(1))
        self.assertGreaterEqual(minutes * 60, queue + run + 300, (minutes, queue, run))


if __name__ == "__main__":
    unittest.main()
