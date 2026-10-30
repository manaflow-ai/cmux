#!/usr/bin/env python3
"""The DEV Release compile records the fleet whole-app build's REF, off by default and never in its way.

scripts/cmux-next/hybrid_ref_capture.py and the cmux-scheme-compile steps around it:

- the REF key moves with Package.resolved, cmux.xcodeproj, a macOS xcconfig, a DEV build setting
  or the toolchain, and not with a source file or an iOS xcconfig;
- a module whose SwiftDriver task has no frontend compile line makes the capture incomplete, and
  an incomplete capture uploads nothing;
- a complete capture packs the build without objects, the compilation cache, .git or the app,
  with the compiled-out browser sources the compiler read, the same bytes twice, split under the
  store's file limit, every part uploaded with its own sha256, and a manifest of names and digests;
- the workflow: the capture is off unless CMUX_NEXT_HYBRID_REF_CAPTURE is 1, never fails the job
  (continue-on-error, a timeout), runs after the compile on a host-mode build only, turns on only
  EMIT_FRONTEND_COMMAND_LINES on the compile, uses the compile's own settings, and adds no
  permission.
"""
from __future__ import annotations

import gzip
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import tarfile
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/cmux-next"))
import hybrid_ref_capture as cap  # noqa: E402

WORKFLOW = ROOT / ".github/workflows/cmux-next.yml"
COMPILE_SCRIPT = ROOT / "scripts/cmux-next/check-cmux-scheme-compile.sh"
TOOLCHAIN = "Xcode 26.6\nBuild version 17F113\n25F61\n"
# The app target is cmux-next and its module is cmux (DEV run 40446615480): a driver is the module
# its builtin-SwiftDriver line names, not the task's target.
LOG = """\
xcodebuild command: xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Release OTHER_SWIFT_FLAGS=\\$\\(inherited\\)\\ -DCMUX_NO_PASSWORD_IMPORT\\ -DCMUX_NO_BROWSER_DATA_IMPORT build
SwiftDriver CmuxNextApp normal arm64 com.apple.xcode.tools.swift.compiler (in target 'CmuxNextApp')
    cd /ws
    builtin-SwiftDriver -- /X/swiftc -module-name CmuxNextApp -O -whole-module-optimization @/dd/a.resp
SwiftCompile normal arm64 Compiling\\ a.swift (in target 'CmuxNextApp')
    /X/usr/bin/swift-frontend -frontend -c /ws/a.swift -module-name CmuxNextApp -o /dd/a.o
SwiftDriver cmux-next normal arm64 com.apple.xcode.tools.swift.compiler (in target 'cmux-next' from project 'cmux')
    cd /ws
    builtin-SwiftDriver -- /X/swiftc -module-name cmux -O @/dd/b.resp
"""
CMUX_LINE = "    /X/usr/bin/swift-frontend -frontend -c -primary-file /ws/b.swift -module-name cmux -o /dd/b.o\n"


def git(repo: Path, *args: str) -> None:
    subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True)


