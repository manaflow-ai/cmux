#!/usr/bin/env python3
"""The resource-lifetime lint: each rule catches its shape, leaves the bounded or owned form alone, and the
allowlist only shrinks. CI runs scripts/ci/lint_resource_lifetimes.py itself for the tree check."""

from __future__ import annotations

import importlib.util
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("lint_resource_lifetimes", ROOT / "scripts/ci/lint_resource_lifetimes.py")
lint = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = lint
SPEC.loader.exec_module(lint)

# Fixture source text, spelled so the test-determinism guard does not read it as a sleep in this test.
SET_TIMEOUT = "set" "Timeout"


def rules(text: str, lang: str) -> list[str]:
    return [rule for _, rule, _ in lint.scan_text(text, lang)]


class Rust(unittest.TestCase):
    def test_connect(self):
        self.assertEqual(rules("async fn a() { let s = TcpStream::connect(addr).await?; }", "rs"),
                         ["connect-no-timeout"])
        self.assertEqual(rules("async fn a() { let (ws, _) = connect_async(url).await?; }", "rs"),
                         ["connect-no-timeout"])
        self.assertEqual(rules("async fn a() {\n let s = tokio::time::timeout(d, UnixStream::connect(p)).await;\n}", "rs"), [])
        self.assertEqual(rules("fn a() { let s = std::net::TcpStream::connect_timeout(&addr, d)?; }", "rs"), [])
        self.assertEqual(rules("fn a() { let c = reqwest::Client::new(); }", "rs"), ["connect-no-timeout"])
        self.assertEqual(rules("fn a() { let c = reqwest::Client::builder().timeout(d).build()?; }", "rs"), [])

    def test_tasks(self):
        self.assertEqual(rules("fn a() {\n    tokio::spawn(async move { run().await });\n}", "rs"), ["task-unowned"])
        self.assertEqual(rules("fn a() { let _ = std::thread::spawn(move || work()); }", "rs"), ["task-unowned"])
        self.assertEqual(rules("fn a() { thread::Builder::new().name(n).spawn(f).expect(\"spawn\"); }", "rs"),
                         ["task-unowned"])
        for owned in ("fn a() { let h = tokio::spawn(run()); h.await; }",
                      "fn a() { handles.push(tokio::spawn(run())); }",
                      "fn a() -> JoinHandle<()> { tokio::spawn(run()) }",
                      "fn a() { self.task = Some(tokio::task::spawn_blocking(f)); }",
                      "fn a() { set.spawn(run()); }"):
            self.assertEqual(rules(owned, "rs"), [], owned)

    def test_processes(self):
        self.assertEqual(rules("fn a() { let c = Command::new(\"x\").arg(y).spawn()?; }", "rs"),
                         ["process-no-cleanup"])
        self.assertEqual(rules("fn a() { let c = Command::new(\"x\").kill_on_drop(true).spawn()?; }", "rs"), [])
        self.assertEqual(rules("fn a() {\n let mut cmd = Command::new(\"x\");\n cmd.kill_on_drop(true);\n"
                               " let c = cmd.spawn()?;\n}", "rs"), [])
        self.assertEqual(rules("fn a() {\n let mut child = Command::new(\"x\").spawn()?;\n"
                               " stop.await;\n child.kill().await?;\n}", "rs"), [])

    def test_waits(self):
        self.assertEqual(rules("fn a() { let status = child.wait().await?; }", "rs"), ["wait-no-deadline"])
        self.assertEqual(rules("fn a() { worker.join().unwrap(); }", "rs"), ["wait-no-deadline"])
        self.assertEqual(rules("fn a() { let o = Command::new(\"git\").output()?; }", "rs"), ["wait-no-deadline"])
        self.assertEqual(rules("fn a() { let s = timeout(Duration::from_secs(5), child.wait()).await; }", "rs"), [])
        self.assertEqual(rules("fn a() { let p = path.join(\"x\"); let s = parts.join(\",\"); }", "rs"), [])

    def test_comments_strings_and_test_modules_are_not_code(self):
        self.assertEqual(rules('fn a() {\n    // tokio::spawn(x);\n    let s = "TcpStream::connect(a)";\n}', "rs"), [])
        self.assertEqual(rules('fn a() { let s = r#"child.wait()"#; let c = \'"\'; }', "rs"), [])
        self.assertEqual(rules("fn a() {}\n#[cfg(test)]\nmod tests {\n    fn t() { tokio::spawn(x); }\n}\n", "rs"), [])
        self.assertEqual(rules("fn a<'b>(x: &'b str) {\n    tokio::spawn(run());\n}", "rs"), ["task-unowned"])


