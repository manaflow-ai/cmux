#!/usr/bin/env python3
"""scripts/lint-connection-lifetimes.py: each rule flags its shape and leaves the bounded one alone, and the
baseline ratchets (a new hit warns, a fixed hit leaves a stale entry that is reported)."""

import contextlib
import importlib.util
import io
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
LINTER = REPO_ROOT / "scripts" / "lint-connection-lifetimes.py"

RS = "cmux-tui/crates/acpmux/src/x.rs"
TS = "webviews/src/x.ts"
SWIFT = "Packages/macOS/CmuxNext/Sources/CmuxNextCloud/X.swift"


def load_linter():
    spec = importlib.util.spec_from_file_location("lint_connection_lifetimes", LINTER)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # dataclasses look their module up while the class is made
    spec.loader.exec_module(module)
    return module


lint = load_linter()


def rules(path, text):
    return [(hit.rule, hit.line) for hit in lint.scan_text(path, text)]


class ScopeTests(unittest.TestCase):
    def test_next_code_is_scanned_and_tests_vendor_classic_are_not(self):
        self.assertEqual(lint.language(RS), "rust")
        self.assertEqual(lint.language(TS), "ts")
        self.assertEqual(lint.language("webviews/src/a/b.tsx"), "ts")
        self.assertEqual(lint.language(SWIFT), "swift")
        for path in (
            "cmux-tui/crates/acpmux/tests/x.rs",
            "cmux-tui/crates/acpmux/src/x_tests.rs",
            "cmux-tui/crates/acpmux/src/tests.rs",
            "cmux-tui/crates/ghostty-vt/src/lib.rs",
            "cmux-tui/crates/cmux-classic-import/src/lib.rs",
            "cmux-tui/vendor/foo/src/lib.rs",
            "webviews/src/a.test.ts",
            "webviews/test/a.ts",
            "Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/A.swift",
            "Sources/Classic.swift",
            "ghostty/src/main.zig",
        ):
            self.assertIsNone(lint.language(path), path)

    def test_cfg_test_modules_comments_and_strings_are_not_scanned(self):
        text = (
            "#[cfg(test)]\n"
            "mod tests {\n"
            "    async fn t() { let s = tokio::net::TcpStream::connect(a).await; }\n"
            "}\n"
            "// TcpStream::connect(addr) in a comment\n"
            'const S: &str = "TcpStream::connect(addr)";\n'
            "fn after() { let s = std::net::TcpStream::connect(a); }\n"
        )
        self.assertEqual(rules(RS, text), [("R1", 7)])


class R1Tests(unittest.TestCase):
    def test_flags_open_without_deadline(self):
        self.assertEqual(rules(RS, "async fn f() {\n    let s = TcpStream::connect(addr).await?;\n}\n"), [("R1", 2)])
        self.assertEqual(rules(RS, "fn f() {\n    let s = UnixStream::connect(&path)?;\n    s.write_all(b)?;\n}\n"), [("R1", 2)])
        self.assertEqual(rules(RS, "async fn f() {\n    let (ws, _) = tokio_tungstenite::connect_async(req).await?;\n}\n"), [("R1", 2)])
        self.assertEqual(rules(RS, "fn f() {\n    let c = reqwest::Client::new();\n}\n"), [("R1", 2)])
        self.assertEqual(rules(RS, "use reqwest::Client;\nfn f() {\n    let c = Client::builder().build()?;\n}\n"), [("R1", 3)])

    def test_bounded_open_passes(self):
        wrapped = "async fn f() {\n    let s = tokio::time::timeout(CONNECT, TcpStream::connect(addr)).await??;\n}\n"
        self.assertEqual(rules(RS, wrapped), [])
        multiline = "async fn f() {\n    let s = timeout(\n        CONNECT,\n        UnixStream::connect(&p),\n    ).await;\n}\n"
        self.assertEqual(rules(RS, multiline), [])
        read_timeout = "fn f() {\n    let s = UnixStream::connect(&p)?;\n    s.set_read_timeout(Some(T))?;\n}\n"
        self.assertEqual(rules(RS, read_timeout), [])
        client = "fn f() {\n    let c = reqwest::Client::builder()\n        .connect_timeout(T)\n        .build()?;\n}\n"
        self.assertEqual(rules(RS, client), [])
        # Without reqwest in the file, `Client::new()` is someone else's type.
        self.assertEqual(rules(RS, "fn f() {\n    let c = Client::new();\n}\n"), [])

    def test_escape_marker(self):
        marked = "fn f() {\n    // lifetime-ok: a local socket the daemon owns; reads are bounded by the caller\n    let s = UnixStream::connect(&p)?;\n}\n"
        self.assertEqual(rules(RS, marked), [])
        inline = "fn f() {\n    let s = UnixStream::connect(&p)?; // lifetime-ok: probe only\n}\n"
        self.assertEqual(rules(RS, inline), [])


