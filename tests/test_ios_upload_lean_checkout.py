#!/usr/bin/env python3
"""Pin the lean macOS checkout of the two iOS TestFlight upload workflows.

ios-testflight.yml (CMUX INTERNAL, every 20 min) and ios-appstore-upload.yml
(cmux.app, hourly) used to clone with fetch-depth 0 + recursive submodules
(~12 min) and install zig unconditionally (~6 min) on the constrained macOS
pool. The policy now is:

- the macOS upload checkout is shallow (fetch-depth 1), with no submodules and
  no tags;
- the prebuilt GhosttyKit.xcframework is downloaded first, keyed by the ghostty
  gitlink, and only when that fails does the job fetch the ghostty source
  (depth 1), install zig, and run ensure-ghosttykit.sh from source;
- the only history the upload reads (the TestFlight notes range) is fetched by
  ios/scripts/fetch-testflight-notes-history.sh, which these tests exercise
  against a real shallow clone.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = {
    "ios-testflight.yml": "upload",
    "ios-appstore-upload.yml": "upload",
}
FETCH_SCRIPT = ROOT / "ios/scripts/fetch-testflight-notes-history.sh"
NOTES_SCRIPT = ROOT / "ios/scripts/generate-testflight-notes.sh"
PREBUILT_IF = "${{ steps.ghosttykit_prebuilt.outputs.available != 'true' }}"


def load(name):
    return yaml.safe_load((ROOT / ".github/workflows" / name).read_text(encoding="utf-8"))


def step_index(steps, name):
    for index, step in enumerate(steps):
        if step.get("name") == name:
            return index
    raise AssertionError(f"missing step {name!r}")


def run_text(step):
    return step.get("run") or ""


class PublicUploadDecisionTests(unittest.TestCase):
    def decision(self, files=None, event="schedule", baseline="base", broken=False, retry=False):
        import json
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake = root / "gh"
            fake.write_text("#!/usr/bin/env python3\n" + r"""
import json, os, sys
args = ' '.join(sys.argv[1:])
if 'compare/' in args and '/compare/' + os.environ['BASE'] + '...head' not in args:
    raise SystemExit('wrong upload comparison baseline')
if 'compare/' in args:
    if os.environ['BROKEN'] == '1': sys.exit(1)
    print(json.dumps({'status': 'ahead', 'files': json.loads(os.environ['FILES'])}))
elif '/artifacts?' in args:
    print(os.environ['BASE'])
elif '/runs/123/artifacts' in args:
    print('456')
elif sys.argv[1:3] == ['run', 'download']:
    from pathlib import Path
    target = Path(sys.argv[sys.argv.index('--dir') + 1])
    (target / 'upload.json').write_text(json.dumps({'sha': 'head', 'app_id': '6783338052', 'build_number': '12345'}))
elif 'status=success' in args:
    print('previous-skipped-run')
elif 'status=completed' in args:
    if os.environ['RETRY'] == '1': print('123')
else:
    raise SystemExit('unexpected API: ' + args)
