#!/usr/bin/env python3
"""The pre-push compile trailer (scripts/cmux-next/compile_trailer.py, lead 2026-10-24).

A push to feat-cmux-next that changes Swift names a passing app + package compile job of its Swift in a
`Compiled: <job id>` trailer; the build controller is asked about the job (here a fake). Run:
python3 -I tests/test_cmux_next_compile_trailer.py
"""
import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("compile_trailer", ROOT / "scripts/cmux-next/compile_trailer.py")
ct = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ct)
gate_spec = importlib.util.spec_from_file_location("prepush_gate", ROOT / "scripts/cmux-next/prepush-gate.py")
gate = importlib.util.module_from_spec(gate_spec)
gate_spec.loader.exec_module(gate)

PKG = "Packages/macOS/CmuxNext"
MANIFEST = """// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "CmuxNext",
    targets: [
        .target(name: "Base"),
        .target(
            name: "Kit",
            dependencies: ["Base"]
        ),
        .target(name: "Other"),
    ]
)
"""


class CompileTrailerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        self.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=str(self.repo / "gitconfig"), HOME=str(self.repo))
        (self.repo / "gitconfig").write_text("[user]\n\tname = t\n\temail = t@t\n")
        self.git("init", "-q", "-b", "feat-cmux-next")
        self.write(f"{PKG}/Package.swift", MANIFEST)
        for module in ("Base", "Kit", "Other"):
            self.write(f"{PKG}/Sources/{module}/{module}.swift", f"public struct {module} {{}}\n")
        self.write("docs/a.md", "a\n")
        self.base = self.commit("base")
        self.jobs = {}
        self.receipts = {}  # job id -> receipts list; default: every asked target passed

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], env=self.env, capture_output=True, text=True,
                              check=True).stdout.strip()

    def write(self, rel, text):
        path = self.repo / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def job(self, ref, state="done", command="--package CmuxNext --app", kind=ct.CHECK_KIND):
        job_id = f"{len(self.jobs) + 1:024x}"
        self.jobs[job_id] = {"id": job_id, "kind": kind, "state": state, "ref": ref,
                             "command": f"/recipes/cmux-next-swift-check.sh {ref} {command}"}
        return job_id

    def check(self, head, base=None):
        def receipts(job):
            if job["id"] in self.receipts:
                value = self.receipts[job["id"]]
                if isinstance(value, Exception):
                    raise value
                return value
            return [{"package": t, "ok": True} for t in ct.asked_targets(job)]
        return ct.check(self.repo, [(base or self.base, head)], fetch=lambda i: self.jobs.get(i, {}), receipts=receipts)

    def swift_edit(self, module="Kit", text="public struct Kit { let x = 1 }\n"):
        self.write(f"{PKG}/Sources/{module}/{module}.swift", text)

    def test_a_swift_push_without_the_trailer_is_refused_with_the_command(self):
        self.swift_edit()
        head = self.commit("kit change")
        refused, lines = self.check(head)
        self.assertTrue(refused)
        self.assertIn(f"cmux-ci compile-check --app --package CmuxNext --ref {head} (then add", lines[0])
        self.assertNotIn("--urgent", lines[0])  # compile-check takes no --urgent or --reason flag
        self.assertIn("Compiled: <the job id it prints>", lines[0])

    def test_a_passing_job_of_the_same_commit_passes(self):
        self.swift_edit()
        first = self.commit("kit change")
        job = self.job(first)
        self.git("commit", "-q", "--amend", "-m", f"kit change\n\nCompiled: {job}")
        head = self.git("rev-parse", "HEAD")
        refused, lines = self.check(head)
        self.assertFalse(refused, lines)
        self.assertIn("passed", lines[-1])

    def test_a_failed_job_or_another_kind_is_refused(self):
        self.swift_edit()
        first = self.commit("kit change")
        for job in (self.job(first, state="failed"), self.job(first, command="--app"),
                    self.job(first, kind="cmux"), "f" * 24):
            self.git("commit", "-q", "--amend", "-m", f"kit change\n\nCompiled: {job}")
            refused, lines = self.check(self.git("rev-parse", "HEAD"))
            self.assertTrue(refused, (job, lines))

    def test_a_job_of_another_tree_is_refused(self):
        self.swift_edit()
        compiled = self.commit("kit change")
        job = self.job(compiled)
        self.swift_edit(text="public struct Kit { let x = 2 }\n")  # edited after the compile
        head = self.commit(f"kit change again\n\nCompiled: {job}")
        refused, lines = self.check(head)
        self.assertTrue(refused, lines)
        self.assertIn("Kit", lines[0])

    def test_rule_a_same_swift_content_other_files_differ(self):
        self.swift_edit()
        compiled = self.commit("kit change")
        job = self.job(compiled)
        self.write("docs/a.md", "b\n")
        head = self.commit(f"docs too\n\nCompiled: {job}")
        refused, lines = self.check(head)
        self.assertFalse(refused, lines)

    def test_rule_b_a_rebase_onto_unrelated_swift_passes(self):
        self.git("checkout", "-q", "-b", "topic")
        self.swift_edit()
        compiled = self.commit("kit change")
        job = self.job(compiled)
        self.git("checkout", "-q", "feat-cmux-next")
        self.swift_edit("Other", "public struct Other { let y = 1 }\n")  # upstream: a module Kit does not use
        self.commit("upstream other")
        self.git("checkout", "-q", "topic")
        self.git("rebase", "-q", "feat-cmux-next")
        self.git("commit", "-q", "--amend", "-m", f"kit change\n\nCompiled: {job}")
        head = self.git("rev-parse", "HEAD")
        refused, lines = self.check(head, base=self.git("rev-parse", "feat-cmux-next"))
        self.assertFalse(refused, lines)

    def test_rule_b_a_rebase_onto_a_change_in_a_dependency_is_refused(self):
        self.git("checkout", "-q", "-b", "topic")
        self.swift_edit()
        compiled = self.commit("kit change")
        job = self.job(compiled)
        self.git("checkout", "-q", "feat-cmux-next")
        self.swift_edit("Base", "public struct Renamed {}\n")  # upstream: a rename in a module Kit depends on
        self.commit("upstream base rename")
        self.git("checkout", "-q", "topic")
        self.git("rebase", "-q", "feat-cmux-next")
        self.git("commit", "-q", "--amend", "-m", f"kit change\n\nCompiled: {job}")
        head = self.git("rev-parse", "HEAD")
        refused, lines = self.check(head, base=self.git("rev-parse", "feat-cmux-next"))
        self.assertTrue(refused, lines)
        self.assertIn("Base", lines[0])

    def test_a_docs_only_push_is_not_affected(self):
        self.write("docs/a.md", "c\n")
        head = self.commit("docs")
        self.assertEqual(self.check(head), (False, []))

    def test_a_down_controller_lets_the_push_through_with_a_warning(self):
        self.swift_edit()
        head = self.commit("kit change\n\nCompiled: " + "a" * 24)
        refused, lines = ct.check(self.repo, [(self.base, head)], fetch=lambda i: None)
        self.assertFalse(refused)
        self.assertIn("did not answer", lines[0])
        self.assertTrue(lines[0].startswith("!!! COMPILE TRAILER NOT CHECKED"), lines)

    def test_compiled_skip_passes_loudly(self):
        self.swift_edit()
        head = self.commit("kit change\n\nCompiled-skip: the controller is down and the tip is broken")
        refused, lines = self.check(head)
        self.assertFalse(refused)
        self.assertIn("COMPILE CHECK SKIPPED", lines[0])

    def test_the_rule_applies_only_to_a_push_to_feat_cmux_next_on_manaflow_ai_cmux(self):
        self.swift_edit()
        head = self.commit("kit change")
        row = f"refs/heads/feat-cmux-next {head} refs/heads/feat-cmux-next {self.base}"
        side = f"refs/heads/topic {head} refs/heads/topic 0000000000000000000000000000000000000000"
        old = os.environ.get("CMUX_PREPUSH_REMOTE_URL")
        try:
            os.environ["CMUX_PREPUSH_REMOTE_URL"] = "https://github.com/manaflow-ai/cmux.git"
            self.assertEqual(len(gate.compile_ranges(self.repo, [row])), 1)
            self.assertEqual(gate.compile_ranges(self.repo, [side]), [], "a side branch is where the compile runs")
            os.environ["CMUX_PREPUSH_REMOTE_URL"] = str(self.repo / "origin.git")
            self.assertEqual(gate.compile_ranges(self.repo, [row]), [], "another remote (a test fixture)")
        finally:
            if old is None:
                os.environ.pop("CMUX_PREPUSH_REMOTE_URL", None)
            else:
                os.environ["CMUX_PREPUSH_REMOTE_URL"] = old

    def test_a_shim_only_push_needs_a_passing_app_build(self):
        self.write(f"{PKG}/CEFShim/src/shim_browser.mm", "namespace cmux { void f(); }\n")
        base = self.commit("shim base")
        self.write(f"{PKG}/CEFShim/src/shim_browser.mm", "namespace cmux { void f() {} }\n")
        compiled = self.commit("shim change")
        refused, lines = self.check(compiled, base=base)
        self.assertTrue(refused)
        self.assertIn(f"cmux-ci build cmux --ref {compiled}", lines[0])
        check = self.job(compiled)  # a passing compile check does not build the shim
        self.git("commit", "-q", "--amend", "-m", f"shim change\n\nCompiled: {check}")
        refused, lines = self.check(self.git("rev-parse", "HEAD"), base=base)
        self.assertTrue(refused, lines)
        self.assertIn("full app build", lines[0])
        build = self.job(self.git("rev-parse", "HEAD"), kind=ct.BUILD_KIND, command="")
        self.git("commit", "-q", "--amend", "-m", f"shim change\n\nCompiled: {build}")
        refused, lines = self.check(self.git("rev-parse", "HEAD"), base=base)
        self.assertFalse(refused, lines)

    def test_a_fork_pin_change_needs_an_app_build_of_the_same_pin(self):
        self.write("scripts/cmux-next/cef-manifest.json", '{"version": "a"}\n')
        base = self.commit("pin base")
        self.write("scripts/cmux-next/cef-manifest.json", '{"version": "b"}\n')
        built = self.commit("pin b")
        build = self.job(built, kind=ct.BUILD_KIND, command="")
        self.write("scripts/cmux-next/cef-manifest.json", '{"version": "c"}\n')
        head = self.commit(f"pin c\n\nCompiled: {build}")
        refused, lines = self.check(head, base=base)
        self.assertTrue(refused, lines)
        self.assertIn("fork pin differs", lines[0])

    # The recipe exits 0 when a check fails (the job is "done"): the verdict is in its receipts (lead 2026-10-24).
    def amended_with(self, job):
        self.git("commit", "-q", "--amend", "-m", f"kit change\n\nCompiled: {job}")
        return self.git("rev-parse", "HEAD")

    def test_a_done_job_whose_app_receipt_failed_is_refused(self):
        self.swift_edit()
        job = self.job(self.commit("kit change"))
        self.receipts[job] = [{"package": "CmuxNext", "ok": True}, {"package": "app", "ok": False}]
        refused, lines = self.check(self.amended_with(job))
        self.assertTrue(refused)
        self.assertIn("FAILED to compile app", lines[0])

    def test_a_done_job_missing_the_app_receipt_is_refused(self):
        self.swift_edit()
        job = self.job(self.commit("kit change"))
        self.receipts[job] = [{"package": "CmuxNext", "ok": True}]
        refused, lines = self.check(self.amended_with(job))
        self.assertTrue(refused)
        self.assertIn("no receipt for app", lines[0])

    def test_all_receipts_ok_pass(self):
        self.swift_edit()
        job = self.job(self.commit("kit change"))
        self.receipts[job] = {"receipts": [{"package": "CmuxNext", "ok": True}, {"package": "app", "ok": True}]}["receipts"]
        refused, lines = self.check(self.amended_with(job))
        self.assertFalse(refused, lines)

    def test_an_artifact_store_that_does_not_answer_lets_the_push_through_with_a_warning(self):
        self.swift_edit()
        job = self.job(self.commit("kit change"))
        self.receipts[job] = ct.StoreDown("the artifact store did not answer")
        refused, lines = self.check(self.amended_with(job))
        self.assertFalse(refused)
        self.assertTrue(lines[0].startswith("!!! COMPILE TRAILER NOT CHECKED"), lines)
        self.assertIn("the artifact store did not answer", lines[0])
        down = {"id": "x", "artifact": "sha256:" + "0" * 64}
        with self.assertRaises(ct.StoreDown):
            ct.fetch_receipts(down, timeout=0.5, url="http://127.0.0.1:9")

    def test_fetch_receipts_reads_and_checks_the_artifact(self):
        import hashlib
        import http.server
        import json
        import threading
        body = json.dumps({"receipts": [{"package": "app", "ok": False}]}).encode()
        digest = "sha256:" + hashlib.sha256(body).hexdigest()

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path.endswith("/url"):
                    self.send_response(404)
                    self.end_headers()
                    return
                data = body if self.path == f"/v1/artifacts/{digest}" else b""
                self.send_response(200 if data else 404)
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *a):
                pass
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.shutdown)
        url = f"http://127.0.0.1:{server.server_address[1]}"
        self.assertEqual(ct.fetch_receipts({"artifact": digest}, url=url), [{"package": "app", "ok": False}])
        self.assertEqual(ct.fetch_receipts({"artifact": "sha256:" + "1" * 64}, url=url), [], "no such artifact: no verdict")

    def test_the_manifest_parser_reads_one_line_and_multi_line_targets(self):
        deps = ct.module_deps(MANIFEST)
        self.assertEqual(deps, {"Base": set(), "Kit": {"Base"}, "Other": set()})

    # Holes found after PL-instant's push c4a98974c65..8a9d03d646e (cmux-b6, 2026-10-24).
    def rebased_push(self, own, upstream, edit_after=None):
        """Topic commits OWN {path: text}, compiled; upstream commits UPSTREAM; topic rebased on it (and EDIT_AFTER
        {path: text} applied after the compile). Returns check()'s answer for the push over the new upstream."""
        self.git("checkout", "-q", "-b", "topic")
        for rel, text in own.items():
            self.write(rel, text)
        job = self.job(self.commit("own change"))
        self.git("checkout", "-q", "feat-cmux-next")
        if upstream:
            for rel, text in upstream.items():
                self.write(rel, text)
            self.commit("upstream")
        self.git("checkout", "-q", "topic")
        self.git("rebase", "-q", "feat-cmux-next")
        for rel, text in (edit_after or {}).items():
            self.write(rel, text)
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", f"own change, newest\n\nCompiled: {job}")
        return self.check(self.git("rev-parse", "HEAD"), base=self.git("rev-parse", "feat-cmux-next"))

    def with_manifest(self, manifest):
        self.write(f"{PKG}/Package.swift", manifest)
        self.base = self.commit("manifest")

    def test_a_test_file_edited_after_the_compile_is_refused(self):
        test = f"{PKG}/Tests/KitTests/KitTests.swift"
        self.with_manifest(MANIFEST.replace('.target(name: "Other"),',
                                            '.target(name: "Other"),\n        .testTarget(name: "KitTests", dependencies: ["Kit"]),'))
        refused, lines = self.rebased_push({test: "import Kit\nlet a = 1\n"}, {},
                                           edit_after={test: "import Kit\nlet a = Kit.missing\n"})
        self.assertTrue(refused, lines)
        self.assertIn("KitTests", lines[0])

    def test_rule_b_a_test_only_push_is_refused_when_upstream_changed_the_module_it_tests(self):
        self.with_manifest(MANIFEST.replace('.target(name: "Other"),',
                                            '.target(name: "Other"),\n        .testTarget(\n            name: "KitTests",\n'
                                            '            dependencies: ["Kit"]\n        ),'))
        refused, lines = self.rebased_push({f"{PKG}/Tests/KitTests/KitTests.swift": "import Kit\nlet a = Kit()\n"},
                                           {f"{PKG}/Sources/Kit/Kit.swift": "public struct Renamed {}\n"})
        self.assertTrue(refused, lines)
        self.assertIn("Kit", lines[0])

    def test_rule_b_an_upstream_change_in_another_package_the_module_uses_is_refused(self):
        shared = "Packages/Shared/CmuxShared"
        self.write(f"{shared}/Package.swift", 'let package = Package(name: "CmuxShared", targets: [.target(name: "CmuxShared")])\n')
        self.write(f"{shared}/Sources/CmuxShared/Shared.swift", "public struct Shared {}\n")
        self.with_manifest(MANIFEST.replace('dependencies: ["Base"]',
                                            'dependencies: ["Base", .product(name: "CmuxShared", package: "CmuxShared")]'))
        refused, lines = self.rebased_push({f"{PKG}/Sources/Kit/Kit.swift": "public struct Kit { let s = Shared() }\n"},
                                           {f"{shared}/Sources/CmuxShared/Shared.swift": "public struct Renamed {}\n"})
        self.assertTrue(refused, lines)
        self.assertIn("CmuxShared", lines[0])

    def test_rule_b_an_upstream_change_in_a_module_a_dependency_re_exports_is_refused(self):
        self.write(f"{PKG}/Sources/Tokens/Tokens.swift", "public struct Tokens {}\n")
        self.write(f"{PKG}/Sources/Base/Export.swift", "@_exported public import Tokens\n")
        self.with_manifest(MANIFEST.replace('.target(name: "Base"),',
                                            '.target(name: "Tokens"),\n        .target(name: "Base", dependencies: ["Tokens"]),'))
        refused, lines = self.rebased_push({f"{PKG}/Sources/Kit/Kit.swift": "public struct Kit { let t = Tokens() }\n"},
                                           {f"{PKG}/Sources/Tokens/Tokens.swift": "public struct Renamed {}\n"})
        self.assertTrue(refused, lines)
        self.assertIn("Tokens", lines[0])

    def test_rule_b_upstream_changes_in_modules_the_push_does_not_use_still_pass(self):
        self.write(f"{PKG}/Sources/Tokens/Tokens.swift", "public struct Tokens {}\n")
        self.write(f"{PKG}/Sources/Base/Export.swift", "@_exported public import Tokens\n")
        self.with_manifest(MANIFEST.replace('.target(name: "Base"),',
                                            '.target(name: "Tokens"),\n        .target(name: "Base", dependencies: ["Tokens"]),'))
        refused, lines = self.rebased_push({f"{PKG}/Sources/Kit/Kit.swift": "public struct Kit { let x = 3 }\n"},
                                           {f"{PKG}/Sources/Other/Other.swift": "public struct Other { let y = 2 }\n"})
        self.assertFalse(refused, lines)

    def test_a_silent_controller_uses_the_job_record_an_earlier_push_read(self):
        # PL-instant's push: refused twice, then let through when the controller missed the bound on the third try.
        self.git("checkout", "-q", "-b", "topic")
        self.swift_edit()
        job = self.job(self.commit("kit change"))
        self.git("checkout", "-q", "feat-cmux-next")
        self.swift_edit("Base", "public struct Renamed {}\n")
        upstream = self.commit("upstream base rename")
        self.git("checkout", "-q", "topic")
        self.git("rebase", "-q", "feat-cmux-next")
        head = self.amended_with(job)
        refused, _ = self.check(head, base=upstream)  # the controller answers: refused, and the job is remembered
        self.assertTrue(refused)
        def silent(_job_id):
            raise ct.ControllerDown("timed out after 5.0 s")
        refused, lines = ct.check(self.repo, [(upstream, head)], fetch=silent,
                                  receipts=lambda job: (_ for _ in ()).throw(ct.StoreDown("down")))
        self.assertTrue(refused, lines)
        self.assertIn("Base", lines[-1])

    def test_a_silent_controller_with_no_record_passes_loudly_and_logs_the_reason(self):
        self.swift_edit()
        head = self.commit("kit change\n\nCompiled: " + "b" * 24)
        def silent(_job_id):
            raise ct.ControllerDown("timed out after 5.0 s")
        refused, lines = ct.check(self.repo, [(self.base, head)], fetch=silent)
        self.assertFalse(refused)
        loud = [line for line in lines if line.startswith("!!! COMPILE TRAILER NOT CHECKED")]
        self.assertTrue(loud, lines)
        self.assertIn("timed out after 5.0 s", loud[0])
        record = Path(self.git("rev-parse", "--git-common-dir"))
        record = (record if record.is_absolute() else self.repo / record) / ct.FAIL_OPEN_LOG
        self.assertIn(head, record.read_text())

    def test_the_controller_bound_is_5_s(self):
        import http.server
        import json
        import threading
        import time

        class Slow(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                time.sleep(2.5)  # slower than the old 2 s bound, inside the lead's 5 s
                body = json.dumps({"id": "c" * 24}).encode()
                self.send_response(200)
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *a):
                pass
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Slow)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.shutdown)
        self.assertGreaterEqual(ct.CONTROLLER_TIMEOUT, 5.0)
        job = ct.fetch_job("c" * 24, url=f"http://127.0.0.1:{server.server_address[1]}")
        self.assertEqual(job, {"id": "c" * 24})
        with self.assertRaises(ct.ControllerDown):
            ct.fetch_job("a" * 24, timeout=0.5, url="http://127.0.0.1:9")


if __name__ == "__main__":
    unittest.main()