class R2Tests(unittest.TestCase):
    def test_flags_spawn_nobody_kills(self):
        text = 'fn f() {\n    let child = Command::new("x").arg("y").spawn()?;\n    Ok(child)\n}\n'
        self.assertEqual(rules(RS, text), [("R2", 2)])
        waited_no_group = 'fn f() {\n    let mut c = Command::new("x");\n    let mut child = c.spawn()?;\n    child.wait()?;\n}\n'
        self.assertEqual(rules(RS, waited_no_group), [("R2", 2)])

    def test_owned_spawn_passes(self):
        kill = 'async fn f() {\n    let child = tokio::process::Command::new("x")\n        .kill_on_drop(true)\n        .spawn()?;\n}\n'
        self.assertEqual(rules(RS, kill), [])
        group = (
            "fn f() {\n"
            '    let mut c = Command::new("x");\n'
            "    c.process_group(0);\n"
            "    let mut child = c.spawn()?;\n"
            "    let status = child.wait()?;\n"
            "}\n"
        )
        self.assertEqual(rules(RS, group), [])
        # .output() / .status() wait for the child themselves.
        self.assertEqual(rules(RS, 'fn f() {\n    let out = Command::new("git").arg("x").output()?;\n}\n'), [])

    def test_scope_ends_at_the_next_fn(self):
        text = (
            'fn build() -> Command {\n    Command::new("x")\n}\n'
            "fn other() {\n    let child = make().spawn();\n}\n"
        )
        self.assertEqual(rules(RS, text), [])


class R3Tests(unittest.TestCase):
    def test_flags_dropped_handle(self):
        self.assertEqual(rules(RS, "fn f() {\n    tokio::spawn(async move {\n        work().await;\n    });\n}\n"), [("R3", 2)])
        self.assertEqual(rules(RS, "fn f() {\n    let _ = tokio::spawn(work());\n}\n"), [("R3", 2)])
        imported = "use tokio::task::spawn_local;\nfn f() {\n    spawn_local(async { work().await });\n}\n"
        self.assertEqual(rules(RS, imported), [("R3", 3)])

    def test_kept_or_cancellable_passes(self):
        self.assertEqual(rules(RS, "fn f() {\n    let h = tokio::spawn(work());\n    h.abort();\n}\n"), [])
        self.assertEqual(rules(RS, "fn f() -> JoinHandle<()> {\n    tokio::spawn(work())\n}\n"), [])
        self.assertEqual(rules(RS, "fn f() {\n    handles.push(tokio::spawn(work()));\n}\n"), [])
        token = (
            "fn f(token: CancellationToken) {\n"
            "    tokio::spawn(async move {\n"
            "        tokio::select! { _ = token.cancelled() => {}, _ = work() => {} }\n"
            "    });\n"
            "}\n"
        )
        self.assertEqual(rules(RS, token), [])
        # A bare spawn( that is not tokio's.
        self.assertEqual(rules(RS, "fn f() {\n    spawn(async { work().await });\n}\n"), [])