class TypeScript(unittest.TestCase):
    def test_fetch(self):
        self.assertEqual(rules("const r = await fetch(url, { method: 'POST' });", "ts"), ["connect-no-timeout"])
        self.assertEqual(rules("const r = await fetch(url, { signal: AbortSignal.timeout(10_000) });", "ts"), [])
        self.assertEqual(rules("const r = await api.fetch(url);", "ts"), [])
        self.assertEqual(rules("export default { async fetch(request, env) { return new Response('') } }", "ts"), [])

    def test_websocket(self):
        self.assertEqual(rules("const ws = new WebSocket(url);\nws.onopen = () => {};", "ts"), ["connect-no-timeout"])
        self.assertEqual(rules(f"const ws = new WebSocket(url);\nconst openTimer = {SET_TIMEOUT}(() => ws.close(), 10_000);",
                               "ts"), [])

    def test_timers(self):
        self.assertEqual(rules(f"function f() {{\n  {SET_TIMEOUT}(() => setCopied(false), 900);\n}}", "ts"), ["timer-unowned"])
        self.assertEqual(rules("function f() {\n  window.setInterval(tick, 1000)\n}", "ts"), ["timer-unowned"])
        for owned in (f"const id = {SET_TIMEOUT}(f, 10);",
                      "this.timer = setInterval(f, 10);",
                      f"useEffect(() => {{ const t = {SET_TIMEOUT}(f, 1); return () => clearTimeout(t); }}, []);",
                      f"await new Promise((r) => {SET_TIMEOUT}(r, 10));",
                      f"timers.push({SET_TIMEOUT}(f, 1));"):
            self.assertEqual(rules(owned, "ts"), [], owned)

    def test_processes(self):
        imp = 'import { spawn, execSync } from "node:child_process";\n'
        self.assertEqual(rules(imp + "spawn('git', ['status']);", "ts"), ["process-no-cleanup"])
        self.assertEqual(rules(imp + "const p = spawn('git', [], { signal: controller.signal });", "ts"), [])
        self.assertEqual(rules(imp + "const p = spawn('x');\nprocess.on('exit', () => p.kill());", "ts"), [])
        self.assertEqual(rules(imp + "const out = execSync('git status');", "ts"), ["wait-no-deadline"])
        self.assertEqual(rules(imp + "const out = execSync('git status', { timeout: 5000 });", "ts"), [])
        self.assertEqual(rules("const proc = Bun.spawn(['git']);", "ts"), ["process-no-cleanup"])
        self.assertEqual(rules("const m = /x/.exec(s); spawn(thing);", "ts"), [])


class Go(unittest.TestCase):
    def test_rules(self):
        self.assertEqual(rules("func a() {\n\tc, err := net.Dial(\"tcp\", addr)\n}", "go"), ["connect-no-timeout"])
        self.assertEqual(rules("func a() {\n\tc, err := net.DialTimeout(\"tcp\", addr, d)\n}", "go"), [])
        self.assertEqual(rules("var c = &http.Client{}\n", "go"), ["connect-no-timeout"])
        self.assertEqual(rules("var c = &http.Client{Timeout: 10 * time.Second}\n", "go"), [])
        self.assertEqual(rules("func a() {\n\tgo s.readLoop()\n}", "go"), ["task-unowned"])
        self.assertEqual(rules("func a() {\n\tgo s.readLoop(ctx)\n}", "go"), [])
        self.assertEqual(rules("func a() {\n\tgo func() {\n\t\tdefer wg.Done()\n\t\twork()\n\t}()\n}", "go"), [])
        self.assertEqual(rules("func a() {\n\tout, _ := exec.Command(\"ps\").Output()\n}", "go"), ["process-no-cleanup"])
        self.assertEqual(rules("func a() {\n\tout, _ := exec.CommandContext(ctx, \"ps\").Output()\n}", "go"), [])
        self.assertEqual(rules("func a() {\n\ts := `go x()`\n\t// net.Dial(a)\n}", "go"), [])


