#!/usr/bin/env python3
"""The DEV Release compile records the Linux whole-app build's REF, off by default and never in its way.

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
  permission;
- the nightly-next profile: its key moves with the nightly compile's settings and step and not
  with the DEV recipe, the DEV key is unchanged, and a DerivedData inside the workspace is packed
  once; nightly.yml captures the same way, off unless NIGHTLY_HYBRID_REF_CAPTURE is 1, on an owned
  mini only, beside the rest of build-nightly-app, and waits for it only within a bound; the
  capture stops at its deadline with its upload killed, refuses a linked package cache, and reads
  the build's arguments from the log run-xcodebuild-with-diagnostics.sh keeps.
"""
from __future__ import annotations

import gzip
import hashlib
import io
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
from argparse import Namespace
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/cmux-next"))
import hybrid_ref_capture as cap  # noqa: E402

WORKFLOW = ROOT / ".github/workflows/cmux-next.yml"
NIGHTLY = ROOT / ".github/workflows/nightly.yml"
COMPILE_SCRIPT = ROOT / "scripts/cmux-next/check-cmux-scheme-compile.sh"
TOOLCHAIN = "Xcode 26.6\nBuild version 17F113\n25F61\n"
LOG = """\
xcodebuild command: xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Release OTHER_SWIFT_FLAGS=\\$\\(inherited\\)\\ -DCMUX_NO_PASSWORD_IMPORT\\ -DCMUX_NO_BROWSER_DATA_IMPORT build
SwiftDriver CmuxNextApp normal arm64 com.apple.xcode.tools.swift.compiler (in target 'CmuxNextApp')
    cd /ws
    builtin-SwiftDriver -- /X/swiftc -module-name CmuxNextApp -O -whole-module-optimization @/dd/a.resp
SwiftCompile normal arm64 Compiling\\ a.swift (in target 'CmuxNextApp')
    /X/usr/bin/swift-frontend -frontend -c /ws/a.swift -module-name CmuxNextApp -o /dd/a.o
SwiftDriver cmux normal arm64 com.apple.xcode.tools.swift.compiler (in target 'cmux')
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

    def test_the_nightly_profile_looks_up_its_own_artifacts(self) -> None:
        calls = []

        def opener(request, timeout):
            calls.append(request.full_url)
            return io.BytesIO(json.dumps({"artifacts": []}).encode())

        nightly = {"HYBRID_REF_PROFILE": "nightly-next"}
        self.assertEqual(cap.have("k" * 64, "o/r", "t", opener=opener, environ=nightly), (0, 0))
        self.assertEqual(calls, [f"https://api.github.com/repos/o/r/actions/artifacts?name={name}&per_page=100"
                                 for name in ("hybrid-ref-capture-nightly-next-" + "k" * 64,
                                              "hybrid-ref-capture-nightly-next-incomplete-" + "k" * 64)])
        self.assertEqual((cap.complete_name("K", {}), cap.incomplete_name("K", {})),
                         ("hybrid-ref-capture-K", "hybrid-ref-capture-incomplete-K"), "the DEV names do not move")

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


NIGHTLY_ENV = {"HYBRID_REF_PROFILE": "nightly-next",
               "HYBRID_REF_SETTINGS": "BUILD_TRACK=nightly-next\nNIGHTLY_COMPILE_ARCHS=arm64\n"}
NIGHTLY_STEP_TEXT = """\
jobs:
  build-nightly-app:
    steps:
      - name: Build nightly app (Release)
        run: |
          xcodebuild -scheme cmux build
      # the next step's comment
      - name: Bundle
        run: true
