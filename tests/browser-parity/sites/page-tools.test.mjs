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

test("pageAssets.bundle sends cookies only to the page's own origin; a cross-origin asset is fetched without credentials", async () => {
  await s.run('await page.goto("https://assets.example/xpage")');
  const before = env.state.requests.length;
  await s.value('sites.pageAssets.bundle((await sites.pageAssets.list()).id, { kinds: ["image"] })');
  const reqs = env.state.requests.slice(before);
  const other = reqs.filter((r) => r.url.startsWith("https://github.com/"));
  assert.ok(other.length, "the cross-origin asset was requested");
  assert.deepEqual(other.map((r) => r.cookie), other.map(() => ""), "no cookie went to github.com");
  const own = reqs.filter((r) => r.url === "https://assets.example/img/logo.png");
  assert.ok(own.length && own.every((r) => r.cookie.includes("asset_session=asset-session-secret")), "the page's own asset kept the session cookie");
});

test("pageAssets.bundle fetches through the inventory's tab and origin, not the current tab's", async () => {
  await s.run('await page.goto("https://assets.example/xpage"); var assetInventory = await sites.pageAssets.list(); var assetPage = page; await tabs.open("https://tools.example/")');
  assert.equal(await s.value("page.url()"), "https://tools.example/");
  const before = env.state.requests.length;
  await s.value('sites.pageAssets.bundle(assetInventory.id, { kinds: ["image"] })');
  const reqs = env.state.requests.slice(before);
  const own = reqs.filter((r) => r.url === "https://assets.example/img/logo.png");
  assert.ok(own.length && own.every((r) => r.cookie.includes("asset_session=asset-session-secret")), "the inventory page's own asset lost its session cookie because another tab is current");
  const other = reqs.filter((r) => r.url.startsWith("https://github.com/"));
  assert.deepEqual(other.map((r) => r.cookie), other.map(() => ""), "no cookie went to github.com");
  // An inventory whose tab closed is not fetched through whichever tab is current.
  await s.run("await assetPage.close()");
  assert.match(await s.error('sites.pageAssets.bundle(assetInventory.id, { kinds: ["image"] })'), /tab .*closed/);
  // A copied inventory, not one list() made in this session, sends no cookies.
  await s.run('await page.goto("https://assets.example/xpage")');
  const beforeCopy = env.state.requests.length;
  await s.value('sites.pageAssets.bundle({ ...assetInventory, id: "copied" }, { kinds: ["image"] })');
  const copied = env.state.requests.slice(beforeCopy).filter((r) => r.url === "https://assets.example/img/logo.png");
  assert.ok(copied.length && copied.every((r) => r.cookie === ""), "a copied inventory's asset was fetched with the current tab's cookies");
});

test("webmcp: lists a page's tools; a call needs a confirmed draft, a trusted read-only call runs", async () => {
  await s.run('await page.goto("https://tools.example/")');
  const t = await s.value("sites.webmcp.tools()");
  assert.deepEqual(t.tools.map((x) => [x.name, !!x.annotations.readOnlyHint]), [["search_products", true], ["empty_cart", true], ["add_to_cart", false]]);
  assert.deepEqual(await s.value('sites.webmcp.call("search_products", { q: "tea" }, { trustReadOnlyHint: true })'), { content: [{ type: "text", text: "2 results for tea" }] });
  const d = await s.value('sites.webmcp.call("add_to_cart", { sku: "T-1" })');
  assert.equal(d.status, "draft");
  assert.equal(env.state.cart, undefined);
  assert.deepEqual(await s.value(`sites.webmcp.call(${JSON.stringify(d.id)}, { confirm: true })`), { content: [{ type: "text", text: "added T-1" }] });
  assert.deepEqual(env.state.cart, [{ sku: "T-1" }]);
  await s.run('await page.goto("https://tools.example/none")');
  assert.deepEqual(await s.value("sites.webmcp.tools()"), { supported: false, tools: [], note: "webmcp: this page declares no WebMCP tools (no navigator.modelContext). WebKit has no built-in WebMCP; only pages that ship their own implementation expose tools." });
});

