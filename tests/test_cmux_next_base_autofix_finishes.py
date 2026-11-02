#!/usr/bin/env python3
"""cmux-next base autofix lands its repairs while feat-cmux-next keeps moving, and never lands a wrong one.

2026-10-19: the settings exports went stale on feat-cmux-next (defaults-snapshot red on every PR) because
each push cancelled the running Mac export job and the autofix job, and autofix refused to push once the
base had moved. With merges minutes apart, 9 runs in a row were cancelled and the repair never landed.
A repair generated at an older head may land on the moved tip only where nothing in between touched that
file's input areas; otherwise the newer run regenerates it (a revert in between would make it wrong).
That is judged file by file (2026-10-20): the files of untouched areas land even when another area moved,
and the run still fails so the next run's "since" covers what was left out. Since 2026-10-21 the push is
scripts/cmux-next/base-autofix-push.sh, which this drives against a local remote; it also holds a file a
newer commit wrote itself, and its own cases are in scripts/cmux-next/tests/base-autofix-push.test.sh.
"""
from __future__ import annotations

import json
import os
import re
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
DOC = yaml.safe_load((ROOT / ".github/workflows/cmux-next-base-autofix.yml").read_text())
PUSH_SCRIPT = ROOT / "scripts/cmux-next/base-autofix-push.sh"
SETTINGS = "Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Settings.swift"
EXPORT = "schemas/settings/settings-schema.json"
SNAPSHOT = "schemas/defaults/cmux-next.json"
SHORTCUTS = "web/data/cmux-shortcuts.generated.json"
SURFACES = "plans/cmux-next/action-surfaces.json"
WEBVIEWS = "webviews/src/generated.ts"
APP = "first-party-apps/app/fragment.json"
ACTION_TESTS = "Packages/macOS/CmuxNext/Tests/CmuxNextActionsTests/ActionTests.swift"


def git(cwd, *args):
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


