// Reference C parity (docs/browser-repl/reference-c-parity.md): Markdown and
// selector extraction, page text search, scrolling, drop-down options,
// highlights, search result parsing, custom tools, downloads, recording,
// secrets and the domain policy.
// oracle: skip (cmux-defined tools with no Playwright counterpart)
// ---- cell session=bu
await page.setViewportSize({ width: 1280, height: 800 });
await page.goto(`${PRIMARY}/agent-tools.html?peer=${PEER}`);
await page.frameLocator("#peer-frame").locator("h2").waitFor();
emitCmux("markdown", await page.markdown());
emitCmux("markdown-main-chunk", await page.markdown({ main: true, maxChars: 300 }));
const firstCut = /start: (\d+)/.exec(await page.markdown({ main: true, maxChars: 300 }))[1];
emitCmux("markdown-main-next", (await page.markdown({ main: true, maxChars: 300, start: Number(firstCut) })).split("\n").slice(0, 3));
emitCmux("markdown-no-links", (await page.markdown({ main: true, links: false })).split("\n")[2]);
// ---- cell session=bu
emitCmux("extract", await page.extract({ title: "h1", products: [{ $: ".product", name: "h3", price: ".price", url: "a@href", sku: "@data-sku", tags: ["li"] }], scores: ["#scores td"] }));
emitCmux("extract-scoped", await page.extract({ name: "h3", missing: ".nothing" }, { scope: page.locator(".product").nth(1) }));
const found = await page.searchText("beta", { context: 12 });
emitCmux("search-text", { total: found.total, matches: found.matches.map((m) => ({ match: m.match, context: m.context, ref: typeof m.ref })) });
emitCmux("search-text-ref-works", await page.locator(found.matches[0].ref).evaluate((e) => e.tagName));
emitCmux("search-text-regex", (await page.searchText("log line \\d+5\\b", { regex: true, limit: 2 })).matches.map((m) => m.match));
// ---- cell session=bu
emitCmux("dropdown-select", await page.dropdownOptions("#plan"));
emitCmux("dropdown-closed-aria", await page.dropdownOptions("#combo").catch((e) => e.message.replace(/#combo/, "<target>")));
await page.click("#combo");
const fruit = await page.dropdownOptions("#combo");
emitCmux("dropdown-aria", fruit.map(({ ref, ...o }) => ({ ...o, ref: typeof ref })));
await page.locator(fruit[0].ref).click();
emitCmux("dropdown-aria-ref-clicks", await page.locator(fruit[0].ref).textContent());
// ---- cell session=bu
const deep = await page.scrollToText("Deep anchor");
emitCmux("scroll-to-text", [typeof deep, await page.locator("#deep").evaluate((e) => { const r = e.getBoundingClientRect(); return r.top >= 0 && r.bottom <= innerHeight; })]);
const before = await page.scrollInfo();
const after = await page.scroll({ pages: -1 });
emitCmux("scroll-page", [before.pagesBelow, after.y < before.y, after.pagesBelow >= 1]);
const inner = await page.scroll({ target: "#log", pages: 1 });
emitCmux("scroll-element", [inner.viewportHeight, inner.y > 0, inner.pagesAbove > 0]);
await page.locator("#login").scrollIntoViewIfNeeded();
emitCmux("highlight", await page.highlight(["#user", page.locator("#login input[type=password], #login button")]));
await page.hideHighlight();
await page.locator("#plan").highlight();
await page.hideHighlight();
// ---- cell session=bu
emitCmux("search-duckduckgo", await search("cmux terminal", { endpoint: `${PRIMARY}/search-duckduckgo.html?q=%s` }));
emitCmux("search-bing", await search("cmux", { engine: "bing", endpoint: `${PRIMARY}/search-bing.html?q=%s`, limit: 1 }));
emitCmux("search-bad-engine", await search("x", { engine: "altavista" }).catch((e) => e.message));
// ---- cell session=bu
tools.register("price", async ({ sku }, { page }) => page.extract(`.product[data-sku="${sku}"] .price`), { description: "Price of a product by SKU", params: { sku: "string" } });
tools.register("onlyElsewhere", async () => 1, { domains: ["example.com"] });
emitCmux("tools-list", tools.list());
emitCmux("tools-call", [await tools.price({ sku: "B2" }), await tools.call("price", { sku: "C3" })]);
emitCmux("tools-errors", await Promise.all([tools.price({}), tools.price({ sku: 1 }), tools.price({ sku: "A1", extra: 1 }), tools.onlyElsewhere()].map((p) => p.catch((e) => e.message.replace(/http:\/\/\S+/, "<url>")))));
// ---- cell session=bu
const [download] = await Promise.all([page.waitForEvent("download"), page.click("#download")]);
await download.path();
emitCmux("downloads", session.downloads().map((d) => ({ url: d.url, suggestedFilename: d.suggestedFilename, state: d.state, readable: fs.readFileSync(d.path, "utf8") })));
// ---- cell session=bu
const rec = session.record({ dir: "./artifacts/record-32" });
await page.goto(`${PRIMARY}/aria.html`);
await page.goto(`${PRIMARY}/agent-tools.html`);
await page.fill("#user", "ada");
const run = await rec.stop();
const lines = fs.readFileSync(run.trace, "utf8").trim().split("\n").map((l) => JSON.parse(l));
const png = fs.readFileSync(run.animation);
emitCmux("record", { frames: run.frames, steps: lines.map((l) => l.method || l.event).filter((s) => !s.startsWith("input.")), apng: [png.toString("latin1", 1, 4), png.toString("latin1", 37, 41)] });
// ---- cell session=bu
secrets.set("key", "sk-live-4242", { domains: ["localhost"] });
secrets.set("pw", "correct horse", { domains: ["localhost"] });
await page.goto(`${PRIMARY}/agent-tools.html?peer=${PEER}`);
await page.fill("#apikey", secret("key"));
await page.locator("#pass").pressSequentially(secret("pw"));
await page.fill("#user", "ada");
await page.click("text=Sign in");
emitCmux("secret-status", await page.locator("#status").textContent());
emitCmux("secret-snapshot", (await snapshot()).tree.split("\n").filter((l) => /API key|Signed in|^url:|^title:/.test(l)).map((l) => l.replace(/ \[ref=e\d+\]/, "")));
emitCmux("secret-evaluate", await page.evaluate(() => [document.getElementById("apikey").value, location.search]));
emitCmux("secret-console", (await page.consoleMessages()).map(String).filter((t) => t.startsWith("signing in")));
emitCmux("secret-value", [String(secret("key")), JSON.stringify({ k: secret("key") }), secrets.list()]);
emitCmux("secret-frame-refused", await page.frameLocator("#peer-frame").locator("#frame-field").fill(secret("key")).catch((e) => e.message));
emitCmux("secret-keyboard-refused", await page.keyboard.type(secret("key")).catch((e) => e.message));
// ---- cell session=bu capture
// Printing masks a value the agent writes itself; errors are checked in
// unit/agent-tools.test.mjs (a recorded scenario may not throw).
console.log("typed sk-live-4242 and correct horse");
console.error(String(new Error("failed with sk-live-4242")));
emitCmux("secret-fetch-text", await (await fetch(page.url())).text().then((t) => t.includes("sk-live-4242")));
// ---- cell session=bu
session.allowedDomains(["http://localhost"]);
emitCmux("policy-goto", await page.goto(`${PEER}/aria.html`).then(() => "loaded", (e) => e.message));
emitCmux("policy-fetch", await fetch(`${PEER}/api/data`).then(() => "fetched", (e) => e.message));
emitCmux("policy-tabs-open", await tabs.open(`${PEER}/aria.html`).then(() => "opened", (e) => e.message));
await page.goto(`${PRIMARY}/agent-tools.html?peer=${PEER}`);
// Subresources follow the policy too: a script from the allowed origin
// loads, one from the peer is blocked.
emitCmux("policy-subresources", await page.evaluate(async (peer) => {
  const load = (src) => new Promise((r) => { const s = document.createElement("script"); s.onload = () => r("loaded"); s.onerror = () => r("blocked"); s.src = src; document.head.append(s); });
  return [await load("/log.js?own"), await load(peer + "/log.js?peer")];
}, PEER));
// The driver cancels the link's navigation in a tab the session opened: the
// tab stays on its page and the block is logged (the click fails if the
// report arrives before it returns, so its outcome is not recorded).
await page.click("#peer-link").catch(() => {});
for (let i = 0; i < 100 && !session.blockedNavigations().some((b) => b.blocked === "cancelled"); i++) await sleep(50);
emitCmux("policy-after-link", [page.url(), [...new Set(session.blockedNavigations().map((b) => `${b.blocked} ${b.url}`))]]);
session.allowedDomains(null);
session.prohibitedDomains(["http://127.0.0.1"]);
emitCmux("policy-prohibited", await page.goto(`${PEER}/aria.html`).then(() => "loaded", (e) => e.message));
session.prohibitedDomains(null);
session.blockIPAddresses(true);
emitCmux("policy-ip", await page.goto(`${PEER}/aria.html`).then(() => "loaded", (e) => e.message));
session.blockIPAddresses(false);
session.allowedDomains(["http://localhost"], { lock: true });
emitCmux("policy-locked", (() => { try { session.allowedDomains(null); } catch (e) { return e.message; } })());
// ---- cell session=bu
// A secret typed into a plain text field never shows in a capture: the
// field's pixels are the same for any secret of that length, and differ
// from the same field showing that text unregistered.
await page.goto(`${PRIMARY}/agent-tools.html`);
const keyField = page.locator("#apikey");
await keyField.fill(secret("key"));
await keyField.evaluate((e) => e.blur());
const shotSecret = (await keyField.screenshot()).toString("base64");
await keyField.fill("xx-xxxx-xxxx");
await keyField.evaluate((e) => e.blur());
const shotText = (await keyField.screenshot()).toString("base64");
secrets.set("decoy", "xx-xxxx-xxxx", { domains: ["localhost"] });
const shotDecoy = (await keyField.screenshot()).toString("base64");
// Two captures at once: the one that ends first must not unmask the other's
// field, and the field is unmasked once both end.
const [shotA, shotB] = await Promise.all([keyField.screenshot(), keyField.screenshot()]);
const concurrentMasked = shotA.toString("base64") === shotDecoy && shotB.toString("base64") === shotDecoy;
secrets.delete("decoy");
const shotAfter = (await keyField.screenshot()).toString("base64");
emitCmux("secret-screenshot", { maskedLikeAnySecret: shotSecret === shotDecoy, textHidden: shotSecret !== shotText, restored: shotAfter === shotText });
emitCmux("secret-screenshot-concurrent", { masked: concurrentMasked, restored: shotAfter === shotText });
emitCmux("secret-needs-domains", (() => { try { secrets.set("x", "y"); } catch (e) { return e.message; } })());
