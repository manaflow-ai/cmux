// sites.pageAssets, sites.webmcp and sites.browserAuth on mock pages, plus
// the loader (sites.list/help/drafts) and a JavaScriptCore-like load.
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";
import { createSitesEnv, fillLike } from "./harness.mjs";

const env = await createSitesEnv({ authResponder: async (params, ctx) => (globalThis.__authAnswer ? globalThis.__authAnswer(params, ctx) : { status: "cancelled" }) });
test.after(() => env.close());
const s = env.session("tools");

test("pageAssets.list inventories images (src, srcset, CSS, poster, data:), fonts, stylesheets, video, icons, inline SVG", async () => {
  await s.run('await page.goto("https://assets.example/page")');
  const inv = await s.value("sites.pageAssets.list()");
  const byUrl = Object.fromEntries(inv.assets.map((a) => [a.url.startsWith("data:") ? "data" : a.url.replace("https://assets.example", ""), a.kind]));
  assert.deepEqual(
    Object.fromEntries(Object.entries(byUrl).filter(([u]) => !u.startsWith("/favicon"))),
    { "/img/logo.png": "image", "/img/logo@2x.png": "image", "/img/poster.png": "image", "/media/clip.mp4": "video", data: "image", "/css/site.css": "stylesheet", "/img/hero.png": "image", "/fonts/mock.woff2": "font" },
  );
  assert.equal(byUrl["/favicon.ico"], "image");
  assert.deepEqual(inv.inlineSvgs.map((x) => x.name), ["Check"]);
  assert.equal(inv.summary.totalCount, inv.assets.length);
  assert.ok(inv.assets.find((a) => a.url.endsWith("hero.png")).sources.some((x) => x.kind === "computedStyle" && x.property === "background-image"));
});

test("pageAssets.bundle downloads through the session, reports failures, writes inline SVGs and a manifest", async () => {
  const b = await s.value('sites.pageAssets.bundle((await sites.pageAssets.list()).id, { kinds: ["image", "font"] })');
  const names = b.assets.map((a) => path.basename(a.path)).sort();
  assert.ok(names.includes("logo.png") && names.includes("hero.png") && names.includes("mock.woff2") && names.includes("Check.svg"), names.join(","));
  assert.deepEqual(b.failures.map((f) => [f.name, f.reason]), [["logo@2x.png", "HTTP 404"]]);
  assert.ok(fs.readFileSync(b.assets.find((a) => a.name === "Check").path, "utf8").startsWith('<svg xmlns="http://www.w3.org/2000/svg"'));
  assert.equal(JSON.parse(fs.readFileSync(b.manifestPath, "utf8")).summary.failedCount, 1);
  assert.match(await s.error('sites.pageAssets.bundle("inv-999")'), /expected an inventory/);
});

test("webmcp: lists a page's tools; read-only tools run, others need a confirmed draft", async () => {
  await s.run('await page.goto("https://tools.example/")');
  const t = await s.value("sites.webmcp.tools()");
  assert.deepEqual(t.tools.map((x) => [x.name, !!x.annotations.readOnlyHint]), [["search_products", true], ["add_to_cart", false]]);
  assert.deepEqual(await s.value('sites.webmcp.call("search_products", { q: "tea" })'), { content: [{ type: "text", text: "2 results for tea" }] });
  const d = await s.value('sites.webmcp.call("add_to_cart", { sku: "T-1" })');
  assert.equal(d.status, "draft");
  assert.equal(env.state.cart, undefined);
  assert.deepEqual(await s.value(`sites.webmcp.call(${JSON.stringify(d.id)}, { confirm: true })`), { content: [{ type: "text", text: "added T-1" }] });
  assert.deepEqual(env.state.cart, [{ sku: "T-1" }]);
  await s.run('await page.goto("https://tools.example/none")');
  assert.deepEqual(await s.value("sites.webmcp.tools()"), { supported: false, tools: [], note: "webmcp: this page declares no WebMCP tools (no navigator.modelContext). WebKit has no built-in WebMCP; only pages that ship their own implementation expose tools." });
});

test("browserAuth.request: the app fills marked fields and submits; no value reaches the REPL and markers are removed", async () => {
  await s.run('await page.goto("https://login.example/")');
  globalThis.__authAnswer = fillLike({ email: "ada@example.com", password: "correct horse" });
  const req = `sites.browserAuth.request({ origin: "https://login.example", fields: [
    { id: "email", label: "Email", type: "email", autocomplete: "username", selector: 'input[name="email"]' },
    { id: "password", label: "Password", type: "password", autocomplete: "current-password", selector: page.getByLabel("Password") } ],
    submit: { selector: 'button[type="submit"]', action: "click" } })`;
  assert.deepEqual(await s.value(req), { status: "submitted" });
  const sent = s.auth.at(-1);
  assert.deepEqual(sent.fields.map((f) => [f.id, f.label, f.type]), [["email", "Email", "email"], ["password", "Password", "password"]]);
  assert.equal(sent.origin, "https://login.example");
  assert.ok(!JSON.stringify(sent).includes("correct horse"));
  assert.equal(await s.value('page.locator("#out").textContent()'), "submitted as ada@example.com with a 13-character password");
  assert.deepEqual(await s.value("page.evaluate(() => [document.querySelectorAll('[data-cmux-auth]').length, [...new Set(window.seen)]])"), [0, ["email", "password"]]);
  const scope = Object.keys(s.repl.scope).map((k) => { try { return JSON.stringify(s.repl.scope[k]); } catch { return ""; } }).join("\n");
  assert.ok(!scope.includes("correct horse"));
});