""")
            fake.chmod(0o755)
            output = root / "output"
            summary = root / "summary"
            result = subprocess.run(
                ["bash", "-c", load("ios-appstore-upload.yml")["jobs"]["decide"]["steps"][0]["run"]],
                env={**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"],
                     "GITHUB_OUTPUT": str(output), "GITHUB_STEP_SUMMARY": str(summary),
                     "RUNNER_TEMP": str(root), "REPOSITORY": "test/repo", "HEAD_SHA": "head",
                     "EVENT_NAME": event, "BASE": baseline, "BROKEN": str(int(broken)), "RETRY": str(int(retry)),
                     "FILES": json.dumps(files if files is not None else [])},
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            return dict(line.split("=", 1) for line in output.read_text().splitlines())

    def test_public_skips_unrelated_changes(self):
        for path in ["web/app/page.tsx", "docs/guide.md", "tests/test_ci.py", ".github/workflows/ci.yml"]:
            with self.subTest(path=path):
                self.assertEqual(self.decision([{"filename": path}])["upload"], "false")

    def test_public_retry_assignment_precedes_irrelevant_change_skip(self):
        output = self.decision([{"filename": "web/page.tsx"}], retry=True)
        self.assertEqual(output, {"last_upload_sha": "base", "upload": "false", "retry_build_number": "12345"})

    def test_public_preserves_build_inputs(self):
        for path in ["ios/cmuxPackage/Package.swift", "Packages/macOS/CmuxPhonePush/Package.swift",
                     "Packages/Shared/CMUXMobileCore/Protocol.swift", "Sources/Mobile/Host.swift",
                     "scripts/lib/verify-ios-release-origins.sh", ".github/scripts/install-app-store-provisioning-profile.sh",
                     ".github/workflows/ios-appstore-upload.yml", "ghostty", "unknown-new-input"]:
            with self.subTest(path=path):
                self.assertEqual(self.decision([{"filename": path}])["upload"], "true")

    def test_public_rename_out_of_ios_still_builds(self):
        self.assertEqual(self.decision([{"filename": "docs/old", "previous_filename": "ios/old"}])["upload"], "true")

    def test_public_uncertain_comparisons_and_manual_dispatch_build(self):
        files = [{"filename": "web/page.tsx"}]
        self.assertEqual(self.decision(files, broken=True)["upload"], "true")
        self.assertEqual(self.decision(files, baseline="")["upload"], "true")
        self.assertEqual(self.decision(files, event="workflow_dispatch")["upload"], "true")
        self.assertEqual(self.decision(files * 300)["upload"], "true")

    def upload_notes(self, root, decision, build_number=""):
        """Run the workflow wiring, substituting only the expensive upload."""
        workflow = load("ios-appstore-upload.yml")["jobs"]
        context = {
            "runner.temp": str(root),
            "github.event.inputs.build_number": build_number,
            **{f"steps.decide.outputs.{key}": value for key, value in decision.items()},
        }

        def resolve(value):
            return re.sub(r"\$\{\{\s*(.*?)\s*\}\}",
                          lambda match: context.get(match[1], ""), str(value))

        context.update({
            f"needs.decide.outputs.{key}": resolve(value)
            for key, value in workflow["decide"]["outputs"].items()
        })
        scripts = root / "ios/scripts"
        scripts.mkdir(parents=True, exist_ok=True)
        shutil.copy2(FETCH_SCRIPT, scripts / FETCH_SCRIPT.name)
        uploader = scripts / "upload-testflight.sh"
        uploader.write_text("#!/usr/bin/env python3\n" + r'''
import json, os, subprocess, sys
from pathlib import Path
args = sys.argv[1:]
Path(os.environ["CAPTURE_ARGS"]).write_text(json.dumps(args))
if "--notes-from-range" in args:
    base = args[args.index("--notes-from-range") + 1]
    notes = subprocess.check_output(
        ["bash", os.environ["NOTES_SCRIPT"], base, "--audience", "internal"], text=True)
else:
    notes = "fixed changelog entry\n"
Path(os.environ["CAPTURE_NOTES"]).write_text(notes)
Path(os.environ["CMUX_BUILD_NUMBER_OUT_FILE"]).write_text("12345\n")
''')
        uploader.chmod(0o755)
        env = {
            **os.environ, "RUNNER_TEMP": str(root),
            "GITHUB_OUTPUT": str(root / "upload-output"),
            "CAPTURE_ARGS": str(root / "upload-args.json"),
            "CAPTURE_NOTES": str(root / "notes.txt"),
            "NOTES_SCRIPT": str(NOTES_SCRIPT),
        }
        for step in workflow["upload"]["steps"]:
            if step.get("name") == "Fetch TestFlight notes history":
                self.assertLessEqual(step["timeout-minutes"], 5)
                self.assertIs(step["continue-on-error"], True)
            elif step.get("id") != "upload":
                continue
            result = subprocess.run(
                ["bash", "-c", step["run"]], cwd=root,
                env={**env, **{key: resolve(value) for key, value in step["env"].items()}},
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
        return (root / "notes.txt").read_text(), json.loads((root / "upload-args.json").read_text())

    def test_official_upload_generates_internal_notes_since_its_last_upload(self):
        for event in ("schedule", "workflow_dispatch"):
            with tempfile.TemporaryDirectory() as directory, self.subTest(event=event):
                root = Path(directory)
                src, shas = build_remote(
                    root, [START + i * HOUR for i in range(6)],
                    {0: "ios/old.swift", 2: "ios/new.swift", 3: "web/page.tsx",
                     4: "Packages/iOS/New.swift"},
                )
                base = shas[1]
                clone = shallow_clone(root, src)
                decision = self.decision([{"filename": "ios/new.swift"}], event=event, baseline=base)
                actual, args = self.upload_notes(clone, decision, build_number="12345")
                self.assertEqual(actual, notes(src, base))
                self.assertIn("ios: change 4 (#4)", actual)
                self.assertNotIn("change 0", actual)
                self.assertNotIn("change 3", actual)
                self.assertEqual(args, ["--lane", "appstore", "--signing", "manual",
                                        "--notes-from-range", base, "--build-number", "12345"])

    def test_official_first_upload_keeps_internal_changelog_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            decision = self.decision(event="workflow_dispatch", baseline="")
            actual, args = self.upload_notes(Path(directory), decision)
            self.assertEqual(actual, "fixed changelog entry\n")
            self.assertEqual(args, ["--lane", "appstore", "--signing", "manual"])


class WorkflowPolicyTests(unittest.TestCase):
    def test_macos_checkouts_are_shallow_without_submodules(self):
        for name in WORKFLOWS:
            for job_name, job in load(name)["jobs"].items():
                if "macos" not in str(job.get("runs-on", "")).lower():
                    continue
                for step in job.get("steps", []):
                    if not str(step.get("uses", "")).startswith("actions/checkout@"):
                        continue
                    options = step.get("with") or {}
                    with self.subTest(workflow=name, job=job_name):
                        self.assertEqual(str(options.get("fetch-depth")), "1")
                        self.assertNotIn("submodules", options)
                        self.assertNotIn("fetch-tags", options)

    def test_no_recursive_submodule_or_unshallow_commands(self):
        for name in WORKFLOWS:
            text = (ROOT / ".github/workflows" / name).read_text(encoding="utf-8")
            with self.subTest(workflow=name):
                self.assertNotIn("--recursive", text)
                self.assertNotIn("--unshallow", text)
                self.assertNotIn("fetch-depth: 0", text)

    def test_zig_and_ghostty_source_only_on_prebuilt_fallback(self):
        for name, job_name in WORKFLOWS.items():
            steps = load(name)["jobs"][job_name]["steps"]
            download = step_index(steps, "Download prebuilt GhosttyKit")
            zig = step_index(steps, "Fetch ghostty and install zig for GhosttyKit fallback")
            build = step_index(steps, "Build fallback GhosttyKit")
            verify = step_index(steps, "Verify provisioned GhosttyKit")
            with self.subTest(workflow=name):
                self.assertLess(download, zig)
                self.assertLess(zig, build)
                self.assertLess(build, verify)
                self.assertEqual(steps[download].get("id"), "ghosttykit_prebuilt")
                self.assertNotIn("if", steps[download])
                self.assertIn("git rev-parse HEAD:ghostty", run_text(steps[download]))
                self.assertIn("download-prebuilt-ghosttykit.sh", run_text(steps[download]))

                self.assertEqual(steps[zig].get("if"), PREBUILT_IF)
                zig_run = run_text(steps[zig])
                init = zig_run.index("git submodule update --init --depth 1 ghostty")
                self.assertLess(init, zig_run.index("./scripts/install-zig-ci.sh"))

                self.assertEqual(steps[build].get("if"), PREBUILT_IF)
                self.assertEqual(steps[build]["env"]["CMUX_GHOSTTYKIT_NO_PREBUILT"], "1")
                self.assertIn("./scripts/ensure-ghosttykit.sh", run_text(steps[build]))

                # No other step in the job installs zig, initializes submodules,
                # or runs the from-source provisioner.
                for index, step in enumerate(steps):
                    if index in (zig, build):
                        continue
                    text = run_text(step)
                    self.assertNotIn("install-zig-ci.sh", text, step.get("name"))
                    self.assertNotIn("ensure-ghosttykit.sh", text, step.get("name"))
                    self.assertNotIn("git submodule", text, step.get("name"))

    def test_download_step_reports_availability(self):
        name = "ios-appstore-upload.yml"
        steps = load(name)["jobs"]["upload"]["steps"]
        script = run_text(steps[step_index(steps, "Download prebuilt GhosttyKit")])
        for stub_exit, expected in ((0, "true"), (1, "false")):
            with tempfile.TemporaryDirectory() as repo, self.subTest(stub_exit=stub_exit):
                git(repo, "init", "-q", "-b", "main")
                ghostty_sha = "c5c31ce819131ebb2deb4c4d4a75beffe4340c8d"
                git(repo, "update-index", "--add", "--cacheinfo",
                    f"160000,{ghostty_sha},ghostty")
                git(repo, "-c", "user.email=t@t.test", "-c", "user.name=T",
                    "commit", "-q", "-m", "gitlink")
                scripts = Path(repo, "scripts")
                scripts.mkdir()
                stub = scripts / "download-prebuilt-ghosttykit.sh"
                stub.write_text(
                    "#!/bin/sh\n"
                    'printf "%s %s %s\\n" "$GHOSTTY_SHA" "$GHOSTTYKIT_DOWNLOAD_RETRIES" '
                    '"$GHOSTTYKIT_DOWNLOAD_MAX_TIME" > seen.txt\n'
                    f"exit {stub_exit}\n"
                )
                stub.chmod(0o755)
                output = Path(repo, "github_output")
                result = subprocess.run(
                    ["bash", "-c", script], cwd=repo, capture_output=True, text=True,
                    env={**os.environ, "GITHUB_OUTPUT": str(output)},
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output.read_text().strip(), f"available={expected}")
                self.assertEqual(
                    Path(repo, "seen.txt").read_text().split(),
                    [ghostty_sha, "3", "300"],
                )

    def test_testflight_fetches_only_the_notes_range(self):
        steps = load("ios-testflight.yml")["jobs"]["upload"]["steps"]
        distribution = step_index(steps, "Resolve TestFlight distribution")
        history = step_index(steps, "Fetch TestFlight notes history")
        upload = step_index(steps, "Archive, export, and upload to TestFlight")
        self.assertLess(distribution, history)
        self.assertLess(history, upload)
        step = steps[history]
        self.assertIn("needs.decide.outputs.last_uploaded_sha != ''", step["if"])
        self.assertIn("marketing_version_override", step["if"])
        self.assertEqual(
            step["env"]["LAST_UPLOADED_SHA"], "${{ needs.decide.outputs.last_uploaded_sha }}"
        )
        self.assertIn("./ios/scripts/fetch-testflight-notes-history.sh", run_text(step))
        # Best effort and bounded: a slow or failed fetch never blocks the upload.
        self.assertLessEqual(int(step["timeout-minutes"]), 5)
        self.assertIs(step["continue-on-error"], True)
        self.assertIn('--notes-from-range "$LAST_UPLOADED_SHA"', run_text(steps[upload]))

def git(repo, *args, env=None):
    return subprocess.run(
        ["git", "-C", str(repo), *args], check=True, capture_output=True, text=True, env=env,
    ).stdout.strip()


def build_remote(root, dates, paths=None):
    """Create a linear repo whose i-th commit has committer date dates[i].

    Built with one `git fast-import` call so the suite stays fast.
    """
    src = Path(root, "src")
    git(root, "init", "-q", "-b", "main", str(src))
    stream = []
    for index, date in enumerate(dates):
        path = (paths or {}).get(index, "README.md")
        message = f"ios: change {index} (#{index})".encode()
        content = f"{index}\n".encode()
        stream.append(b"commit refs/heads/main\n")
        stream.append(f"mark :{index + 1}\n".encode())
        stream.append(f"author T <t@t.test> {date} +0000\n".encode())
        stream.append(f"committer T <t@t.test> {date} +0000\n".encode())
        stream.append(f"data {len(message)}\n".encode() + message + b"\n")
        if index:
            stream.append(f"from :{index}\n".encode())
        stream.append(f"M 100644 inline {path}\ndata {len(content)}\n".encode() + content + b"\n")
    subprocess.run(["git", "-C", str(src), "fast-import", "--quiet"],
                   input=b"".join(stream), check=True, capture_output=True)
    git(src, "reset", "-q", "--hard", "main")
    git(src, "config", "uploadpack.allowFilter", "true")
    shas = git(src, "rev-list", "--reverse", "main").split()
    return src, shas


def build_merge_remote(root):
    """main m0..m99 (hourly) with a side branch merged at m80.

    The side branch forks at m10, merges m30 back in, and has five ios/
    commits dated between m10 and m31: all older than the base (m60) minus the
    one-day --shallow-since margin, and none of them ancestors of the base.
    Returns (src, main shas by index).
    """
    src = Path(root, "src")
    git(root, "init", "-q", "-b", "main", str(src))
    stream = []
    marks = {}

    def commit(ref, key, date, message, parents, path):
        mark = len(marks) + 1
        marks[key] = mark
        body = message.encode()
        content = f"{key}\n".encode()
        stream.append(f"commit {ref}\nmark :{mark}\n".encode())
        stream.append(f"author T <t@t.test> {date} +0000\n".encode())
        stream.append(f"committer T <t@t.test> {date} +0000\n".encode())
        stream.append(f"data {len(body)}\n".encode() + body + b"\n")
        if parents:
            stream.append(f"from :{marks[parents[0]]}\n".encode())
            for parent in parents[1:]:
                stream.append(f"merge :{marks[parent]}\n".encode())
        for name in [path] if isinstance(path, str) else path:
            stream.append(
                f"M 100644 inline {name}\ndata {len(content)}\n".encode() + content + b"\n"
            )

    side = []
    for i in range(100):
        if i == 81:
            commit("refs/heads/main", "merge", START + 80 * HOUR + 1800,
                   "Merge branch 'side'", ["m80", side[-1]],
                   # A real merge carries the side branch's files into main.
                   [f"ios/side{k}.swift" for k in range(5)])
        parents = [] if i == 0 else (["merge"] if i == 81 else [f"m{i - 1}"])
        path = f"ios/m{i}.swift" if i > 60 and i % 7 == 0 else "README.md"
        commit("refs/heads/main", f"m{i}", START + i * HOUR,
               f"ios: main change {i} (#{i})", parents, path)
        if i == 10:
            for k in range(3):
                key = f"s{k}"
                commit("refs/heads/side", key, START + 10 * HOUR + (k + 1) * 600,
                       f"ios: side change {k}", [side[-1] if side else "m10"],
                       f"ios/side{k}.swift")
                side.append(key)
        if i == 30:
            commit("refs/heads/side", "side-sync", START + 30 * HOUR + 1800,
                   "Merge main into side", [side[-1], "m30"], "sync.txt")
            side.append("side-sync")
            for k in range(3, 5):
                key = f"s{k}"
                commit("refs/heads/side", key, START + 30 * HOUR + (k + 1) * 600,
                       f"ios: side change {k}", [side[-1]], f"ios/side{k}.swift")
                side.append(key)
    subprocess.run(["git", "-C", str(src), "fast-import", "--quiet"],
                   input=b"".join(stream), check=True, capture_output=True)
    git(src, "reset", "-q", "--hard", "main")
    git(src, "config", "uploadpack.allowFilter", "true")
    main = {}
    for line in git(src, "log", "--first-parent", "--format=%H %s", "main").splitlines():
        sha, subject = line.split(" ", 1)
        if subject.startswith("ios: main change "):
            main[int(subject.split()[3])] = sha
    return src, main


def shallow_clone(root, src):
    clone = Path(root, "clone")
    subprocess.run(
        ["git", "clone", "-q", "--depth", "1", "--no-tags", f"file://{src}", str(clone)],
        check=True, capture_output=True,
    )
    return clone


def fetch_history(clone, base, **env):
    return subprocess.run(
        ["bash", str(FETCH_SCRIPT), base], cwd=clone, capture_output=True, text=True,
        env={**os.environ, **env},
    )


def is_ancestor(clone, base):
    return subprocess.run(
        ["git", "-C", str(clone), "merge-base", "--is-ancestor", base, "HEAD"],
        capture_output=True,
    ).returncode == 0


def notes(clone, base):
    return subprocess.run(
        ["bash", str(NOTES_SCRIPT), base, "--audience", "internal"], cwd=clone,
        capture_output=True, text=True, check=True,
    ).stdout


HOUR = 3600
DAY = 24 * HOUR
START = 1_700_000_000


class FetchNotesHistoryTests(unittest.TestCase):
    def test_script_is_executable(self):
        self.assertTrue(os.access(FETCH_SCRIPT, os.X_OK))

    def test_fetches_range_and_notes_match_a_full_clone(self):
        with tempfile.TemporaryDirectory() as root:
            dates = [START + i * HOUR for i in range(120)]
            paths = {i: f"ios/f{i}.swift" for i in range(80, 120, 5)}
            src, shas = build_remote(root, dates, paths)
            base = shas[79]
            clone = shallow_clone(root, src)
            self.assertFalse(_has(clone, base))

            result = fetch_history(clone, base)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(is_ancestor(clone, base))
            self.assertEqual(git(clone, "rev-list", "--count", f"{base}..HEAD"), "40")
            # The shallow checkout stays small: the range plus about a day.
            self.assertLess(int(git(clone, "rev-list", "--count", "HEAD")), 80)
            self.assertEqual(notes(clone, base), notes(src, base))
            self.assertIn("ios: change 115 (#115)", notes(clone, base))

    def test_non_monotonic_dates_fall_back_to_bounded_deepening(self):
        with tempfile.TemporaryDirectory() as root:
            # Commits after the base carry committer dates two days before it, so
            # --shallow-since cannot reach the base on its own (but they are
            # within the give-up slack, so deepening continues).
            dates = [START + i * HOUR for i in range(200)]
            for i in range(151, 200):
                dates[i] = START + 150 * HOUR - 2 * DAY + i
            src, shas = build_remote(root, dates)
            base = shas[150]
            clone = shallow_clone(root, src)
            result = fetch_history(clone, base, CMUX_NOTES_HISTORY_DEEPEN_STEP="20")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(is_ancestor(clone, base))
            self.assertEqual(notes(clone, base), notes(src, base))

    def test_deepening_is_bounded(self):
        with tempfile.TemporaryDirectory() as root:
            dates = [START + i * HOUR for i in range(200)]
            for i in range(51, 200):
                dates[i] = START + 50 * HOUR - 2 * DAY + i
            src, shas = build_remote(root, dates)
            base = shas[50]
            clone = shallow_clone(root, src)
            result = fetch_history(
                clone, base,
                CMUX_NOTES_HISTORY_DEEPEN_STEP="10", CMUX_NOTES_HISTORY_MAX_COMMITS="30",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("not reached within 30", result.stderr)
            self.assertFalse(is_ancestor(clone, base))
            self.assertIn("no notable iOS changes", notes(clone, base))

    def test_merged_side_branch_older_than_cutoff_is_fetched(self):
        with tempfile.TemporaryDirectory() as root:
            src, main = build_merge_remote(root)
            base = main[60]
            full_range = git(src, "rev-list", "--count", f"{base}..HEAD")
            expected = notes(src, base)
            for k in range(5):
                self.assertIn(f"ios: side change {k}", expected)

            clone = shallow_clone(root, src)
            result = fetch_history(clone, base, CMUX_NOTES_HISTORY_DEEPEN_STEP="5")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(is_ancestor(clone, base))
            self.assertEqual(git(clone, "rev-list", "--count", f"{base}..HEAD"), full_range)
            self.assertEqual(notes(clone, base), expected)
            self.assertNotIn("warning", result.stderr)

    def test_merged_side_branch_bound_is_logged(self):
        with tempfile.TemporaryDirectory() as root:
            src, main = build_merge_remote(root)
            base = main[60]
            clone = shallow_clone(root, src)
            result = fetch_history(
                clone, base,
                CMUX_NOTES_HISTORY_DEEPEN_STEP="1", CMUX_NOTES_HISTORY_MAX_COMMITS="1",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            # --shallow-since cuts main at the merge, so the one-commit bound is
            # hit either before or after the base connects; both are logged.
            self.assertRegex(
                result.stderr,
                r"not reached within 1 extra commits|range may still be incomplete after 1 extra",
            )
            notes(clone, base)  # still generates (possibly the fallback line)

    def test_force_pushed_base_stops_without_walking_history(self):
        with tempfile.TemporaryDirectory() as root:
            src, shas = build_remote(root, [START + i * HOUR for i in range(300)])
            # The previous beta's commit was on a branch that main no longer has.
            git(src, "checkout", "-q", "-b", "gone", shas[250])
            Path(src, "gone.txt").write_text("gone\n")
            git(src, "add", "gone.txt")
            date = f"@{START + 250 * HOUR + 60} +0000"
            subprocess.run(
                ["git", "-C", str(src), "-c", "user.email=t@t.test", "-c", "user.name=T",
                 "commit", "-q", "-m", "gone"],
                check=True, capture_output=True,
                env={**os.environ, "GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date},
            )
            base = git(src, "rev-parse", "HEAD")
            git(src, "checkout", "-q", "main")
            git(src, "branch", "-q", "-D", "gone")  # unreachable, still fetchable by SHA
            git(src, "config", "uploadpack.allowAnySHA1InWant", "true")

            clone = shallow_clone(root, src)
            result = fetch_history(clone, base, CMUX_NOTES_HISTORY_DEEPEN_STEP="10")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("is not an ancestor of HEAD", result.stderr)
            # One deepen reaches the fork point; the rest of main is never walked.
            self.assertLess(int(git(clone, "rev-list", "--count", "HEAD")), 100)
            self.assertIn("no notable iOS changes", notes(clone, base))

    def test_unrelated_base_gives_up_once_boundaries_pass_the_slack(self):
        with tempfile.TemporaryDirectory() as root:
            src, shas = build_remote(root, [START + i * HOUR for i in range(300)])
            # A base from an unrelated history never connects to HEAD, so only
            # the date slack stops the walk.
            other_root = Path(root, "other")
            other_root.mkdir()
            other, other_shas = build_remote(other_root, [START + 250 * HOUR])
            git(src, "fetch", "-q", str(other), "main:refs/heads/other")
            base = other_shas[0]
            clone = shallow_clone(root, src)
            result = fetch_history(
                clone, base,
                CMUX_NOTES_HISTORY_DEEPEN_STEP="10", CMUX_NOTES_HISTORY_DATE_SLACK_DAYS="1",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("over 1 days older", result.stderr)
            self.assertLess(int(git(clone, "rev-list", "--count", "HEAD")), 150)
            self.assertIn("no notable iOS changes", notes(clone, base))

    def test_empty_and_unknown_bases_are_non_fatal_no_ops(self):
        with tempfile.TemporaryDirectory() as root:
            src, _ = build_remote(root, [START + i * HOUR for i in range(5)])
            clone = shallow_clone(root, src)
            for base in ("", "0" * 40, "not-a-sha"):
                with self.subTest(base=base):
                    result = fetch_history(clone, base)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(git(clone, "rev-list", "--count", "HEAD"), "1")
                    self.assertIn("no notable iOS changes", notes(clone, base))

    def test_full_clone_is_left_alone(self):
        with tempfile.TemporaryDirectory() as root:
            src, shas = build_remote(root, [START + i * HOUR for i in range(5)])
            result = fetch_history(src, shas[1])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("full history", result.stderr)


def _has(clone, sha):
    return subprocess.run(
        ["git", "-C", str(clone), "cat-file", "-e", f"{sha}^{{commit}}"], capture_output=True,
    ).returncode == 0


if __name__ == "__main__":
    unittest.main()