class R4Tests(unittest.TestCase):
    def test_flags_unkept_and_uncleared_timers(self):
        self.assertEqual(rules(TS, "export function start() {\n  setInterval(tick, 1000);\n}\n"), [("R4", 2)])
        self.assertEqual(rules(TS, "export function start() {\n  window.setTimeout(() => refresh(), 5000);\n}\n"), [("R4", 2)])
        self.assertEqual(rules(TS, "export function start() {\n  const id = setInterval(tick, 1000);\n}\n"), [("R4", 2)])

    def test_kept_cleared_or_short_timers_pass(self):
        cleared = "useEffect(() => {\n  const id = setInterval(tick, 1000);\n  return () => clearInterval(id);\n}, []);\n"
        self.assertEqual(rules(TS, cleared), [])
        ref = "timer.current = window.setTimeout(save, 2000);\nexport const stop = () => window.clearTimeout(timer.current);\n"
        self.assertEqual(rules(TS, ref), [])
        self.assertEqual(rules(TS, "export function later() {\n  setTimeout(() => focus(), 0);\n}\n"), [])
        self.assertEqual(rules(TS, "export function later() {\n  setTimeout(() => focus());\n}\n"), [])
        self.assertEqual(rules(TS, "export async function sleep(ms: number) {\n  await new Promise((r) => setTimeout(r, ms));\n}\n"), [])

    def test_sockets_need_close_and_handlers(self):
        bare = "export function open(url: string) {\n  const ws = new WebSocket(url);\n  ws.onmessage = (e) => handle(e);\n}\n"
        self.assertEqual(rules(TS, bare), [("R4", 2)])
        handled = (
            "export function open(url: string) {\n"
            "  const ws = new WebSocket(url);\n"
            "  ws.addEventListener('close', reconnect);\n"
            "  return () => ws.close();\n"
            "}\n"
        )
        self.assertEqual(rules(TS, handled), [])
        source = "const es = new EventSource(url);\nes.onerror = () => es.close();\n"
        self.assertEqual(rules(TS, source), [])


class R5Tests(unittest.TestCase):
    def test_flags_unbounded_polling_wait(self):
        rust = (
            "async fn wait_ready() {\n"
            "    loop {\n"
            "        if ready().await { break; }\n"
            "        tokio::time::sleep(Duration::from_millis(100)).await;\n"
            "    }\n"
            "}\n"
        )
        self.assertEqual(rules(RS, rust), [("R5", 2)])
        ts = "export async function waitReady() {\n  while (true) {\n    if (await ready()) return;\n    await sleep(100);\n  }\n}\n"
        self.assertEqual(rules(TS, ts), [("R5", 2)])

    def test_bounded_or_periodic_loops_pass(self):
        rust = (
            "async fn wait_ready() {\n"
            "    let deadline = Instant::now() + WAIT;\n"
            "    loop {\n"
            "        if ready().await { break; }\n"
            "        if Instant::now() > deadline { return; }\n"
            "        sleep(Duration::from_millis(100)).await;\n"
            "    }\n"
            "}\n"
        )
        self.assertEqual(rules(RS, rust), [])
        periodic = "async fn ticker() {\n    loop {\n        sleep(PERIOD).await;\n        refresh().await;\n    }\n}\n"
        self.assertEqual(rules(RS, periodic), [])
        ts = (
            "export async function waitReady(signal: AbortSignal) {\n"
            "  while (true) {\n"
            "    if (signal.aborted || (await ready())) return;\n"
            "    await sleep(100);\n"
            "  }\n"
            "}\n"
        )
        self.assertEqual(rules(TS, ts), [])


class R6Tests(unittest.TestCase):
    def test_flags_socket_without_ping_and_process_without_terminate(self):
        text = "func open() {\n    let task = session.webSocketTask(with: request)\n    let p = Process()\n    try p.run()\n}\n"
        self.assertEqual(rules(SWIFT, text), [("R6", 2), ("R6", 3)])

    def test_pinged_terminated_or_marked_passes(self):
        text = (
            "func open() {\n"
            "    let task = session.webSocketTask(with: request)\n"
            "    task.sendPing { _ in }\n"
            "    let p = Process()\n"
            "    onCancel { p.terminate() }\n"
            "}\n"
        )
        self.assertEqual(rules(SWIFT, text), [])
        marked = "func open() {\n    // wakeup-allow: the server pings us every 20 s\n    let task = session.webSocketTask(with: r)\n}\n"
        self.assertEqual(rules(SWIFT, marked), [])
        self.assertEqual(rules(SWIFT, "let x = AsyncProcess()\n"), [])


