#!/usr/bin/env python3
"""The iPhone INTERNAL archive takes the dedicated mini only while it can take the job, else Blacksmith.

Before, runs-on read vars.CI_IOS_INTERNAL_RUNNER (one mini's own runner label)
directly, and a set variable never falls through: every archive waited on that
mini (Leo, 2026-10-24: no job waits on one reserved machine).
"""

from __future__ import annotations

import base64
import contextlib
import datetime as dt
import gzip
import io
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
sys.path.insert(0, str(ROOT / "tests"))

import ios_internal_runner as picker  # noqa: E402
import workflow_jobs  # noqa: E402

LABEL = "glaeda-runner-mini-ios-internal"
WORKFLOW = ROOT / ".github" / "workflows" / "ios-internal-nightly.yml"


def runner(status: str = "online", busy: bool = False, label: str = LABEL) -> dict:
    return {"status": status, "busy": busy, "labels": [{"name": label}, {"name": "glaeda-ios-internal-next"}]}


class Clock:
    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.now += seconds


class Pick(unittest.TestCase):
    def pick(self, reads: list, label: str = LABEL) -> tuple[str, str, int]:
        clock, calls = Clock(), []

        def read():
            calls.append(1)
            return reads[min(len(calls), len(reads)) - 1]

        dedicated, why = picker.pick(label, read, sleep=clock.sleep, clock=clock)
        return dedicated, why, len(calls)

    def test_idle_mini_is_taken(self) -> None:
        self.assertEqual(self.pick([[runner()]])[0], LABEL)

    def test_offline_unread_or_unset_takes_blacksmith_at_once(self) -> None:
        self.assertEqual(self.pick([[runner("offline")]])[:1], ("",))
        self.assertEqual(self.pick([[]])[:1], ("",))
        self.assertEqual(self.pick([None])[:1], ("",))
        self.assertEqual(self.pick([[runner()]], label="")[:1], ("",))
        # Another runner's label does not count.
        self.assertEqual(self.pick([[runner(label="glaeda-runner-other")]])[:1], ("",))

    def test_busy_mini_is_waited_on_for_at_most_five_minutes(self) -> None:
        dedicated, why, calls = self.pick([[runner(busy=True)]])
        self.assertEqual(dedicated, "")
        self.assertIn("stayed busy", why)
        self.assertLessEqual(calls, picker.WAIT_SECONDS // picker.LOOK_SECONDS + 1)
        dedicated, _, calls = self.pick([[runner(busy=True)], [runner(busy=True)], [runner()]])
        self.assertEqual((dedicated, calls), (LABEL, 3))

    def test_several_minis_take_the_first_idle_in_order(self) -> None:
        # Leo, 2026-11-25: "Don't we have freed up Mac capacity?" The variable lists every
        # trusted builder, preferred first; a busy or offline first mini hands on to the next.
        other = "glaeda-runner-cmux23-ios-internal"
        both = f"{LABEL}, {other}"
        self.assertEqual(self.pick([[runner(), runner(label=other)]], label=both)[0], LABEL)
        dedicated, why, calls = self.pick([[runner(busy=True), runner(label=other)]], label=both)
        self.assertEqual((dedicated, calls), (other, 1))
        self.assertIn(f"`{other}` is online and idle", why)
        self.assertEqual(self.pick([[runner(label=other)]], label=both)[0], other)
        dedicated, why, _ = self.pick([[runner("offline"), runner("offline", label=other)]], label=both)
        self.assertEqual(dedicated, "")
        self.assertIn(f"`{LABEL}` is offline, `{other}` is offline", why)
        dedicated, why, calls = self.pick([[runner(busy=True)]], label=both)
        self.assertEqual(dedicated, "")
        self.assertIn("stayed busy", why)
        self.assertGreater(calls, 1)

    def test_labels_split_on_commas_and_spaces_and_drop_repeats(self) -> None:
        self.assertEqual(picker.labels_of("a,b  c,,a\n"), ["a", "b", "c"])
        self.assertEqual(picker.labels_of(" , "), [])

    def test_main_never_fails_and_writes_the_attempt(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "out")

            def broken(token, repo):
                raise RuntimeError("body with a token-like value")

            env = {"GITHUB_REPOSITORY": "o/r", "ROUTE_TOKEN": "t", "DEDICATED_LABEL": LABEL,
                   "GITHUB_RUN_ATTEMPT": "2", "GITHUB_OUTPUT": out}
            import contextlib
            import io
            printed = io.StringIO()
            with contextlib.redirect_stdout(printed):
                self.assertEqual(picker.main(env, read_runners=broken), 0)
            self.assertNotIn("token-like", printed.getvalue())
            self.assertEqual(Path(out).read_text(), "dedicated=\nattempt=2\nfallback=\n")
            Path(out).write_text("")
            self.assertEqual(picker.main(env, read_runners=lambda token, repo: [runner()]), 0)
            self.assertEqual(Path(out).read_text(), f"dedicated={LABEL}\nattempt=2\nfallback=\n")


class SharedFirstLook(unittest.TestCase):
    def document(self, *, busy=False, repository=True):
        row = dict(runner(busy=busy), id=1, name="synthetic-archive", os="macOS")
        doc = dict(schema="runner-state/v1", repository="manaflow-ai/cmux", complete=True,
                   generated_at=dt.datetime.now(dt.timezone.utc).isoformat(),
                   repository_runners=[row] if repository else [],
                   runner_groups={"glaeda-minis": [] if repository else [row]}, scale_sets={})
        return base64.b64encode(gzip.compress(json.dumps(doc).encode())).decode()

    def run_main(self, raw):
        env = dict(GITHUB_REPOSITORY="manaflow-ai/cmux", ROUTE_TOKEN="synthetic-token",
                   DEDICATED_LABEL=LABEL, CI_RUNNER_STATE=raw)
        clock, output = Clock(), io.StringIO()
        with mock.patch.object(picker.pool.GitHub, "_runner_pages", return_value=[runner()]) as pages, \
             contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(picker.main(env, sleep=clock.sleep, clock=clock), 0)
        return output.getvalue(), clock.now, pages

    def test_idle_document_is_first_look_without_a_repository_read(self):
        output, waited, pages = self.run_main(self.document())
        self.assertIn(f"archive runner: {LABEL}", output)
        self.assertEqual(waited, 0)
        pages.assert_not_called()

    def test_busy_document_is_rechecked_live_and_can_become_idle(self):
        output, waited, pages = self.run_main(self.document(busy=True))
        self.assertIn(f"archive runner: {LABEL}", output)
        self.assertEqual(waited, picker.LOOK_SECONDS)
        pages.assert_called_once_with("/repos/manaflow-ai/cmux/actions/runners")

    def test_document_preserves_repository_only_scope_and_invalid_state_falls_back(self):
        output, _, pages = self.run_main(self.document(repository=False))
        self.assertIn("archive runner: cmux-mac + xcode-27.0", output)
        pages.assert_not_called()
        for raw in ("", "invalid-base64"):
            with self.subTest(raw=raw):
                output, _, pages = self.run_main(raw)
                self.assertIn(f"archive runner: {LABEL}", output)
                pages.assert_called_once_with("/repos/manaflow-ai/cmux/actions/runners")


def census(rows: list[dict]) -> str:
    doc = dict(schema="runner-state/v1", repository="manaflow-ai/cmux", complete=True,
               generated_at=dt.datetime.now(dt.timezone.utc).isoformat(), repository_runners=[],
               runner_groups={"glaeda-minis": [dict(row, id=index + 1, name=f"synthetic-{index}", os="macOS")
                                               for index, row in enumerate(rows)]}, scale_sets={})
    return base64.b64encode(gzip.compress(json.dumps(doc).encode())).decode()


class NoCarrierReroutes(unittest.TestCase):
    """Leo, 2026-11-26: "refuse to queue a job for a label no live runner has". Run 45717448413's archive
    queued 2 h 23 min on cmux-mac + xcode-27.0 while no Mac offered Xcode 27."""

    FALLBACK = "blacksmith-6vcpu-macos-26"

    def fallback(self, raw: str, fallback: str = FALLBACK) -> tuple[str, str]:
        env = dict(GITHUB_REPOSITORY="manaflow-ai/cmux", CI_RUNNER_STATE=raw, FALLBACK_MAC=fallback)
        return picker.fleet_fallback(env)

    def mac(self, status: str = "online", *labels: str) -> dict:
        return {"status": status, "busy": True, "labels": [{"name": label} for label in labels]}

    def test_a_declared_xcode_label_no_online_runner_carries_takes_the_fallback(self) -> None:
        only_26 = census([self.mac("online", "glaeda-side-std-xcode-26.6", "xcode-26.6")])
        self.assertEqual(self.fallback(only_26)[0], self.FALLBACK)
        offline_27 = census([self.mac("offline", "glaeda-side-std-xcode-27.0", "xcode-27.0")])
        self.assertEqual(self.fallback(offline_27)[0], self.FALLBACK)
        self.assertIn("no online runner carries", self.fallback(offline_27)[1])

    def test_a_live_carrier_keeps_the_fleet_label(self) -> None:
        # Busy still counts: the job waits for a Mac that has Xcode 27, not for none.
        live = census([self.mac("online", "cmux-mac", "xcode-27.0")])
        self.assertEqual(self.fallback(live)[0], "")

    def test_no_reading_or_no_fallback_keeps_the_fleet_label(self) -> None:
        self.assertEqual(self.fallback("")[0], "")
        self.assertEqual(self.fallback("invalid-base64")[0], "")
        self.assertEqual(self.fallback(census([]), fallback="")[0], "")

    def test_main_writes_the_fallback_only_without_a_dedicated_pick(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "out")
            env = dict(GITHUB_REPOSITORY="manaflow-ai/cmux", GITHUB_OUTPUT=out, FALLBACK_MAC=self.FALLBACK,
                       CI_RUNNER_STATE=census([]), GITHUB_RUN_ATTEMPT="1")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(picker.main(env), 0)
            self.assertEqual(Path(out).read_text(), f"dedicated=\nattempt=1\nfallback={self.FALLBACK}\n")

    def test_the_checked_set_is_the_workflows_fleet_fallback(self) -> None:
        self.assertIn("fromJSON('" + json.dumps(list(picker.FLEET_XCODE), separators=(",", ":")) + "')",
                      WORKFLOW.read_text(encoding="utf-8"))


class Workflow(unittest.TestCase):
    def test_runs_on_never_reads_the_variable_directly(self) -> None:
        jobs = yaml.load(WORKFLOW.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)["jobs"]
        archive = jobs["archive"]
        cells = workflow_jobs.runs_on_cells(archive)
        self.assertIsNotNone(cells, "archive: runs-on reads a matrix value nothing resolves")
        self.assertEqual(len(cells), 1, cells)
        (runs_on,) = cells
        self.assertNotIn("CI_IOS_INTERNAL_RUNNER", runs_on)
        self.assertIn("needs.pick-archive-runner.outputs.attempt == format('{0}', github.run_attempt) && "
                      "needs.pick-archive-runner.outputs.dedicated != '' && "
                      "needs.pick-archive-runner.outputs.dedicated || ", runs_on)
        # The fallback must land on an Xcode 27 Mac: plain cmux-mac took 26.6-only Macs.
        # ... unless no online runner carries xcode-27.0: then the picker's fallback (a Blacksmith Mac).
        self.assertTrue(runs_on.rstrip("} ").endswith(
            "|| vars.CI_OVERFLOW_MAC || needs.pick-archive-runner.outputs.fallback != '' && "
            "needs.pick-archive-runner.outputs.fallback || fromJSON('[\"cmux-mac\",\"xcode-27.0\"]')"), runs_on)
        self.assertEqual(jobs["pick-archive-runner"]["outputs"]["fallback"], "${{ steps.pick.outputs.fallback }}")
        self.assertEqual(archive["needs"], "pick-archive-runner")
        self.assertIn("!cancelled()", archive["if"])
        self.assertIn("vars.CI_IOS_INTERNAL_RUNNER", jobs["pick-archive-runner"]["steps"][-1]["env"]["DEDICATED_LABEL"])


class ArchiveSource(unittest.TestCase):
    def test_same_commit_full_remote_sparse_remote_and_verified_mirror(self):
        archive = yaml.safe_load(WORKFLOW.read_text())["jobs"]["archive"]
        steps = {step.get("name"): step for step in archive["steps"]}
        kept = steps["Checkout from the verified fleet mirror"]["run"]
        cold = steps["Checkout the commit"]["run"]
        patterns = archive["env"]["ARCHIVE_PATHS"]
        self.assertIn('git sparse-checkout set --no-cone --stdin <<< "$ARCHIVE_PATHS"', cold)
        self.assertIn("--filter=blob:none", cold)
        self.assertIn("http.lowSpeedLimit=1024", cold)
        self.assertIn("http.lowSpeedTime=45", cold)
        self.assertIn("for wait in 0 10 30 60 120", cold)
        self.assertIn("git checkout -q --force --detach \"$SHA\"", cold)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            def git(cwd, *args, input=None):
                return subprocess.check_output(["git", *args],
                                               cwd=cwd, text=True, input=input).strip()

            git(root, "init", "-q", "seed")
            seed = root / "seed"
            input_file = "cmux-next-ios/App/Info.plist"
            catalog = "cmux-next-ios/verify/nested/example.xcstrings"
            media = "cmux-next-ios/verify/nested/recording.mp4"
            build_dirs = ("Packages", "vendor/stack-auth-swift-sdk-prerelease", "AppIcon.icon", "cmux-tui",
                          "schemas", "backend/catalog", "backend/packages", "plans/cmux-next", "skills", "mux", "samples")
            build_inputs = [f"{directory}/input" for directory in build_dirs]
            for name in [input_file, catalog, media, "web/unrelated.bin", ".gitmodules", *build_inputs]:
                path = seed / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(os.urandom(2**20) if name.endswith((".bin", ".mp4")) else b"")
            git(seed, "add", ".")
            git(seed, "-c", "user.name=test", "-c", "user.email=test@example.org", "commit", "-qm", "fixture")
            sha = git(seed, "rev-parse", "HEAD")
            mirror = root / "cmux.git"
            git(root, "clone", "-q", "--bare", "seed", str(mirror))
            marker = mirror / "glaeda-verified"
            output = root / "output"
            env = dict(os.environ, ARCHIVE_PATHS=patterns, SHA=sha, RUNNER_TEMP=tmp,
                       GITHUB_OUTPUT=str(output), GLAEDA_GIT_MIRROR_DIR=tmp, REPO_URL="https://invalid.example/cmux")
            def warm():
                output.write_text("")
                subprocess.run(["bash", "-c", kept], cwd=root, env=env, check=True)
                return output.read_text().strip()
            self.assertEqual(warm(), "")
            marker.touch()
            (mirror / "glaeda-repair-pending").touch()
            self.assertEqual(warm(), "")
            (mirror / "glaeda-repair-pending").unlink()
            env["SHA"] = "1" * 40
            self.assertEqual(warm(), "")
            env["SHA"] = sha
            for mode in ("full", "sparse", "mirror"):
                start = time.monotonic()
                if mode == "mirror":
                    result = warm()
                    self.assertTrue(result.startswith("directory="), result)
                    src = Path(result.split("=", 1)[1])
                    self.assertEqual(git(src, "remote", "get-url", "origin"), env["REPO_URL"])
                    self.assertFalse((src / ".git/objects/info/alternates").exists())
                else:
                    src = root / mode
                    git(root, "init", "-q", mode)
                    git(src, "remote", "add", "origin", mirror.as_uri())
                    git(src, "config", "remote.origin.uploadpack", "git -c uploadpack.allowFilter=true upload-pack")
                    args = []
                    if mode == "sparse":
                        git(src, "sparse-checkout", "set", "--no-cone", "--stdin", input=patterns)
                        args.append("--filter=blob:none")
                    git(src, "fetch", "-q", "--depth=1", "--no-tags", *args, "origin", sha)
                    git(src, "checkout", "-q", "--detach", sha)
                elapsed = time.monotonic() - start
                self.assertEqual(git(src, "rev-parse", "HEAD"), sha)
                self.assertTrue((src / input_file).is_file())
                self.assertTrue((src / catalog).is_file())
                self.assertEqual((src / media).exists(), mode == "full")
                self.assertEqual((src / "web/unrelated.bin").exists(), mode == "full")
                if mode != "full":
                    # The archive step must work even when neither origin nor the mirror
                    # is accessible. Exercise the build script's exclusion of verification media.
                    git(src, "remote", "set-url", "origin", str(root / "offline.git"))
                    build_script = (ROOT / "cmux-next-ios/scripts/testflight-build.sh").read_text()
                    source_step = build_script.split("# --- Source (the commit only)", 1)[1].split("\n", 1)[1]
                    source_step = source_step.split("# --- CmuxMobileLinkFFI", 1)[0]
                    work = root / (mode + "-build")
                    (work / "src").mkdir(parents=True)
                    (src / input_file).write_text("local edit")
                    subprocess.run(["bash", "-euo", "pipefail", "-c", source_step], cwd=src, check=True,
                                   env=dict(os.environ, repo=str(src), sha=sha, private=str(work), work=str(work),
                                            CMUX_INTERNAL_SPARSE_ARCHIVE=steps["Archive"]["env"]["CMUX_INTERNAL_SPARSE_ARCHIVE"]))
                    self.assertEqual((work / "src" / input_file).read_bytes(), b"")
                    for name in build_inputs:
                        self.assertTrue((work / "src" / name).is_file(), name)
                    self.assertFalse((work / "src" / media).exists())
                size = sum(p.stat().st_size for p in (src / ".git/objects").rglob("*") if p.is_file())
                print(f"archive fixture {sha} {mode}: {elapsed:.3f}s, {size} object bytes")
                if mode != "full":
                    self.assertLess(size, 2**20)


class StoreSdk(unittest.TestCase):
    """ITMS-90725 (2026-11-22): every INTERNAL upload built with Xcode 26.6 (iOS 26.5 SDK)
    mailed the team. The archive and the signer pin a released Xcode 27 before Select Xcode,
    and the archive refuses an app whose DTSDKName is below iphoneos27."""

    def steps(self, job: str) -> list[dict]:
        return yaml.safe_load(WORKFLOW.read_text())["jobs"][job]["steps"]

    def test_archive_and_signer_try_usable_release_sdks(self) -> None:
        steps = [next(s for s in self.steps(job) if s.get("name") == "Select Xcode")
                 for job in ("archive", "upload")]
        self.assertEqual(steps[0]["run"], steps[1]["run"])
        for step in steps:
            self.assertEqual(step["env"]["CMUX_CI_SKIP_XCODE_SELECT"], "1")
            self.assertIn("./scripts/select-ci-xcode.sh", step["shell"])
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            select = root / "select"
            select.write_text('#!/bin/sh\nprintf "%s" "$CMUX_CI_XCODE_APP" > "$PICK"\n')
            select.chmod(0o755)
            for tool, body in {"xcodebuild": 'cat "$DEVELOPER_DIR/version"',
                               "xcrun": 'cat "$DEVELOPER_DIR/$2"'}.items():
                stub = root / tool
                stub.write_text("#!/bin/sh\n" + body + "\n")
                stub.chmod(0o755)
            def install(name, version, sdk):
                dev = root / name / "Contents/Developer"
                dev.mkdir(parents=True)
                (dev / "version").write_text("Xcode " + version)
                (dev / "iphoneos").write_text(sdk)
                (dev / "macosx").write_text("27.0")
                return root / name
            install("Xcode_27.1.app", "27.1", "26.5")
            install("Xcode_27.4.app", "27.4", "26.5")
            broken = install("Xcode_broken.app", "27", "27")
            (broken / "Contents/Developer/version").unlink()
            beta = install("Xcode_27.8_Beta.app", "27.8", "27.8")
            install("Xcode_new.app", "27.9 beta 1", "27.9")
            (root / "Xcode.app").symlink_to(beta)
            release = install("Xcode_27.3.app", "27.3", "27.3")
            env = dict(os.environ, CMUX_XCODE_APPLICATIONS_DIR=tmp, PICK=str(root / "pick"),
                       PATH=tmp + os.pathsep + os.environ["PATH"])
            for configured in (root / "missing.app", root / "Xcode.app", release):
                env["IOS_STORE_XCODE_APP"] = str(configured)
                subprocess.run([sys.executable, "-I", "-c", steps[0]["run"], str(select)], env=env, check=True)
                self.assertEqual((root / "pick").read_text(), str(release))
            (release / "Contents/Developer/iphoneos").unlink()
            failed = subprocess.run([sys.executable, "-I", "-c", steps[0]["run"], str(select)],
                                    env=env, capture_output=True, text=True)
            self.assertNotEqual(failed.returncode, 0)
            self.assertIn("xcode-pin-missing", failed.stderr)

    def test_archive_refuses_an_sdk_below_ios_27(self) -> None:
        run = next(s["run"] for s in self.steps("archive") if s.get("name") == "App Store review rules (built app)")
        self.assertIn("Print :DTSDKName", run)
        self.assertIn("iphoneos27*", run)


if __name__ == "__main__":
    unittest.main()
