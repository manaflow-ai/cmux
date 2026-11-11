#!/usr/bin/env python3
"""gallery-health.yml renders a pull request merged with its base, as the other PR gates do.

It checked out pull_request.head.sha, so a branch cut before a base fix kept failing on what base
had already fixed (transcript-density: "Module not found health.ts" after #23333). The merge ref
(GitHub's refs/pull/N/merge, the default checkout of a pull_request event) is what lands.
"""

from __future__ import annotations

import importlib.util
import os
import re
import subprocess
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
WORKFLOW = ROOT / ".github" / "workflows" / "gallery-health.yml"


def steps() -> list[dict]:
    workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    return workflow["jobs"]["health"]["steps"]


def step(name: str) -> dict:
    found = [entry for entry in steps() if entry.get("name") == name]
    if not found:
        raise AssertionError(f"gallery-health.yml has no step named {name!r}")
    return found[0]


class GalleryHealthMergeRef(unittest.TestCase):
    def test_a_pull_request_renders_its_merge_with_base(self) -> None:
        checkout = step("Checkout")
        ref = str((checkout.get("with") or {}).get("ref", ""))
        self.assertNotIn("pull_request.head.sha", ref, "check out the merge ref, not the pull request head")

    def test_the_merge_ref_is_confirmed_on_the_pull_request_head(self) -> None:
        resolve = step("Resolve the head and the merge")
        self.assertIn("github.event.pull_request.head.sha", str(resolve.get("env")))
        self.assertIn("HEAD^2", resolve["run"])

    def test_the_touched_entries_are_the_pull_requests_own_change(self) -> None:
        # The merge's first parent is the base it was merged with: diffing against it is the pull
        # request's change, never base commits the branch has not merged yet.
        run = step("Choose the entries to render")["run"]
        self.assertIn('git diff --name-only HEAD^1 HEAD', run)
        self.assertNotIn("git merge-base", run)

    def test_the_upload_carries_only_the_screenshots_a_reader_needs(self) -> None:
        # cmuxterm-hq#9131: the upload carried a screenshot of every passing state, ~190 MB a shard on a
        # full render, and nothing read them. upload-set.ts drops them first (upload-set.test.ts holds what
        # it keeps); it runs after the base replay has read health.json, on the folder the upload takes.
        names = [entry.get("name") for entry in steps()]
        trim = step("Keep only the screenshots a reader needs")
        upload = step("Upload the health run")
        self.assertLess(names.index("Judge the red states against the base"), names.index(trim["name"]))
        self.assertEqual(names.index(trim["name"]) + 1, names.index(upload["name"]))
        self.assertIn("always()", trim["if"])
        self.assertIn('upload-set.ts --dir "$RUNNER_TEMP/health"', trim["run"])
        self.assertEqual(upload["with"]["path"], "${{ runner.temp }}/health")
        # More screenshots only on an explicit dispatch input, empty by default.
        inputs = triggers()["workflow_dispatch"]["inputs"]
        self.assertEqual(inputs["screenshots"]["default"], "")
        self.assertEqual(trim["env"]["KEEP"], "${{ inputs.screenshots }}")

    def test_reports_keep_the_pull_request_head(self) -> None:
        # The artifact names the head the pull request shows, beside the merge commit rendered.
        record = step("Record what was rendered")
        self.assertIn("steps.resolve.outputs.head_sha", str(record.get("env")))
        self.assertIn("health/source.json", record["run"])
        names = [entry.get("name") for entry in steps()]
        self.assertLess(names.index("Record what was rendered"), names.index("Upload the health run"))


