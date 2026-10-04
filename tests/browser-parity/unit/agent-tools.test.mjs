// Reference C parity tools (Resources/browser-repl/agent-tools.js,
// docs/browser-repl/reference-c-parity.md): TOTP, domain patterns, the
// animated PNG writer, and on Playwright WebKit through the dev driver: a
// registered secret never appears in output, errors, page reads or files; a
// TOTP secret types the current code; storage state round-trips; Markdown
// chunks cover the page.
//
//   node --test tests/browser-parity/unit/agent-tools.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import zlib from "node:zlib";
import { loadRuntime, createDevBrowser, createNodeHost, createDevRepl } from "../lib/dev-driver.mjs";
import { startFixtureServers } from "../lib/fixture-server.mjs";
import { siteOf } from "../lib/public-suffix.mjs";

const ns = loadRuntime();
const T = ns.agentTools;

test("totp: RFC 6238 SHA-1 vectors", () => {
  const seed = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"; // base32 of "12345678901234567890"
  const vectors = [[59, "94287082"], [1111111109, "07081804"], [1111111111, "14050471"], [1234567890, "89005924"], [2000000000, "69279037"], [20000000000, "65353130"]];
  for (const [t, code] of vectors) assert.equal(T.totp(seed, t * 1000, { digits: 8 }), code, `t=${t}`);
  assert.equal(Buffer.from(T.sha1(new TextEncoder().encode("abc"))).toString("hex"), "a9993e364706816aba3e25717850c26c9cd0d89d");
  assert.throws(() => T.base32Decode("not base32!"), /base32/);
});

test("domain patterns: reference C's syntax, with ports and refusals", () => {
  const m = (url, pattern, secure = false) => T.urlMatches(url, T.parsePattern(pattern, "t"), secure);
  // Domain-only: the host and, for a root domain, www.
  assert.equal(m("https://example.com/a", "example.com"), true);
  assert.equal(m("https://www.example.com/a", "example.com"), true);
  assert.equal(m("https://api.example.com/a", "example.com"), false);
  assert.equal(m("https://evilexample.com/", "example.com"), false);
  // *.domain: subdomains and the bare domain, never a suffix lookalike.
  assert.equal(m("https://a.b.example.com/", "*.example.com"), true);
  assert.equal(m("https://example.com/", "*.example.com"), true);
  assert.equal(m("https://evil-example.com/", "*.example.com"), false);
  // Schemes: navigation allows http and https; secrets need https (or loopback http).
  assert.equal(m("http://example.com/", "example.com"), true);
  assert.equal(m("http://example.com/", "example.com", true), false);
  assert.equal(m("http://localhost:3000/", "localhost", true), true);
  assert.equal(m("http://example.com/", "http*://example.com", true), true);
  assert.equal(m("http://example.com/", "https://example.com", true), false);
  assert.equal(m("chrome-extension://abc/", "example.com"), false);
  // Ports in the pattern must match.
  assert.equal(m("http://localhost:8765/x", "localhost:8765"), true);
  assert.equal(m("http://localhost:9999/x", "localhost:8765"), false);
  assert.equal(m("https://anything.test/", "*"), true);
  // Unsafe patterns are refused when set (reference C logs and ignores them).
  for (const bad of ["*.*.example.com", "example.*", "ex*ample.com", "", "  "]) assert.throws(() => T.parsePattern(bad, "t"), /t:/, bad);
});

test("hosts compare without case, trailing dots or Unicode spelling in domain patterns", () => {
  const m = (url, pattern, secure = false) => T.urlMatches(url, T.parsePattern(pattern, "t"), secure);
  // A trailing dot names the same host; it must not slip past a pattern.
  assert.equal(m("https://example.com./a", "example.com"), true);
  assert.equal(m("https://www.example.com./a", "example.com"), true);
  assert.equal(m("https://a.example.com./a", "*.example.com"), true);
  assert.equal(m("https://example.com./a", "example.com."), true);
  assert.equal(m("https://EXAMPLE.COM/a", "Example.Com"), true);
  // Internationalized names match in either spelling.
  assert.equal(m("https://xn--bcher-kva.de/", "bücher.de"), true);
  assert.equal(m("https://bücher.de/", "xn--bcher-kva.de"), true);
  assert.equal(m("https://bucher.de/", "bücher.de"), false);
});