def make_repo(root: Path) -> Path:
    repo = root / "ws"
    if repo.exists():
        return repo
    for rel, text in {
        cap.RESOLVED: '{"pins": []}\n', "cmux.xcodeproj/project.pbxproj": "// pbx\n",
        "config/Release.xcconfig": "A = 1\n", "ios/Config/Release.xcconfig": "B = 1\n",
        "Sources/a.swift": "let a = 1\n", cap.BROWSER_SOURCES: '{"real": true}\n',
        cap.BROWSER_SOURCES_COMPILED_OUT: (ROOT / cap.BROWSER_SOURCES_COMPILED_OUT).read_text(),
        "web/node_modules/x/index.js": "x\n", "cmux-tui/target/debug/big": "x\n",
        "Packages/macOS/CmuxNext/Package.swift": "// pkg\n", "Packages/iOS/Mobile/Package.swift": "// ios\n",
        "scripts/cmux-next/check-cmux-scheme-compile.sh": "# recipe\n",
    }.items():
        path = repo / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    git(repo, "init", "-q")
    git(repo, "add", "-A")
    git(repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init")
    return repo


def make_dd(root: Path) -> Path:
    dd = root / "dd"
    if dd.exists():
        return dd
    for rel in ("Build/Intermediates.noindex/XCBuildData/abc.xcbuilddata/manifest.json",
                "Build/Intermediates.noindex/CmuxNext.build/Release/a.o",
                "Build/Intermediates.noindex/CmuxNext.build/Release/a-OutputFileMap.json",
                "Build/Products/Release/cmux NEXT DEV.app/Contents/Info.plist",
                "Build/Products/Release/CmuxNextApp.swiftmodule/arm64.swiftmodule",
                "CompilationCache.noindex/cas/blob", "Logs/Build/x.xcactivitylog",
                "SourcePackages/checkouts/swift-atomics/Package.swift",
                "SourcePackages/repositories/swift-atomics-1/HEAD",
                "SourcePackages/checkouts/swift-atomics/.git/objects/pack/p.pack"):
        path = dd / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(rel + "\n")
    (dd / "Build/Intermediates.noindex/empty").mkdir()
    return dd


def names(tgz: Path) -> set[str]:
    with tarfile.open(tgz) as tar:
        return set(tar.getnames())


class Key(unittest.TestCase):
    def test_moves_only_with_build_line_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = make_repo(Path(tmp))
            env = {"HYBRID_REF_SETTINGS": "CMUX_NEXT_CONFIGURATION=Release\nCMUX_NEXT_SWIFT_COMPILATION_MODE=singlefile\n"}
            base = cap.key(repo, env, TOOLCHAIN)
            self.assertEqual(base, cap.key(repo, dict(env), TOOLCHAIN))
            (repo / "Sources/a.swift").write_text("let a = 2\n")
            (repo / "ios/Config/Release.xcconfig").write_text("B = 2\n")
            (repo / "Packages/iOS/Mobile/Package.swift").write_text("// ios 2\n")
            self.assertEqual(base, cap.key(repo, env, TOOLCHAIN), "a source file, an iOS xcconfig or an iOS package")
            other = {"HYBRID_REF_SETTINGS": env["HYBRID_REF_SETTINGS"].replace("singlefile", "wholemodule")}
            self.assertNotEqual(base, cap.key(repo, other, TOOLCHAIN))
            with self.assertRaises(SystemExit):
                cap.key(repo, {"HYBRID_REF_SETTINGS": "CMUX_NEXT_TYPO=1"}, TOOLCHAIN)
            self.assertNotEqual(base, cap.key(repo, env, TOOLCHAIN.replace("17F113", "17F114")))
            for rel in (cap.RESOLVED, "cmux.xcodeproj/project.pbxproj", "config/Release.xcconfig",
                        "Packages/macOS/CmuxNext/Package.swift", "scripts/cmux-next/check-cmux-scheme-compile.sh"):
                before = (repo / rel).read_text()
                (repo / rel).write_text(before + " ")
                self.assertNotEqual(base, cap.key(repo, env, TOOLCHAIN), rel)
                (repo / rel).write_text(before)


class Capture(unittest.TestCase):
    def run_capture(self, log: str, part_bytes: int | None = None, upload: bool = True):
        tmp = Path(self.tmp.name)
        repo, dd = make_repo(tmp), make_dd(tmp)
        (tmp / "xcodebuild.log").write_text(log)
        calls = tmp / "calls.jsonl"
        client = tmp / "cmux-ci"
        client.write_text("#!/usr/bin/env python3\nimport json, sys\n"
                          f"open({str(calls)!r}, 'a').write(json.dumps(sys.argv[1:]) + '\\n')\n")
        client.chmod(0o755)
        out = tmp / f"out-{len(list(tmp.glob('out-*')))}"
        output = tmp / "github_output"
        env = {"CMUX_CI_CLIENT": str(client), "HYBRID_REF_SETTINGS": "CMUX_NEXT_BROWSER_DATA_IMPORT=compiled-out\n",
               "GITHUB_OUTPUT": str(output), "TMPDIR": "/var/folders/x/T/"}
        a = Namespace(log=str(tmp / "xcodebuild.log"), workspace="/Users/cmux/host/src",
                      derived_data="/Users/cmux/host/Release/xcode-1", read_workspace=str(repo), read_derived_data=str(dd),
                      sha="a" * 40, key="k" * 64, run_id=7, out=str(out), lane="hybrid-ref-dev", upload=upload)
        saved = cap.PART_BYTES
        if part_bytes:
            cap.PART_BYTES = part_bytes
        try:
            self.assertEqual(cap.capture(a, env), 0)
        finally:
            cap.PART_BYTES = saved
        manifest = json.loads((out / "manifest.json").read_text())
        uploads = [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []
        return manifest, out, uploads, output.read_text()

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_missing_frontend_line_is_incomplete_and_uploads_nothing(self) -> None:
        manifest, out, uploads, output = self.run_capture(LOG)
        self.assertFalse(manifest["complete"])
        self.assertEqual(manifest["missing"], ["cmux"])
        self.assertEqual(manifest["blobs"], {})
        self.assertEqual(uploads, [])
        self.assertFalse((out / "packs").exists())
        self.assertIn("complete=false", output)

    def test_complete_capture(self) -> None:
        manifest, out, uploads, output = self.run_capture(LOG + CMUX_LINE)
        self.assertTrue(manifest["complete"], manifest["missing"])
        self.assertEqual((manifest["workspace"], manifest["derived_data"]),
                         ("/Users/cmux/host/src", "/Users/cmux/host/Release/xcode-1"), "the build's paths, not the snapshot's")
        self.assertIn("complete=true", output)
        self.assertEqual(manifest["xcodebuild_args"][-2:],
                         ["OTHER_SWIFT_FLAGS=$(inherited) -DCMUX_NO_PASSWORD_IMPORT -DCMUX_NO_BROWSER_DATA_IMPORT", "build"])
        self.assertEqual(set(manifest["blobs"]), {"xcodebuild.log.gz", "xcbuilddata.tgz", "build-noobj.tgz",
                                                  "ws-src.tgz", "Package.resolved"})
        packs = out / "packs"
        dd = names(packs / "build-noobj.tgz")
        self.assertIn("Build/Products/Release/CmuxNextApp.swiftmodule/arm64.swiftmodule", dd)
        self.assertIn("SourcePackages/checkouts/swift-atomics/Package.swift", dd)
        self.assertIn("Build/Intermediates.noindex/empty", dd)
        for gone in ("a.o", "CompilationCache.noindex", "Logs/", "repositories", ".app/", ".git/"):
            self.assertFalse([n for n in dd if gone in n], gone)
        self.assertEqual({n.split("/")[0] for n in names(packs / "xcbuilddata.tgz")}, {"XCBuildData"})
        ws = names(packs / "ws-src.tgz")
        self.assertIn("Sources/a.swift", ws)
        self.assertFalse([n for n in ws if n.startswith(".git") or "node_modules" in n or "/target/" in n])
        with tarfile.open(packs / "ws-src.tgz") as tar:
            self.assertEqual(tar.extractfile(cap.BROWSER_SOURCES).read(),
                             (ROOT / cap.BROWSER_SOURCES_COMPILED_OUT).read_bytes(), "the compiler read the compiled-out file")
            self.assertEqual({(m.uid, m.gid, m.mtime) for m in tar.getmembers()}, {(0, 0, 0)})
        self.assertEqual(gzip.decompress((packs / "xcodebuild.log.gz").read_bytes()).decode(), LOG + CMUX_LINE)
        self.assertEqual(sorted(u[1].rsplit("/", 1)[1] for u in uploads), sorted(manifest["blobs"]))
        for u in uploads:
            self.assertEqual(u[0], "artifact-put")
            self.assertEqual(u[u.index("--lane") + 1], "hybrid-ref-dev")
            self.assertEqual(u[u.index("--sha256") + 1], hashlib.sha256(Path(u[1]).read_bytes()).hexdigest())
        text = json.dumps(manifest)
        self.assertNotIn("let a = 1", text, "the public manifest names files, never their contents")
        again, _, _, _ = self.run_capture(LOG + CMUX_LINE)
        self.assertEqual({k: v["sha256"] for k, v in again["blobs"].items()},
                         {k: v["sha256"] for k, v in manifest["blobs"].items()}, "the same build gives the same packs")

    def test_large_pack_is_split_and_parts_join_to_it(self) -> None:
        manifest, out, uploads, _ = self.run_capture(LOG + CMUX_LINE, part_bytes=200)
        blob = manifest["blobs"]["ws-src.tgz"]
        self.assertGreater(len(blob["parts"]), 1)
        joined = b"".join((out / "packs" / p["name"]).read_bytes() for p in blob["parts"])
        self.assertEqual(hashlib.sha256(joined).hexdigest(), blob["sha256"])
        self.assertEqual(len(joined), blob["size"])
        self.assertTrue(all(p["size"] <= 200 for p in blob["parts"]))
        self.assertEqual(len(uploads), sum(len(b["parts"]) for b in manifest["blobs"].values()))


class Toolchain(unittest.TestCase):
    def test_xcode_version(self) -> None:
        self.assertEqual(cap.xcode_version("Xcode 26.6\nBuild version 17F113\n"), "Xcode 26.6 / 17F113")


class Snapshot(unittest.TestCase):
    def test_the_snapshot_is_taken_before_the_host_lock_goes(self) -> None:
        text = (ROOT / "scripts/cmux-next/compile-dev-release.sh").read_text()
        zipped, snapshot = text.index('ditto -c -k --keepParent "$app" "$archive"'), text.index('hybrid-ref-snapshot')
        self.assertLess(zipped, snapshot)
        self.assertNotIn("release_lock", text[snapshot:], "the lock is held until the script exits")
        self.assertIn('"${CMUX_NEXT_EMIT_FRONTEND_COMMAND_LINES:-}" == 1', text[snapshot - 400:snapshot + 400])


class FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *exc) -> None:
        self.close()


class Have(unittest.TestCase):
    NOW = 1_800_000_000.0

    def run_have(self, replies, budget=600.0):
        """replies: a list of (status, headers, body); returns (result or exception, sleeps, calls)."""
        import urllib.error
        clock = [self.NOW]
        sleeps, calls = [], []

        def opener(request, timeout):
            calls.append(request.full_url)
            status, headers, body = replies.pop(0)
            if status == 200:
                return FakeResponse(json.dumps(body).encode())
            raise urllib.error.HTTPError(request.full_url, status, "x", headers, io.BytesIO(body.encode()))

        def sleep(s):
            sleeps.append(s)
            clock[0] += s

        try:
            result = cap.have("k" * 64, "o/r", "t", budget, opener=opener, sleep=sleep, clock=lambda: clock[0])
        except cap.LookupFailed as e:
            result = e
        return result, sleeps, calls

    def stamp(self, days_ago: float) -> str:
        import datetime as dt
        return (dt.datetime.fromtimestamp(self.NOW - days_ago * 86400, dt.timezone.utc)).strftime("%Y-%m-%dT%H:%M:%SZ")

    def test_counts_only_readable_captures(self) -> None:
        arts = [{"expired": False, "created_at": self.stamp(1)}, {"expired": True, "created_at": self.stamp(1)},
                {"expired": False, "created_at": self.stamp(13.5)}]
        recent = [{"expired": False, "created_at": self.stamp(0.5)}, {"expired": False, "created_at": self.stamp(1.5)}]
        result, sleeps, calls = self.run_have([(200, {}, {"artifacts": arts}), (200, {}, {"artifacts": recent})])
        self.assertEqual(result, (1, 1), "13 days for a complete capture, one day for an incomplete one")
        self.assertEqual(sleeps, [])
        self.assertIn("name=hybrid-ref-capture-" + "k" * 64 + "&", calls[0])
        self.assertIn("name=" + cap.incomplete_name("k" * 64) + "&", calls[1])

    def test_rate_limit_waits_for_its_reset(self) -> None:
        limited = (403, {"x-ratelimit-remaining": "0", "x-ratelimit-reset": str(int(self.NOW) + 120)},
                   '{"message":"API rate limit exceeded for installation."}')
        result, sleeps, _ = self.run_have([limited, (200, {}, {"artifacts": []}), (200, {}, {"artifacts": []})])
        self.assertEqual(result, (0, 0))
        self.assertEqual(sleeps, [121.0])

    def test_retry_after_and_429(self) -> None:
        result, sleeps, _ = self.run_have([(200, {}, {"artifacts": []}), (429, {"Retry-After": "30"}, ""), (200, {}, {"artifacts": []})])
        self.assertEqual((result, sleeps), ((0, 0), [30.0]))

    def test_a_reset_past_the_budget_fails_without_waiting(self) -> None:
        limited = (403, {"x-ratelimit-remaining": "0", "x-ratelimit-reset": str(int(self.NOW) + 3000)}, "rate limit")
        result, sleeps, _ = self.run_have([limited])
        self.assertIsInstance(result, cap.LookupFailed)
        self.assertIn("HTTP 403", str(result))
        self.assertEqual(sleeps, [])

    def test_a_truncated_error_body_is_still_retried(self) -> None:
        import http.client
        import urllib.error

        class Truncated(io.BytesIO):
            def read(self, *a):
                raise http.client.IncompleteRead(b"par")

        replies = iter([lambda req: urllib.error.HTTPError(req.full_url, 502, "x", {}, Truncated()),
                        lambda req: FakeResponse(json.dumps({"artifacts": []}).encode()),
                        lambda req: FakeResponse(json.dumps({"artifacts": []}).encode())])
        sleeps = []

        def opener(request, timeout):
            reply = next(replies)(request)
            if isinstance(reply, Exception):
                raise reply
            return reply

        result = cap.have("k" * 64, "o/r", "t", 600, opener=opener, sleep=sleeps.append, clock=lambda: self.NOW)
        self.assertEqual((result, sleeps), ((0, 0), [15.0]))

    def test_a_forbidden_lookup_is_not_retried(self) -> None:
        result, sleeps, _ = self.run_have([(403, {}, '{"message":"Resource not accessible by integration"}')])
        self.assertIsInstance(result, cap.LookupFailed)
        self.assertEqual(sleeps, [])

    def test_the_budget_covers_both_lookups(self) -> None:
        limited = (403, {"x-ratelimit-remaining": "0", "x-ratelimit-reset": str(int(self.NOW) + 400)}, "rate limit")
        later = (403, {"x-ratelimit-remaining": "0", "x-ratelimit-reset": str(int(self.NOW) + 900)}, "rate limit")
        result, sleeps, _ = self.run_have([limited, (200, {}, {"artifacts": []}), later])
        self.assertIsInstance(result, cap.LookupFailed, "401 s, then 500 s more would pass 600")
        self.assertEqual(sleeps, [401.0])

    def test_server_errors_back_off_within_the_budget(self) -> None:
        result, sleeps, _ = self.run_have([(502, {}, "bad gateway")] * 20, budget=100)
        self.assertIsInstance(result, cap.LookupFailed)
        self.assertEqual(sleeps, [15.0, 30.0], "15 + 30, then 60 would pass 100")
        self.assertLessEqual(sum(sleeps), 100)
def shortest_minutes(timeout: int | str) -> int:
    """The shortest limit a job's timeout-minutes can resolve to.

    A plain number is itself. An expression (`${{ cond && 90 || 60 }}`, the
    hosted-runner branch of cmux-scheme-compile) is bounded by its smallest
    numeric branch, so a check against it holds on every runner.
    """
    if isinstance(timeout, int):
        return timeout
    branches = [int(n) for n in re.findall(r"(?:&&|\|\|)\s*(\d+)\b", timeout)]
    if not branches:
        raise AssertionError(f"timeout-minutes {timeout!r} has no numeric branch")
    return min(branches)


class Workflow(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.job = yaml.safe_load(WORKFLOW.read_text())["jobs"]["cmux-scheme-compile"]
        cls.steps = {s.get("id"): s for s in cls.job["steps"] if s.get("id")}
        cls.order = [s.get("id") or s.get("name") for s in cls.job["steps"]]

    def test_the_capture_uses_the_compile_settings(self) -> None:
        compile_env = self.steps["compile-cmux-next-dev-release"]["env"]
        want = {name: str(compile_env.get(name, "")) for name in cap.SETTINGS}
        for step in ("hybrid-ref", "hybrid-ref-capture"):
            env = self.steps[step]["env"]
            self.assertEqual(cap.settings({"HYBRID_REF_SETTINGS": env["HYBRID_REF_SETTINGS"]}), want, step)
            self.assertFalse(set(cap.SETTINGS) & set(env), f"{step}: only the compile step carries the settings")

    def test_off_by_default_and_never_in_the_way(self) -> None:
        decide, capture = self.steps["hybrid-ref"], self.steps["hybrid-ref-capture"]
        self.assertTrue(decide["if"].startswith("vars.CMUX_NEXT_HYBRID_REF_CAPTURE == '1' &&"))
        for step in (decide, capture):
            self.assertTrue(step["continue-on-error"])
        upload = next(s for s in self.job["steps"] if s.get("name") == "Upload the REF capture manifest")
        self.assertLessEqual(decide["timeout-minutes"], 12, "the lookup waits out a rate limit for 10 minutes at most")
        self.assertIn("--budget 600", decide["run"])
        self.assertTrue(upload["continue-on-error"])
        self.assertLessEqual(40 + capture["timeout-minutes"] + upload["timeout-minutes"], shortest_minutes(self.job["timeout-minutes"]) - 10,
                             "a capture that starts by job minute 40 ends, upload included, well inside the job's limit")
        self.assertIn("(( $(date +%s) - started > 40 * 60 ))", capture["run"])
        self.assertIn("actions/runs/$GITHUB_RUN_ID/attempts/$GITHUB_RUN_ATTEMPT/jobs", capture["run"],
                      "timed from the job's own start, not from a later step")
        self.assertIn('if [[ -z "$started" ]]', capture["run"], "an unknown start skips the capture")
        self.assertIn('[[ -n "$started" ]] || started="$DECIDE_STARTED"', capture["run"],
                      "a failed jobs read (a rate limit that outlasted the lookup) falls back to the decide step's start")
        self.assertEqual(capture["env"]["DECIDE_STARTED"], "${{ steps.hybrid-ref.outputs.started }}")
        self.assertIn("hybrid_ref_capture.py have --key", decide["run"], "the lookup that retries a rate limit")
        self.assertEqual(upload["with"]["retention-days"], 14, "the manifest lives as long as the store keeps the packs")
        self.assertIn("steps.hybrid-ref.outputs.capture == 'true'", capture["if"])
        self.assertIn("outputs.build_mode == 'host'", capture["if"])
        self.assertIn("steps.compile-cmux-next-dev-release.outcome == 'success'", capture["if"])
        self.assertIn("outputs.snapshot != ''", capture["if"], "the capture reads the snapshot taken under the host lock")
        self.assertIn("--read-workspace \"$SNAPSHOT/src\"", capture["run"])
        self.assertIn('trap \'rm -rf -- "$SNAPSHOT"\' EXIT', capture["run"])
        self.assertLess(self.order.index("hybrid-ref"), self.order.index("compile-cmux-next-dev-release"))
        self.assertLess(self.order.index("Upload the exact cmux-next app for the trusted publisher"),
                        self.order.index("hybrid-ref-capture"), "the capture runs last")
        self.assertEqual(self.steps["compile-cmux-next-dev-release"]["env"]["CMUX_NEXT_EMIT_FRONTEND_COMMAND_LINES"],
                         "${{ steps.hybrid-ref.outputs.capture == 'true' && '1' || '' }}")

    def test_a_needed_capture_compiles_instead_of_reusing(self) -> None:
        # 40428066457: the product was a reuse hit, so a capture rerun would have compiled nothing.
        decide, lookup = self.steps["hybrid-ref"], self.steps["dev-product"]
        self.assertLess(self.order.index("hybrid-ref"), self.order.index("dev-product"))
        self.assertNotIn("steps.dev-product", decide["if"])
        self.assertIn("steps.hybrid-ref.outputs.compile == 'true' && ", lookup["env"]["SKIP_REASON"])

    def decide(self, have_output: str | None) -> dict[str, str]:
        """Runs the decide step's shell with a fake hybrid_ref_capture.py; returns its outputs."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fake = root / "scripts/cmux-next/hybrid_ref_capture.py"
            fake.parent.mkdir(parents=True)
            fake.write_text("import sys\n"
                            "if sys.argv[1] == 'key': print('k' * 64); sys.exit(0)\n"
                            + ("sys.exit(1)\n" if have_output is None else f"print({have_output!r})\n"))
            out = root / "out"
            proc = subprocess.run(["bash", "-e", "-c", self.steps["hybrid-ref"]["run"]], cwd=root, capture_output=True,
                                  text=True, env={**os.environ, "CMUX_NEXT_RUNNER": "glaeda-side-std-xcode-26.6",
                                                  "GITHUB_OUTPUT": str(out), "GITHUB_REPOSITORY": "o/r"})
            outputs = dict(line.split("=", 1) for line in out.read_text().splitlines())
            outputs["rc"] = str(proc.returncode)
            return outputs

    def test_the_decision(self) -> None:
        cases = {"complete=0\nrecent_incomplete=0": ("true", "true", "0"),
                 "complete=1\nrecent_incomplete=0": ("false", "false", "0"),
                 "complete=0\nrecent_incomplete=2": ("true", "false", "0"),
                 # a failed lookup must compile: with reuse it would build nothing to capture (40428066457)
                 None: ("true", "true", "1")}
        for have_output, (capture, compile_, rc) in cases.items():
            got = self.decide(have_output)
            self.assertRegex(got["started"], r"^\d{10}$", "written before the lookup, even when it fails")
            self.assertEqual((got["capture"], got["compile"], got["rc"]), (capture, compile_, rc), have_output)
            self.assertEqual(got["key"], "k" * 64)

    def test_an_incomplete_capture_has_its_own_name(self) -> None:
        upload = next(s for s in self.job["steps"] if s.get("name") == "Upload the REF capture manifest")
        self.assertEqual(upload["with"]["name"],
                         "${{ steps.hybrid-ref-capture.outputs.complete != 'true' && 'hybrid-ref-capture-incomplete-' "
                         "|| 'hybrid-ref-capture-' }}${{ steps.hybrid-ref.outputs.key }}")
        self.assertEqual(cap.incomplete_name("K"), "hybrid-ref-capture-incomplete-K")

    def test_no_new_permission(self) -> None:
        self.assertEqual(self.job["permissions"], {"actions": "read", "contents": "read", "statuses": "write"})

    def test_the_compile_only_adds_emit_frontend_command_lines(self) -> None:
        text = COMPILE_SCRIPT.read_text()
        self.assertIn('[[ "${CMUX_NEXT_EMIT_FRONTEND_COMMAND_LINES:-}" == 1 ]] && xcode_args+=(EMIT_FRONTEND_COMMAND_LINES=YES)',
                      text)
        self.assertEqual(text.count("EMIT_FRONTEND_COMMAND_LINES"), 2)
        self.assertIn(cap.BROWSER_SOURCES_COMPILED_OUT, text)
        self.assertIn(cap.BROWSER_SOURCES, text)


if __name__ == "__main__":
    unittest.main(verbosity=1)