class GalleryHealthBaseReds(unittest.TestCase):
    """A pull request's red state that is red the same way on its base warns instead of failing.

    Base reds are warnings, not failures (the rulebook). SHIP'd webview PRs sat held by health shards whose only
    reds were base entries (streaming-text#jump-during-stream, narrow#model-menu, model-picker#many-harnesses).
    """

    def test_the_render_goes_on_to_the_base_judgement(self) -> None:
        render = step("Render the gallery and judge it")
        self.assertEqual(render.get("id"), "render")
        self.assertIs(render.get("continue-on-error"), True)
        judge = step("Judge the red states against the base")
        self.assertIn("steps.render.outcome == 'failure'", judge["if"])
        self.assertIn("!cancelled()", judge["if"])
        names = [entry.get("name") for entry in steps()]
        self.assertEqual(names.index("Judge the red states against the base"),
                         names.index("Render the gallery and judge it") + 1)
        self.assertLess(names.index("Judge the red states against the base"), names.index("Upload the health run"))

    def test_the_base_is_the_merges_first_parent_rendered_by_the_same_checker(self) -> None:
        judge = step("Judge the red states against the base")
        self.assertIn("steps.resolve.outputs.base_sha", str(judge.get("env")))
        run = judge["run"]
        self.assertIn("git restore --source=\"$BASE_SHA\"", run)
        self.assertIn("':(exclude)scripts/gallery-matrix'", run)
        self.assertIn('--entries "$entries"', run)
        self.assertIn("bun health.ts", run)

    def test_the_base_replays_only_the_red_states_within_a_budget(self) -> None:
        # Whole entries (matched by prefix) re-rendered 1,308 cases for ~40 red states and the job was cancelled
        # at its timeout with no verdict.
        judge = step("Judge the red states against the base")
        run = judge["run"]
        self.assertIn("gallery --head \"$head\" --states", run)
        self.assertIn('"$RUNNER_TEMP/base-entries.json" > "$RUNNER_TEMP/base-manifest.json"', run)
        self.assertLess(run.index("base-manifest.json"), run.index("bun health.ts"))
        self.assertIn('--manifest "$RUNNER_TEMP/base-manifest.json"', run)
        workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        self.assertLess(int(judge["timeout-minutes"]), int(workflow["jobs"]["health"]["timeout-minutes"]))

    def test_the_shard_count_matches_the_matrix(self) -> None:
        workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        shards = workflow["jobs"]["health"]["strategy"]["matrix"]["shard"]
        self.assertEqual(shards, list(range(len(shards))))
        self.assertIn(f"--shard-count {len(shards)} ", step("Render the gallery and judge it")["run"])

    def test_every_health_run_may_render(self) -> None:
        # health.ts refuses to render without CMUX_GALLERY_IN_VM=1 and writes no verdict; the base replay
        # first ran without it, so no base result ever existed and every red failed (review of #27100).
        workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        job_env = workflow["jobs"]["health"].get("env") or {}
        runs = [entry for entry in steps() if "bun health.ts" in str(entry.get("run", ""))]
        self.assertEqual(len(runs), 2)
        for entry in runs:
            env = {**job_env, **(entry.get("env") or {})}
            self.assertEqual(str(env.get("CMUX_GALLERY_IN_VM")), "1", entry.get("name"))

    def test_a_base_replay_with_no_verdict_fails_loudly(self) -> None:
        run = step("Judge the red states against the base")["run"]
        replay = run[run.index("bun health.ts"):]
        self.assertNotIn("|| true", replay.split("\n", 2)[0] + replay.split("\n", 2)[1])
        self.assertIn('[ ! -s "$RUNNER_TEMP/health/base/$pass/health.json" ]', run)
        self.assertLess(run.index('[ ! -s "$RUNNER_TEMP/health/base/$pass/health.json" ]'), run.index('"${bases[@]}"'))

    def test_a_state_red_in_any_base_render_is_the_bases(self) -> None:
        # The head holds a state red only when every retry shows it; the base must not need that too, or a state
        # that flakes on the base is the pull request's own (pages.home-channels#emoji-return, run 41393541781).
        run = step("Judge the red states against the base")["run"]
        self.assertIn("for pass in 1 2", run)
        self.assertIn("--retries 0", run)

    def test_one_classifier_judges_it_and_fails_closed(self) -> None:
        run = step("Judge the red states against the base")["run"]
        self.assertIn("scripts/ci/test_reds.py", run)
        self.assertIn("gallery --head", run)
        self.assertIn("--annotate", run)
        # The classifier is copied before the base replaces it in the checkout.
        self.assertLess(run.index("cp scripts/ci/test_reds.py"), run.index("git restore"))
        # Only a run with no base (the nightly dispatch, a new tip) fails on every red; a failed render
        # with no red state is a tool failure.
        self.assertIn('if [ -z "$BASE_SHA" ]; then', run)
        self.assertNotIn("!= pull_request", run)
        self.assertIn('[ "$rc" = 2 ]', run)
        self.assertTrue(run.rstrip().endswith('exit "$rc"'))