test("browserAuth.request: cancel, wrong origin, bad selectors, and no native sheet", async () => {
  await s.run('await page.goto("https://login.example/")');
  globalThis.__authAnswer = null;
  const field = `{ id: "email", label: "Email", type: "email", selector: 'input[name="email"]' }`;
  assert.deepEqual(await s.value(`sites.browserAuth.request({ origin: "https://login.example", fields: [${field}] })`), { status: "cancelled" });
  assert.deepEqual(await s.value(`sites.browserAuth.request({ origin: "https://evil.example", fields: [${field}] })`), { status: "origin_changed" });
  assert.deepEqual(await s.value(`sites.browserAuth.request({ origin: "https://login.example", fields: [{ id: "x", label: "X", type: "text", selector: "input" }] })`), { status: "locator_invalid", locator_error: { field_id: "x", reason: "not_unique" } });
  assert.deepEqual(await s.value(`sites.browserAuth.request({ origin: "https://login.example", fields: [{ id: "b", label: "B", type: "text", selector: "button" }] })`), { status: "locator_invalid", locator_error: { field_id: "b", reason: "not_editable_text_field" } });
  assert.match(await s.error(`sites.browserAuth.request({ origin: "https://login.example", fields: [{ id: "e", label: "Enter your email\\nand password", type: "email", selector: "input" }] })`), /label: expected a short noun phrase/);
  globalThis.__authAnswer = (params, { call }) => call("auth.request", params);
  assert.deepEqual(await s.value(`sites.browserAuth.request({ origin: "https://login.example", fields: [${field}] })`), { status: "unavailable" });
  assert.equal(await s.value("page.evaluate(() => document.querySelectorAll('[data-cmux-auth]').length)"), 0);
});

test("sites.list names every tool; help lists methods; drafts list", async () => {
  const names = (await s.value("sites.list()")).map((t) => t.name);
  assert.deepEqual(names, ["googleAccounts", "googleDocs", "googleSheets", "googleSlides", "googleDrive", "gmail", "googleCalendar", "googleSearch", "youtube", "slack", "notion", "linkedin", "x", "github", "linear", "jira", "pageAssets", "webmcp", "browserAuth"]);
  assert.ok((await s.value("sites.list()")).every((t) => t.summary && !t.error));
  assert.match(await s.value('sites.help("gmail")'), /sites\.gmail\.search\nsites\.gmail\.inbox\nsites\.gmail\.thread/);
  assert.ok(Array.isArray(await s.value("sites.drafts.list()")));
});

test("the tools load and parse without Node's URL (JavaScriptCore has none)", () => {
  const here = path.dirname(fileURLToPath(import.meta.url));
  const dir = path.join(here, "../../../Resources/browser-repl");
  const manifest = JSON.parse(fs.readFileSync(path.join(dir, "manifest.json"), "utf8"));
  const ctx = vm.createContext({ console });
  for (const f of manifest.repl) vm.runInContext(fs.readFileSync(path.join(dir, f), "utf8"), ctx, { filename: f });
  const out = vm.runInContext(`
    const ns = globalThis.CmuxBrowserRepl;
    const sites = ns.sites.createSites({ session: { now: () => 0, sleep: async () => {} }, host: { tmpdir: "/tmp" }, fetch: null, fs: null, path: null, Buffer: ns.core.Buffer, URL: ns.core.URL, currentPage: () => null });
    const g = ns.sites.shared.google;
    [typeof URL, g.exportURL(g.parse("https://docs.google.com/spreadsheets/u/2/d/SHEETID_0123456789abcdef/edit#gid=42", "t"), "csv", "t"),
     sites.youtube.videoId("https://youtu.be/dQw4w9WgXcQ?t=1"), sites.notion.pageId("https://www.notion.so/x/Page-1a2b3c4d00004000800000000000abcd?v=1")]`, ctx);
  assert.deepEqual(JSON.parse(JSON.stringify(out)), ["undefined", "https://docs.google.com/spreadsheets/d/SHEETID_0123456789abcdef/export?format=csv&gid=42&authuser=2", "dQw4w9WgXcQ", "1a2b3c4d-0000-4000-8000-00000000abcd"]);
});
