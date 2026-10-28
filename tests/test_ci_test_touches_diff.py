#!/usr/bin/env python3
"""test_touches_diff: per-file verdicts from a bun metafile, and a real bundle when bun is present."""
import http.server
import importlib.util
import shutil
import socket
import threading
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
spec = importlib.util.spec_from_file_location("touches", ROOT / "scripts/ci/test_touches_diff.py")
touches = importlib.util.module_from_spec(spec)
spec.loader.exec_module(touches)

# The shape of PR #21651's case: the test reaches repository.ts through
# routeHelpers.ts, and never reaches workflows.ts.
EDGES = {
    "tests/vm-route-deadlines.test.ts": ["services/vms/routeHelpers.ts", "services/vms/routeDeadline.ts"],
    "services/vms/routeHelpers.ts": ["services/vms/repository.ts"],
    "services/vms/routeDeadline.ts": ["services/vms/types.ts"],
    "services/vms/repository.ts": [],
    "services/vms/types.ts": [],
    "tests/test-preload.ts": [],
}
SIZES = {"services/vms/routeHelpers.ts": 900, "services/vms/repository.ts": 4000, "services/vms/types.ts": 0}
ENTRIES = ["tests/vm-route-deadlines.test.ts", "tests/test-preload.ts"]


def by_file(files):
    return {f["file"]: f for f in files}


class Verdicts(unittest.TestCase):
    def test_graph_only_verdicts(self):
        files = by_file(touches.verdicts(
            ["web/services/vms/workflows.ts", "web/services/vms/repository.ts", "web/services/vms/types.ts",
             "docs/x.md"], EDGES, SIZES, ENTRIES))
        self.assertEqual(files["web/services/vms/workflows.ts"]["verdict"], "not imported")
        self.assertEqual(files["docs/x.md"]["verdict"], "not imported")
        self.assertEqual(files["web/services/vms/types.ts"]["verdict"], "tree-shaken")
        repo = files["web/services/vms/repository.ts"]
        self.assertEqual(repo["verdict"], "imported")
        self.assertEqual(repo["chain"], ["tests/vm-route-deadlines.test.ts", "services/vms/routeHelpers.ts",
                                         "services/vms/repository.ts"])

    def test_test_paths(self):
        self.assertEqual(touches.test_path("tests/a.test.ts"), "web/tests/a.test.ts")
        self.assertEqual(touches.test_path("./tests/a.test.ts"), "web/tests/a.test.ts")
        self.assertEqual(touches.test_path("web/tests/a.test.ts"), "web/tests/a.test.ts")

    def test_runner_files_reach_every_test(self):
        files = touches.verdicts(["web/bun.lock", "web/bunfig.toml"], EDGES, SIZES, ENTRIES)
        self.assertEqual({f["verdict"] for f in files}, {"runner"})
        self.assertIn("every test", touches.summary_line("tests/a.test.ts", files, False))

    def test_coverage_separates_run_from_merely_imported(self):
        lines = {"web/services/vms/repository.ts": {3844, 3849}, "web/services/vms/routeHelpers.ts": {10},
                 "web/services/vms/routeDeadline.ts": {7}}
        hits = {"services/vms/repository.ts": {3844: 0, 3849: 0, 12: 5},
                "services/vms/routeHelpers.ts": {10: 3}}
        sizes = {**SIZES, "services/vms/routeDeadline.ts": 100}
        files = by_file(touches.verdicts(list(lines), EDGES, sizes, ENTRIES, lines, hits))
        self.assertEqual(files["web/services/vms/repository.ts"]["verdict"], "not executed")
        self.assertEqual(files["web/services/vms/repository.ts"]["lines_not_run"], [3844, 3849])
        self.assertEqual(files["web/services/vms/routeHelpers.ts"]["verdict"], "executed")
        # Bundled, but bun never loaded it while the test ran.
        self.assertEqual(files["web/services/vms/routeDeadline.ts"]["verdict"], "not executed")

    def test_changed_lines_above_the_first_block_are_not_code(self):
        files = touches.verdicts(["web/services/vms/repository.ts"], EDGES, SIZES, ENTRIES,
                                 {"web/services/vms/repository.ts": {3, 4}},
                                 {"services/vms/repository.ts": {12: 1}})
        self.assertEqual(files[0]["verdict"], "no code changed")
        self.assertIn("runs none of the changed code", touches.summary_line("tests/t.test.ts", files, True))

    def test_a_changed_line_takes_its_blocks_hits(self):
        # bun lists an uncalled function only by its first line (4, 0 hits); line 5 is inside it.
        hits = {1: 11, 2: 9, 4: 0}
        self.assertEqual(touches.block_hits(hits, {2, 5}), {2: 9, 5: 0})
        self.assertEqual(touches.block_hits(hits, None), hits)

    def test_comments_and_type_declarations_are_not_code(self):
        text = "\n".join([
            "export type Shape = {",       # 1
            "  /** doc",                   # 2
            "   * more */",                # 3
            "  readonly a: number;",       # 4
            "};",                          # 5
            "// note",                     # 6
            "",                            # 7
            "export const x = run();",     # 8
            "interface Other { b: string }",  # 9
            "function f() {",              # 10
            "  return x; // trailing",     # 11
            "}",                           # 12
        ])
        self.assertEqual(touches.code_lines(text), {8, 10, 11, 12})

    def test_lcov_parsing_relativizes_and_sums(self):
        root = Path("/w/web")
        text = "SF:/w/web/services/a.ts\nDA:1,2\nDA:2,0\nend_of_record\nSF:services/b.ts\nDA:5,1\nend_of_record\n"
        self.assertEqual(touches.parse_lcov(text, root), {"services/a.ts": {1: 2, 2: 0}, "services/b.ts": {5: 1}})

    def test_buns_environment_is_an_allowlist(self):
        import os
        saved = dict(os.environ)
        os.environ.update({"GH_TOKEN": "x", "DBUS_SESSION_BUS_ADDRESS": "x", "XDG_CONFIG_HOME": "/x",
                           "SOMETHING": "x", "LANG": "C.UTF-8"})
        try:
            with tempfile.TemporaryDirectory() as tmp:
                env = touches.bun_env(Path(tmp) / "home")
        finally:
            os.environ.clear()
            os.environ.update(saved)
        self.assertEqual(set(env) - {"PATH", "LANG", "LC_ALL", "TERM"}, {"HOME", "TMPDIR", "NO_COLOR"})
        self.assertEqual(env["LANG"], "C.UTF-8")

    def test_render_names_what_the_graph_cannot_see(self):
        report = {"summary": "s", "test": "web/tests/a.test.ts", "head": "abc", "graph_size": 1, "entries": ["a"],
                  "changed": 1, "files": [], "deleted": ["web/lib/gone.ts"], "sandboxed": False}
        text = touches.render(report)
        self.assertIn("1 deleted file(s) not checked: web/lib/gone.ts", text)
        self.assertIn("unsandboxed", text)
        self.assertIn("mock.module()", text)