class BaseAutofixFinishes(unittest.TestCase):
    def test_a_running_repair_finishes(self):
        # A newer push still replaces a pending autofix, so at most one waits.
        self.assertFalse(DOC["jobs"]["autofix"]["concurrency"]["cancel-in-progress"])

    def test_a_queued_mac_export_job_keeps_its_place(self):
        # 2026-10-21 11:15-11:36Z: with the Mac runners saturated, every run's Mac job waited minutes for a
        # runner and the next push replaced it while pending, so none ever started (no export after 02:14Z).
        # It has no concurrency group now: nothing replaces it.
        self.assertNotIn("concurrency", DOC["jobs"]["action-exports"])

    def test_a_run_skips_its_mac_job_while_another_is_queued_or_running(self):
        areas = DOC["jobs"]["action-areas"]
        self.assertIn("mac_busy", areas["outputs"])
        busy = next(s for s in areas["steps"] if "base-autofix-mac-busy.sh" in s.get("run", ""))
        self.assertIn("$GITHUB_RUN_ID", busy["run"])
        self.assertIn("GITHUB_OUTPUT", busy["run"])
        self.assertIn("needs.action-areas.outputs.mac_busy != 'true'", DOC["jobs"]["action-exports"]["if"])

    def test_a_deferred_run_is_not_red(self):
        # While the Mac runners are saturated most runs defer, and base-red-watch would blame each red one
        # on whoever pushed. A deferred run ends green and names the run that carries its exports.
        self.assertNotIn("action-areas", DOC["jobs"]["autofix"]["needs"])
        for step in DOC["jobs"]["autofix"]["steps"]:
            self.assertNotIn("mac_busy", str(step.get("if", "")))
        job = DOC["jobs"]["mac-exports-deferred"]
        self.assertEqual(job["name"], "Mac exports deferred")
        # A deferred run looks for no pack (pushed-exports is skipped while another run carries the exports).
        self.assertEqual(job["needs"], "action-areas")
        self.assertEqual(job["if"], "needs.action-areas.outputs.mac_busy == 'true'")
        self.assertNotIn("continue-on-error", job)
        run = "\n".join(s.get("run", "") for s in job["steps"])
        self.assertIn("GITHUB_STEP_SUMMARY", run)
        self.assertIn("mac_busy_run", str(job["steps"]))
        self.assertNotIn("exit 1", run)
        self.assertNotIn("::error::", run)

    def test_both_change_lookups_skip_runs_that_deferred_their_exports(self):
        # A deferred run is green but exported nothing: the next run's "since" must reach past it.
        for job in ("action-areas", "autofix"):
            with self.subTest(job=job):
                areas = next(s for s in DOC["jobs"][job]["steps"] if s.get("id") == "areas")
                self.assertIn("scripts/cmux-next/base-autofix-since.sh", areas["run"])
                self.assertNotIn("status=success", areas["run"])
        self.assertIn("scripts/cmux-next/base-autofix-since.sh", DOC[True]["push"]["paths"])

    def test_the_autofix_that_carries_mac_exports_is_never_replaced_while_pending(self):
        # 2026-10-21: runs whose own Mac job a newer push replaced still run autofix (about 1.5 minutes,
        # every minute or two), so the run whose Mac job finished queued its autofix behind one of them,
        # and the next push replaced it: half an hour of Mac exports lost. That autofix has a group of
        # its own; the others still queue only the latest, one group per branch.
        group = DOC["jobs"]["autofix"]["concurrency"]["group"]
        self.assertIn("(needs.pushed-exports.outputs.hit == 'true' && needs.pushed-exports.outputs.exports || needs.action-exports.outputs.exports) == 'true'", group)
        self.assertIn("github.run_id", group)
        self.assertIn("github.ref_name", group)

    def push(self, moved: dict[str, str] | None, *, repair: dict[str, str] | None = None,
             reject_without_moving=False, move_again: dict[str, str] | None = None):
        """Run the push loop: a repair (default: the settings export) made at HEAD_SHA, while feat-cmux-next
        gained `moved`; with `move_again`, the first push is rejected after the branch moves once more."""
        repair = repair or {EXPORT: "new"}
        work = Path(tempfile.mkdtemp())
        os.environ.update({"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
                           "GIT_COMMITTER_EMAIL": "t@t"})
        git(work, "init", "-q", "--bare", "remote.git")
        seed = work / "seed"
        git(work, "clone", "-q", "remote.git", "seed")
        git(seed, "checkout", "-q", "-b", "feat-cmux-next")
        files = {SETTINGS: "k1", EXPORT: "old", SNAPSHOT: "old", SHORTCUTS: "old", SURFACES: "old", WEBVIEWS: "old", APP: "a1", ACTION_TESTS: "t1",
                 "README.md": "r", "unlisted/output.txt": "old",
                 "scripts/cmux-next/autofix-areas.sh": (ROOT / "scripts/cmux-next/autofix-areas.sh").read_text()}
        for path, text in files.items():
            (seed / path).parent.mkdir(parents=True, exist_ok=True)
            (seed / path).write_text(text)
        (seed / "scripts/cmux-next/autofix-areas.sh").chmod(0o755)
        git(seed, "add", "-A")
        git(seed, "commit", "-qm", "base")
        git(seed, "push", "-q", "origin", "feat-cmux-next")
        head = git(seed, "rev-parse", "HEAD")
        git(work, "clone", "-q", "--depth=1", "-b", "feat-cmux-next", f"file://{work}/remote.git", "runner")
        runner = work / "runner"
        if moved:
            for path, text in moved.items():
                (seed / path).write_text(text)
            git(seed, "commit", "-qam", "someone merged")
            git(seed, "push", "-q", "origin", "feat-cmux-next")
        if move_again:
            for path, text in move_again.items():
                (seed / path).write_text(text)
            git(seed, "commit", "-qam", "someone merged again")
            git(seed, "push", "-q", "origin", "HEAD:refs/heads/later")
            hook = work / "remote.git" / "hooks" / "pre-receive"
            hook.write_text("#!/bin/sh\nunset GIT_QUARANTINE_PATH\nif [ ! -e moved-once ]; then touch moved-once; "
                            "git update-ref refs/heads/feat-cmux-next refs/heads/later; exit 1; fi\n")
            hook.chmod(0o755)
        for path, text in repair.items():
            (runner / path).write_text(text)
        git(runner, "commit", "-qam", f"chore(next): base autofix at {head[:12]}")
        if reject_without_moving:
            hook = work / "remote.git" / "hooks" / "pre-receive"
            hook.write_text("#!/bin/sh\nexit 1\n")
            hook.chmod(0o755)
        done = subprocess.run(["bash", str(PUSH_SCRIPT), f"file://{work}/remote.git", "feat-cmux-next", head],
                              cwd=runner, capture_output=True, text=True)
        tip = git(work / "remote.git", "rev-parse", "refs/heads/feat-cmux-next")
        landed = {path: git(work / "remote.git", "show", f"{tip}:{path}") for path in repair}
        return done, landed, done.stdout + done.stderr

    def test_the_repair_lands_on_a_base_that_moved_elsewhere(self):
        done, landed, out = self.push({"README.md": "r2"})
        self.assertEqual(done.returncode, 0, out)
        self.assertEqual(landed[EXPORT], "new")

    def test_a_retry_when_the_base_moves_twice(self):
        done, landed, out = self.push({"README.md": "r2"}, move_again={"README.md": "r3"})
        self.assertEqual(done.returncode, 0, out)
        self.assertEqual(landed[EXPORT], "new")
        # The script reads the tip before its first push, so the second move costs one retry, not two.
        self.assertIn("attempt 2 of", out)

    def test_a_repair_whose_inputs_changed_meanwhile_is_left_to_the_newer_run(self):
        # The settings sources moved (a revert, say): this run's export would be wrong at the tip.
        done, landed, out = self.push({SETTINGS: "k0"})
        self.assertEqual(done.returncode, 1)
        self.assertEqual(landed[EXPORT], "old")
        self.assertIn("newer run", out)

    def test_the_unaffected_part_of_a_repair_lands_while_the_affected_part_waits(self):
        # 2026-10-20: 4 of ~50 runs landed in a day. Packages/ (the graph area) moves on nearly every push,
        # so a repair that also carried the graph, settings or webviews never landed any of it. Each file
        # whose areas are untouched since HEAD_SHA is exactly right at the tip, so it lands alone.
        done, landed, out = self.push({SETTINGS: "k0"}, repair={EXPORT: "new", SHORTCUTS: "new"})
        self.assertEqual(landed[SHORTCUTS], "new")
        self.assertEqual(landed[EXPORT], "old")
        self.assertIn(EXPORT, out)
        self.assertIn("next run", out)
        # The run still fails, so the next run's "since" stays at the last whole repair.
        self.assertEqual(done.returncode, 1, out)

    def test_a_partial_repair_stays_partial_when_the_base_moves_again(self):
        done, landed, out = self.push({SETTINGS: "k0"}, repair={EXPORT: "new", SHORTCUTS: "new"},
                                      move_again={"README.md": "r3"})
        self.assertEqual(landed[SHORTCUTS], "new")
        self.assertEqual(landed[EXPORT], "old")
        # As above: one retry for the second move.
        self.assertIn("attempt 2 of", out)
        self.assertEqual(done.returncode, 1, out)

    def test_a_partial_repair_never_overwrites_an_output_changed_meanwhile(self):
        # web/data/ is no input area: the tip's own edit of the output keeps it out of the partial repair.
        done, landed, out = self.push({SETTINGS: "k0", SHORTCUTS: "someone else's"},
                                      repair={EXPORT: "new", SHORTCUTS: "new", WEBVIEWS: "new"})
        self.assertEqual(landed[SHORTCUTS], "someone else's")
        self.assertEqual(landed[EXPORT], "old")
        self.assertEqual(landed[WEBVIEWS], "new")
        self.assertEqual(done.returncode, 1, out)

    def test_outputs_built_from_an_export_whose_inputs_moved_wait_for_the_tip(self):
        # Greptile on #22474: the shortcuts file built from the action export at the run's commit must not
        # land past a move of the export's inputs. The export itself lands as progress (run 39633520123:
        # held, none landed), and base-autofix-land.sh makes the shortcuts again on the tip from it.
        done, landed, out = self.push({ACTION_TESTS: "changed"},
                                      repair={SURFACES: "new", SHORTCUTS: "new", WEBVIEWS: "new"})
        self.assertEqual(landed[SURFACES], "new")
        self.assertEqual(landed[SHORTCUTS], "old")
        self.assertEqual(landed[WEBVIEWS], "new")
        self.assertEqual(done.returncode, 1, out)

    def test_an_app_host_input_change_does_not_hold_the_action_export(self):
        # The action exports read the actions area only (2026-10-21: held for areas they don't read,
        # they never landed). The shortcuts file lands with the export it was built from.
        done, landed, out = self.push({APP: "changed"}, repair={SURFACES: "new", SHORTCUTS: "new", WEBVIEWS: "new"})
        self.assertEqual(landed[SURFACES], "new")
        self.assertEqual(landed[SHORTCUTS], "new")
        self.assertEqual(landed[WEBVIEWS], "new")
        self.assertEqual(done.returncode, 0, out)

    def test_the_defaults_snapshot_never_lands_in_a_partial_repair(self):
        # defaults_guard.py also reads *Enabled flags and keybind lines across the sources, outside any area.
        done, landed, out = self.push({SETTINGS: "k0"}, repair={SNAPSHOT: "new", SHORTCUTS: "new"})
        self.assertEqual(landed[SNAPSHOT], "old")
        self.assertEqual(landed[SHORTCUTS], "new")
        self.assertEqual(done.returncode, 1, out)

    def test_the_defaults_snapshot_waits_when_the_action_exports_moved(self):
        # The snapshot is built from the settings and the action exports (coord-2 review of c30bfe5).
        done, landed, out = self.push({SURFACES: "changed"}, repair={SNAPSHOT: "new"})
        self.assertEqual(done.returncode, 1, out)
        self.assertEqual(landed[SNAPSHOT], "old")

    def test_a_shortcuts_repair_lands_past_an_unrelated_change(self):
        done, landed, out = self.push({"README.md": "r2"}, repair={SHORTCUTS: "new"})
        self.assertEqual(done.returncode, 0, out)
        self.assertEqual(landed[SHORTCUTS], "new")

    def test_an_output_no_area_claims_is_never_reapplied(self):
        done, landed, out = self.push({"README.md": "r2"}, repair={"unlisted/output.txt": "new"})
        self.assertEqual(done.returncode, 1, out)
        self.assertEqual(landed["unlisted/output.txt"], "old")
        self.assertIn("unlisted/output.txt", out)

    def test_a_newer_write_of_the_file_fails_without_pushing(self):
        # web/data/ is no input area; the script holds a file a newer commit wrote (it applies no patch,
        # so there is no conflict to report) and names it.
        done, landed, out = self.push({SHORTCUTS: "someone else's"}, repair={SHORTCUTS: "new"})
        self.assertEqual(done.returncode, 1, out)
        self.assertEqual(landed[SHORTCUTS], "someone else's")
        self.assertIn(SHORTCUTS, out)

    def test_a_push_rejected_without_the_base_moving_says_so(self):
        done, _, out = self.push(None, reject_without_moving=True)
        self.assertEqual(done.returncode, 1)
        self.assertIn("rejected", out)
        self.assertNotIn("kept moving", out)

    def test_the_workflow_pushes_through_the_script(self):
        # base-autofix-land.sh pushes with base-autofix-push.sh, and makes a held repair again on the tip.
        push = next(step for step in DOC["jobs"]["autofix"]["steps"] if step.get("name") == "Push the repairs")["run"]
        self.assertIn("scripts/cmux-next/base-autofix-land.sh", push)
        self.assertIn("base-autofix-push.sh", (ROOT / "scripts/cmux-next/base-autofix-land.sh").read_text())

    def test_the_mac_job_regenerates_the_settings_exports_on_the_newest_tip(self):
        # 2026-10-21: a run takes ~28 minutes and feat-cmux-next takes a push a minute, so some push
        # nearly always moved a settings input and the exports made at HEAD_SHA were held on every run.
        # The Mac job regenerates them on the newest tip (a bounded number of times) and says where.
        job = DOC["jobs"]["action-exports"]
        step = next(step for step in job["steps"] if step.get("id") == "settings")
        self.assertIn("scripts/cmux-next/base-autofix-settings-exports.sh", step["run"])
        self.assertIn("made_at=", step["run"])
        self.assertEqual(job["outputs"]["settings_made_at"], "${{ steps.settings.outputs.made_at }}")

    def test_the_mac_job_makes_the_action_exports_on_the_newest_tip(self):
        # 2026-10-21: judged from the run's own commit, the action exports were held on every run
        # (the Mac job queues for half an hour; the actions area moves every few minutes).
        job = DOC["jobs"]["action-exports"]
        step = next(s for s in job["steps"] if s.get("id") == "actions")
        self.assertIn("scripts/cmux-next/base-autofix-action-exports.sh", step["run"])
        self.assertIn("made_at=", step["run"])
        self.assertIn("CMUX_BASE_AUTOFIX_ACTIONS_PREPARE", step["env"])
        self.assertIn("timeout-minutes", step)
        self.assertEqual(job["outputs"]["actions_made_at"], "${{ steps.actions.outputs.made_at }}")
        push = next(s for s in DOC["jobs"]["autofix"]["steps"] if "base-autofix-land.sh" in s.get("run", ""))
        self.assertEqual(push["env"]["ACTIONS_MADE_AT"], "${{ needs.pushed-exports.outputs.hit == 'true' && needs.pushed-exports.outputs.made_at || needs.action-exports.outputs.actions_made_at }}")
        self.assertIn('"$SETTINGS_MADE_AT" "$ACTIONS_MADE_AT"', push["run"])
        self.assertIn("scripts/cmux-next/base-autofix-action-exports.sh", DOC[True]["push"]["paths"])
        self.assertGreaterEqual(job["timeout-minutes"], step["timeout-minutes"] + 40)

    def test_a_slow_settings_regeneration_never_costs_the_action_exports(self):
        # Up to three swift builds: the settings step has its own timeout, below the job's, so a slow
        # one fails that step (continue-on-error) and the upload of the action exports still runs.
        job = DOC["jobs"]["action-exports"]
        steps = job["steps"]
        settings = next(i for i, step in enumerate(steps) if step.get("id") == "settings")
        upload = next(i for i, step in enumerate(steps) if "upload-artifact" in str(step.get("uses", "")))
        self.assertTrue(steps[settings].get("continue-on-error"))
        self.assertIn("timeout-minutes", steps[settings])
        self.assertLess(steps[settings]["timeout-minutes"], job["timeout-minutes"])
        before = [step for step in steps[:settings] if "timeout-minutes" not in step]
        self.assertLessEqual(steps[settings]["timeout-minutes"] + 15, job["timeout-minutes"],
                             "leave the earlier steps and the upload room inside the job's timeout")
        self.assertGreater(upload, settings)
        self.assertTrue(before)

    def test_the_push_judges_the_settings_exports_from_where_they_were_made(self):
        step = next(step for step in DOC["jobs"]["autofix"]["steps"] if step.get("name") == "Push the repairs")
        self.assertEqual(step["env"]["SETTINGS_MADE_AT"], "${{ needs.pushed-exports.outputs.hit == 'true' && needs.pushed-exports.outputs.made_at || needs.action-exports.outputs.settings_made_at }}")
        self.assertIn('"$HEAD_SHA" "$SETTINGS_MADE_AT"', step["run"])

    def test_the_push_script_knows_every_settings_export(self):
        # The push lands the whole export made at SETTINGS_MADE_AT, file by file from this list.
        def listed(path: Path, name: str) -> set[str]:
            text = path.read_text()
            body = text.split(f"{name}=(", 1)[1].split(")", 1)[0]
            return set(body.split())
        self.assertEqual(listed(PUSH_SCRIPT, "settings_exports"),
                         listed(ROOT / "scripts/cmux-next/regenerate-settings-exports.sh", "exports"))

    def test_the_target_graph_never_waits_for_the_mac_job(self):
        # 2026-10-21: a push to feat-cmux-next added a test target without the graph (Tier routing red on
        # every PR) and the graph landed 90 minutes later: autofix, which made it, needed the Mac exports
        # job, 12-15 minutes in the owned queue and 15-26 running, and two of those runs' repairs were
        # held. The graph is made on Linux from the manifest alone, so its own job needs nothing.
        job = DOC["jobs"]["target-graph"]
        self.assertNotIn("needs", job)
        self.assertIn("ubuntu", job["runs-on"])
        self.assertNotIn("macos", job["runs-on"])
        self.assertFalse(job["concurrency"]["cancel-in-progress"])
        self.assertNotEqual(job["concurrency"]["group"], DOC["jobs"]["autofix"]["concurrency"]["group"])
        push = next(step for step in job["steps"] if step.get("name") == "Push the graph")
        self.assertIn("scripts/cmux-next/base-autofix-land.sh", push["run"])
        self.assertEqual(push["env"]["ENABLED"], "${{ vars.CMUX_NEXT_BASE_AUTOFIX == '1' }}")

    def test_the_target_graph_job_makes_the_graph_and_nothing_else(self):
        # Its repair env asks for the graph only, and as a remake on the tip: no Mac export, nothing built
        # from one (the defaults snapshot, the docs shortcuts, the app-host files), no formatting.
        job = DOC["jobs"]["target-graph"]
        steps = [step for step in job["steps"] if "base-autofix-repair.sh" in step.get("run", "")]
        self.assertEqual(len(steps), 1)
        env = {key: str(value) for key, value in steps[0]["env"].items()}
        push = next(step for step in job["steps"] if step.get("name") == "Push the graph")
        # The land script makes it again on a moved tip with the same areas.
        self.assertEqual({key: push["env"][key] for key in ("GRAPH", "CMUX_BASE_AUTOFIX_AGAIN")},
                         {key: env[key] for key in ("GRAPH", "CMUX_BASE_AUTOFIX_AGAIN")})
        work = Path(tempfile.mkdtemp())
        stub = work / "autofix.sh"
        stub.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$ARGS_OUT"\n')
        stub.chmod(0o755)
        dump = work / "dump.sh"
        dump.write_text("#!/bin/sh\necho '{}'\n")
        dump.chmod(0o755)
        clean = {key: value for key, value in os.environ.items()
                 if key not in ("GRAPH", "STRINGS", "SDK", "SHORTCUTS", "APPHOST", "ACTIONS", "SETTINGS", "RATCHETS",
                                "CLOUD", "FMT", "EXPORTS_DIR", "WEBVIEWS_PATCH", "CMUX_BASE_AUTOFIX_AGAIN")}
        done = subprocess.run(["bash", str(ROOT / "scripts/cmux-next/base-autofix-repair.sh"), str(work)],
                              env={**clean, **env, "CMUX_BASE_AUTOFIX_SCRIPT": str(stub),
                                   "CMUX_BASE_AUTOFIX_DUMP": str(dump), "ARGS_OUT": str(work / "args")},
                              capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        args = (work / "args").read_text().split()
        self.assertIn("--package-dump", args)
        for flag in ("--unverified-exports", "--unverified-settings-exports", "--no-fmt"):
            self.assertIn(flag, args)
        for flag in ("--generated", "--strings", "--sdk", "--docs-shortcuts", "--app-host", "--ratchets",
                     "--cloud-clients", "--webviews-fmt-patch"):
            self.assertNotIn(flag, args)

    def mac_busy(self, runs: dict[int, list[tuple[str, str]]], self_run: int = 1, fail: bool = False) -> str:
        """Runs base-autofix-mac-busy.sh with a gh stand-in: `runs` maps an unfinished run to its (job, status)."""
        work = Path(tempfile.mkdtemp())
        self.addCleanup(subprocess.run, ["rm", "-rf", str(work)])
        (work / "bin").mkdir()
        data = work / "runs.json"
        data.write_text(json.dumps({str(k): v for k, v in runs.items()}))
        gh = work / "bin/gh"
        # The script's own --jq filter runs on the API's JSON, so the job names it counts are its own.
        gh.write_text(f"""#!/usr/bin/env python3
import json, re, subprocess, sys
if {fail!r}:
    sys.exit(1)
runs = json.load(open({str(data)!r}))
path, jq = sys.argv[2], sys.argv[sys.argv.index("--jq") + 1]
m = re.search(r"/runs/(\\d+)/jobs", path)
if m:
    body = {{"jobs": [{{"name": name, "status": status}} for name, status in runs[m.group(1)]]}}
else:
    body = {{"workflow_runs": [{{"id": int(run), "status": "in_progress"}} for run in runs]}}
sys.exit(subprocess.run(["jq", "-r", jq], input=json.dumps(body), text=True).returncode)
""")
        gh.chmod(0o755)
        done = subprocess.run(["bash", str(ROOT / "scripts/cmux-next/base-autofix-mac-busy.sh"), str(self_run)],
                              capture_output=True, text=True, env={**os.environ, "PATH": f"{work / 'bin'}:{os.environ['PATH']}"})
        self.assertEqual(done.returncode, 0, done.stderr)
        return done.stdout

    def test_mac_busy_sees_another_runs_queued_or_running_mac_job(self):
        # Another run's pushed-exports wait carries the exports too (2026-11-01: with only the Mac job
        # counted, every run waited up to 45 minutes there and its formatting repairs with it).
        for job in ("action exports (Mac)", "exports from the push's generated files"):
            for status in ("queued", "in_progress", "waiting"):
                with self.subTest(job=job, status=status):
                    out = self.mac_busy({1: [], 7: [(job, status)]})
                    self.assertEqual(out, "mac_busy=true\nmac_busy_run=7\n")

    def test_mac_busy_is_false_without_another_unfinished_mac_job(self):
        self.assertEqual(self.mac_busy({1: [("action exports (Mac)", "queued")]}), "mac_busy=false\n")  # its own
        self.assertEqual(self.mac_busy({1: [("exports from the push's generated files", "in_progress")]}), "mac_busy=false\n")
        self.assertEqual(self.mac_busy({1: [], 7: [("action exports (Mac)", "completed"), ("autofix feat-cmux-next",
                                                                                          "in_progress")]}),
                         "mac_busy=false\n")
        self.assertEqual(self.mac_busy({}), "mac_busy=false\n")

    def test_mac_busy_fails_open_when_github_cannot_be_read(self):
        # Two Mac jobs beat none.
        self.assertEqual(self.mac_busy({7: [("action exports (Mac)", "queued")]}, fail=True), "mac_busy=false\n")

    def since(self, runs: list[tuple[int, str, list[tuple[str, str]] | None]], fail: bool = False) -> str:
        """Runs base-autofix-since.sh with a gh stand-in: `runs` lists successful runs, newest first, as
        (id, head sha, its (job, conclusion) list, or None when its jobs cannot be read)."""
        work = Path(tempfile.mkdtemp())
        self.addCleanup(subprocess.run, ["rm", "-rf", str(work)])
        (work / "bin").mkdir()
        data = work / "runs.json"
        data.write_text(json.dumps(runs))
        gh = work / "bin/gh"
        gh.write_text(f"""#!/usr/bin/env python3
import json, re, sys
if {fail!r}:
    sys.exit(1)
runs = json.load(open({str(data)!r}))
path = sys.argv[2]
m = re.search(r"/runs/(\\d+)/jobs", path)
if m:
    jobs = next(j for i, _, j in runs if str(i) == m.group(1))
    if jobs is None:
        sys.exit(1)
    assert 'all(.jobs[]; .conclusion == "skipped")' in sys.argv[sys.argv.index("--jq") + 1], sys.argv
    print(sum(1 for name, c in jobs if name == "Mac exports deferred" and c == "success")
          + (1 if jobs and all(c == "skipped" for _, c in jobs) else 0))
else:
    assert "status=success" in path and "event=push" in path, path
    for i, sha, _ in runs:
        print(i, sha)
""")
        gh.chmod(0o755)
        done = subprocess.run(["bash", str(ROOT / "scripts/cmux-next/base-autofix-since.sh")], capture_output=True,
                              text=True, env={**os.environ, "PATH": f"{work / 'bin'}:{os.environ['PATH']}"})
        self.assertEqual(done.returncode, 0, done.stderr)
        return done.stdout

    def test_since_is_the_newest_successful_run_that_made_its_own_exports(self):
        deferred = [("action export areas", "success"), ("Mac exports deferred", "success")]
        made = [("action exports (Mac)", "success"), ("Mac exports deferred", "skipped")]
        self.assertEqual(self.since([(9, "c" * 40, deferred), (8, "b" * 40, deferred), (7, "a" * 40, made)]),
                         "a" * 40 + "\n")
        self.assertEqual(self.since([(9, "c" * 40, made), (8, "b" * 40, deferred)]), "c" * 40 + "\n")
        # A run with no Mac areas at all made nothing to defer.
        self.assertEqual(self.since([(9, "c" * 40, [("action export areas", "success")])]), "c" * 40 + "\n")

    def test_since_passes_the_run_of_its_own_repair_push(self):
        # An App-token repair push starts this workflow again; every job skips it (No loop), and that
        # run must not move "since" past a human push whose run failed or still runs.
        skipped = [("action export areas", "skipped"), ("CI target graph", "skipped"),
                   ("autofix feat-cmux-next", "skipped")]
        made = [("action exports (Mac)", "success"), ("Mac exports deferred", "skipped")]
        self.assertEqual(self.since([(9, "c" * 40, skipped), (7, "a" * 40, made)]), "a" * 40 + "\n")

    def test_since_passes_a_run_whose_jobs_cannot_be_read(self):
        self.assertEqual(self.since([(9, "c" * 40, None), (7, "a" * 40, [])]), "a" * 40 + "\n")

    def test_since_is_empty_when_no_run_qualifies_or_github_cannot_be_read(self):
        # The caller then runs every repair.
        self.assertEqual(self.since([(9, "c" * 40, [("Mac exports deferred", "success")])]), "")
        self.assertEqual(self.since([]), "")
        self.assertEqual(self.since([(7, "a" * 40, [])], fail=True), "")

    def test_ci_runs_this_test(self):
        steps = DOC_NEXT["jobs"]
        runs = "\n".join(step.get("run", "") for job in steps.values() for step in job.get("steps", []))
        self.assertIn("tests/test_cmux_next_base_autofix_finishes.py", runs)



BRANCH = "feat-cmux-next"
SELF_COMMIT_PREFIXES = ("chore(next): base autofix at ", "chore(next): pin GhosttyKit for ghostty ")


def workflow_docs():
    for path in sorted((ROOT / ".github/workflows").glob("*.yml")):
        yield path.name, yaml.safe_load(path.read_text())


def pushes_the_branch(step: dict) -> bool:
    run = step.get("run", "")
    return f"HEAD:refs/heads/{BRANCH}" in run or ("base-autofix-land.sh" in run and BRANCH in run)


class BotPushesStartWorkflows(unittest.TestCase):
    """A bot push to feat-cmux-next starts the push workflows like any other commit.

    2026-10-26: 60c696be ("chore(next): base autofix at 7f042d4d3741") was pushed with a job's GITHUB_TOKEN,
    which starts no workflow, so it had no cmux-next.yml push run and the nightly-next promotion passed it
    over. Every step that pushes the branch pushes with an App token first (GITHUB_TOKEN only when the App
    token can't be minted), and the workflow that pushes skips its own commits, so the push can't loop."""

    def test_every_push_to_the_branch_uses_an_app_token(self):
        found = []
        for name, doc in workflow_docs():
            for job_id, job in (doc.get("jobs") or {}).items():
                steps = job.get("steps") or []
                minted = {s["id"] for s in steps if "create-github-app-token" in str(s.get("uses", "")) and "id" in s}
                for step in steps:
                    if not pushes_the_branch(step):
                        continue
                    found.append((name, job_id))
                    token = str((step.get("env") or {}).get("TOKEN", ""))
                    with self.subTest(workflow=name, job=job_id, step=step.get("name")):
                        self.assertTrue(any(token.startswith(f"${{{{ steps.{i}.outputs.token") for i in minted), token)
                        mint = next(s for s in steps if s.get("id") in minted and f"steps.{s['id']}." in token)
                        self.assertEqual(mint["with"].get("permission-contents"), "write")
                        self.assertNotIn("permission-workflows", mint["with"])
        self.assertEqual(sorted(found), sorted([("cmux-next-base-autofix.yml", "target-graph"),
                                                ("cmux-next-base-autofix.yml", "autofix"),
                                                ("cmux-next-base-autofix.yml", "ghosttykit-checksum")]))

    def test_the_bot_head_dispatch_is_only_the_fallback(self):
        # An App push starts cmux-tui-artifacts.yml itself; a dispatch too would race its push run.
        for job_id in ("target-graph", "autofix", "ghosttykit-checksum"):
            step = next(s for s in DOC["jobs"][job_id]["steps"] if "publish-bot-head-tree.sh" in s.get("run", ""))
            with self.subTest(job=job_id):
                self.assertIn("steps.push-token.outputs.token == ''", step["if"])

    def test_every_job_skips_its_own_repair_push(self):
        for job_id, job in DOC["jobs"].items():
            needs = job.get("needs") or []
            if needs and "!cancelled()" not in str(job.get("if", "")):
                continue  # skipped with the job it needs
            with self.subTest(job=job_id):
                condition = str(job.get("if", ""))
                self.assertIn("github.event.head_commit.author.name == 'github-actions[bot]'", condition)
                for prefix in SELF_COMMIT_PREFIXES:
                    self.assertIn(f"startsWith(github.event.head_commit.message, '{prefix}')", condition)

    def test_its_commits_carry_the_skipped_prefixes(self):
        # A commit message the guard does not know would start the workflow again on its own push.
        texts = (ROOT / ".github/workflows/cmux-next-base-autofix.yml").read_text() + (
            ROOT / "scripts/cmux-next/base-autofix-land.sh").read_text()
        messages = re.findall(r'git commit[^\n]*?-(?:a?m) "([^"$]*)', texts)
        self.assertTrue(messages)
        for message in messages:
            with self.subTest(message=message):
                self.assertTrue(message.startswith(SELF_COMMIT_PREFIXES), message)


DOC_NEXT = yaml.safe_load((ROOT / ".github/workflows/cmux-next.yml").read_text())

if __name__ == "__main__":
    unittest.main()
