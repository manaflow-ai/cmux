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
        self.swift_edit(text="public struct Kit { let b = Base() }\n")  # the push uses what upstream renames
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

    # Per-symbol rule (b) (2026-10-28): a751 was refused 11 times out of 15 rebased pushes because feat-cmux-next
    # got new Swift in CmuxNextApp's dependency modules during every 7-10 min compile, none of it touching what the
    # push used. Rule (b) now asks whether the upstream change and the push's change can meet: a declaration one side
    # changed or removed that the other side's files name, a new declaration both sides could see, or the push's own
    # change differing from the one compiled. The rename safety cases above still refuse.
    def kit_app(self, extra=""):
        """A Kit module with a few declarations and an App module that uses Kit (the CmuxNextApp shape)."""
        self.write(f"{PKG}/Sources/Kit/Kit.swift",
                   "public struct Kit {\n    public init() {}\n    public func run() -> Int { 1 }\n}\n"
                   "public enum Mode {\n    case a\n    case b\n}\n"
                   "public protocol Runner {\n    func go()\n}\n"
                   "public struct Point {\n    public var x: Int\n}\n" + extra)
        self.write(f"{PKG}/Sources/Kit/Tools.swift", "public func helper() -> Int {\n    return 1\n}\n")
        self.write(f"{PKG}/Sources/App/App.swift", "import Kit\nstruct App {\n    let kit = Kit()\n}\n")
        self.with_manifest(MANIFEST.replace('.target(name: "Other"),',
                                            '.target(name: "Other"),\n        .target(name: "App", dependencies: ["Kit"]),'))

    APP = f"{PKG}/Sources/App/Feature.swift"
    KIT = f"{PKG}/Sources/Kit/Kit.swift"

    def test_per_symbol_an_upstream_body_change_in_a_dependency_passes(self):
        self.kit_app()
        refused, lines = self.rebased_push({self.APP: "import Kit\nfunc feature() -> Int { Kit().run() }\n"},
                                           {f"{PKG}/Sources/Kit/Tools.swift": "public func helper() -> Int {\n    return 2\n}\n"})
        self.assertFalse(refused, lines)

    def test_per_symbol_an_upstream_change_the_push_does_not_name_passes(self):
        self.kit_app()
        refused, lines = self.rebased_push({self.APP: "import Kit\nfunc feature() -> Int { Kit().run() }\n"},
                                           {f"{PKG}/Sources/Kit/Tools.swift": "public func helper(_ n: Int) -> Int {\n    return n\n}\n"})
        self.assertFalse(refused, lines)

    def test_per_symbol_an_upstream_change_in_the_push_s_own_module_it_does_not_name_passes(self):
        self.kit_app()
        refused, lines = self.rebased_push({self.APP: "import Kit\nfunc feature() -> Int { Kit().run() }\n"},
                                           {f"{PKG}/Sources/App/Other.swift": "struct Elsewhere {\n    let n = 2\n}\n"})
        self.assertFalse(refused, lines)

    def test_per_symbol_an_upstream_new_member_on_a_type_the_push_does_not_name_passes(self):
        self.kit_app()
        refused, lines = self.rebased_push({self.APP: "import Kit\nfunc feature() -> Int { helper() }\n"},
                                           {self.KIT: self.read(self.KIT).replace("    public var x: Int\n",
                                            "    public var x: Int\n    public func feature() -> Int { x }\n")})
        self.assertFalse(refused, lines)

    # Safety cases the per-symbol rule must keep refusing.
    def test_per_symbol_an_upstream_rename_of_a_function_the_push_calls_is_refused(self):
        self.kit_app()
        refused, lines = self.rebased_push({self.APP: "import Kit\nfunc feature() -> Int { Kit().run() }\n"},
                                           {self.KIT: self.read(self.KIT).replace("func run()", "func start()")})
        self.assertTrue(refused, lines)
        self.assertIn("run", lines[0])

    def test_per_symbol_an_upstream_signature_change_on_a_continuation_line_is_refused(self):
        self.kit_app(extra="public func make(\n    a: Int\n) -> Int { a }\n")
        refused, lines = self.rebased_push({self.APP: "import Kit\nfunc feature() -> Int { make(a: 1) }\n"},
                                           {self.KIT: self.read(self.KIT).replace("    a: Int\n", "    a: Int,\n    b: Int\n")})
        self.assertTrue(refused, lines)
        self.assertIn("make", lines[0])

    def test_per_symbol_an_upstream_stored_property_on_a_struct_the_push_builds_is_refused(self):
        self.kit_app()
        refused, lines = self.rebased_push({self.APP: "import Kit\nlet origin = Point(x: 0)\n"},
                                           {self.KIT: self.read(self.KIT).replace("    public var x: Int\n",
                                                                                   "    public var x: Int\n    public var y: Int\n")})
        self.assertTrue(refused, lines)
        self.assertIn("Point", lines[0])

    def test_per_symbol_an_upstream_enum_case_with_a_push_switch_is_refused(self):
        self.kit_app()
        refused, lines = self.rebased_push({self.APP: "import Kit\nfunc name(_ m: Mode) -> Int {\n    switch m {\n"
                                                      "    case .a: return 1\n    case .b: return 2\n    }\n}\n"},
                                           {self.KIT: self.read(self.KIT).replace("    case b\n", "    case b\n    case c\n")})
        self.assertTrue(refused, lines)
        self.assertIn("Mode", lines[0])

    def test_per_symbol_an_upstream_protocol_requirement_the_push_conforms_to_is_refused(self):
        self.kit_app()
        refused, lines = self.rebased_push({self.APP: "import Kit\nstruct Fast: Runner {\n    func go() {}\n}\n"},
                                           {self.KIT: self.read(self.KIT).replace("    func go()\n", "    func go()\n    func stop()\n")})
        self.assertTrue(refused, lines)
        self.assertIn("Runner", lines[0])

    def test_per_symbol_an_upstream_attribute_on_a_type_the_push_uses_is_refused(self):
        self.kit_app()
        refused, lines = self.rebased_push({self.APP: "import Kit\nfunc feature() -> Int { Kit().run() }\n"},
                                           {self.KIT: self.read(self.KIT).replace("public struct Kit {", "@MainActor\npublic struct Kit {")})
        self.assertTrue(refused, lines)
        self.assertIn("Kit", lines[0])

    def test_per_symbol_an_upstream_use_of_a_function_the_push_renames_is_refused(self):
        self.kit_app()
        refused, lines = self.rebased_push({f"{PKG}/Sources/Kit/Tools.swift": "public func assist() -> Int {\n    return 1\n}\n"},
                                           {self.APP: "import Kit\nfunc feature() -> Int { helper() }\n"})
        self.assertTrue(refused, lines)
        self.assertIn("helper", lines[0])

    def test_per_symbol_the_same_new_name_on_both_sides_is_refused(self):
        self.kit_app()
        refused, lines = self.rebased_push({self.APP: "import Kit\nfunc shared() -> Int { 1 }\n"},
                                           {f"{PKG}/Sources/Kit/More.swift": "public func shared() -> Int { 2 }\n"})
        self.assertTrue(refused, lines)
        self.assertIn("shared", lines[0])

    def test_per_symbol_a_name_inside_a_string_or_comment_does_not_count(self):
        self.kit_app()
        refused, lines = self.rebased_push({self.APP: "import Kit\n// helper() is not called here\nlet s = \"helper\"\n"},
                                           {f"{PKG}/Sources/Kit/Tools.swift": "public func helper(_ n: Int) -> Int {\n    return n\n}\n"})
        self.assertFalse(refused, lines)

    def test_per_symbol_a_name_in_a_string_interpolation_counts(self):
        self.kit_app()
        refused, lines = self.rebased_push({self.APP: "import Kit\nlet s = \"n=\\(helper())\"\n"},
                                           {f"{PKG}/Sources/Kit/Tools.swift": "public func helper(_ n: Int) -> Int {\n    return n\n}\n"})
        self.assertTrue(refused, lines)
        self.assertIn("helper", lines[0])

    def test_per_symbol_an_own_file_edited_after_the_compile_is_refused_even_with_unrelated_upstream(self):
        self.kit_app()
        refused, lines = self.rebased_push({self.APP: "import Kit\nlet a = 1\n"},
                                           {f"{PKG}/Sources/Other/Other.swift": "public struct Other { let y = 2 }\n"},
                                           edit_after={self.APP: "import Kit\nlet a = Kit.missing\n"})
        self.assertTrue(refused, lines)
        self.assertIn("App", lines[0])

    def test_per_symbol_a_private_upstream_change_of_a_name_the_push_also_uses_passes(self):
        self.kit_app(extra="public struct Box {\n    private enum CodingKeys: String {\n        case a\n    }\n}\n")
        refused, lines = self.rebased_push({self.APP: "import Kit\nstruct Mine {\n    enum CodingKeys: String {\n        case z\n    }\n}\n"},
                                           {self.KIT: self.read(self.KIT).replace("        case a\n", "        case a\n        case b\n")})
        self.assertFalse(refused, lines)

    def test_per_symbol_a_rebase_conflict_resolved_after_the_compile_is_refused(self):
        self.kit_app(extra="public let names = [\"a\"]\n")
        self.git("checkout", "-q", "-b", "topic")
        self.write(self.KIT, self.read(self.KIT).replace('[\"a\"]', '[\"a\", \"own\"]'))
        job = self.job(self.commit("own change"))
        self.git("checkout", "-q", "feat-cmux-next")
        self.write(self.KIT, self.read(self.KIT).replace('[\"a\"]', '[\"a\", \"up\"]'))
        upstream = self.commit("upstream")
        self.git("checkout", "-q", "topic")
        self.git("reset", "-q", "--hard", upstream)
        self.write(self.KIT, self.read(self.KIT).replace('[\"a\", \"up\"]', '[\"a\", \"up\", \"own\"]'))
        head = self.commit(f"own change, conflict resolved\n\nCompiled: {job}")
        refused, lines = self.check(head, base=upstream)
        self.assertTrue(refused, lines)
        self.assertIn("not the one the compile job compiled", lines[0])

    # A moved base alone (a803, 2026-10-28): its compiled change, replayed 10, 20 and 30 commits later, was refused
    # every time though it needed no new compile: upstream edited another target in the same Package.swift, added a
    # declaration in a file the push also edits (the push's file then holds upstream's own line), or named an enum
    # the push only added a case to.
    def test_moved_base_another_target_in_the_push_s_package_manifest_passes(self):
        self.kit_app()
        manifest = self.read(f"{PKG}/Package.swift")
        refused, lines = self.rebased_push({self.APP: "import Kit\nfunc feature() -> Int { Kit().run() }\n"},
                                           {f"{PKG}/Package.swift": manifest.replace('.target(name: "Other"),',
                                                                                     '.target(name: "Other", dependencies: ["Base"]),')})
        self.assertFalse(refused, lines)

    def test_moved_base_a_manifest_change_to_a_target_that_uses_the_push_s_module_passes(self):
        self.kit_app()
        manifest = self.read(f"{PKG}/Package.swift")
        refused, lines = self.rebased_push({self.KIT: self.read(self.KIT).replace("func run() -> Int { 1 }", "func run() -> Int { 2 }")},
                                           {f"{PKG}/Package.swift": manifest.replace('name: "App", dependencies: ["Kit"]',
                                                                                     'name: "App", dependencies: ["Kit", "Other"]')})
        self.assertFalse(refused, lines)

    def test_moved_base_a_module_the_push_imports_gaining_dependencies_passes(self):
        self.kit_app()
        manifest = self.read(f"{PKG}/Package.swift")
        refused, lines = self.rebased_push({self.APP: "import Kit\nfunc feature() -> Int { Kit().run() }\n"},
                                           {f"{PKG}/Package.swift": manifest.replace('dependencies: ["Base"]',
                                                                                     'dependencies: ["Base", "Other"]')})
        self.assertFalse(refused, lines)

    def test_moved_base_a_module_the_push_imports_gaining_linker_settings_passes(self):
        self.kit_app()
        manifest = self.read(f"{PKG}/Package.swift")
        refused, lines = self.rebased_push({self.APP: "import Kit\nfunc feature() -> Int { Kit().run() }\n"},
                                           {f"{PKG}/Package.swift": manifest.replace(
                                               'dependencies: ["Base"]',
                                               'dependencies: ["Base"],\n            linkerSettings: [.linkedFramework("CoreFoundation")]')})
        self.assertFalse(refused, lines)

    def test_moved_base_a_module_the_push_imports_losing_a_dependency_is_refused(self):
        self.kit_app()
        manifest = self.read(f"{PKG}/Package.swift")
        refused, lines = self.rebased_push({self.APP: "import Kit\nfunc feature() -> Int { Kit().run() }\n"},
                                           {f"{PKG}/Package.swift": manifest.replace('dependencies: ["Base"]', 'dependencies: []')})
        self.assertTrue(refused, lines)
        self.assertIn("Package.swift", lines[0])

    def test_moved_base_the_push_s_own_module_gaining_a_dependency_passes(self):
        self.kit_app()
        manifest = self.read(f"{PKG}/Package.swift")
        refused, lines = self.rebased_push({self.KIT: self.read(self.KIT).replace("func run() -> Int { 1 }", "func run() -> Int { 2 }")},
                                           {f"{PKG}/Package.swift": manifest.replace('dependencies: ["Base"]',
                                                                                     'dependencies: ["Base", "Other"]')})
        self.assertFalse(refused, lines)

    def test_moved_base_a_manifest_change_to_a_target_the_push_uses_is_refused(self):
        self.kit_app()
        manifest = self.read(f"{PKG}/Package.swift")
        refused, lines = self.rebased_push({self.APP: "import Kit\nfunc feature() -> Int { Kit().run() }\n"},
                                           {f"{PKG}/Package.swift": manifest.replace('dependencies: ["Base"]',
                                                                                     'dependencies: ["Base"],\n            swiftSettings: [.define("X")]')})
        self.assertTrue(refused, lines)
        self.assertIn("Package.swift", lines[0])

    def test_moved_base_a_manifest_change_outside_the_targets_is_refused(self):
        self.kit_app()
        manifest = self.read(f"{PKG}/Package.swift")
        refused, lines = self.rebased_push({self.APP: "import Kit\nfunc feature() -> Int { Kit().run() }\n"},
                                           {f"{PKG}/Package.swift": manifest.replace('    name: "CmuxNext",\n',
                                                                                     '    name: "CmuxNext",\n    platforms: [.macOS(.v15)],\n')})
        self.assertTrue(refused, lines)

    def test_moved_base_an_upstream_declaration_in_a_file_the_push_also_edits_passes(self):
        long_app = "import Kit\nstruct App {\n    let kit = Kit()\n}\n" + "".join(f"let pad{i} = {i}\n" for i in range(12))
        self.kit_app()
        self.write(f"{PKG}/Sources/App/App.swift", long_app)
        self.base = self.commit("long app")
        refused, lines = self.rebased_push(
            {f"{PKG}/Sources/App/App.swift": long_app.replace("    let kit = Kit()\n", "    let kit = Kit()\n    let n = 1\n")},
            {f"{PKG}/Sources/App/App.swift": long_app + "func extra() -> Int { 2 }\n"})
        self.assertFalse(refused, lines)

    def test_moved_base_the_push_s_new_line_naming_upstream_s_new_declaration_is_refused(self):
        long_app = "import Kit\nstruct App {\n    let kit = Kit()\n}\n" + "".join(f"let pad{i} = {i}\n" for i in range(12))
        self.kit_app()
        self.write(f"{PKG}/Sources/App/App.swift", long_app)
        self.base = self.commit("long app")
        refused, lines = self.rebased_push(
            {f"{PKG}/Sources/App/App.swift": long_app.replace("    let kit = Kit()\n", "    let kit = Kit()\n    let n = extra()\n")},
            {f"{PKG}/Sources/App/App.swift": long_app + "func extra() -> Int { 2 }\n"})
        self.assertTrue(refused, lines)
        self.assertIn("extra", lines[0])

    def test_moved_base_an_enum_case_the_push_adds_passes_upstream_code_that_names_the_enum(self):
        self.kit_app()
        refused, lines = self.rebased_push({self.KIT: self.read(self.KIT).replace("    case b\n", "    case b\n    case c\n")},
                                           {f"{PKG}/Sources/App/Uses.swift": "import Kit\nlet chosen = Mode.a\n"})
        self.assertFalse(refused, lines)

    def test_moved_base_an_enum_case_the_push_adds_with_an_upstream_switch_is_refused(self):
        self.kit_app()
        refused, lines = self.rebased_push({self.KIT: self.read(self.KIT).replace("    case b\n", "    case b\n    case c\n")},
                                           {f"{PKG}/Sources/App/Uses.swift": "import Kit\nfunc name(_ m: Mode) -> Int {\n"
                                            "    switch m {\n    case .a: return 1\n    case .b: return 2\n    }\n}\n"})
        self.assertTrue(refused, lines)
        self.assertIn("Mode", lines[0])

    def test_moved_base_an_enum_case_the_push_adds_passes_an_upstream_switch_over_another_enum(self):
        self.kit_app(extra="public enum Shade {\n    case light\n    case dark\n}\n")
        refused, lines = self.rebased_push({self.KIT: self.read(self.KIT).replace("    case b\n", "    case b\n    case c\n")},
                                           {f"{PKG}/Sources/App/Uses.swift": "import Kit\nfunc tone(_ s: Shade) -> Int {\n"
                                            "    switch s {\n    case .light: return 1\n    case .dark: return 2\n    }\n}\n"})
        self.assertFalse(refused, lines)

    def test_moved_base_an_enum_case_the_push_renames_is_refused_where_upstream_names_the_enum(self):
        self.kit_app()
        refused, lines = self.rebased_push({self.KIT: self.read(self.KIT).replace("    case a\n", "    case first\n")},
                                           {f"{PKG}/Sources/App/Uses.swift": "import Kit\nlet chosen = Mode.a\n"})
        self.assertTrue(refused, lines)

    def test_moved_base_an_internal_member_removed_in_another_module_passes(self):
        self.kit_app(extra="struct Hidden {\n    let key = 1\n}\n")
        refused, lines = self.rebased_push({self.APP: "import Kit\nfunc feature() -> Int { let key = 2; return key }\n"},
                                           {self.KIT: self.read(self.KIT).replace("    let key = 1\n", "")})
        self.assertFalse(refused, lines)

    def test_moved_base_an_internal_member_removed_is_refused_for_a_testable_import(self):
        self.kit_app(extra="struct Hidden {\n    let key = 1\n}\n")
        refused, lines = self.rebased_push({self.APP: "@testable import Kit\nfunc feature() -> Int { Hidden().key }\n"},
                                           {self.KIT: self.read(self.KIT).replace("    let key = 1\n", "")})
        self.assertTrue(refused, lines)
        self.assertIn("key", lines[0])

    def test_moved_base_an_internal_member_removed_in_the_same_module_is_refused(self):
        self.kit_app()
        self.write(f"{PKG}/Sources/App/Store.swift", "struct Store {\n    let key = 1\n}\n")
        self.base = self.commit("store")
        refused, lines = self.rebased_push({self.APP: "import Kit\nfunc feature() -> Int { Store().key }\n"},
                                           {f"{PKG}/Sources/App/Store.swift": "struct Store {\n}\n"})
        self.assertTrue(refused, lines)
        self.assertIn("key", lines[0])

    def test_moved_base_cases_of_an_internal_enum_in_another_module_pass_an_upstream_switch(self):
        self.kit_app(extra="enum Keys: String {\n    case one\n    case two\n}\n")
        refused, lines = self.rebased_push({self.KIT: self.read(self.KIT).replace("    case two\n", "    case two\n    case three\n")},
                                           {f"{PKG}/Sources/App/Uses.swift": "import Kit\nfunc n(_ s: String) -> Int {\n"
                                            "    switch s {\n    case \"one\": return 1\n    default: return 2\n    }\n}\nlet one = 1\n"})
        self.assertFalse(refused, lines)

    def read(self, rel):
        return (self.repo / rel).read_text()

    def test_a_silent_controller_uses_the_job_record_an_earlier_push_read(self):
        # PL-instant's push: refused twice, then let through when the controller missed the bound on the third try.
        self.git("checkout", "-q", "-b", "topic")
        self.swift_edit(text="public struct Kit { let b = Base() }\n")
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
