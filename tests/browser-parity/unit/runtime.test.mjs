// Focused tests for the browser REPL runtime: Myers diff and hunk format,
// key parsing, top-level rewrite, URL shortening, and snapshot ref
// persistence (on Playwright WebKit through the dev driver).
//
//   node --test tests/browser-parity/unit/
import test from "node:test";
import assert from "node:assert/strict";
import { loadRuntime, runDevRepl } from "../lib/dev-driver.mjs";
import { startFixtureServers } from "../lib/fixture-server.mjs";

const ns = loadRuntime();
const { diffText, truncateUrl } = ns.aside;
const { describeKey, splitKeyCombo, MiniURL } = ns.core;
const { rewriteTopLevel, createReplSession } = ns.replHost;

test("diff: first snapshot compares against an empty string", () => {
  assert.equal(diffText("", "a\nb"), "@@ -1 +1,2 @@\n-\n+a\n+b\n");
});

test("diff: no context lines, zero-count start is not decremented", () => {
  const old = Array.from({ length: 18 }, (_, i) => `l${i}`).join("\n");
  assert.equal(diffText(old, old + "\nnew"), "@@ -19,0 +19 @@\n+new\n");
  assert.equal(diffText("a\nb\nc", "a\nB\nc"), "@@ -2 +2 @@\n-b\n+B\n");
  assert.equal(diffText("a\nb", "a\nb"), "No changes detected\n");
});

test("diff: deletes come before inserts inside a hunk", () => {
  assert.equal(diffText("x\na\nb\ny", "x\nA\nB\ny"), "@@ -2,2 +2,2 @@\n-a\n-b\n+A\n+B\n");
  assert.equal(diffText("a\nb\nc\nd\ne\nf", "x"), "@@ -1,6 +1 @@\n-a\n-b\n-c\n-d\n-e\n-f\n+x\n");
});

test("keys: combos split on + with a trailing plus key", () => {
  assert.deepEqual(splitKeyCombo("Meta+a"), ["Meta", "a"]);
  assert.deepEqual(splitKeyCombo("Shift+KeyC"), ["Shift", "KeyC"]);
  assert.deepEqual(splitKeyCombo("Control++"), ["Control", "+"]);
  assert.deepEqual(splitKeyCombo("+"), ["+"]);
});

test("keys: Shift maps codes to shifted keys; Meta suppresses text", () => {
  assert.deepEqual(describeKey("KeyC", new Set(["Shift"])), { key: "C", code: "KeyC", keyCode: 67, text: "C", location: 0 });
  assert.equal(describeKey("KeyC", new Set()).key, "c");
  assert.equal(describeKey("Digit1", new Set(["Shift"])).key, "!");
  assert.equal(describeKey("a", new Set(["Meta"])).text, "");
  assert.equal(describeKey("Enter", new Set()).text, "\r");
  assert.equal(describeKey("Shift", new Set()).code, "ShiftLeft");
  assert.equal(describeKey("é", new Set()).text, "é");
  assert.throws(() => describeKey("NotAKey", new Set()), /Unknown key/);
});

test("rewrite: top-level declarations become scope assignments", () => {
  const r = rewriteTopLevel("const a = 1, { b, c: [d] } = o;\nlet e;\nfunction f() { return a; }\nclass G {}\na + 1");
  assert.deepEqual(r.names.sort(), ["G", "a", "b", "d", "e", "f"]);
  assert.match(r.source, /^f = function f\(\) \{ return a; \};/);
  assert.match(r.source, /void \(a = 1\); void \(\(\{ b, c: \[d\] \} = o\)\);/);
  assert.match(r.source, /__cmuxLast = \(a \+ 1\);$/);
  const inner = rewriteTopLevel("for (const x of y) { const z = x; }");
  assert.deepEqual(inner.names, []);
});