class FailClosed(unittest.TestCase):
    """Anything that could carry import attributes refuses the bundle; ordinary code passes."""

    UNSAFE = {
        "plain": 'import { b } from "./m" with { type: "macro" };',
        "quoted key": "import { b } from './m' with { \"type\": \"macro\" };",
        "extra attribute": 'import { b } from "./m" with { type: "macro", x: "y" };',
        "comment in braces": 'import { b } from "./m" with { /* hi */ type: "macro" };',
        "escaped value": 'import { b } from "./m" with { type: "\\x6dacro" };',
        "comment before clause": 'import { b } from "./m" /* c */ with // d\n { type: "macro" };',
        "assert": 'import { b } from "./m" assert { type: "macro" };',
        "json attribute": 'import data from "./d.json" with { type: "json" };',
        "re-export": 'export { b } from "./m" with { type: "macro" };',
        "dynamic": 'const m = await import("./m", { with: { type: "macro" } });',
        "dynamic quoted": 'const m = await import("./m", { "assert": { type: "macro" } });',
        # JS ends a // comment at CR, LS and PS too, and treats BOM and NBSP as whitespace.
        "comment ended by CR": 'import { b } from "./m" //x\rwith { type: "macro" };',
        "comment ended by LS": 'import { b } from "./m" //x\u2028with { type: "macro" };',
        "comment ended by PS": 'import { b } from "./m" //x\u2029with { type: "macro" };',
        "BOM as whitespace": 'import { b } from "./m"\ufeffwith\ufeff{ type: "macro" };',
        "NBSP as whitespace": 'import { b } from "./m"\u00a0with {type:"macro"};',
        "CRLF lines": 'import { b } from "./m"\r\nwith\r\n{ type: "macro" };',
        # Any second argument to import() is refused, however far or however punctuated.
        "dynamic past a semicolon": 'const m = await import("./m", { x: ";", with: { type: "macro" } });',
        "dynamic far away": 'const m = await import("./m", {' + " " * 500 + 'with: { type: "macro" } });',
        "dynamic computed key": 'const k = "with";\nconst m = await import("./m", { [k]: { type: "macro" } });',
        "dynamic options variable": "const m = await import('./m', options);",
        "dynamic nested": 'const m = await import(String(import("./m", o)));',
        "dynamic unterminated": 'const m = await import("./m"',
    }
    SAFE = {
        "doc comment": "/** Rejects with {@link VmModelPlaneError}; the workflow fails. */\nexport const a = 1;",
        "plain import": 'import { b } from "./m";\nconst o = { with: 1 };',
        "dynamic": "const m = await import(pathToFileURL(resolve(root, path)).href);",
        # The shapes web/ uses today.
        "dynamic template": "const messages = (await import(`../messages/${locale}.json`)).default;",
        "dynamic nested template": "await import(`../messages/${f(`x${a}`, [1, {b: 2}])}.json`);",
        "dynamic identifier": "const mod = await import(ssrLayoutEffectPath);",
        "dynamic trailing comma": 'const m = await import(\n  "./m",\n);',
        "dynamic with comment": 'const m = await import(/* webpackChunkName: "m" */ "./m");',
        "type query": 'type M = typeof import("./m").default;',
    }

    def reasons(self, files):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name, text in files.items():
                (root / name).parent.mkdir(parents=True, exist_ok=True)
                (root / name).write_text(text)
            return touches.unsafe_reasons(root)

    def test_every_attribute_spelling_is_refused(self):
        for label, text in self.UNSAFE.items():
            with self.subTest(label):
                self.assertTrue(self.reasons({"lib/a.ts": text}), label)

    def test_ordinary_code_is_not(self):
        for label, text in self.SAFE.items():
            with self.subTest(label):
                self.assertEqual(self.reasons({"lib/a.ts": text}), [], label)

    def test_symlinks_and_oversized_files_are_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "lib").mkdir()
            (root / "lib" / "link.ts").symlink_to("/etc/hostname")
            (root / "lib" / "big.ts").write_text("x" * (touches.MAX_SCAN_BYTES + 1))
            reasons = touches.unsafe_reasons(root)
        self.assertEqual(reasons, ["lib/big.ts is too large to scan", "lib/link.ts is a symlink"])

    def test_a_crafted_file_cannot_make_the_scan_slow(self):
        # A backtracking scanner would hang on this input; the thread join is a
        # hang guard, not a latency budget (a linear scan finishes in well under 1s).
        crafted = '"' + "/*" + "*" * 200_000 + ' with x' * 20_000
        worker = threading.Thread(target=self.reasons, args=({"lib/a.ts": crafted},), daemon=True)
        worker.start()
        worker.join(timeout=120)
        self.assertFalse(worker.is_alive(), "the import scan hung on a crafted file")

    def test_a_package_json_that_mentions_macros_is_refused(self):
        self.assertTrue(self.reasons({"package.json": '{"macros": {"x": "./m"}}'}))
        self.assertEqual(self.reasons({"package.json": '{"name": "web"}'}), [])