class GalleryHealthPushBase(unittest.TestCase):
    """A push to feat-cmux-next is judged against the tip it replaced, so a red names the push that
    caused it. With no base, every red failed every push (8 of 8 shards on 6 of 8 pushes, 2026-11-10)
    and a red one push introduced could not be told from one already there."""

    def resolve(self, event: str, before: str) -> dict[str, str]:
        run = step("Resolve the head and the merge")["run"]
        with tempfile.TemporaryDirectory() as tmp:
            git = ["git", "-C", tmp, "-c", "user.name=t", "-c", "user.email=t@t"]
            subprocess.run(["git", "init", "-q", tmp], check=True)
            shas = []
            for n in range(2):
                subprocess.run([*git, "commit", "-q", "--allow-empty", "-m", str(n)], check=True)
                shas.append(subprocess.run([*git, "rev-parse", "HEAD"], check=True, capture_output=True,
                                           text=True).stdout.strip())
            out = Path(tmp) / "out"
            env = {**os.environ, "EVENT": event, "PR_HEAD": "", "GITHUB_OUTPUT": str(out),
                   "BEFORE": shas[0] if before == "previous" else before}
            subprocess.run(["bash", "-c", run], cwd=tmp, env=env, check=True, capture_output=True)
            values = dict(line.split("=", 1) for line in out.read_text().splitlines())
            return {**values, "previous": shas[0], "tip": shas[1]}

    def test_a_push_compares_with_the_tip_it_replaced(self) -> None:
        self.assertIn("github.event.before", str(step("Resolve the head and the merge").get("env")))
        values = self.resolve("push", "previous")
        self.assertEqual(values["base_sha"], values["previous"])
        self.assertEqual(values["head_sha"], values["tip"])

    def test_a_push_fetches_the_history_its_before_is_in(self) -> None:
        """A push compares with `before`, which may be any depth back, so it fetches full history. GitHub's
        `cond && a || b` gives b whenever a is falsy, and 0 is falsy: `push && 0 || 2` fetched depth 2 on
        every push, and a multi-commit push lost its base (review of cmux#40994)."""
        depth = str(step("Checkout")["with"]["fetch-depth"])
        match = re.fullmatch(r"\$\{\{ github\.event_name == 'push' && (\S+) \|\| (\S+) \}\}", depth)
        self.assertIsNotNone(match, depth)
        when_push, otherwise = match.group(1), match.group(2)
        self.assertNotIn(when_push, {"0", "false", "''", "null"}, "a falsy value here makes `||` take the right side")
        self.assertEqual(int(when_push.strip("'")), 0)
        self.assertEqual(int(otherwise.strip("'")), 2)

    def test_a_new_tip_or_the_nightly_has_no_base(self) -> None:
        self.assertEqual(self.resolve("push", "0" * 40)["base_sha"], "")
        self.assertEqual(self.resolve("workflow_dispatch", "")["base_sha"], "")