class BaselineTests(unittest.TestCase):
    def test_fingerprint_ignores_line_numbers_and_indentation(self):
        a = lint.scan_text(RS, "fn f() {\n    let s = UnixStream::connect(&p)?;\n}\n")
        b = lint.scan_text(RS, "// moved\n\nfn f() {\n        let s = UnixStream::connect(&p)?;\n}\n")
        self.assertEqual([hit.key for hit in a], [hit.key for hit in b])
        self.assertNotEqual(a[0].line, b[0].line)

    def test_ratchet_reports_new_and_stale(self):
        old = lint.scan_text(RS, "fn f() {\n    let s = UnixStream::connect(&p)?;\n    let t = TcpStream::connect(a)?;\n}\n")
        baseline = lint.load_baseline(lint.render_baseline(old))
        self.assertEqual(sum(baseline.values()), 2)
        self.assertEqual(lint.compare(old, baseline), ([], []))
        # The TcpStream hit is fixed, a new reqwest client appears, the UnixStream line is unchanged.
        now = lint.scan_text(RS, "fn f() {\n    let s = UnixStream::connect(&p)?;\n    let c = reqwest::Client::new();\n}\n")
        new, stale = lint.compare(now, baseline)
        self.assertEqual([(hit.rule, hit.line) for hit in new], [("R1", 3)])
        self.assertEqual([(key[0], key[1], gone) for key, gone in stale], [(RS, "R1", 1)])

    def test_a_repeated_line_counts_each_hit(self):
        one = lint.scan_text(RS, "fn f() {\n    let s = UnixStream::connect(&p)?;\n}\n")
        two = lint.scan_text(RS, "fn f() {\n    let s = UnixStream::connect(&p)?;\n}\nfn g() {\n    let s = UnixStream::connect(&p)?;\n}\n")
        new, stale = lint.compare(two, lint.load_baseline(lint.render_baseline(one)))
        self.assertEqual(([(hit.line) for hit in new], stale), ([5], []))

    def test_main_is_warn_only_unless_strict(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            src = root / RS
            src.parent.mkdir(parents=True)
            src.write_text("fn f() {\n    let s = UnixStream::connect(&p)?;\n}\n", encoding="utf-8")
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(["git", "-C", str(root), "add", "."], check=True)
            baseline = root / "baseline.txt"
            baseline.write_text(lint.BASELINE_HEADER, encoding="utf-8")
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(lint.main(["--root", str(root), "--baseline", str(baseline)]), 0)
            self.assertIn("1 new", out.getvalue())
            self.assertIn("connections-and-lifetimes.md", out.getvalue())
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(lint.main(["--root", str(root), "--baseline", str(baseline), "--strict"]), 1)
                self.assertEqual(lint.main(["--root", str(root), "--baseline", str(baseline), "--update-baseline"]), 0)
                self.assertEqual(lint.main(["--root", str(root), "--baseline", str(baseline), "--strict"]), 0)
            # Fixing the hit leaves a stale entry: reported, red under --strict.
            src.write_text("fn f() {}\n", encoding="utf-8")
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(lint.main(["--root", str(root), "--baseline", str(baseline)]), 0)
                self.assertEqual(lint.main(["--root", str(root), "--baseline", str(baseline), "--strict"]), 1)
            self.assertIn("1 fixed since the baseline", out.getvalue())

    def test_checked_in_baseline_parses(self):
        baseline = lint.load_baseline(lint.BASELINE.read_text(encoding="utf-8"))
        self.assertGreater(sum(baseline.values()), 0)


if __name__ == "__main__":
    unittest.main()