test("rewrite: bindings persist across cells, including closures", async () => {
  const host = { setTimeout, clearTimeout, now: Date.now };
  const repl = createReplSession({ host, globals: [] });
  assert.equal((await repl.evaluate("const n = 2; function twice() { return n * 2; }")).ok, true);
  assert.equal((await repl.evaluate("let m = await Promise.resolve(n + 1); twice() + m")).value, 7);
  assert.equal((await repl.evaluate("n = 5; twice()")).value, 10);
  const err = await repl.evaluate("throw new TypeError('boom')");
  assert.equal(err.ok, false);
  assert.equal(err.error, "TypeError: boom");
});

test("url: Aside strips tracking params with its iterator skip", () => {
  assert.equal(truncateUrl("http://Example.com:80?utm_source=a&utm_medium=b&x=1"), "http://example.com/?utm_medium=b&x=1");
  assert.equal(truncateUrl("http://h/p?q=a%20b"), "http://h/p?q=a%20b");
  assert.equal(truncateUrl("http://h/p?gclid=1&q=a%20b&z=2"), "http://h/p?q=a+b&z=2");
  assert.equal(truncateUrl("http://h/" + "a".repeat(200)).length, 129);
});

test("url: the JavaScriptCore fallback matches WHATWG URL for common cases", () => {
  for (const [input, base] of [
    ["http://Example.COM:80/a/./b/../c?x=1#h", undefined],
    ["https://h:443", undefined],
    ["../x?y", "http://h/a/b/c"],
    ["//other/p", "https://h/"],
    ["?q", "http://h/p?old"],
    ["about:blank", undefined],
  ]) {
    assert.equal(new MiniURL(input, base).href, new URL(input, base).href, input);
  }
  const u = new MiniURL("http://h/?utm_source=a&utm_medium=b&x=1");
  for (const k of u.searchParams.keys()) if (k.startsWith("utm")) u.searchParams.delete(k);
  assert.equal(u.href, "http://h/?utm_medium=b&x=1");
});

test("refs: persist by role and name, renames get new numbers, scoped snapshots invalidate", async () => {
  const server = await startFixtureServers();
  try {
    const code = `
      await openTab(${JSON.stringify(server.origins.primary + "/")});
      await page.evaluate(() => { document.body.innerHTML = '<ul id=L><li><button>Alpha</button></li><li><button id=b>Beta</button></li></ul><button id=out>Out</button>'; });
      const s1 = await snapshot(page, { interactive: true });
      console.log("S1", JSON.stringify(s1.tree.split("\\n").slice(2)));
      await page.evaluate(() => { document.getElementById("b").textContent = "Beta2"; document.getElementById("L").insertAdjacentHTML("afterbegin", "<li><button>Zero</button></li>"); });
      const s2 = await snapshot(page, { interactive: true });
      console.log("S2", JSON.stringify(s2.tree.split("\\n").slice(2)));
      console.log("DIFF", JSON.stringify(s2.diff));
      await snapshot(page, { selector: "#L" });
      try { await page.locator("e3").click(); console.log("CLICKED"); } catch (e) { console.log("STALE", e.message); }
    `;
    const out = await runDevRepl(code);
    const line = (tag) => JSON.parse(out.split("\n").find((l) => l.startsWith(tag + " ")).slice(tag.length + 1));
    assert.deepEqual(line("S1"), ['- button "Alpha" [ref=e1]', '- button "Beta" [ref=e2]', '- button "Out" [ref=e3]']);
    assert.deepEqual(line("S2"), ['- button "Zero" [ref=e4]', '- button "Alpha" [ref=e1]', '- button "Beta2" [ref=e5]', '- button "Out" [ref=e3]']);
    assert.equal(line("DIFF"), '@@ -1,0 +1 @@\n+- button "Zero" [ref=e4]\n@@ -2 +3 @@\n-- button "Beta" [ref=e2]\n+- button "Beta2" [ref=e5]\n');
    assert.match(out, /STALE Ref "e3" is stale/);
  } finally {
    await server.close();
  }
});