class GalleryHealthBrowserConsistency(unittest.TestCase):
    def test_gallery_head_and_base_receive_the_same_resolved_browser(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/gallery-health.yml").read_text())
        steps = workflow["jobs"]["health"]["steps"]
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            for folder in ("webviews", "scripts/ci", "scripts/gallery-matrix", "bin"):
                (work / folder).mkdir(parents=True)
            browser = str(work / "resolved chrome-headless-shell")
            env_file, launches = work / "env", work / "launches"
            env_file.touch()
            stubs = {
                "scripts/ci/ensure-system-chrome.sh":
                    '#!/bin/sh\nprintf "CMUX_CHROME_HEADLESS_SHELL=%s\\n" "$TEST_BROWSER" >> "$GITHUB_ENV"\n',
                "bin/git": '#!/bin/sh\nprintf "%s\\n" "$GITHUB_WORKSPACE"\n',
                "bin/bun": '#!/bin/sh\nif [ "$1" = health.ts ]; then\n'
                    '  printf "%s\\n" "${CMUX_CHROME_HEADLESS_SHELL:-chrome}" >> "$TEST_LAUNCHES"\nfi\n',
            }
            for name, contents in stubs.items():
                script = work / name
                script.write_text(contents)
                script.chmod(0o755)
            env = git_fixture_env.fixture_env({
                "PATH": str(work / "bin") + os.pathsep + os.defpath,
                "GITHUB_WORKSPACE": str(work), "GITHUB_ENV": str(env_file),
                "RUNNER_TEMP": str(work), "TEST_BROWSER": browser, "TEST_LAUNCHES": str(launches),
                "ALL": "true", "IDS": "", "SHARD": "0", "pass": "1",
            })
            render = next(entry for entry in steps if entry.get("id") == "render")
            for entry in steps:
                script = entry.get("run", "")
                if "ensure-system-chrome.sh" not in script and "bun health.ts" not in script:
                    continue
                if "ensure-system-chrome.sh" in script:
                    self.assertEqual(entry.get("if"), render.get("if"))
                if "git restore" in script:
                    # Only execute the base browser invocation; classification and rebuilding
                    # do not select the executable. Keep its real command and arguments.
                    script = re.search(r"(?m)^[ \t]*bun health\.ts(?:[^\n]*\\\n)*[^\n]*", script).group()
                subprocess.run(["bash", "-euc", script], cwd=work / entry.get("working-directory", "."), env=env,
                               check=True, capture_output=True, text=True)
                # Actions imports GITHUB_ENV between steps, never into the writer's shell.
                env.update(line.split("=", 1) for line in env_file.read_text().splitlines())
            self.assertEqual(launches.read_text().splitlines(), [browser, browser])


def triggers() -> dict:
    workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    return workflow.get("on", workflow.get(True))


_spec = importlib.util.spec_from_file_location("gallery_unplaced", ROOT / "scripts/gallery-matrix/unplaced.py")
unplaced_tool = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(unplaced_tool)
triggered = unplaced_tool.routed


def tracked(*paths: str) -> list[str]:
    return subprocess.run(["git", "-C", str(ROOT), "ls-files", "--", *paths], check=True,
                          capture_output=True, text=True).stdout.split()


# The scripts a gallery render runs: the build's entry points, the scripts build-agent-pane-web.sh runs, and
# the checker. What they reach through relative imports, and the files beside them they name in a string
# (broken-allowlist.json), is what a render reads from those folders; the workflow lists those files by name.
RENDER_SCRIPTS = (
    "webviews/vite.config.ts",
    "webviews/vite.config.gallery.ts",
    "webviews/scripts/pages/gen-strings.mjs",
    "webviews/scripts/pages/split-strings.mjs",
    "webviews/scripts/agent-pane/bundle.mjs",
    "webviews/scripts/agent-pane/tailwind-css.mjs",
    "webviews/scripts/gallery/manifest.ts",
    "webviews/scripts/gallery/touched.ts",
    "scripts/gallery-matrix/health.ts",
    "scripts/gallery-matrix/unplaced.py",
    "scripts/gallery-matrix/upload-set.ts",
)
_RELATIVE = re.compile(r"""(?:\bfrom\s*|\bimport\s*\(?\s*|\bnew\s+URL\(\s*)["'](\.{1,2}/[^"'?$]+)""")
_SIBLING = re.compile(r"""["']([\w.-]+\.(?:json|py|ts|mjs))["']""")


def render_script_closure() -> set[str]:
    """Repo paths reachable from RENDER_SCRIPTS: relative imports, and a sibling file named in a string."""
    files = set(tracked("webviews", "scripts/gallery-matrix", "config/vite-plus"))
    seen: set[str] = set()
    queue = list(RENDER_SCRIPTS)
    while queue:
        name = queue.pop()
        if name in seen or name not in files:
            continue
        seen.add(name)
        text = (ROOT / name).read_text(encoding="utf-8", errors="replace")
        folder = os.path.dirname(name)
        targets = [os.path.normpath(os.path.join(folder, spec)) for spec in _RELATIVE.findall(text)]
        targets += [os.path.join(folder, sibling) for sibling in _SIBLING.findall(text)]
        for target in targets:
            for candidate in (target, *(target + ext for ext in (".ts", ".tsx", ".mjs", ".js")),
                              re.sub(r"\.js$", ".ts", target)):
                if candidate in files:
                    queue.append(candidate)
                    break
    return seen


class GalleryHealthPathRouting(unittest.TestCase):
    """A pull request runs gallery health only when a path the gallery render reads changes.

    2026-11-05 CI audit (cmuxterm-hq plans/ci/baggage-2026-11-05.md): ~403,000 runner-minutes in 14 days, the
    most expensive check on the base. Leo, 2026-11-05: "we're kind of pushing a lot of frontiers here. We are at
    the same time, like doing a lot of goofy stuff and, like, keeping around a lot of baggage."
    """

    def test_a_pull_request_and_a_push_route_on_the_same_paths(self) -> None:
        on = triggers()
        self.assertEqual(on["pull_request"]["paths"], on["push"]["paths"])
        self.assertEqual(on["pull_request"]["branches"], ["feat-cmux-next"])

    def test_what_the_render_reads_triggers_it(self) -> None:
        paths = triggers()["pull_request"]["paths"]
        for path in (
            "webviews/src/agent-session/acpmux/conversation/conversation.css",
            "webviews/src/gallery/frame/main.ts",
            "webviews/dev-server/galleryHost.ts",
            "webviews/scripts/gallery/touched.ts",
            "webviews/scripts/agent-pane/bundle.mjs",
            "webviews/scripts/pages/gen-strings.mjs",
            "webviews/vite.config.gallery.ts",
            "webviews/bun.lock",
            "scripts/gallery-matrix/bun.lock",
            "scripts/gallery-matrix/health.ts",
            "scripts/ci/test_reds.py",
            ".github/workflows/gallery-health.yml",
            "Resources/ghostty/themes/Token Dark",
            "webviews/src/gallery/fixtures/markdown-showcase.md",
            "scripts/gallery-matrix/broken-allowlist.json",
            "scripts/gallery-matrix/geometry-collector.ts",
        ):
            self.assertTrue(triggered(path, paths), path)

    def test_what_the_render_never_reads_does_not_trigger_it(self) -> None:
        paths = triggers()["pull_request"]["paths"]
        for path in (
            "webviews/src/agent-session/acpmux/conversation/scrollAnchor.test.ts",
            "webviews/test/transcript-cohesion.browser.test.ts",
            "webviews/bench/hover-sweep.ts",
            "webviews/scripts/check-design-tokens.ts",
            "webviews/README.md",
            "bun.lock",
            "Packages/macOS/CmuxNext/Sources/CmuxNextApp/AppDelegate.swift",
            # The matrix's other tools, benches, capture tools and docs: no render reads them.
            "scripts/gallery-matrix/README.md",
            "scripts/gallery-matrix/geometry-audit.ts",
            "scripts/gallery-matrix/health.test.ts",
            "webviews/scripts/agent-pane/hidden-idle-bench.ts",
            "webviews/scripts/agent-pane/chat-load/reopen.sh",
            "webviews/scripts/gallery/capture-window-chrome.ts",
            "webviews/scripts/pages/layout-check.mjs",
            "webviews/src/ui/README.md",
            "webviews/src/gallery/ENTRIES.md",
        ):
            self.assertFalse(triggered(path, paths), path)

    def test_every_broad_touched_path_triggers_it(self) -> None:
        # touched.ts's EVERYTHING list re-renders every entry; each of its files must start the workflow. The
        # repository's root bun.lock is the exception: neither install here (webviews/, scripts/gallery-matrix/)
        # reads it.
        source = (ROOT / "webviews/scripts/gallery/touched.ts").read_text(encoding="utf-8")
        block = source[source.index("const EVERYTHING"):source.index("];", source.index("const EVERYTHING"))]
        broad = [re.compile(body) for body in re.findall(r"^\s*/(.+)/,\s*$", block, re.M)]
        self.assertGreater(len(broad), 5)
        paths = triggers()["pull_request"]["paths"]
        files = [path for path in tracked(".") if any(pattern.search(path) for pattern in broad)]
        # A unit test beside the gallery (`*.test.ts`) is never bundled, so it renders nothing either.
        # A matrix tool or a gallery script no render runs (geometry-audit.ts, capture-window-chrome.ts) and a doc
        # (ENTRIES.md) change no render either: of those folders, only what the render scripts reach must trigger.
        reached = render_script_closure()
        missed = [path for path in files
                  if path != "bun.lock" and not re.search(r"\.test\.tsx?$", path) and not path.endswith(".md")
                  and (path in reached or not path.startswith(("scripts/gallery-matrix/", "webviews/scripts/gallery/")))
                  and not triggered(path, paths)]
        self.assertEqual(missed, [])

    def test_every_script_a_render_runs_triggers_it(self) -> None:
        # The scripts folders are routed file by file; a module the build or the checker starts importing must
        # join the list, or a change to it would skip the check.
        paths = triggers()["pull_request"]["paths"]
        reached = render_script_closure()
        self.assertGreater(len(reached), 20)
        self.assertIn("scripts/gallery-matrix/shift-baseline.json", reached)
        self.assertIn("webviews/scripts/pages/gen-feature-tips.mjs", reached)
        self.assertEqual(sorted(path for path in reached if not triggered(path, paths)), [])

    def test_every_routed_script_is_one_a_render_runs(self) -> None:
        # The other way round: a file listed by name under the scripts folders is one a render reaches, so the
        # list keeps no file nothing reads.
        paths = triggers()["pull_request"]["paths"]
        reached = render_script_closure()
        folders = ("scripts/gallery-matrix/", "webviews/scripts/agent-pane/", "webviews/scripts/pages/",
                   "webviews/scripts/gallery/", "webviews/scripts/lint/")
        listed = [path for path in paths if path.startswith(folders) and not path.endswith("/bun.lock")]
        self.assertTrue(listed)
        self.assertEqual(sorted(path for path in listed if path not in reached), [])

    def test_a_markdown_file_a_gallery_source_imports_triggers_it(self) -> None:
        # webviews/src Markdown is routed only under src/gallery/fixtures/; a page that imports one from
        # elsewhere (`?raw`) must still start the check.
        paths = triggers()["pull_request"]["paths"]
        pattern = re.compile(r"""["'](\.{1,2}/[^"'?]+\.md)(?:\?raw)?["']""")
        missed = set()
        for name in tracked("webviews/src"):
            if not re.search(r"\.(ts|tsx|js|mjs|css)$", name) or re.search(r"\.test\.tsx?$", name):
                continue
            text = (ROOT / name).read_text(encoding="utf-8", errors="replace")
            for match in pattern.finditer(text):
                target = os.path.normpath(os.path.join(os.path.dirname(name), match.group(1)))
                if (ROOT / target).is_file() and not triggered(target, paths):
                    missed.add(f"{target} (from {name})")
        self.assertEqual(sorted(missed), [])

    def test_every_file_the_gallery_imports_from_outside_webviews_triggers_it(self) -> None:
        # A gallery file, a component or a stylesheet that imports a fixture, a schema or a font from outside
        # webviews/: that file changes what renders, so it must start the workflow.
        paths = triggers()["pull_request"]["paths"]
        pattern = re.compile(r"""(?:\bfrom\s*|\bimport\s*\(?\s*|@import\s+(?:url\()?|new URL\(\s*)["'](\.{1,2}/[^"'?]+)""")
        missed = set()
        for name in tracked("webviews/src", "webviews/dev-server", "webviews/scripts/gallery",
                            "webviews/scripts/agent-pane", "webviews/scripts/pages"):
            if not re.search(r"\.(ts|tsx|js|mjs|css)$", name) or re.search(r"\.test\.tsx?$", name):
                continue
            # A script no render runs (a bench, a capture tool) is not routed, and neither is what it imports.
            if not triggered(name, paths):
                continue
            text = (ROOT / name).read_text(encoding="utf-8", errors="replace")
            for match in pattern.finditer(text):
                target = os.path.normpath(os.path.join(os.path.dirname(name), match.group(1)))
                # Inside webviews/, only a test helper a gallery stage imports (test/latency/mock-host.ts) sits
                # outside the routed folders.
                if target.startswith("webviews/") and not target.startswith("webviews/test/"):
                    continue
                if (ROOT / target).is_file() and not triggered(target, paths):
                    missed.add(f"{target} (from {name})")
        self.assertEqual(sorted(missed), [])

    def test_the_string_catalogs_the_gallery_build_reads_trigger_it(self) -> None:
        # gallery:build runs gen-strings.mjs, which reads these catalogs into the pages' strings.
        paths = triggers()["pull_request"]["paths"]
        source = (ROOT / "webviews/scripts/pages/gen-strings.mjs").read_text(encoding="utf-8")
        sources = re.search(r'const sources = "([^"]+)"', source).group(1)
        files = {f.replace("${sources}", sources) for f in re.findall(r'file: [`"]([^`"]+)[`"]', source)}
        files |= set(re.findall(r'inputs: \["([^"]+)"', source))
        self.assertGreater(len(files), 10)
        self.assertEqual(sorted(f for f in files if not triggered(f, paths)), [])

    def test_the_design_scale_and_feature_tips_the_build_writes_trigger_it(self) -> None:
        # gen-strings.mjs (gallery:build) also writes the design scale (gen-design-scale.mjs) and the feature
        # tips (gen-feature-tips.mjs); their sources must start the workflow.
        paths = triggers()["pull_request"]["paths"]
        scale = (ROOT / "webviews/scripts/pages/gen-design-scale.mjs").read_text(encoding="utf-8")
        sources = re.findall(r'_?SOURCE = "([^"]+)"', scale)
        self.assertGreaterEqual(len(sources), 3)
        tips = [path for path in tracked("release-notes/next/highlights")][:1]
        for path in [*sources, *tips]:
            self.assertTrue(triggered(path, paths), path)

    def test_the_tool_reads_the_same_paths_yaml_does(self) -> None:
        self.assertEqual(unplaced_tool.pull_request_paths(WORKFLOW.read_text(encoding="utf-8")),
                         triggers()["pull_request"]["paths"])

    def test_a_global_input_no_entry_imports_renders_every_entry(self) -> None:
        # A theme, a font or a string catalog is global to every page: touched.ts names no entry for it, and
        # rendering nothing would pass with no verdict (review of #36741).
        paths = triggers()["pull_request"]["paths"]
        touched = {"all": False, "entries": ["a"], "reasons": {"a": [
            "Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/cancelled.json"]}}
        for path in ("Resources/ghostty/themes/Token Dark", "webviews/bun.lock", "scripts/ci/test_reds.py",
                     "Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Localizable.xcstrings"):
            self.assertEqual(unplaced_tool.unplaced(paths, [path], touched), [path])
        # An imported fixture renders only the entries that import it; an unreached webviews/src file and an
        # unrouted file render nothing.
        for path in ("Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/cancelled.json",
                     "webviews/src/unused/Thing.tsx", "Packages/macOS/CmuxNext/Sources/CmuxNextApp/AppDelegate.swift"):
            self.assertEqual(unplaced_tool.unplaced(paths, [path], touched), [], path)
        run = step("Choose the entries to render")["run"]
        self.assertIn("scripts/gallery-matrix/unplaced.py ../.github/workflows/gallery-health.yml", run)

    def test_an_untraced_webviews_asset_or_string_catalog_renders_every_entry(self) -> None:
        # A string catalog gen-strings.mjs compiles and an asset no import traces reach no entry, but they
        # change what pages show, so they render every entry; a placed asset renders only its entries.
        paths = triggers()["pull_request"]["paths"]
        placed = "webviews/src/agent-session/acpmux/mascots/ChiefMascotFox.png"
        touched = {"all": False, "entries": ["a"], "reasons": {"a": [placed]}}
        for path in ("webviews/src/agent-session/acpmux/Localizable.xcstrings",
                     "webviews/src/pages/import-history/Localizable.xcstrings",
                     "webviews/src/agent-session/acpmux/mascots/ChiefMascotOwl.png"):
            self.assertEqual(unplaced_tool.unplaced(paths, [path], touched), [path])
        self.assertEqual(unplaced_tool.unplaced(paths, [placed], touched), [])

    def test_a_dispatch_renders_every_entry(self) -> None:
        # The nightly full render of the base: a main-side dispatcher starts it on feat-cmux-next, since a
        # schedule on this branch never fires.
        self.assertIn("workflow_dispatch", triggers())
        run = step("Choose the entries to render")["run"]
        branch = run[run.index('[ "$EVENT" = workflow_dispatch ]'):]
        branch = branch[:branch.index("elif", 1)]
        self.assertIn("echo .github/workflows/gallery-health.yml", branch)
        workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        self.assertIn("github.event_name", workflow["concurrency"]["group"])


def sparse_patterns() -> list[str]:
    checkout = step("Checkout")["with"]
    return [line.strip() for line in str(checkout["sparse-checkout"]).splitlines() if line.strip()]


def in_sparse(path: str, patterns: list[str]) -> bool:
    """Whether the job's allow-list checkout (non-cone: folders, files and `**` globs, no negation) has PATH."""
    for pattern in patterns:
        rel = pattern.lstrip("/")
        if rel.endswith("/") and path.startswith(rel):
            return True
        if "*" in rel and unplaced_tool.glob_regex(rel).match(path):
            return True
        if rel == path:
            return True
    return False


class GalleryHealthTime(unittest.TestCase):
    """Leo, 2026-11-11: "what the heck is 30 minutes of 'gallery health'". Each shard's job is held to 10 minutes."""

    def test_the_checkout_has_every_path_a_render_reads(self) -> None:
        # The checkout takes only the folders a render reads (the full tree's blobs were ~60 s of every shard);
        # each routed path is what a render reads, so each routed file must be in it, and so must the job's tools.
        patterns = sparse_patterns()
        checkout = step("Checkout")["with"]
        self.assertIs(checkout["sparse-checkout-cone-mode"], False)
        self.assertEqual(str(checkout["filter"]), "blob:none")
        self.assertFalse(any(p.startswith("!") for p in patterns), "an allow-list: name what the job reads")
        routed = triggers()["pull_request"]["paths"]
        missing = [path for path in tracked() if triggered(path, routed) and not in_sparse(path, patterns)]
        self.assertEqual(missing, [], "add these to the Checkout step's sparse-checkout")
        for path in ("scripts/ci/api_call_log/env.sh", "scripts/ci/test_reds.py", "scripts/ci/ensure-system-chrome.sh",
                     ".github/actions/playwright-apt-cache/action.yml", ".github/workflows/gallery-health.yml",
                     "scripts/gallery-matrix/upload-set.ts", "webviews/package.json"):
            self.assertTrue(in_sparse(path, patterns), path)
        self.assertFalse(in_sparse("cmux-tui/Cargo.toml", patterns))
        self.assertFalse(in_sparse("Packages/macOS/CmuxNext/Sources/CmuxNextApp/AppDelegate.swift", patterns))

    def test_a_shard_past_its_case_budget_fails_naming_the_shard_count(self) -> None:
        cap = step("Hold each shard within its time budget")
        self.assertEqual(cap["env"]["SHARDS"], "${{ strategy.job-total }}")
        self.assertIn("matrix.shard == 0", cap["if"])
        self.assertIn("!cancelled()", cap["if"])
        names = [entry.get("name") for entry in steps()]
        # It counts before the base replay restores the base's webviews/ (review of #41296), goes on so the
        # render still gives its verdict, and a later step fails the job.
        self.assertLess(names.index("Hold each shard within its time budget"), names.index("Render the gallery and judge it"))
        self.assertIs(cap["continue-on-error"], True)
        fail = step("Fail past the case budget")
        self.assertIn("steps.cap.outcome == 'failure'", fail["if"])
        self.assertLess(names.index("Judge the red states against the base"), names.index("Fail past the case budget"))
        self.assertIn("exit 1", fail["run"])
        with tempfile.TemporaryDirectory(prefix="gallery-cap-") as tmp:
            root = Path(tmp)
            (root / "webviews/scripts/gallery").mkdir(parents=True)
            (root / "bin").mkdir()
            # A stand-in manifest.ts: bun writes N cases to --out.
            (root / "bin/bun").write_text(
                "#!/bin/sh\nwhile [ $# -gt 0 ]; do [ \"$1\" = --out ] && { python3 -c \"import json,sys; "
                "json.dump([{}]*int(sys.argv[1]), open(sys.argv[2], 'w'))\" \"$CASES\" \"$2\"; }; shift; done\n")
            (root / "bin/bun").chmod(0o755)

            def run(cases: int) -> subprocess.CompletedProcess:
                env = {**os.environ, "PATH": f"{root / 'bin'}:{os.environ['PATH']}", "RUNNER_TEMP": tmp,
                       "CASES": str(cases), "SHARDS": "16", "MAX_CASES_PER_SHARD": cap["env"]["MAX_CASES_PER_SHARD"]}
                return subprocess.run(["bash", "-c", cap["run"]], cwd=root, env=env, capture_output=True, text=True)

            limit = 16 * int(cap["env"]["MAX_CASES_PER_SHARD"])
            self.assertEqual(run(limit).returncode, 0, run(limit).stdout + run(limit).stderr)
            over = run(limit + 1)
            self.assertEqual(over.returncode, 1, over.stdout + over.stderr)
            self.assertIn("::error", over.stdout)
            self.assertIn("to 17 shards", over.stdout)


if __name__ == "__main__":
    unittest.main()