// A w x h RGBA PNG filled with one color.
function png(w, h, rgba) {
  const crcTable = new Uint32Array(256).map((_, n) => {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    return c >>> 0;
  });
  const crc = (b) => {
    let c = 0xffffffff;
    for (const x of b) c = crcTable[(c ^ x) & 255] ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
  };
  const chunk = (type, data) => {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    const body = Buffer.concat([Buffer.from(type, "latin1"), data]);
    const c = Buffer.alloc(4);
    c.writeUInt32BE(crc(body));
    return Buffer.concat([len, body, c]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr.set([8, 6, 0, 0, 0], 8);
  const raw = Buffer.alloc(h * (1 + w * 4));
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) raw.set(rgba, y * (1 + w * 4) + 1 + x * 4);
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", ihdr), chunk("IDAT", zlib.deflateSync(raw)), chunk("IEND", Buffer.alloc(0))]);
}

test("buildApng: valid chunks, frame count, sequence numbers; other sizes skipped", () => {
  const frames = [png(4, 3, [255, 0, 0, 255]), png(4, 3, [0, 255, 0, 255]), png(5, 3, [0, 0, 255, 255]), png(4, 3, [0, 0, 255, 255])];
  const { bytes, frames: n, skipped } = T.buildApng(frames, 500);
  assert.equal(n, 3);
  assert.equal(skipped, 1);
  const buf = Buffer.from(bytes);
  assert.deepEqual([...buf.subarray(0, 8)], [137, 80, 78, 71, 13, 10, 26, 10]);
  const chunks = [];
  for (let off = 8; off < buf.length;) {
    const len = buf.readUInt32BE(off);
    const type = buf.toString("latin1", off + 4, off + 8);
    const data = buf.subarray(off + 8, off + 8 + len);
    assert.equal(buf.readUInt32BE(off + 8 + len), zlib.crc32(buf.subarray(off + 4, off + 8 + len)), `${type} CRC`);
    chunks.push({ type, data });
    off += 12 + len;
  }
  assert.deepEqual(chunks.map((c) => c.type), ["IHDR", "acTL", "fcTL", "IDAT", "fcTL", "fdAT", "fcTL", "fdAT", "IEND"]);
  assert.equal(chunks[1].data.readUInt32BE(0), 3);
  const seqs = chunks.filter((c) => c.type === "fcTL" || c.type === "fdAT").map((c) => c.data.readUInt32BE(0));
  assert.deepEqual(seqs, [0, 1, 2, 3, 4]);
  assert.equal(chunks[2].data.readUInt16BE(20), 500);
  // Each frame's data inflates to the original image.
  assert.equal(zlib.inflateSync(chunks[5].data.subarray(4)).length, 3 * (1 + 4 * 4));
});

// One REPL session on the dev driver, with the app's output cap.
async function withRepl(fn, { maxOutput, setupContext } = {}) {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "cmux-repl-bu-")));
  const sessionId = `bu-${process.pid}-${Math.random().toString(36).slice(2, 8)}`;
  const browser = await createDevBrowser({ setupContext });
  const driver = browser.driver();
  const lines = [];
  const host = createNodeHost({ workDir: dir, sessionId, print: (level, text) => lines.push(text) });
  const repl = createDevRepl({ host, driver });
  const outputs = [];
  const run = async (code) => {
    const start = lines.length;
    const r = await repl.evaluate(code, { maxOutput });
    const out = { output: lines.slice(start).join("\n"), error: r.ok ? null : r.error, formatted: r.ok ? null : ns.replHost.formatError(r.exception) };
    outputs.push(out);
    return out;
  };
  const sessionTmp = path.join(fs.realpathSync(os.tmpdir()), "cmux-browser-repl", sessionId);
  try {
    await fn({ run, dir, sessionTmp, outputs });
  } finally {
    repl.dispose();
    await browser.close();
    fs.rmSync(dir, { recursive: true, force: true });
    fs.rmSync(sessionTmp, { recursive: true, force: true });
  }
}

const filesUnder = (root) => {
  if (!fs.existsSync(root)) return [];
  return fs.readdirSync(root, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? filesUnder(path.join(root, e.name)) : [path.join(root, e.name)]));
};