test("webmcp: a page's readOnlyHint is advisory; every call is a draft unless the agent opts out per call", async () => {
  await s.run('await page.goto("https://tools.example/")');
  const lie = await s.value('sites.webmcp.call("empty_cart", {})');
  assert.equal(lie.status, "draft", "a tool that claims readOnlyHint still needs a confirmed draft");
  assert.equal(env.state.cartCleared, undefined);
  assert.equal((await s.value('sites.webmcp.call("search_products", { q: "tea" })')).status, "draft");
  // The agent's per-call opt-out runs a tool that declares readOnlyHint directly, and only such a tool.
  assert.deepEqual(await s.value('sites.webmcp.call("search_products", { q: "tea" }, { trustReadOnlyHint: true })'), { content: [{ type: "text", text: "2 results for tea" }] });
  assert.equal((await s.value('sites.webmcp.call("add_to_cart", { sku: "T-2" }, { trustReadOnlyHint: true })')).status, "draft");
  assert.match(await s.error('sites.webmcp.call("not_a_tool", {})'), /has no tool "not_a_tool"/);
});

test("browserAuth.request: the app fills marked fields and submits; no value reaches the REPL and markers are removed", async () => {
  await s.run('await page.goto("https://login.example/")');
  globalThis.__authAnswer = fillLike({ email: "ada@example.com", password: "correct horse" });
  const req = `sites.browserAuth.request({ origin: "https://login.example", fields: [
    { id: "email", label: "Email", type: "email", autocomplete: "username", selector: 'input[name="email"]' },
    { id: "password", label: "Password", type: "password", autocomplete: "current-password", selector: page.getByLabel("Password") } ],
    submit: { selector: '#f button[type="submit"]', action: "click" } })`;
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

// r16 tabs#1: agent code can reach the driver's auth.request itself and
// name any marked element, so the helper's visibility check is not the
// guard. The app's own bind and fill take only a field the user can see:
// shown (no display:none, visibility, opacity 0 or inert), at least a few
// pixels, on screen and not covered, and focusable; a field hidden while
// the sheet is up gets nothing either.
test("browserAuth.request: no hidden field is filled, also when auth.request is called directly", async () => {
  const hides = {
    display: "el.style.display = 'none'",
    visibility: "el.style.visibility = 'hidden'",
    opacity: "el.style.opacity = '0'",
    parentOpacity: "const w = document.createElement('div'); w.style.opacity = '0'; el.replaceWith(w); w.append(el)",
    tiny: "el.style.cssText = 'width:1px;height:1px;padding:0;border:0'",
    offscreen: "el.style.cssText = 'position:absolute;left:-10000px;top:0'",
    covered: "const c = document.createElement('div'); const r = el.getBoundingClientRect(); c.style.cssText = `position:fixed;left:${r.left - 5}px;top:${r.top - 5}px;width:${r.width + 10}px;height:${r.height + 10}px;background:white;z-index:9`; document.body.append(c)",
    inert: "el.inert = true",
  };
  const call = (marker) => `page._session.call("auth.request", { targetId: page._targetId, origin: "https://login.example", timeoutMs: 5000, fields: [{ id: "pw", label: "Password", type: "password", autocomplete: null, required: true, marker: ${JSON.stringify(marker)} }] })`;
  for (const [name, hide] of Object.entries(hides)) {
    await s.run('await page.goto("https://login.example/")');
    globalThis.__authAnswer = fillLike({ pw: "correct horse" });
    await s.value(`page.evaluate(() => { const el = document.querySelector('input[type="password"]'); el.setAttribute("data-cmux-auth", "hidden-${name}"); ${hide}; return true; })`);
    const r = await s.value(call(`hidden-${name}`));
    assert.equal(r.status, "locator_invalid", `${name}: ${JSON.stringify(r)}`);
    assert.equal(await s.value(`page.evaluate(() => document.querySelector('input[type="password"]').value)`), "", `${name}: the hidden field was filled`);
  }
  // Shown when the sheet opens, hidden before Fill.
  await s.run('await page.goto("https://login.example/")');
  globalThis.__authAnswer = fillLike({ pw: "correct horse" }, {
    meanwhile: ({ params, call: driverCall }) => driverCall("frame.evaluate", { targetId: params.targetId, frameId: params.frameId, world: "page", source: `() => { document.querySelector('input[type="password"]').style.opacity = "0"; return true; }`, args: [], awaitPromise: true }),
  });
  await s.value(`page.evaluate(() => { document.querySelector('input[type="password"]').setAttribute("data-cmux-auth", "later"); return true; })`);
  const later = await s.value(call("later"));
  assert.equal(later.status, "locator_invalid", JSON.stringify(later));
  assert.equal(await s.value(`page.evaluate(() => document.querySelector('input[type="password"]').value)`), "");
  // A shown field is filled through the same direct call.
  await s.run('await page.goto("https://login.example/")');
  globalThis.__authAnswer = fillLike({ pw: "correct horse" });
  await s.value(`page.evaluate(() => { document.querySelector('input[type="password"]').setAttribute("data-cmux-auth", "shown"); return true; })`);
  assert.deepEqual(await s.value(call("shown")), { status: "filled" });
  assert.equal(await s.value(`page.evaluate(() => document.querySelector('input[type="password"]').value)`), "correct horse");
});

test("browserAuth.request: a frame whose origin changed while the sheet was open is not filled", async () => {
  await s.run('await page.goto("https://login.example/")');
  // The sheet named https://login.example; by Fill the frame holds another
  // origin's document. The fill compares its own location.origin.
  globalThis.__authAnswer = fillLike({ email: "ada@example.com" }, { origin: "https://elsewhere.example" });
  const field = `{ id: "email", label: "Email", type: "email", selector: 'input[name="email"]' }`;
  assert.deepEqual(await s.value(`sites.browserAuth.request({ origin: "https://login.example", fields: [${field}] })`), { status: "origin_changed" });
  assert.equal(await s.value(`page.locator('input[name="email"]').inputValue()`), "");
});

test("browserAuth.request: the fill goes only to the elements and document marked when the sheet was requested", async () => {
  const field = `{ id: "email", label: "Email", type: "email", selector: 'input[name="email"]' }`;
  const pageEval = (call, params, source) => call("frame.evaluate", { targetId: params.targetId, frameId: params.frameId, world: "page", source, args: [], awaitPromise: true });
  // Another session (or the page) moves the marker to a decoy in the same
  // document while the sheet is up.
  await s.run('await page.goto("https://login.example/")');
  globalThis.__authAnswer = fillLike({ email: "ada@example.com" }, {
    meanwhile: ({ params, call }) => pageEval(call, params, `() => {
      const original = document.querySelector("[data-cmux-auth]");
      const decoy = document.createElement("input");
      decoy.type = "email";
      decoy.id = "decoy";
      decoy.setAttribute("data-cmux-auth", original.getAttribute("data-cmux-auth"));
      original.removeAttribute("data-cmux-auth");
      document.body.append(decoy);
      return true;
    }`),
  });
  assert.deepEqual(await s.value(`sites.browserAuth.request({ origin: "https://login.example", fields: [${field}] })`), { status: "page_changed" });
  assert.deepEqual(await s.value(`page.evaluate(() => [document.getElementById("decoy").value, document.querySelector('input[name="email"]').value])`), ["", ""]);
  // A duplicate marker: the original keeps it and a decoy gets a copy.
  await s.run('await page.goto("https://login.example/")');
  globalThis.__authAnswer = fillLike({ email: "ada@example.com" }, {
    meanwhile: ({ params, call }) => pageEval(call, params, `() => {
      const decoy = document.createElement("input");
      decoy.type = "email";
      decoy.id = "decoy";
      decoy.setAttribute("data-cmux-auth", document.querySelector("[data-cmux-auth]").getAttribute("data-cmux-auth"));
      document.body.prepend(decoy);
      return true;
    }`),
  });
  assert.deepEqual(await s.value(`sites.browserAuth.request({ origin: "https://login.example", fields: [${field}] })`), { status: "page_changed" });
  assert.deepEqual(await s.value(`page.evaluate(() => [document.getElementById("decoy").value, document.querySelector('input[name="email"]').value])`), ["", ""]);
  // Another same-origin document replaces the one marked, and its field
  // gets the marker.
  await s.run('await page.goto("https://login.example/")');
  globalThis.__authAnswer = fillLike({ email: "ada@example.com" }, {
    meanwhile: async ({ params, call }) => {
      const marker = await pageEval(call, params, `() => document.querySelector("[data-cmux-auth]").getAttribute("data-cmux-auth")`);
      await call("tab.navigate", { targetId: params.targetId, url: "https://login.example/?again" });
      await pageEval(call, params, `() => { document.querySelector('input[name="email"]').setAttribute("data-cmux-auth", ${JSON.stringify(marker)}); return true; }`);
    },
  });
  assert.deepEqual(await s.value(`sites.browserAuth.request({ origin: "https://login.example", fields: [${field}] })`), { status: "page_changed" });
  assert.equal(await s.value(`page.evaluate(() => document.querySelector('input[name="email"]').value)`), "");
});

test("browserAuth.request: cancel, wrong origin, bad selectors, and no native sheet", async () => {
  await s.run('await page.goto("https://login.example/")');
  globalThis.__authAnswer = null;
  const field = `{ id: "email", label: "Email", type: "email", selector: 'input[name="email"]' }`;
  assert.deepEqual(await s.value(`sites.browserAuth.request({ origin: "https://login.example", fields: [${field}] })`), { status: "cancelled" });
  assert.deepEqual(await s.value(`sites.browserAuth.request({ origin: "https://evil.example", fields: [${field}] })`), { status: "origin_changed" });
  assert.deepEqual(await s.value(`sites.browserAuth.request({ origin: "https://login.example", fields: [{ id: "x", label: "X", type: "text", selector: "input" }] })`), { status: "locator_invalid", locator_error: { field_id: "x", reason: "not_unique" } });
  assert.deepEqual(await s.value(`sites.browserAuth.request({ origin: "https://login.example", fields: [{ id: "b", label: "B", type: "text", selector: "#f button" }] })`), { status: "locator_invalid", locator_error: { field_id: "b", reason: "not_editable_text_field" } });
  assert.match(await s.error(`sites.browserAuth.request({ origin: "https://login.example", fields: [{ id: "e", label: "Enter your email\\nand password", type: "email", selector: "input" }] })`), /label: expected a short noun phrase/);
  globalThis.__authAnswer = (params, { call }) => call("auth.request", params);
  assert.deepEqual(await s.value(`sites.browserAuth.request({ origin: "https://login.example", fields: [${field}] })`), { status: "unavailable" });
  assert.equal(await s.value("page.evaluate(() => document.querySelectorAll('[data-cmux-auth]').length)"), 0);
});

// r15 sites#5: after the user fills the sheet, cmux activates only the
// submit control of the form that holds the filled fields (a submit
// button or input of that form; Enter only in a filled field). Any other
// control the agent names is refused before the sheet opens, and nothing
// is filled or pressed.
test("browserAuth.request: submit presses only a submit control of the fields' own form", async () => {
  await s.run('await page.goto("https://login.example/")');
  globalThis.__authAnswer = fillLike({ email: "ada@example.com" });
  const field = `{ id: "email", label: "Email", type: "email", selector: 'input[name="email"]' }`;
  for (const submit of ['{ selector: "#danger" }', '{ selector: "#other" }', '{ selector: "#note", action: "press_enter" }', '{ selector: "label" }']) {
    const count = s.auth.length;
    const r = await s.value(`sites.browserAuth.request({ origin: "https://login.example", fields: [${field}], submit: ${submit} })`);
    assert.equal(r.status, "locator_invalid", submit);
    assert.equal(r.locator_error.field_id, "submit", submit);
    assert.equal(s.auth.length, count, `the sheet opened for ${submit}`);
    assert.deepEqual(await s.value(`page.evaluate(() => [document.getElementById("out").textContent, document.querySelector('input[name="email"]').value, document.querySelectorAll("[data-cmux-auth], [data-cmux-auth-form]").length])`), ["", "", 0], submit);
  }
  assert.deepEqual(await s.value(`sites.browserAuth.request({ origin: "https://login.example", fields: [${field}], submit: { selector: 'input[name="email"]', action: "press_enter" } })`), { status: "submitted" });
  assert.match(await s.value('page.locator("#out").textContent()'), /^submitted as ada@example\.com/);
});

// r15 tabs#2: the sheet shows only what cmux verified. The agent's labels
// (and the page's title) are not shown; each field is labeled by the
// credential kind the app's bind found on the bound element itself.
test("browserAuth.request: the app's bind answers each bound element's credential kind for the sheet's labels", async () => {
  await s.run('await page.goto("https://login.example/")');
  let bound = null;
  globalThis.__authAnswer = fillLike({}, { onBound: (b) => (bound = b) });
  await s.value(`sites.browserAuth.request({ origin: "https://login.example", fields: [
    { id: "a", label: "Your favorite color", type: "email", selector: 'input[name="email"]' },
    { id: "b", label: "Confirm to continue", type: "password", selector: 'input[name="password"]' } ] })`);
  assert.deepEqual(bound, { status: "bound", kinds: ["username", "password"] });
});

test("browserAuth.request: only credential fields (password, username, one-time code) are filled", async () => {
  await s.run('await page.goto("https://login.example/")');
  globalThis.__authAnswer = fillLike({ note: "correct horse", comment: "correct horse" });
  const count = s.auth.length;
  for (const [id, selector] of [["note", "#note"], ["comment", "#comment"]]) {
    assert.deepEqual(await s.value(`sites.browserAuth.request({ origin: "https://login.example", fields: [{ id: "${id}", label: "Password", type: "text", selector: "${selector}" }] })`), { status: "locator_invalid", locator_error: { field_id: id, reason: "not_credential_field" } });
  }
  assert.equal(s.auth.length, count);
  assert.equal(await s.value('page.evaluate(() => [document.getElementById("note").value, document.getElementById("comment").value])').then(JSON.stringify), JSON.stringify(["", ""]));
});

test("sites.list names every tool; help lists methods; drafts list", async () => {
  const names = (await s.value("sites.list()")).map((t) => t.name);
  assert.deepEqual(names, ["googleAccounts", "googleDocs", "googleSheets", "googleSlides", "googleDrive", "gmail", "googleCalendar", "googleSearch", "youtube", "slack", "notion", "linkedin", "x", "github", "linear", "jira", "pageAssets", "webmcp", "browserAuth"]);
  assert.ok((await s.value("sites.list()")).every((t) => t.summary && !t.error));
  assert.match(await s.value('sites.help("gmail")'), /sites\.gmail\.search\nsites\.gmail\.inbox\nsites\.gmail\.thread/);
  assert.ok(Array.isArray(await s.value("sites.drafts.list()")));
});

test("embeddedJSON reads page data given as an object or as an escaped string (YouTube's mobile pages)", () => {
  const { embeddedJSON } = globalThis.CmuxBrowserRepl.sites;
  assert.deepEqual(embeddedJSON('<script>var ytInitialData = {"a":"}{","b":[1]};</script>', "ytInitialData = "), { a: "}{", b: [1] });
  const escaped = String.raw`<script>var ytInitialData = '\x7b\x22a\x22:\x22it\x5c\x22s \u00e9\x22\x7d';</script>`;
  assert.deepEqual(embeddedJSON(escaped, "ytInitialData = "), { a: 'it"s é' });
  assert.equal(embeddedJSON("<p>none</p>", "ytInitialData = "), null);
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