class Scope(unittest.TestCase):
    def test_product_sources_only(self):
        self.assertEqual(lint.lang_of("cmux-tui/crates/x/src/lib.rs"), "rs")
        self.assertEqual(lint.lang_of("webviews/src/app.tsx"), "ts")
        self.assertEqual(lint.lang_of("daemon/remote/cmd/x.go"), "go")
        for rel in ("cmux-tui/crates/x/tests/a.rs", "cmux-tui/crates/x/src/tests.rs", "cmux-tui/crates/x/build.rs",
                    "web/app/a.test.ts", "web/e2e/a.ts", "daemon/remote/x_test.go", "Sources/A.swift",
                    "scripts/a.ts", "cmux-tui/crates/x/benches/b.rs"):
            self.assertIsNone(lint.lang_of(rel), rel)


class Allowlist(unittest.TestCase):
    def found(self, **per_rule):
        out = {rule: {} for rule in lint.RULES}
        out.update(per_rule)
        return out

    def test_new_raised_lowered_stale_and_reasonless_entries_fail(self):
        debt = {"count": 1, "reason": "debt: old"}
        allow = {"task-unowned": {"a.rs": debt, "gone.rs": debt, "b.rs": {"count": 1, "reason": "because"}},
                 "wait-no-deadline": {"c.rs": {"count": 3, "reason": "debt: old"}}}
        found = self.found(**{"task-unowned": {"a.rs": 2, "b.rs": 1, "new.rs": 1}, "wait-no-deadline": {"c.rs": 1}})
        text = "\n".join(lint.problems(found, allow, None))
        self.assertIn("a.rs: 2 cases, the allowlist says 1: a new one", text)
        self.assertIn("new.rs: 1 new case(s)", text)
        self.assertIn("gone.rs: listed but no longer matches", text)
        self.assertIn("b.rs: the reason must start with", text)
        self.assertIn("c.rs: 1 cases, the allowlist says 3: lower the count", text)

    def test_debt_only_shrinks_against_the_base(self):
        found = self.found(**{"task-unowned": {"a.rs": 2, "b.rs": 1}})
        base = {"task-unowned": {"a.rs": {"count": 1, "reason": "debt: old"}}}
        allow = {"task-unowned": {"a.rs": {"count": 2, "reason": "debt: old"},
                                  "b.rs": {"count": 1, "reason": "safe: the owner aborts it on drop"}}}
        bad = lint.problems(found, allow, base)
        self.assertEqual(len(bad), 1, bad)
        self.assertIn("a.rs: allowlist 1 -> 2 since the base", bad[0])
        self.assertEqual(lint.problems(found, allow, None), [])

    def test_write_baseline_keeps_reasons(self):
        allow = {"task-unowned": {"a.rs": {"count": 3, "reason": "safe: aborted by its owner"}}}
        new = lint.write_baseline(self.found(**{"task-unowned": {"a.rs": 2, "b.rs": 1}}), allow)
        self.assertEqual(new["task-unowned"]["a.rs"], {"count": 2, "reason": "safe: aborted by its owner"})
        self.assertTrue(new["task-unowned"]["b.rs"]["reason"].startswith("debt: "))
        self.assertEqual(json.loads(lint.dump(new)), new)


if __name__ == "__main__":
    unittest.main()
