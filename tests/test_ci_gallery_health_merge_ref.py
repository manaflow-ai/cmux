#!/usr/bin/env python3
"""gallery-health.yml renders a pull request merged with its base, as the other PR gates do.

It checked out pull_request.head.sha, so a branch cut before a base fix kept failing on what base
had already fixed (transcript-density: "Module not found health.ts" after #23333). The merge ref
(GitHub's refs/pull/N/merge, the default checkout of a pull_request event) is what lands.
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
        # A push has no base to compare with; a failed render with no red state is a tool failure.
        self.assertIn('[ "$EVENT" != pull_request ] || [ -z "$BASE_SHA" ]', run)
        self.assertIn('[ "$rc" = 2 ]', run)
        self.assertTrue(run.rstrip().endswith('exit "$rc"'))


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
            env = {
                "PATH": str(work / "bin") + os.pathsep + os.defpath,
                "GITHUB_WORKSPACE": str(work), "GITHUB_ENV": str(env_file),
                "RUNNER_TEMP": str(work), "TEST_BROWSER": browser, "TEST_LAUNCHES": str(launches),
                "ALL": "true", "IDS": "", "SHARD": "0", "pass": "1",
            }
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


def glob_regex(pattern: str) -> re.Pattern[str]:
    """A GitHub paths pattern (`**`, `*`) as a regular expression over one repo path."""
    out, index = "", 0
    while index < len(pattern):
        if pattern.startswith("**/", index):
            out, index = out + "(?:.*/)?", index + 3
        elif pattern.startswith("**", index):
            out, index = out + ".*", index + 2
        elif pattern[index] == "*":
            out, index = out + "[^/]*", index + 1
        else:
            out, index = out + re.escape(pattern[index]), index + 1
    return re.compile(out + r"\Z")


def triggered(path: str, patterns: list[str]) -> bool:
    """GitHub's rule: the last pattern that matches decides, a `!` pattern excluding."""
    hit = False
    for pattern in patterns:
        if glob_regex(pattern.lstrip("!")).match(path):
            hit = not pattern.startswith("!")
    return hit


def tracked(*paths: str) -> list[str]:
    return subprocess.run(["git", "-C", str(ROOT), "ls-files", "--", *paths], check=True,
                          capture_output=True, text=True).stdout.split()


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
        ):
            self.assertFalse(triggered(path, paths), path)

    def test_every_broad_touched_path_triggers_it(self) -> None:
        # touched.ts's EVERYTHING list re-renders every entry; each of its files must start the workflow. The
        # repository's root bun.lock is the one exception: neither install here (webviews/, scripts/gallery-matrix/)
        # reads it.
        source = (ROOT / "webviews/scripts/gallery/touched.ts").read_text(encoding="utf-8")
        block = source[source.index("const EVERYTHING"):source.index("];", source.index("const EVERYTHING"))]
        broad = [re.compile(body) for body in re.findall(r"^\s*/(.+)/,\s*$", block, re.M)]
        self.assertGreater(len(broad), 5)
        paths = triggers()["pull_request"]["paths"]
        files = [path for path in tracked(".") if any(pattern.search(path) for pattern in broad)]
        missed = [path for path in files if path != "bun.lock" and not triggered(path, paths)]
        self.assertEqual(missed, [])

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


if __name__ == "__main__":
    unittest.main()