test("secrets: a registered value never appears in output, errors, page reads or files", async () => {
  const servers = await startFixtureServers();
  const { primary, peer } = servers.origins;
  const KEY = "Zx9-secret-VALUE-77";
  const PW = "pw with spaces&<x>";
  const secretsDir = fs.mkdtempSync(path.join(os.tmpdir(), "bu-secrets-"));
  const secretsFile = path.join(secretsDir, "secrets.json");
  fs.writeFileSync(secretsFile, JSON.stringify({ localhost: { apikey: KEY, pw: PW } }));
  const forms = [KEY, PW, encodeURIComponent(KEY), encodeURIComponent(PW), encodeURIComponent(PW).replace(/%20/g, "+"), "pw with spaces&amp;&lt;x&gt;"];
  try {
    await withRepl(async ({ run, dir, sessionTmp, outputs }) => {
      let r = await run(`secrets.load(${JSON.stringify(secretsFile)})`);
      assert.equal(r.error, null);
      assert.match(r.output, /name: 'apikey', domains: \[ 'localhost' \]/);
      r = await run(`
        const rec = session.record();
        await page.goto("${primary}/agent-tools.html?peer=${peer}");
        await page.fill("#apikey", secret("apikey"));
        await page.locator("#pass").pressSequentially(secret("pw"));
        await page.fill("#user", "ada");
        await page.click("text=Sign in");
        await page.locator("#status").filter({ hasText: "Signed in" }).waitFor();
        console.log(String(await snapshot()));
        console.log(await page.content());
        console.log(await page.evaluate(() => [document.getElementById("apikey").value, document.getElementById("pass").value, location.href, document.title]));
        console.log(await page.locator("#apikey").inputValue(), page.url(), await page.title());
        console.log((await page.consoleMessages()).map(String));
        console.log(await tabs.list());
        console.log(await page.markdown());
        console.log(fs.readFileSync(await page.exportContent(), "utf8"));
        console.log(await tabs.content([page.url()], { format: "text" }));
        console.log(await (await fetch(page.url())).text());
        await session.storageState({ path: "./state.json" });
        fs.writeFileSync("./reads.json", JSON.stringify({ v: await page.evaluate(() => document.getElementById("apikey").value), md: await page.markdown() }));
        const out = await rec.stop();
        console.log(fs.readFileSync(out.trace, "utf8"));
        console.log(secret("apikey"), JSON.stringify([secret("pw")]), secrets.list());
      `);
      assert.equal(r.error, null);
      assert.match(r.output, /<secret:apikey>/);
      assert.match(r.output, /password 18 chars/);
      // A secret is inserted by the native session in one piece; the trace
      // names it, and other typed text and keys stay out of it.
      const traceFile = filesUnder(sessionTmp).find((f) => f.endsWith("trace.jsonl"));
      const trace = fs.readFileSync(traceFile, "utf8").trim().split("\n").map((l) => JSON.parse(l));
      assert.ok(trace.some((e) => e.method === "input.insertText" && e.text === "<secret:pw>"));
      assert.ok(trace.every((e) => e.key === undefined && (e.text === undefined || /^<(\d+ characters|secret:\w+)>$/.test(e.text))));
      // Reading the secrets file and printing it, throwing it, logging it from
      // a listener and spilling a large output all mask it.
      r = await run(`
        const raw = fs.readFileSync(${JSON.stringify(secretsFile)}, "utf8");
        console.log(raw);
        page.on("console", () => { throw new Error("listener " + JSON.parse(raw).localhost.apikey); });
        await page.evaluate(() => console.log("ping"));
        await sleep(50);
        for (let i = 0; i < 400; i++) console.log("line " + i + " " + JSON.parse(raw).localhost.apikey);
        throw new Error("thrown " + raw);
      `);
      assert.match(r.error, /thrown .*<secret:apikey>/);
      assert.match(r.formatted, /<secret:apikey>/);
      assert.match(r.output, /# output continues in .*output-\d+\.txt/);
      // A secret is refused outside its domains, also in a frame of another site.
      r = await run(`await page.frameLocator("#peer-frame").locator("#frame-pass").fill(secret("pw"))`);
      assert.match(r.error, /may not be typed into http:\/\/127\.0\.0\.1:\d+; its domains are localhost/);
      r = await run(`secrets.set("other", "elsewhere-value-1", { domains: ["example.com"] }); await page.fill("#user", secret("other"))`);
      assert.match(r.error, /may not be typed into http:\/\/localhost:\d+; its domains are example\.com/);
      assert.equal(await run(`await page.locator("#user").inputValue()`).then((o) => o.output), "ada");

      const texts = outputs.flatMap((o) => [o.output, o.error || "", o.formatted || ""]);
      const files = [...filesUnder(dir), ...filesUnder(sessionTmp)];
      assert.ok(files.some((f) => f.endsWith("state.json")) && files.some((f) => /export-\d+\.md$/.test(f)) && files.some((f) => /output-\d+\.txt$/.test(f)) && files.some((f) => f.endsWith(".png")));
      for (const form of forms) {
        texts.forEach((t, i) => assert.ok(!t.includes(form), `output ${i} contains ${JSON.stringify(form)}`));
        for (const f of files) assert.ok(!fs.readFileSync(f).toString("latin1").includes(form), `${f} contains ${JSON.stringify(form)}`);
      }
    }, { maxOutput: 6000 });
  } finally {
    fs.rmSync(secretsDir, { recursive: true, force: true });
    await servers.close();
  }
});

test("secrets: a TOTP secret types the current code, and reading it back shows the mask", async () => {
  const servers = await startFixtureServers();
  try {
    await withRepl(async ({ run }) => {
      const seed = "JBSWY3DPEHPK3PXP";
      // The code at any moment of the run is one of these windows' codes.
      const now = Date.now();
      const candidates = [T.totp(seed, now), T.totp(seed, now + 30_000), T.totp(seed, now + 60_000)];
      const r = await run(`
        secrets.set("otp", "${seed}", { domains: ["localhost"], totp: true });
        await page.goto("${servers.origins.primary}/agent-tools.html");
        await page.fill("#otp", secret("otp"));
        const typed = await page.evaluate((codes) => codes.includes(document.getElementById("otp").value), ${JSON.stringify(candidates)});
        console.log(typed, await page.evaluate(() => document.getElementById("otp").value));
      `);
      assert.equal(r.error, null);
      assert.equal(r.output, "true <secret:otp>");
      assert.ok(!r.output.includes(seed));
    });
  } finally {
    await servers.close();
  }
});

test("storage state: cookies and localStorage round-trip through a file", async () => {
  const servers = await startFixtureServers();
  const { primary } = servers.origins;
  try {
    await withRepl(async ({ run, dir }) => {
      let r = await run(`
        await page.goto("${primary}/set-cookie");
        await page.goto("${primary}/agent-tools.html");
        await page.evaluate(() => { localStorage.setItem("theme", "dark"); localStorage.setItem("n", "1"); });
        const state = await page.context().storageState({ path: "./state.json" });
        [state.cookies.map((c) => [c.name, c.value, c.path]), state.origins]
      `);
      assert.equal(r.error, null);
      const state = JSON.parse(fs.readFileSync(path.join(dir, "state.json"), "utf8"));
      assert.deepEqual(state.cookies.map((c) => [c.name, c.value]), [["parity", "1"]]);
      assert.deepEqual(state.origins.map((o) => [o.origin, o.localStorage.map((i) => [i.name, i.value]).sort()]), [[primary, [["n", "1"], ["theme", "dark"]]]]);
      // Cleared, then restored with no tab on the origin open.
      r = await run(`
        await page.evaluate(() => localStorage.clear());
        await page.context().clearCookies();
        await page.goto("about:blank");
        const cleared = await (await fetch("${primary}/echo-cookie")).json();
        const restored = await session.setStorageState("./state.json");
        await page.goto("${primary}/agent-tools.html");
        [cleared.cookie, restored, await page.evaluate(() => [localStorage.getItem("theme"), localStorage.getItem("n")]), (await (await fetch("${primary}/echo-cookie")).json()).cookie, (await tabs.list()).length]
      `);
      assert.equal(r.error, null);
      assert.equal(r.output, "[ null, { cookies: 1, origins: 1 }, [ 'dark', '1' ], 'parity=1', 1 ]");
    });
  } finally {
    await servers.close();
  }
});

test("storage state: scoped to the current tab's site unless { all: true }", async () => {
  const servers = await startFixtureServers();
  const { primary, peer } = servers.origins;
  try {
    await withRepl(async ({ run, dir }) => {
      const r = await run(`
        let noTab;
        try { await session.storageState(); } catch (e) { noTab = e.message; }
        await page.goto("${primary}/set-cookie");
        await page.goto("${primary}/agent-tools.html");
        await page.evaluate(() => localStorage.setItem("site", "primary"));
        const first = page;
        const other = await tabs.open("${peer}/set-cookie");
        await other.goto("${peer}/agent-tools.html");
        await other.evaluate(() => localStorage.setItem("site", "peer"));
        await tabs.use(first);
        const view = (s) => [s.cookies.map((c) => c.domain).sort(), s.origins.map((o) => o.origin).sort()];
        const out = [noTab, view(await session.storageState()), view(await session.storageState({ all: true })), view(await other.context().storageState()), view(await session.storageState({ urls: ["${peer}/"] }))];
        await other.close();
        fs.writeFileSync("./scope.json", JSON.stringify(out));
      `);
      assert.equal(r.error, null);
      const [noTab, scoped, all, otherScoped, byUrl] = JSON.parse(fs.readFileSync(path.join(dir, "scope.json"), "utf8"));
      assert.match(noTab, /session\.storageState: .*\{ all: true \}/);
      const host = (o) => new URL(o).hostname;
      assert.deepEqual(scoped, [[host(primary)], [primary]]);
      assert.deepEqual(all, [[host(primary), host(peer)].sort(), [primary, peer].sort()]);
      assert.deepEqual(otherScoped, [[host(peer)], [peer]]);
      assert.deepEqual(byUrl, [[host(peer)], [peer]]);
    });
  } finally {
    await servers.close();
  }
});

test("clearCookies: scoped to the current tab's site unless { all: true }", async () => {
  const servers = await startFixtureServers();
  const { primary, peer } = servers.origins;
  try {
    await withRepl(async ({ run, dir }) => {
      const r = await run(`
        const jar = async () => (await page.context().cookies()).map((c) => c.domain + " " + c.name).sort();
        await page.goto("${primary}/set-cookie");
        const first = page;
        const other = await tabs.open("${peer}/set-cookie");
        await tabs.use(first);
        await page.context().addCookies([
          { name: "a1", value: "1", url: "${primary}/" }, { name: "a2", value: "1", url: "${primary}/" },
          { name: "b1", value: "1", url: "${peer}/" }, { name: "b2", value: "1", url: "${peer}/" },
        ]);
        const out = { start: await jar() };
        await page.context().clearCookies({ name: "a1" });
        out.byName = await jar();
        await page.context().clearCookies({ name: /^(parity|b1)$/ });
        out.byRegExp = await jar();
        await other.context().clearCookies();
        out.otherSite = await jar();
        await page.context().clearCookies();
        out.thisSite = await jar();
        await page.context().addCookies([{ name: "a3", value: "1", url: "${primary}/" }, { name: "b3", value: "1", url: "${peer}/" }]);
        await page.goto("about:blank");
        try { await page.context().clearCookies(); } catch (e) { out.noSite = e.message; }
        try { await page.context().clearCookies({ all: true }); out.all = "cleared"; } catch (e) { out.all = e.message; }
        out.afterAll = await jar();
        fs.writeFileSync("./clear.json", JSON.stringify(out));
      `);
      assert.equal(r.error, null);
      const out = JSON.parse(fs.readFileSync(path.join(dir, "clear.json"), "utf8"));
      const a = new URL(primary).hostname;
      const b = new URL(peer).hostname;
      const jar = (...names) => names.map(([host, name]) => `${host} ${name}`).sort();
      assert.deepEqual(out.start, jar([a, "a1"], [a, "a2"], [a, "parity"], [b, "b1"], [b, "b2"], [b, "parity"]));
      assert.deepEqual(out.byName, jar([a, "a2"], [a, "parity"], [b, "b1"], [b, "b2"], [b, "parity"]), "a name filter stays on the tab's site");
      assert.deepEqual(out.byRegExp, jar([a, "a2"], [b, "b1"], [b, "b2"], [b, "parity"]), "a RegExp filter stays on the tab's site");
      assert.deepEqual(out.otherSite, jar([a, "a2"]), "another tab clears its own site");
      assert.deepEqual(out.thisSite, [], "no filter clears the tab's whole site");
      assert.match(out.noSite, /clearCookies: .*has no site to scope to/, "a tab with no site clears nothing");
      assert.match(out.all, /clearCookies: .*user's browser profile/, "{ all: true } is refused on the user's profile");
      assert.deepEqual(out.afterAll, jar([a, "a3"], [b, "b3"]));
    });
  } finally {
    await servers.close();
  }
});

// A tab's cookies live in that tab's data store (a private tab's, or the
// session's proxy store, is not the user's profile), so every cookie call a
// page makes names its tab; without it the driver would use another tab's
// store.
test("cookie calls name the page's tab, so the driver uses that tab's store", async () => {
  const browser = await createDevBrowser();
  const servers = await startFixtureServers();
  const { primary } = servers.origins;
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "cmux-repl-cookie-")));
  const driver = browser.driver();
  const calls = [];
  const call = driver.call.bind(driver);
  driver.call = (method, params) => {
    if (method.startsWith("cookies.")) calls.push({ method, targetId: params && params.targetId });
    return call(method, params);
  };
  const repl = createDevRepl({ host: createNodeHost({ workDir: dir, sessionId: `cookie-${process.pid}`, print: () => {} }), driver });
  try {
    const r = await repl.evaluate(`
      const other = await tabs.open(${JSON.stringify(primary)} + "/index.html");
      const own = await tabs.open(${JSON.stringify(primary)} + "/agent-tools.html");
      await other.bringToFront();
      await own.context().cookies();
      await own.context().addCookies([{ name: "n", value: "1", url: ${JSON.stringify(primary)} + "/" }]);
      await own.context().storageState();
      await own.context().setStorageState({ cookies: [{ name: "m", value: "1", url: ${JSON.stringify(primary)} + "/" }] });
      await own.context().clearCookies();
      own._targetId
    `);
    assert.equal(r.ok, true, r.error);
    const ownId = r.value;
    assert.ok(calls.length >= 5, JSON.stringify(calls));
    assert.deepEqual(calls.filter((c) => c.targetId !== ownId), [], `every cookie call names ${ownId}`);
  } finally {
    repl.dispose();
    await browser.close();
    await servers.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// localStorage lives in a tab's data store too: storageState and
// setStorageState read and write it only through tabs in the page's own
// store, and restore an origin no such tab shows in a new tab of that store.
// The dev driver has one store, so this test reports the other tab as a
// private tab's store.
test("storage state reads and writes localStorage only in the page's own data store", async () => {
  const browser = await createDevBrowser();
  const servers = await startFixtureServers();
  const { primary } = servers.origins;
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "cmux-repl-store-")));
  const driver = browser.driver();
  let otherId = null;
  let recording = false;
  const storageCalls = [];
  const opened = [];
  const call = driver.call.bind(driver);
  const storeOf = (targetId, store) => (otherId && targetId === otherId ? "private" : store);
  driver.call = async (method, params) => {
    if (recording && method === "frame.evaluate" && /localStorage/.test(String(params && params.source))) storageCalls.push(params.targetId);
    if (recording && method === "tabs.open") opened.push({ ...params });
    const result = await call(method, params);
    if (method === "tabs.list") return result.map((t) => ({ ...t, dataStore: storeOf(t.targetId, t.dataStore) }));
    if (method === "tabs.dataStore") return { dataStore: storeOf(params && params.targetId, result.dataStore) };
    return result;
  };
  const repl = createDevRepl({ host: createNodeHost({ workDir: dir, sessionId: `store-${process.pid}`, print: () => {} }), driver });
  try {
    let r = await repl.evaluate(`
      globalThis.other = await tabs.open(${JSON.stringify(primary)} + "/agent-tools.html");
      await other.evaluate(() => localStorage.setItem("k", "private"));
      globalThis.own = await tabs.open();
      [own._targetId, other._targetId]
    `);
    assert.equal(r.ok, true, r.error);
    const [ownId, other] = r.value;
    otherId = other;
    recording = true;
    r = await repl.evaluate(`
      const state = await own.context().storageState({ all: true });
      const restored = await own.context().setStorageState({ origins: [{ origin: ${JSON.stringify(primary)}, localStorage: [{ name: "k", value: "own" }] }] });
      [state.origins, restored.origins]
    `);
    assert.equal(r.ok, true, r.error);
    assert.deepEqual(r.value, [[], 1], "the private tab's localStorage stayed out of the state");
    assert.deepEqual(storageCalls.filter((id) => id === otherId), [], "no localStorage call went to the private tab");
    assert.ok(storageCalls.some((id) => id !== otherId && id !== ownId), "the origin was restored in a new tab");
    assert.deepEqual(opened.map((p) => p.dataStore), ["default"], "the new tab opened in the page's store");
  } finally {
    repl.dispose();
    await browser.close();
    await servers.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("cookies.clear: the driver clears the target tab's site, never a named one or the whole profile", async () => {
  const servers = await startFixtureServers();
  const { primary, peer } = servers.origins;
  const browser = await createDevBrowser();
  try {
    const driver = browser.driver();
    await driver.call("cookies.set", { cookies: [{ name: "a", value: "1", url: `${primary}/` }, { name: "b", value: "1", url: `${peer}/` }] });
    const names = async () => (await driver.call("cookies.get", {})).map((c) => c.name).sort();
    const { targetId: blank } = await driver.call("tabs.open", {});
    await assert.rejects(driver.call("cookies.clear", { targetId: blank }), (e) => e.code === "invalid" && /no site/.test(e.message));
    await assert.rejects(driver.call("cookies.clear", { targetId: blank, all: true }), (e) => e.code === "invalid" && /user's browser profile/.test(e.message));
    assert.deepEqual(await names(), ["a", "b"]);
    const { targetId } = await driver.call("tabs.open", { url: `${primary}/index.html` });
    await driver.call("cookies.clear", { targetId, site: new URL(peer).hostname });
    assert.deepEqual(await names(), ["b"], "the tab's own site, not the named one");
  } finally {
    await browser.close();
    await servers.close();
  }
});

test("cookie and storage-state scope follow the Public Suffix List", async () => {
  // x.co.at and y.co.at are different sites (co.at is a public suffix), as
  // are two github.io pages; www.example.co.uk shares example.co.uk.
  const hosts = ["x.co.at", "y.co.at", "ada.github.io", "bob.github.io", "www.example.co.uk", "example.co.uk"];
  const setupContext = async (ctx) => {
    await ctx.route((url) => hosts.includes(url.hostname), (route) => route.fulfill({ status: 200, headers: { "content-type": "text/html" }, body: "<!doctype html><title>psl</title>" }));
  };
  await withRepl(async ({ run, dir }) => {
    const r = await run(`
      const jar = async () => (await page.context().cookies()).map((c) => c.domain).sort();
      await page.context().addCookies(${JSON.stringify(hosts)}.map((h) => ({ name: "c", value: "1", url: "https://" + h + "/" })));
      const out = {};
      await page.goto("https://x.co.at/");
      out.state = (await session.storageState()).cookies.map((c) => c.domain).sort();
      await page.context().clearCookies();
      out.afterCoAt = await jar();
      await page.goto("https://ada.github.io/");
      await page.context().clearCookies();
      out.afterGithub = await jar();
      await page.goto("https://www.example.co.uk/");
      await page.context().clearCookies();
      out.afterCoUk = await jar();
      fs.writeFileSync("./psl.json", JSON.stringify(out));
    `);
    assert.equal(r.error, null);
    const out = JSON.parse(fs.readFileSync(path.join(dir, "psl.json"), "utf8"));
    assert.deepEqual(out.state, ["x.co.at"]);
    assert.deepEqual(out.afterCoAt, ["ada.github.io", "bob.github.io", "example.co.uk", "www.example.co.uk", "y.co.at"]);
    assert.deepEqual(out.afterGithub, ["bob.github.io", "example.co.uk", "www.example.co.uk", "y.co.at"]);
    assert.deepEqual(out.afterCoUk, ["bob.github.io", "y.co.at"]);
  }, { setupContext });
});

test("storage state: sites by the Public Suffix List (the dev backend's stand-in for the app's)", () => {
  const d = siteOf;
  assert.equal(d("www.example.com"), "example.com");
  assert.equal(d("a.b.example.co.uk"), "example.co.uk");
  assert.equal(d("a.x.co.at"), "x.co.at");
  assert.equal(d("co.at"), "co.at");
  assert.equal(d("ada.github.io"), "ada.github.io");
  assert.equal(d("a.b.ck"), "a.b.ck");
  assert.equal(d("www.ck"), "www.ck");
  assert.equal(d("foo.bar.unlisted"), "foo.bar.unlisted");
  assert.equal(d("localhost"), "localhost");
  assert.equal(d("127.0.0.1"), "127.0.0.1");
  assert.equal(d("[::1]"), "[::1]");
  assert.equal(d(".docs.google.com"), "google.com");
  assert.equal(d("www.食狮.公司.cn"), "xn--85x722f.xn--55qx5d.cn");
});

test("markdown: chunks cut at block boundaries, repeat a table's header and cover the page", async () => {
  const servers = await startFixtureServers();
  try {
    await withRepl(async ({ run, dir }) => {
      const r = await run(`
        await page.goto("${servers.origins.primary}/corpus/wikipedia.html");
        const full = await page.markdown();
        const chunks = [];
        let start = 0;
        for (let i = 0; i < 200; i++) {
          const text = await page.markdown({ start, maxChars: 4000 });
          const note = /<!-- characters ([\\d,]+) to ([\\d,]+) of ([\\d,]+)(?:; continue with page\\.markdown\\(\\{ start: (\\d+), maxChars: 4000 \\}\\))? -->\\n$/.exec(text);
          if (!note) throw new Error("chunk without a note: " + text.slice(-200));
          chunks.push({ text: text.slice(0, note.index).replace(/\\n+$/, "\\n"), from: Number(note[1].replace(/,/g, "")), to: Number(note[2].replace(/,/g, "")) });
          if (!note[4]) break;
          start = Number(note[4]);
        }
        fs.writeFileSync("./md.json", JSON.stringify({ full, chunks }));
        chunks.length
      `);
      assert.equal(r.error, null);
      const { full, chunks } = JSON.parse(fs.readFileSync(path.join(dir, "md.json"), "utf8"));
      assert.ok(chunks.length > 5, `${chunks.length} chunks`);
      let at = 0;
      for (const c of chunks) {
        assert.equal(c.from, at, "chunks are contiguous");
        assert.ok(c.to - c.from <= 4000);
        assert.ok(c.to === full.length || full.slice(c.to - 2, c.to) === "\n\n" || full[c.to - 1] === "\n", "a chunk ends at a block or line boundary");
        const own = full.slice(c.from, c.to);
        if (c.text !== own.replace(/\n+$/, "\n")) {
          // Only a repeated table header may come before the chunk's own text.
          const header = c.text.slice(0, c.text.length - own.replace(/\n+$/, "\n").length).split("\n");
          assert.equal(header.length, 3, "a header of two lines");
          assert.match(header[1], /^\|( --- \|)+$/);
        }
        at = c.to;
      }
      assert.equal(at, full.length);
    });
  } finally {
    await servers.close();
  }
});

// docs/browser-repl/reference-c-parity.md: every row has a verdict, a
// skipped row says why, and every proof names a scenario key or a unit test
// that exists.
test("reference-c-parity.md: verdicts and proofs resolve", () => {
  const root = path.join(path.dirname(new URL(import.meta.url).pathname), "..");
  const doc = fs.readFileSync(path.join(root, "../../docs/browser-repl/reference-c-parity.md"), "utf8");
  const rows = doc.split("\n").filter((l) => l.startsWith("| ") && !l.startsWith("| Reference C |") && !/^\| ---/.test(l));
  assert.ok(rows.length > 60, `${rows.length} rows`);
  const goldenKeys = (name) => {
    const g = JSON.parse(fs.readFileSync(path.join(root, "goldens", `${name}.json`), "utf8"));
    return [...Object.keys(g.cmux || {}), ...Object.keys(g.oracle || {})];
  };
  const titles = (file) => [...fs.readFileSync(path.join(root, "unit", `${file}.test.mjs`), "utf8").matchAll(/^test\("((?:[^"\\]|\\.)*)"/gm)].map((m) => m[1]);
  for (const row of rows) {
    const cells = row.split(/(?<!\\)\|/).slice(1, -1).map((c) => c.trim());
    assert.equal(cells.length, 4, `row has ${cells.length} cells: ${row}`);
    const [, , proof, verdict] = cells;
    const kind = /^(same|better|skipped|known limit)\b/.exec(verdict);
    assert.ok(kind, `no verdict: ${row}`);
    if (kind[1] === "skipped" && !/^skipped( for [^:]+)?: .{20,}/.test(verdict)) assert.fail(`skipped without a reason: ${row}`);
    if (kind[1] === "same" || kind[1] === "better") assert.ok(proof.trim(), `no proof: ${row}`);
    for (const part of proof.split(/, (?=\d\d-|unit:|sites\/|diff )|; /).map((p) => p.trim()).filter(Boolean)) {
      const scenario = /^(\d\d-[a-z0-9-]+)((?: `[^`]+`,?)*)$/.exec(part);
      const unit = /^unit: ([\w-]+) ((?:`[^`]+`(?:, )?)+)$/.exec(part);
      const diffCase = /^diff ((?:`[^`]+`(?:, )?)+)$/.exec(part);
      if (diffCase) {
        const dir = path.join(root, "diff", "cases");
        const ids = fs.readdirSync(dir).flatMap((f) => [...fs.readFileSync(path.join(dir, f), "utf8").matchAll(/\bid: [`"]([^`"$]+)/g)].map((m) => m[1]));
        for (const [, id] of diffCase[1].matchAll(/`([^`]+)`/g)) {
          const hit = id.endsWith("*") ? ids.some((x) => x.startsWith(id.slice(0, -1))) : ids.includes(id);
          assert.ok(hit, `no diff case ${id}`);
        }
      } else if (scenario) {
        assert.ok(fs.existsSync(path.join(root, "scenarios", `${scenario[1]}.js`)), `no scenario ${scenario[1]}`);
        const keys = goldenKeys(scenario[1]);
        for (const [, key] of scenario[2].matchAll(/`([^`]+)`/g)) {
          const hit = key.endsWith("*") ? keys.some((k) => k.startsWith(key.slice(0, -1))) : keys.includes(key);
          assert.ok(hit, `${scenario[1]} has no golden key ${key}`);
        }
      } else if (unit) {
        const all = titles(unit[1]);
        for (const [, t] of unit[2].matchAll(/`([^`]+)`/g)) {
          assert.equal(all.filter((x) => x.startsWith(t.replace(/…$/, ""))).length, 1, `unit/${unit[1]}: "${t}" names no single test`);
        }
      } else assert.ok(/^sites\/\*\.test\.mjs$/.test(part), `unknown proof "${part}" in: ${row}`);
    }
  }
});