"""


class NightlyProfile(unittest.TestCase):
    def nightly_repo(self, root: Path) -> Path:
        repo = make_repo(root)
        for rel, text in {cap.NIGHTLY_STEP[0]: NIGHTLY_STEP_TEXT, cap.NIGHTLY_RECIPE_PATHS[0]: "X=1\n"}.items():
            (repo / rel).parent.mkdir(parents=True, exist_ok=True)
            (repo / rel).write_text(text)
        git(repo, "add", "-A")
        git(repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "nightly")
        return repo

    def test_key_moves_with_the_nightly_compile_only(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = self.nightly_repo(Path(tmp))
            dev_env = {"HYBRID_REF_SETTINGS": "CMUX_NEXT_CONFIGURATION=Release\n"}
            dev = cap.key(repo, dev_env, TOOLCHAIN)
            self.assertEqual(dev, cap.key(repo, dict(dev_env, HYBRID_REF_PROFILE="dev"), TOOLCHAIN))
            base = cap.key(repo, NIGHTLY_ENV, TOOLCHAIN)
            self.assertNotEqual(base, dev)
            (repo / "scripts/cmux-next/check-cmux-scheme-compile.sh").write_text("# recipe 2\n")
            self.assertEqual(base, cap.key(repo, NIGHTLY_ENV, TOOLCHAIN), "the DEV recipe is not the nightly's")
            self.assertNotEqual(dev, cap.key(repo, dev_env, TOOLCHAIN))
            step = repo / cap.NIGHTLY_STEP[0]
            step.write_text(NIGHTLY_STEP_TEXT.replace("# the next step's comment", "# another comment"))
            self.assertEqual(base, cap.key(repo, NIGHTLY_ENV, TOOLCHAIN), "another step's comment")
            step.write_text(NIGHTLY_STEP_TEXT.replace("-scheme cmux build", "-scheme cmux ONLY_ACTIVE_ARCH=YES build"))
            self.assertNotEqual(base, cap.key(repo, NIGHTLY_ENV, TOOLCHAIN), "the compile step's own line")
            step.write_text(NIGHTLY_STEP_TEXT)
            for rel in (cap.NIGHTLY_RECIPE_PATHS[0], cap.RESOLVED, "config/Release.xcconfig"):
                before = (repo / rel).read_text()
                (repo / rel).write_text(before + " ")
                self.assertNotEqual(base, cap.key(repo, NIGHTLY_ENV, TOOLCHAIN), rel)
                (repo / rel).write_text(before)
            arm64_x86 = dict(NIGHTLY_ENV, HYBRID_REF_SETTINGS="BUILD_TRACK=nightly-next\nNIGHTLY_COMPILE_ARCHS=arm64 x86_64\n")
            self.assertNotEqual(base, cap.key(repo, arm64_x86, TOOLCHAIN))
            with self.assertRaises(SystemExit):
                cap.key(repo, dict(NIGHTLY_ENV, HYBRID_REF_SETTINGS="CMUX_NEXT_CONFIGURATION=Release"), TOOLCHAIN)
            with self.assertRaises(SystemExit):
                cap.key(repo, dict(NIGHTLY_ENV, HYBRID_REF_PROFILE="nightly"), TOOLCHAIN)

    def test_derived_data_inside_the_workspace_is_packed_once(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = make_repo(root)
            shutil.copytree(make_dd(root), repo / "build-universal")
            for rel in (".spm-cache/checkouts/swift-atomics/Package.swift", ".spm-cache/.package-cache/x/HEAD",
                        ".spm-cache/repositories/swift-atomics-1/HEAD"):
                (repo / rel).parent.mkdir(parents=True, exist_ok=True)
                (repo / rel).write_text(rel)
            log = root / "xcodebuild.log"
            log.write_text(LOG + CMUX_LINE)
            out = root / "out"
            a = Namespace(log=str(log), workspace="/Users/cmux/w/cmux", derived_data="/Users/cmux/w/cmux/build-universal",
                          read_workspace=str(repo), read_derived_data=str(repo / "build-universal"), sha="b" * 40,
                          key="n" * 64, run_id=8, out=str(out), lane="hybrid-ref-nightly-next", upload=False)
            env = dict(NIGHTLY_ENV, HYBRID_REF_SETTINGS="EMPTY_BROWSER_SOURCES=true\n")
            self.assertEqual(cap.capture(a, env), 0)
            manifest = json.loads((out / "manifest.json").read_text())
            self.assertTrue(manifest["complete"])
            self.assertEqual(manifest["profile"], "nightly-next")
            self.assertEqual(manifest["settings"]["EMPTY_BROWSER_SOURCES"], "true")
            ws = names(out / "packs/ws-src.tgz")
            self.assertIn("Sources/a.swift", ws)
            self.assertIn(".spm-cache/checkouts/swift-atomics/Package.swift", ws)
            self.assertFalse([n for n in ws if n.startswith("build-universal") or "package-cache" in n
                              or n.startswith(".spm-cache/repositories")], "packed once, as DerivedData")
            self.assertIn("Build/Products/Release/CmuxNextApp.swiftmodule/arm64.swiftmodule", names(out / "packs/build-noobj.tgz"))
            with tarfile.open(out / "packs/ws-src.tgz") as tar:
                self.assertEqual(tar.extractfile(cap.BROWSER_SOURCES).read(), b'{"real": true}\n',
                                 "the nightly's tree as its compiler read it, not the DEV file")

    def nightly_args(self, root: Path, **extra) -> Namespace:
        repo = make_repo(root)
        if not (repo / "build-universal").exists():
            shutil.copytree(make_dd(root), repo / "build-universal")
        log = root / "xcodebuild.log"
        log.write_text(LOG + CMUX_LINE)
        return Namespace(log=str(log), workspace="/w", derived_data="/w/build-universal", read_workspace=str(repo),
                         read_derived_data=str(repo / "build-universal"), sha="c" * 40, key="d" * 64, run_id=9,
                         out=str(root / "out"), lane="hybrid-ref-nightly-next", upload=True, **extra)

    def test_a_blocked_upload_stops_at_the_deadline_without_a_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            client = root / "cmux-ci"
            client.write_text("#!/bin/sh\nexec sleep 60\n")
            client.chmod(0o755)
            env = dict(NIGHTLY_ENV, CMUX_CI_CLIENT=str(client))
            started = time.monotonic()
            self.assertEqual(cap.capture(self.nightly_args(root, deadline=int(time.time()) + 2), env), 3)
            self.assertLess(time.monotonic() - started, 20, "the upload is killed at the deadline")
            self.assertFalse((root / "out/manifest.json").exists())
            self.assertEqual(cap.capture(self.nightly_args(root, deadline=int(time.time()) - 1), env), 3)
            self.assertFalse((root / "out/manifest.json").exists())

    @staticmethod
    def helper_client(root: Path, tail: str) -> Path:
        """A cmux-ci that starts a background helper, records both pids, then runs TAIL."""
        client = root / "cmux-ci"
        client.write_text(f"#!/bin/sh\nsleep 60 &\necho \"$$ $!\" > {root / 'pids'}\n{tail}\n")
        client.chmod(0o755)
        return client

    @classmethod
    def setUpClass(cls) -> None:
        # Linux: orphans of what these tests start (an upload's helper) become this process's
        # children, so it reaps them itself and reads how they ended, with no outside reaper's delay.
        cls.subreaper = False
        if sys.platform.startswith("linux"):
            import ctypes
            libc = ctypes.CDLL(None, use_errno=True)
            cls.subreaper = libc.prctl(36, 1, 0, 0, 0) == 0  # PR_SET_CHILD_SUBREAPER

    @classmethod
    def tearDownClass(cls) -> None:
        if cls.subreaper:
            import ctypes
            ctypes.CDLL(None).prctl(36, 0, 0, 0, 0)

    @staticmethod
    def alive(pid: int) -> bool:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        return True

    def assert_all_gone(self, root: Path) -> None:
        pids = [int(x) for x in (root / "pids").read_text().split()]
        ended = {}
        gone = time.monotonic() + 10
        while time.monotonic() < gone:
            if self.subreaper:
                for pid in pids:
                    try:
                        done, status = os.waitpid(pid, os.WNOHANG)
                    except ChildProcessError:
                        continue  # not ours (reaped elsewhere, or never reparented here)
                    if done:
                        ended[pid] = status
            if not any(self.alive(pid) and pid not in ended for pid in pids):
                break
            time.sleep(0.05)
        self.assertEqual([pid for pid in pids if self.alive(pid) and pid not in ended], [],
                         "the upload or its helper outlived the capture")
        # The helper (the second pid) is a sleep 60: it can only have ended by the group kill.
        helper = pids[1]
        if helper in ended:
            self.assertTrue(os.WIFSIGNALED(ended[helper]) and os.WTERMSIG(ended[helper]) == signal.SIGKILL,
                            f"the helper ended by the upload group's SIGKILL, not {ended[helper]}")

    def test_the_deadline_kills_what_the_upload_started(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            env = dict(NIGHTLY_ENV, CMUX_CI_CLIENT=str(self.helper_client(root, "wait")))
            # Room for the packing before the first upload starts its helper.
            self.assertEqual(cap.capture(self.nightly_args(root, deadline=int(time.time()) + 6), env), 3)
            self.assert_all_gone(root)

    def test_a_failed_upload_fails_the_capture_and_leaves_nothing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            env = dict(NIGHTLY_ENV, CMUX_CI_CLIENT=str(self.helper_client(root, "exit 7")))
            with self.assertRaises(subprocess.CalledProcessError):
                cap.capture(self.nightly_args(root, deadline=None), env)
            self.assertFalse((root / "out/manifest.json").exists())
            self.assert_all_gone(root)

    def test_the_cleanup_stop_kills_what_the_upload_started(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            args = self.nightly_args(root, deadline=None)
            env = dict(os.environ, **NIGHTLY_ENV, CMUX_CI_CLIENT=str(self.helper_client(root, "wait")))
            state = root / "state"
            argv = [sys.executable, str(ROOT / "scripts/cmux-next/hybrid_ref_capture.py"), "capture", "--log", args.log,
                    "--workspace", args.workspace, "--derived-data", args.derived_data, "--read-workspace",
                    args.read_workspace, "--read-derived-data", args.read_derived_data, "--sha", args.sha, "--key",
                    args.key, "--run-id", "9", "--lane", args.lane, "--out", args.out, "--upload"]
            background = [sys.executable, str(ROOT / "scripts/ci/background_build.py")]
            subprocess.run([*background, "start", "--state", str(state), "capture", "--", *argv],
                           env=env, check=True, capture_output=True)
            started = time.monotonic() + 30
            while not (root / "pids").exists() and time.monotonic() < started:
                time.sleep(0.1)
            self.assertTrue((root / "pids").exists(), "the upload started")
            subprocess.run([*background, "stop", "--state", str(state)], check=True, capture_output=True)
            self.assert_all_gone(root)
            self.assertFalse((root / "out/manifest.json").exists())

    def test_a_linked_package_cache_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "kept/SourcePackages/checkouts/x").mkdir(parents=True)
            args = self.nightly_args(root, deadline=None)
            (Path(args.read_workspace) / ".spm-cache").symlink_to(root / "kept/SourcePackages")
            with self.assertRaises(SystemExit):
                cap.capture(args, dict(NIGHTLY_ENV))

    def test_the_kept_xcodebuild_log_names_the_command(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            log = root / "kept.log"
            env = dict(os.environ, CMUX_XCODEBUILD_OUTPUT_LOG=str(log), RUNNER_TEMP=str(root),
                       CMUX_XCODEBUILD_HEARTBEAT_SECONDS="5")
            subprocess.run(["bash", str(ROOT / "scripts/ci/run-xcodebuild-with-diagnostics.sh"), "--", "env",
                            "CMUX_SKIP_ZIG_BUILD=1", "printf", "%s\\n", "OTHER_SWIFT_FLAGS=$(inherited) -DX"],
                           env=env, check=True, capture_output=True)
            text = log.read_text()
            self.assertEqual(text.count("xcodebuild command: "), 1)
            _, _, command = cap.drivers_and_lines(log)
            self.assertEqual(cap.shlex.split(command), ["env", "CMUX_SKIP_ZIG_BUILD=1", "printf", "%s\\n",
                                                        "OTHER_SWIFT_FLAGS=$(inherited) -DX"])
            self.assertIn("OTHER_SWIFT_FLAGS=$(inherited) -DX\n", text, "the build's own output follows")


class NightlyWorkflow(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        workflow = yaml.safe_load(NIGHTLY.read_text())
        cls.job = workflow["jobs"]["build-nightly-app"]
        cls.steps = {s.get("id"): s for s in cls.job["steps"] if s.get("id")}
        cls.named = {s.get("name"): s for s in cls.job["steps"]}
        cls.order = [s.get("id") or s.get("name") for s in cls.job["steps"]]
        cls.compile = cls.named[cap.NIGHTLY_STEP[1]]

    def test_the_capture_uses_the_compile_settings(self) -> None:
        env = dict(self.job["env"], **self.compile["env"])
        want = {name: str(env[name]) for name in cap.NIGHTLY_SETTINGS}
        self.assertEqual(set(self.compile["env"]) - set(cap.NIGHTLY_SETTINGS),
                         {"IMPORT_VARIANT", "CMUX_XCODEBUILD_OUTPUT_LOG", "HYBRID_REF_CAPTURE"},
                         "every other env the compile reads sets a build line")
        self.assertNotIn("IMPORT_VARIANT", self.compile["run"].replace("browser import variant: $IMPORT_VARIANT", ""))
        for step in ("hybrid-ref", "hybrid-ref-start"):
            env = self.steps[step]["env"]
            self.assertEqual(env["HYBRID_REF_PROFILE"], "nightly-next")
            got = cap.settings({"HYBRID_REF_PROFILE": "nightly-next", "HYBRID_REF_SETTINGS": env["HYBRID_REF_SETTINGS"]})
            self.assertEqual(got, want, step)
            self.assertFalse(set(cap.NIGHTLY_SETTINGS) & set(env), f"{step}: only the compile step carries the settings")
        self.assertEqual(cap.step_text(NIGHTLY, cap.NIGHTLY_STEP[1]).splitlines()[-1].strip(), '"${notary_test_flags[@]}"')

    def test_off_by_default_owned_mini_only_and_bounded(self) -> None:
        decide, start, finish = self.steps["hybrid-ref"], self.steps["hybrid-ref-start"], self.steps["hybrid-ref-capture"]
        upload = self.named["Upload the REF capture manifest"]
        self.assertTrue(decide["if"].startswith("vars.NIGHTLY_HYBRID_REF_CAPTURE == '1' &&"))
        self.assertIn("needs.decide.outputs.track == 'nightly-next'", decide["if"])
        self.assertIn("runner.environment == 'self-hosted'", decide["if"])
        self.assertIn("*-glaeda | *-glaeda-[0-9]*) ;;", decide["run"], "an owned mini, never a Blacksmith Mac")
        self.assertIn('skip "no cmux-ci on $RUNNER_NAME"', decide["run"])
        self.assertIn('hybrid_ref_capture.py have --key "$key" --repo "$GITHUB_REPOSITORY" --budget 30', decide["run"])
        self.assertEqual(decide["env"]["HYBRID_REF_PROFILE"], "nightly-next", "have looks up the nightly's artifact names")
        self.assertIn('[[ "$capture" == true && "$incomplete" == 0 ]] && compile=true', decide["run"])
        failed = decide["run"][decide["run"].index("exit 0\nfi\n"):]
        self.assertIn("capture=true\\ncompile=true", failed, "a failed lookup captures and compiles anyway")
        self.assertIn("::error title=REF capture lookup failed::", failed)
        self.assertTrue(failed.rstrip().endswith("exit 1"), "and shows red")
        self.assertIn("started=$(( $(date +%s) - 30 * 60 ))", decide["run"], "an unknown job start only moves the deadline earlier")
        self.assertNotIn("skip \"this job's start", decide["run"])
        for step in (decide, start, finish, upload):
            self.assertTrue(step["continue-on-error"], step.get("name"))
        self.assertLessEqual(decide["timeout-minutes"], 2, "the compile waits at most 30 s on the lookup")
        self.assertEqual(start["if"], "steps.hybrid-ref.outputs.capture == 'true' && steps.nightly-product.outputs.hit != 'true'")
        # A capture run never takes a reused product: it decides before the lookup and makes it miss.
        lookup = self.steps["nightly-product"]
        self.assertLess(self.order.index("hybrid-ref"), self.order.index("nightly-product"))
        self.assertTrue(lookup["env"]["SKIP_REASON"].startswith(
            "${{ steps.hybrid-ref.outputs.compile == 'true' && 'a REF capture needs a real compile' || "))
        self.assertIn("steps.nightly-product.outputs.hit != 'true'", self.compile["if"])
        self.assertEqual(finish["if"], "steps.hybrid-ref-start.outputs.started == 'true'")
        self.assertIn("(( $(date +%s) - STARTED > 100 * 60 ))", start["run"])
        self.assertIn("env -u GITHUB_OUTPUT nice -n 10", start["run"])
        self.assertIn("--lane hybrid-ref-nightly-next", start["run"])
        self.assertIn('--read-derived-data "$snapshot/src/build-universal"', start["run"])
        self.assertIn('--deadline "$(( STARTED + 130 * 60 ))"', start["run"], "the capture itself ends by minute 130")
        self.assertIn('if [ -L "$GITHUB_WORKSPACE/.spm-cache" ]; then', start["run"])
        self.assertIn('apfs_clone.py "$packages" "$snapshot/src/.spm-cache"', start["run"])
        self.assertIn("budget=$(( 130 * 60 - ($(date +%s) - STARTED) ))", finish["run"])
        self.assertIn("(( budget > 240 )) && budget=240", finish["run"])
        self.assertLessEqual(130 + finish["timeout-minutes"] + upload["timeout-minutes"], self.job["timeout-minutes"] - 10,
                             "the wait ends by job minute 130; the upload too, well inside the job's limit")
        self.assertLessEqual(240, finish["timeout-minutes"] * 60 - 30)
        self.assertEqual(upload["with"]["retention-days"], 14)
        self.assertEqual(upload["with"]["name"],
                         "${{ steps.hybrid-ref-capture.outputs.complete != 'true' && 'hybrid-ref-capture-nightly-next-incomplete-' "
                         "|| 'hybrid-ref-capture-nightly-next-' }}${{ steps.hybrid-ref.outputs.key }}")
        nightly = {"HYBRID_REF_PROFILE": "nightly-next"}
        self.assertEqual((cap.complete_name("K", nightly), cap.incomplete_name("K", nightly)),
                         ("hybrid-ref-capture-nightly-next-K", "hybrid-ref-capture-nightly-next-incomplete-K"),
                         "the names the upload step writes are the ones have reads")
        # Decide before the compile, start right after it (and the bundling, which changes only the
        # app: tests/test_nightly_helpers_beside_release_build.py pins the steps around the compile),
        # finish and upload last but the cleanup.
        compile_at = self.order.index(cap.NIGHTLY_STEP[1])
        self.assertLess(self.order.index("hybrid-ref"), compile_at)
        self.assertEqual(self.order[compile_at + 1:compile_at + 3],
                         ["Bundle the OptChat Chief and the iPhone host", "hybrid-ref-start"])
        self.assertEqual(self.order[-3:], ["hybrid-ref-capture", "Upload the REF capture manifest",
                                           "Stop the helper builds still running"])
        self.assertIn('stop --state "$RUNNER_TEMP/hybrid-ref-builds"', self.named["Stop the helper builds still running"]["run"])

    def test_the_compile_only_adds_emit_frontend_command_lines(self) -> None:
        env, run = self.compile["env"], self.compile["run"]
        self.assertEqual(env["HYBRID_REF_CAPTURE"], "${{ steps.hybrid-ref.outputs.capture == 'true' && '1' || '' }}")
        self.assertEqual(env["CMUX_XCODEBUILD_OUTPUT_LOG"],
                         "${{ steps.hybrid-ref.outputs.capture == 'true' && format('{0}/hybrid-ref-xcodebuild.log', runner.temp) || '' }}")
        self.assertIn('[[ "${HYBRID_REF_CAPTURE:-}" == 1 ]] && notary_test_flags=(EMIT_FRONTEND_COMMAND_LINES=YES "${notary_test_flags[@]}")', run)
        self.assertEqual(run.count("HYBRID_REF_CAPTURE"), 1)

    def test_no_new_permission(self) -> None:
        self.assertEqual(self.job["permissions"], {"contents": "write", "actions": "read", "attestations": "write",
                                                   "id-token": "write"})


if __name__ == "__main__":
    unittest.main(verbosity=1)