@unittest.skipUnless(touches.can_sandbox() and shutil.which("bun"), "needs Linux user namespaces and bun")
class Sandbox(unittest.TestCase):
    def test_bun_sees_no_home_directory_and_no_network(self):
        # A server on this host's loopback, which a sandbox with its own network namespace can't reach.
        server = http.server.HTTPServer(("127.0.0.1", 0), http.server.BaseHTTPRequestHandler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            url = f"http://127.0.0.1:{server.server_address[1]}/"
            home = str(Path.home())
            script = ("const fs = require('fs');"
                      f"console.log(fs.readdirSync({home!r}).length);"
                      f"try {{ await fetch({url!r}); console.log('net'); }} catch {{ console.log('no-net'); }}")
            with tempfile.TemporaryDirectory(dir="/tmp") as tmp:
                result = touches.run_bun(["-e", script], Path(tmp), Path(tmp), sandbox=True)
                unsandboxed = touches.run_bun(["-e", script], Path(tmp), Path(tmp), sandbox=False)
        finally:
            server.shutdown()
            server.server_close()
        self.assertEqual(result.stdout.split(), ["0", "no-net"], result.stderr)
        self.assertEqual(unsandboxed.stdout.split()[-1], "net", unsandboxed.stderr)  # the server was reachable

    def test_bun_can_write_only_in_the_work_directory(self):
        # Root inside the namespace tries to undo the read-only mounts first, then to write.
        script = ("const fs = require('fs');"
                  "Bun.spawnSync(['mount', '-o', 'remount,bind,rw', '/']);"
                  "Bun.spawnSync(['mount', '-o', 'remount,bind,rw', '/tmp']);"
                  "for (const p of process.argv.slice(1)) {"
                  "  try { fs.writeFileSync(p, 'x'); console.log('wrote'); } catch { console.log('refused'); } }")
        with tempfile.TemporaryDirectory(dir="/tmp") as tmp:
            work, outside = Path(tmp, "work"), Path(tmp, "outside")
            work.mkdir()
            outside.mkdir()
            in_tmp = Path("/tmp", f"{Path(tmp).name}-planted")
            targets = [in_tmp, outside / "planted", work / "ok", work / "home" / "ok"]
            try:
                result = touches.run_bun(["-e", script, *map(str, targets)], work, work, sandbox=True)
                self.assertEqual(result.stdout.split(), ["refused", "refused", "wrote", "wrote"], result.stderr)
                self.assertFalse(in_tmp.exists())
                self.assertFalse((outside / "planted").exists())
            finally:
                in_tmp.unlink(missing_ok=True)

    def test_bun_cannot_reach_the_host_through_proc_or_unix_sockets(self):
        # /proc/<ppid>/root leads back to the host's writable mounts, and a read-only mount
        # still lets connect() reach a socket file (tmux, the user bus, docker, ssh-agent).
        script = ("const fs = require('fs'); const net = require('net');"
                  "const [planted, sock] = process.argv.slice(1);"
                  "for (const pid of [process.ppid, 1]) {"
                  "  try { fs.writeFileSync(`/proc/${pid}/root${planted}`, 'x'); console.log('wrote'); }"
                  "  catch { console.log('refused'); } }"
                  "const c = net.connect(sock);"
                  "c.on('connect', () => { console.log('connected'); c.destroy(); });"
                  "c.on('error', () => console.log('no-socket'));")
        with tempfile.TemporaryDirectory(dir="/tmp") as tmp:
            work, outside = Path(tmp, "work"), Path(tmp, "outside")
            work.mkdir()
            outside.mkdir()
            planted, sock_path = outside / "planted", outside / "host.sock"
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            listener.bind(str(sock_path))
            listener.listen(1)
            try:
                result = touches.run_bun(["-e", script, str(planted), str(sock_path)], work, work, sandbox=True)
            finally:
                listener.close()
            self.assertEqual(result.stdout.split(), ["refused", "refused", "no-socket"], result.stderr)
            self.assertFalse(planted.exists())


@unittest.skipUnless(shutil.which("git"), "needs git")
class ChangedLines(unittest.TestCase):
    def test_a_deletion_only_hunk_still_names_its_place(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            run = lambda *args: subprocess.run(["git", "-C", tmp, *args], check=True, capture_output=True)
            run("init", "-q", "-b", "main")
            run("config", "user.email", "t@example.com")
            run("config", "user.name", "t")
            (repo / "a.ts").write_text("function f() {\n  guard();\n  await work();\n  return 1;\n}\n")
            run("add", "-A")
            run("commit", "-qm", "base")
            (repo / "a.ts").write_text("function f() {\n  return 1;\n}\n")  # deletes lines 2-3 only
            run("commit", "-qam", "head")
            lines = touches.changed_lines(repo, "HEAD~1", "HEAD", "a.ts")
        # The lines on either side of the deletion, so the block that lost them is still checked.
        self.assertEqual(lines, {1, 2})


# The fixture repositories below are this test's own, so it vouches for them where
# there's no sandbox (macOS); on Linux they run sandboxed anyway.
TRUSTED = True


@unittest.skipUnless(shutil.which("bun") and shutil.which("git"), "needs bun and git")
class RealBundle(unittest.TestCase):
    """A two-commit repository: the diff changes one imported and one unrelated file."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "t@example.com")
        self.git("config", "user.name", "t")
        self.write("web/bunfig.toml", '[test]\npreload = ["./tests/preload.ts"]\n')
        self.write("web/tests/preload.ts", "export {};\n")
        self.write("web/lib/used.ts", "export function used() {\n  return 1;\n}\nexport function idle() {\n  return 2;\n}\n")
        self.write("web/lib/types.ts", "export type Shape = { a: number };\n")
        self.write("web/lib/other.ts", "export const other = 1;\n")
        self.write("web/tests/a.test.ts",
                   'import { test, expect } from "bun:test";\nimport { used } from "../lib/used";\n'
                   'import type { Shape } from "../lib/types";\n'
                   'test("a", () => { const s: Shape = { a: used() }; expect(s.a).toBe(1); });\n')
        self.git("add", "-A")
        self.git("commit", "-qm", "base")
        self.write("web/lib/used.ts", "export function used() {\n  return 1;\n}\nexport function idle() {\n  return 3;\n}\n")
        self.write("web/lib/other.ts", "export const other = 2;\n")
        self.git("commit", "-qam", "head")

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        subprocess.run(["git", "-C", str(self.repo), *args], check=True, capture_output=True)

    def write(self, path, text):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def test_checked_out_head(self):
        report = touches.check(self.repo, "tests/a.test.ts", "HEAD~1", "HEAD", allow_unsandboxed=TRUSTED)
        files = by_file(report["files"])
        self.assertEqual(report["entries"], ["tests/a.test.ts", "tests/preload.ts"])
        self.assertEqual(files["web/lib/used.ts"]["verdict"], "imported")
        self.assertEqual(files["web/lib/other.ts"]["verdict"], "not imported")
        self.assertTrue(report["touches"])

    def test_extracted_head_when_the_checkout_is_elsewhere(self):
        self.git("checkout", "-q", "HEAD~1")
        report = touches.check(self.repo, "web/tests/a.test.ts", "main~1", "main", allow_unsandboxed=TRUSTED)
        self.assertEqual(by_file(report["files"])["web/lib/used.ts"]["verdict"], "imported")

    def test_a_macro_in_the_head_is_refused_and_never_run(self):
        # bun runs `with { type: "macro" }` imports while bundling; the check must refuse first.
        canary = self.repo / "PWNED"
        self.write("web/lib/boom.ts", 'import { writeFileSync } from "node:fs";\n'
                   f'export function boom() {{ writeFileSync({str(canary)!r}, "x"); return 1; }}\n')
        self.write("web/tests/a.test.ts", 'import { test } from "bun:test";\n'
                   'import { boom } from "../lib/boom" with { "type": "macro", x: "y" };\n'
                   'test("a", () => { boom(); });\n')
        self.git("add", "-A")
        self.git("commit", "-qm", "macro")
        with self.assertRaises(touches.UnsafeToAnalyse) as raised:
            touches.check(self.repo, "tests/a.test.ts", "HEAD~1", "HEAD", allow_unsandboxed=TRUSTED)
        self.assertIn("tests/a.test.ts has an import attribute clause", str(raised.exception))
        self.assertFalse(canary.exists(), "bun build ran the head's macro")

    def test_without_a_sandbox_bun_never_sees_the_head(self):
        original = touches.can_sandbox
        touches.can_sandbox = lambda: False
        try:
            with self.assertRaises(touches.UnsafeToAnalyse) as raised:
                touches.check(self.repo, "tests/a.test.ts", "HEAD~1", "HEAD")
            self.assertIn("no sandbox", str(raised.exception))
            # A caller vouching for the commit gets the graph, unsandboxed.
            report = touches.check(self.repo, "tests/a.test.ts", "HEAD~1", "HEAD", allow_unsandboxed=True)
            self.assertFalse(report["sandboxed"])
        finally:
            touches.can_sandbox = original

    def test_deleted_files_are_listed(self):
        self.git("rm", "-q", "web/lib/other.ts")
        self.git("commit", "-qm", "delete")
        report = touches.check(self.repo, "tests/a.test.ts", "HEAD~1", "HEAD", allow_unsandboxed=TRUSTED)
        self.assertEqual(report["deleted"], ["web/lib/other.ts"])

    def test_coverage_sees_that_the_changed_function_never_runs(self):
        report = touches.check(self.repo, "tests/a.test.ts", "HEAD~1", "HEAD", coverage=True, allow_unsandboxed=TRUSTED)
        used = by_file(report["files"])["web/lib/used.ts"]
        self.assertEqual(used["verdict"], "not executed", used)
        self.assertFalse(report["touches"])


if __name__ == "__main__":
    unittest.main()
