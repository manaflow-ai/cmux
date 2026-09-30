import { errorsBetter as errBetter } from "../lib.mjs";
// Page-level members: Aside Page.*, ChatGPT Tab.* and PlaywrightAPI.*.
// $P is the dialect's Playwright page (ChatGPT: t.playwright); $T(n) its
// timeout option; $LOG the lab page's event log.
const LAB = "/diff/lab.html";

export default [
  {
    id: "page.goto.basic",
    members: ["aside:Page.goto", "chatgpt:Tab.goto"],
    path: LAB,
    code: `const r = await $P.goto(U("/diff/next.html"));
return { url: $P.url(), title: await $P.title(), status: r ? r.status() : null, ok: r ? r.ok() : null };`,
    chatgpt: `const r = await t.goto(U("/diff/next.html"));
return { url: await t.url(), title: await t.title(), returns: r === undefined ? "void" : typeof r };`,
    compare: { aside: ["url", "title", "status", "ok"], chatgpt: ["url", "title"] },
    expect: { url: "<primary>/diff/next.html", title: "Next page", status: 200, ok: true },
  },
  {
    id: "page.goto.wait-until",
    members: ["aside:Page.goto"],
    path: LAB,
    code: `const out = {};
for (const w of ["commit", "domcontentloaded", "load", "networkidle"]) {
  const r = await E(() => $P.goto(U("/slow?ms=300&w=" + w), { waitUntil: w, $TO: 10000 }));
  out[w] = r.error ? r : { url: $P.url().replace(/\\?.*/, "") };
}
out.bad = await E(() => $P.goto(U("/diff/next.html"), { waitUntil: "bogus" }));
return out;`,
    chatgpt: null,
    na: { chatgpt: "Tab.goto takes only a URL; ChatGPT has no waitUntil or timeout option on navigation" },
    expect: { commit: { url: "<primary>/slow" }, load: { url: "<primary>/slow" }, bad: { error: "invalid-arg" } },
  },
  {
    id: "page.goto.timeout",
    members: ["aside:Page.goto"],
    path: LAB,
    code: `return { slow: await ms(() => $P.goto(U("/slow?ms=4000"), $T(600))) };`,
    chatgpt: null,
    na: { chatgpt: "Tab.goto has no timeout option" },
    expect: { slow: { error: "timeout", ms: "short" } },
  },
  {
    id: "page.goto.errors",
    members: ["aside:Page.goto", "chatgpt:Tab.goto"],
    path: LAB,
    code: `return { empty: await E(() => $P.goto("")), junk: await E(() => $P.goto("not a url")) };`,
    chatgpt: `return { empty: await E(() => t.goto("")), junk: await E(() => t.goto("not a url")) };`,
    better: {
      chatgpt: {
        reason: "cmux rejects a URL without a scheme; ChatGPT reports it as an approval or navigation failure",
        check: (c, r, h) => h.classifyError(c.empty.error) === "invalid-arg" && h.classifyError(c.junk.error) === "invalid-arg",
      },
      aside: errBetter,
    },
    expect: { empty: { error: "invalid-arg" }, junk: { error: "invalid-arg" } },
  },
  {
    id: "page.reload",
    members: ["aside:Page.reload", "chatgpt:Tab.reload"],
    path: LAB,
    code: `await $P.locator("#counter").click();
const before = await $P.locator("#counter").innerText();
const r = await $P.reload();
return { before, after: await $P.locator("#counter").innerText(), status: r ? r.status() : null };`,
    chatgpt: `await $P.locator("#counter").click();
const before = await $P.locator("#counter").innerText();
await t.reload();
return { before, after: await $P.locator("#counter").innerText() };`,
    compare: { aside: ["before", "after", "status"], chatgpt: ["before", "after"] },
    expect: { before: "Count 1", after: "Count 0", status: 200 },
  },
  {
    id: "page.reload.options",
    members: ["aside:Page.reload"],
    path: LAB,
    code: `const a = await E(() => $P.reload({ waitUntil: "domcontentloaded", $TO: 10000 }));
const b = await E(() => $P.reload({ waitUntil: "commit" }));
return { a: !!a.ok, b: !!b.ok, title: await $P.title() };`,
    chatgpt: null,
    na: { chatgpt: "Tab.reload takes no options" },
    expect: { a: true, b: true, title: "Diff lab" },
  },
  {
    id: "page.back-forward",
    members: ["aside:Page.goBack", "aside:Page.goForward", "chatgpt:Tab.back", "chatgpt:Tab.forward"],
    path: LAB,
    code: `await $P.locator("#next").click();
await $P.waitForURL(U("/diff/next.html"));
const b = await $P.goBack();
const afterBack = $P.url();
const f = await $P.goForward();
return { afterBack, afterForward: $P.url(), title: await $P.title(), backStatus: b ? b.status() : null };`,
    chatgpt: `await $P.locator("#next").click();
await $P.waitForURL(U("/diff/next.html"), $T(5000));
await t.back();
const afterBack = await t.url();
await t.forward();
return { afterBack, afterForward: await t.url(), title: await t.title() };`,
    compare: { aside: ["afterBack", "afterForward", "title"], chatgpt: ["afterBack", "afterForward", "title"] },
    expect: { afterBack: "<primary>/diff/lab.html", afterForward: "<primary>/diff/next.html", title: "Next page" },
  },
  {
    id: "page.back-forward.no-entry",
    members: ["aside:Page.goBack", "aside:Page.goForward", "chatgpt:Tab.back", "chatgpt:Tab.forward"],
    path: null,
    code: `await $P.goto(U("${LAB}"));
const back = await E(() => $P.goBack());
const fwd = await E(() => $P.goForward());
return { back: back.error ? back : back.value ?? null, forward: fwd.error ? fwd : fwd.value ?? null, url: $P.url() };`,
    aside: `await openTab(U("${LAB}"));
const back = await E(() => page.goBack());
const fwd = await E(() => page.goForward());
return { back: back.error ? back : back.value ?? null, forward: fwd.error ? fwd : fwd.value ?? null, url: page.url() };`,
    chatgpt: `await t.goto(U("${LAB}"));
const back = await E(() => t.back());
const fwd = await E(() => t.forward());
return { back: back.error ? back : null, forward: fwd.error ? fwd : null, url: await t.url() };`,
    better: {
      chatgpt: {
        reason: "with no history entry cmux resolves null (Playwright) and stays on the page; ChatGPT throws",
        check: (c, r) => c.back === null && c.forward === null && c.url === r.url,
      },
    },
    expect: { back: null, forward: null, url: "<primary>/diff/lab.html" },
  },
  {
    id: "page.url-title.push-state",
    members: ["aside:Page.url", "aside:Page.title", "chatgpt:Tab.url", "chatgpt:Tab.title"],
    path: LAB,
    code: `const before = [$P.url(), await $P.title()];
await $P.locator("#push").click();
return { before, after: [$P.url(), await $P.title()] };`,
    chatgpt: `const before = [await t.url(), await t.title()];
await $P.locator("#push").click();
await $P.waitForTimeout(100);
return { before, after: [await t.url(), await t.title()] };`,
    expect: { before: ["<primary>/diff/lab.html", "Diff lab"], after: ["<primary>/diff/lab.html?pushed=1", "Diff lab pushed"] },
  },
  {
    id: "page.content",
    members: ["aside:Page.content", "chatgpt:PlaywrightAPI.domSnapshot"],
    path: LAB,
    code: `const html = await $P.content();
return { doctype: /^<!DOCTYPE html>/i.test(html), heading: html.includes("<h1>Diff lab</h1>"), frameText: html.includes("Frame action"), typedValue: null };`,
    chatgpt: `const html = await $P.domSnapshot();
return { doctype: /^<!DOCTYPE html>/i.test(html), heading: html.includes("Diff lab"), frameText: html.includes("Frame action"), typedValue: null };`,
    compare: { aside: ["doctype", "heading", "frameText"], chatgpt: ["heading"] },
    better: {
      chatgpt: {
        reason: "page.content() returns the page's HTML; ChatGPT's domSnapshot is a filtered text view, so markup is not recoverable",
        check: (c, r) => c.heading && c.doctype && !r.doctype,
      },
    },
    expect: { doctype: true, heading: true },
  },
  {
    id: "page.evaluate.forms",
    members: ["aside:Page.evaluate", "chatgpt:PlaywrightAPI.evaluate", "chatgpt:Tab.playwright"],
    path: LAB,
    code: `return {
  noArg: await $P.evaluate(() => document.title),
  arg: await $P.evaluate((a) => a.x + 1, { x: 1 }),
  promise: await $P.evaluate(() => new Promise((r) => setTimeout(() => r("later"), 50))),
  string: await $P.evaluate("1 + 2"),
  nested: await $P.evaluate(() => ({ a: [1, "b", null], d: true })),
  undef: (await $P.evaluate(() => undefined)) === undefined,
  thrown: await E(() => $P.evaluate(() => { throw new Error("page boom"); })),
};`,
    expect: { noArg: "Diff lab", arg: 2, promise: "later", string: 3, nested: { a: [1, "b", null], d: true }, undef: true, thrown: { error: "other" } },
  },
  {
    id: "page.evaluate.mutation",
    members: ["aside:Page.evaluate", "chatgpt:PlaywrightAPI.evaluate"],
    path: LAB,
    code: `const set = await E(() => $P.evaluate(() => { document.getElementById("status").textContent = "set by evaluate"; return 1; }));
return { set: set.error ? set : "ok", status: await $P.locator("#status").innerText() };`,
    better: {
      chatgpt: {
        reason: "page.evaluate runs with full page access like Playwright; ChatGPT's evaluate scope is read-only and refuses DOM writes",
        check: (c, r) => c.set === "ok" && c.status === "set by evaluate" && r.status !== "set by evaluate",
      },
    },
    expect: { set: "ok", status: "set by evaluate" },
  },
  {
    id: "page.evaluate.options",
    members: ["chatgpt:PlaywrightAPI.evaluate"],
    path: LAB,
    code: `return { withArg: await $P.evaluate((a) => a + 1, 1) };`,
    chatgpt: `return { withArg: await $P.evaluate((a) => a + 1, 1, { timeoutMs: 2000 }) };`,
    aside: null,
    na: { aside: "Playwright's evaluate has no options argument; the ChatGPT variant is covered on its own" },
    expect: { withArg: 2 },
  },
  {
    id: "page.query.dollar",
    members: ["aside:Page.$", "aside:Page.$$", "aside:Page.$$eval"],
    path: LAB,
    code: `const one = await $P.$("#action");
const none = await $P.$("#missing");
const many = await $P.$$("li");
return {
  one: one ? await one.textContent() : null,
  none,
  count: many.length,
  texts: await $P.$$eval("li", (els) => els.map((e) => e.textContent)),
  arg: await $P.$$eval("li", (els, n) => els.length + n, 10),
  invalid: await E(() => $P.$("!!!")),
};`,
    chatgpt: `const all = await $P.locator("li").all();
return {
  one: await $P.locator("#action").first().textContent(),
  none: (await $P.locator("#missing").count()) ? "found" : null,
  count: all.length,
  texts: await $P.locator("li").allTextContents(),
  arg: await $P.locator("li").evaluateAll((els, n) => els.length + n, 10),
  invalid: await E(() => $P.locator("!!!").count()),
};`,
    expect: { one: "Action", none: null, count: 3, texts: ["First", "Second", "Third"], arg: 13, invalid: { error: "invalid-arg" } },
  },
  {
    id: "page.getters.page-level",
    members: ["aside:Page.locator", "aside:Page.getByRole", "aside:Page.getByText", "aside:Page.getByLabel", "chatgpt:PlaywrightAPI.locator", "chatgpt:PlaywrightAPI.getByRole", "chatgpt:PlaywrightAPI.getByText", "chatgpt:PlaywrightAPI.getByLabel", "chatgpt:PlaywrightAPI.getByPlaceholder", "chatgpt:PlaywrightAPI.getByTestId"],
    path: LAB,
    code: `return {
  locator: await $P.locator("li").count(),
  role: await $P.getByRole("button", { name: "Action" }).count(),
  roleExact: await $P.getByRole("button", { name: "action", exact: true }).count(),
  roleRegex: await $P.getByRole("button", { name: /^Act/ }).count(),
  checkbox: await $P.getByRole("checkbox").count(),
  text: await $P.getByText("Second").count(),
  textExact: await $P.getByText("second", { exact: true }).count(),
  textRegex: await $P.getByText(/^Fir/).count(),
  label: await $P.getByLabel("Name").count(),
  labelRegex: await $P.getByLabel(/nam/i).count(),
  placeholder: typeof $P.getByPlaceholder === "function" ? await $P.getByPlaceholder("Enter name").count() : "absent",
  testId: typeof $P.getByTestId === "function" ? await $P.getByTestId("item").count() : "absent",
};`,
    compare: { aside: ["locator", "role", "roleExact", "roleRegex", "checkbox", "text", "textExact", "textRegex", "label", "labelRegex"], chatgpt: ["locator", "role", "roleExact", "roleRegex", "checkbox", "text", "textExact", "textRegex", "label", "labelRegex", "placeholder", "testId"] },
    expect: { locator: 3, role: 2, roleExact: 0, roleRegex: 1, checkbox: 1, text: 1, textExact: 0, textRegex: 1, label: 1, labelRegex: 1, placeholder: 1, testId: 3 },
  },
  {
    id: "page.getters.errors",
    members: ["aside:Page.locator", "aside:Page.getByRole", "chatgpt:PlaywrightAPI.locator", "chatgpt:PlaywrightAPI.getByRole", "chatgpt:PlaywrightAPI.getByLabel", "chatgpt:PlaywrightAPI.getByPlaceholder", "chatgpt:PlaywrightAPI.getByTestId", "chatgpt:PlaywrightAPI.getByText", "chatgpt:PlaywrightAPI.frameLocator"],
    path: LAB,
    code: `return {
  css: await E(() => $P.locator("!!!").count()),
  role: await E(() => $P.getByRole("notarole!").count()),
  label: await E(() => $P.getByLabel(42).count()),
  text: await E(() => $P.getByText(42).count()),
  frame: await E(() => $P.frameLocator("!!!").locator("input").count()),
};`,
    better: { aside: errBetter, chatgpt: errBetter },
    expect: { css: { error: "invalid-arg" } },
  },
  {
    id: "page.frame-locator",
    members: ["aside:Page.frameLocator", "chatgpt:PlaywrightAPI.frameLocator", "chatgpt:PlaywrightFrameLocator.locator", "chatgpt:PlaywrightFrameLocator.getByRole", "chatgpt:PlaywrightFrameLocator.getByLabel", "chatgpt:PlaywrightFrameLocator.getByPlaceholder", "chatgpt:PlaywrightFrameLocator.getByTestId", "chatgpt:PlaywrightFrameLocator.getByText"],
    path: LAB,
    code: `const f = $P.frameLocator("#frame");
await f.getByPlaceholder("Frame placeholder").fill("in frame");
await f.getByRole("button", { name: "Frame action" }).click();
return {
  value: await f.locator("#inside").evaluate((e) => e.value),
  label: await f.getByLabel("Frame label").count(),
  testId: await f.getByTestId("frame-input").count(),
  text: await f.getByText("frame clicked").count(),
  regex: await f.getByRole("button", { name: /frame/i }).count(),
};`,
    aside: `const f = page.frameLocator("#frame");
await f.locator("#inside").fill("in frame");
await f.locator("button").click();
return { value: await f.locator("#inside").inputValue() };`,
    compare: { aside: ["value"] },
    expect: { value: "in frame", label: 1, testId: 1, text: 1, regex: 1 },
  },
  {
    id: "page.frame-locator.nested",
    members: ["chatgpt:PlaywrightFrameLocator.frameLocator", "aside:Page.frameLocator"],
    path: "/diff/nest.html",
    code: `const inner = $P.frameLocator("#outer").frameLocator("#inner");
const r = await E(async () => { await inner.locator("button").click(); return await inner.locator("button").innerText(); });
return { text: r.value ?? r };`,
    better: {
      aside: {
        reason: "frame locators reach an srcdoc frame inside a cross-origin frame; Aside's frameLocator does not resolve the inner iframe",
        check: (c, r) => c.text === "deep clicked" && typeof r.text !== "string",
      },
    },
    expect: { text: "deep clicked" },
  },
  {
    id: "page.frames",
    members: ["aside:Page.frames", "aside:Page.mainFrame"],
    path: LAB,
    code: `const frames = $P.frames();
return { count: frames.length, mainUrl: $P.mainFrame().url(), child: frames.some((f) => f !== $P.mainFrame() && f.parentFrame() === $P.mainFrame()) };`,
    chatgpt: null,
    na: { chatgpt: "ChatGPT exposes no frame objects; frames are reached with frameLocator (page.frame-locator)" },
    expect: { count: 2, mainUrl: "<primary>/diff/lab.html", child: true },
  },
  {
    id: "page.click-fill",
    members: ["aside:Page.click", "aside:Page.fill"],
    path: LAB,
    code: `await $P.click("#action");
await $P.fill("#name", "via page.fill");
return { status: await $P.locator("#status").innerText(), name: await $P.locator("#name").inputValue(), missing: await E(() => $P.click("#missing", $T(300))) };`,
    chatgpt: `await $P.locator("#action").click();
await $P.locator("#name").fill("via page.fill");
return { status: await $P.locator("#status").innerText(), name: await $P.locator("#name").evaluate((e) => e.value), missing: await E(() => $P.locator("#missing").click($T(300))) };`,
    better: { chatgpt: errBetter, aside: errBetter },
    expect: { status: "clicked", name: "via page.fill", missing: { error: "no-element" } },
  },
  {
    id: "page.screenshot.forms",
    members: ["aside:Page.screenshot", "chatgpt:Tab.screenshot"],
    path: LAB,
    code: `const plain = imgInfo(await $P.screenshot());
const full = imgInfo(await $P.screenshot({ fullPage: true }));
const clip = imgInfo(await $P.screenshot({ clip: { x: 0, y: 0, width: 100, height: 50 } }));
const jpeg = imgInfo(await $P.screenshot({ type: "jpeg", quality: 50 }));
return { image: !!plain.width, fullTaller: full.height > plain.height, clipRatio: clip.width / clip.height, jpeg: jpeg.format, _plain: plain };`,
    chatgpt: `const plain = imgInfo(await t.screenshot({}));
const full = imgInfo(await t.screenshot({ fullPage: true }));
const clip = imgInfo(await t.screenshot({ clip: { x: 0, y: 0, width: 100, height: 50 } }));
const jpeg = await E(async () => imgInfo(await t.screenshot({ format: "jpeg", quality: 50 })).format);
return { image: !!plain.width, fullTaller: full.height > plain.height, clipRatio: clip.width / clip.height, jpeg: jpeg.value ?? jpeg, _plain: plain };`,
    expect: { image: true, fullTaller: true, clipRatio: 2, jpeg: "jpeg" },
  },
  {
    id: "page.screenshot.errors",
    members: ["aside:Page.screenshot", "chatgpt:Tab.screenshot"],
    path: LAB,
    code: `return { clip: await E(() => $P.screenshot({ clip: { x: 0, y: 0, width: "x", height: 1 } })), type: await E(() => $P.screenshot({ type: "gif" })) };`,
    chatgpt: `return { clip: await E(() => t.screenshot({ clip: { x: 0, y: 0, width: "x", height: 1 } })), type: await E(() => t.screenshot({ format: "gif" })) };`,
    better: { aside: errBetter, chatgpt: errBetter },
    expect: { clip: { error: "invalid-arg" }, type: { error: "invalid-arg" } },
  },
  {
    id: "page.pdf",
    members: ["aside:Page.pdf"],
    path: LAB,
    code: `const pdf = await $P.pdf();
const a4 = await $P.pdf({ format: "A4", landscape: true, printBackground: true });
return { pdf: String.fromCharCode(...pdf.slice(0, 5)), a4: String.fromCharCode(...a4.slice(0, 5)), bigger: pdf.length > 500 };`,
    chatgpt: null,
    na: { chatgpt: "ChatGPT for Chrome has no PDF printing" },
    expect: { pdf: "%PDF-", a4: "%PDF-", bigger: true },
  },
  {
    id: "page.wait-for-selector",
    members: ["aside:Page.waitForSelector", "chatgpt:PlaywrightLocator.waitFor"],
    path: LAB,
    code: `await $P.locator("#make-late").click();
const late = await ms(() => $P.waitForSelector("#late"));
return {
  late: late.error ? late : "found",
  hidden: (await E(() => $P.waitForSelector("#hidden", { state: "hidden" }))).ok ?? false,
  attached: (await E(() => $P.waitForSelector("#hidden", { state: "attached" }))).ok ?? false,
  detached: (await E(() => $P.waitForSelector("#missing", { state: "detached" }))).ok ?? false,
  timeout: await ms(() => $P.waitForSelector("#missing", $T(400))),
};`,
    chatgpt: `await $P.locator("#make-late").click();
const late = await ms(() => $P.locator("#late").waitFor({ state: "visible" }));
return {
  late: late.error ? late : "found",
  hidden: (await E(() => $P.locator("#hidden").waitFor({ state: "hidden" }))).ok ?? false,
  attached: (await E(() => $P.locator("#hidden").waitFor({ state: "attached" }))).ok ?? false,
  detached: (await E(() => $P.locator("#missing").waitFor({ state: "detached" }))).ok ?? false,
  timeout: await ms(() => $P.locator("#missing").waitFor({ state: "visible", timeoutMs: 400 })),
};`,
    expect: { late: "found", hidden: true, attached: true, detached: true, timeout: { error: "no-element" } },
  },
  {
    id: "page.wait-for-load-state",
    members: ["aside:Page.waitForLoadState", "chatgpt:PlaywrightAPI.waitForLoadState"],
    path: LAB,
    code: `const out = {};
for (const s of ["domcontentloaded", "load", "networkidle"]) out[s] = (await E(() => $P.waitForLoadState(s, $T(5000)))).ok ?? false;
out.bogus = await E(() => $P.waitForLoadState("bogus"));
return out;`,
    chatgpt: `const out = {};
for (const s of ["domcontentloaded", "load", "networkidle"]) out[s] = (await E(() => $P.waitForLoadState({ state: s, timeoutMs: 5000 }))).ok ?? false;
out.bogus = await E(() => $P.waitForLoadState({ state: "bogus" }));
return out;`,
    better: { aside: errBetter, chatgpt: errBetter },
    expect: { domcontentloaded: true, load: true, networkidle: true, bogus: { error: "invalid-arg" } },
  },
  {
    id: "page.wait-for-url",
    members: ["aside:Page.waitForURL", "chatgpt:PlaywrightAPI.waitForURL"],
    path: LAB,
    code: `await $P.locator("#next").click();
const exact = await E(() => $P.waitForURL(U("/diff/next.html")));
const glob = await E(() => $P.waitForURL("**/next.html"));
const regex = await E(() => $P.waitForURL(/next\\.html$/));
const fn = await E(() => $P.waitForURL((u) => String(u).endsWith("next.html")));
const opts = await E(() => $P.waitForURL(U("/diff/next.html"), { waitUntil: "domcontentloaded", $TO: 5000 }));
return { exact: !!exact.ok, glob: !!glob.ok, regex: !!regex.ok, fn: !!fn.ok, opts: !!opts.ok, never: await ms(() => $P.waitForURL(U("/never"), $T(400))) };`,
    chatgpt: `await $P.locator("#next").click();
const exact = await E(() => $P.waitForURL(U("/diff/next.html"), {}));
const glob = await E(() => $P.waitForURL("**/next.html", {}));
const regex = await E(() => $P.waitForURL(/next\\.html$/, {}));
const fn = await E(() => $P.waitForURL((u) => String(u).endsWith("next.html"), {}));
const opts = await E(() => $P.waitForURL(U("/diff/next.html"), { waitUntil: "domcontentloaded", timeoutMs: 5000 }));
return { exact: !!exact.ok, glob: !!glob.ok, regex: !!regex.ok, fn: !!fn.ok, opts: !!opts.ok, never: await ms(() => $P.waitForURL(U("/never"), { timeoutMs: 400 })) };`,
    better: {
      chatgpt: {
        reason: "waitForURL accepts Playwright's glob, RegExp and predicate matchers; ChatGPT accepts only a string",
        check: (c, r) => c.exact && c.glob && c.regex && c.fn && c.opts && (!r.glob || !r.regex || !r.fn),
      },
    },
    expect: { exact: true, glob: true, regex: true, fn: true, opts: true, never: { error: "timeout", ms: "instant" } },
  },
  {
    id: "page.wait-for-timeout",
    members: ["chatgpt:PlaywrightAPI.waitForTimeout", "aside:sleep"],
    path: LAB,
    code: `const w1 = await ms(() => $P.waitForTimeout(300));
const w2 = await ms(() => sleep(300));
return { waited: w1.ms >= 280 && w1.ms < 1500, slept: w2.ms >= 280 && w2.ms < 1500, bad: await E(() => $P.waitForTimeout("soon")) };`,
    aside: `const w2 = await ms(() => sleep(300));
return { slept: w2.ms >= 280 && w2.ms < 1500 };`,
    chatgpt: `const w1 = await ms(() => $P.waitForTimeout(300));
const w2 = await ms(() => pause(300));
return { waited: w1.ms >= 280 && w1.ms < 1500, slept: w2.ms >= 280 && w2.ms < 1500, bad: await E(() => $P.waitForTimeout("soon")) };`,
    compare: { aside: ["slept"], chatgpt: ["waited", "slept", "bad"] },
    expect: { waited: true, slept: true, bad: { error: "invalid-arg" } },
  },
  {
    id: "page.wait-for-event.popup-console",
    members: ["aside:Page.waitForEvent"],
    path: LAB,
    code: `const popup = E(async () => { const w = $P.waitForEvent("popup", $T(5000)); await $P.locator("#popup-link").click(); const p = await w; await p.waitForLoadState(); const title = await p.title(); await p.close(); return title; });
const pop = await popup;
const con = await E(async () => { const w = $P.waitForEvent("console", $T(5000)); await $P.locator("#log-btn").click(); const m = await w; return [m.type(), m.text()]; });
return { popup: pop.value ?? pop, console: con.value ?? con };`,
    chatgpt: null,
    na: { chatgpt: "playwright.waitForEvent supports only 'download' and 'filechooser' (ported error in page.wait-for-event.errors)" },
    better: {
      aside: {
        reason: "popup and console page events fire in cmux; Aside's waitForEvent times out on both",
        check: (c, r) => c.popup === "Next page" && Array.isArray(c.console) && (typeof r.popup !== "string" || !Array.isArray(r.console)),
      },
    },
    expect: { popup: "Next page", console: ["log", "lab log 42"] },
  },
  {
    id: "page.wait-for-event.errors",
    members: ["chatgpt:PlaywrightAPI.waitForEvent", "chatgpt:PlaywrightAPI.waitForEvent#2", "aside:Page.waitForEvent"],
    path: LAB,
    code: `return { bad: await E(() => $P.waitForEvent("bad-event", $T(200))), none: await ms(() => $P.waitForEvent("filechooser", $T(300))) };`,
    better: {
      chatgpt: {
        reason: "cmux waits for any Playwright page event (popup, console, dialog, request, ...); ChatGPT only for download and filechooser",
        check: (c, r, h) => h.classifyError(c.none.error) === "timeout",
      },
      aside: errBetter,
    },
    expect: { none: { error: "timeout", ms: "instant" } },
  },
  {
    id: "page.on-off",
    members: ["aside:Page.on", "aside:Page.off", "chatgpt:TabDevAPI.logs", "chatgpt:Tab.dev"],
    path: LAB,
    code: `const seen = [];
const h = (m) => seen.push(m.type() + ":" + m.text());
$P.on("console", h);
await $P.locator("#log-btn").click();
await sleep(200);
$P.off("console", h);
await $P.locator("#log-btn").click();
await sleep(200);
return { seen };`,
    chatgpt: `await $P.locator("#log-btn").click();
await $P.waitForTimeout(200);
const logs = await t.dev.logs({});
return { seen: logs.filter((x) => /^lab/.test(x.message)).map((x) => (x.level === "warn" ? "warning" : x.level) + ":" + x.message) };`,
    better: {
      chatgpt: {
        reason: "cmux delivers every console message; ChatGPT's Chrome backend returns an empty tab.dev.logs() for the same page",
        check: (c, r) => c.seen.length === 3 && r.seen.length < 3,
      },
    },
    expect: { seen: ["log:lab log 42", "warning:lab warn", "error:lab error"] },
  },
  {
    id: "page.viewport",
    members: ["aside:Page.viewportSize", "chatgpt:Tab.capabilities"],
    path: LAB,
    code: `const v0 = $P.viewportSize();
await $P.setViewportSize({ width: 700, height: 500 });
const inner = await $P.evaluate(() => [innerWidth, innerHeight]);
return { shape: v0 && typeof v0.width === "number" && typeof v0.height === "number", inner, after: $P.viewportSize() };`,
    aside: `const v0 = page.viewportSize();
return { shape: !!v0 && typeof v0.width === "number" && typeof v0.height === "number" };`,
    chatgpt: `const list = await E(() => t.capabilities.list());
const set = await E(async () => { const vp = await t.capabilities.get("viewport"); await vp.set({ width: 700, height: 500 }); const inner = await $P.evaluate(() => [innerWidth, innerHeight]); await vp.reset?.(); return inner; });
return { shape: !!list.value?.some?.((x) => x.id === "viewport"), inner: set.value ?? set };`,
    compare: { aside: ["shape"], chatgpt: ["shape", "inner"] },
    better: {
      chatgpt: {
        reason: "page.setViewportSize works on every tab; ChatGPT's Chrome backend does not offer the viewport capability",
        check: (c, r) => c.shape && Array.isArray(c.inner) && !Array.isArray(r.inner),
      },
    },
    expect: { shape: true, inner: [700, 500], after: { width: 700, height: 500 } },
  },
  {
    id: "page.bring-to-front",
    members: ["aside:Page.bringToFront", "chatgpt:Tab.requestManualHandoff"],
    path: LAB,
    code: `const r = await E(() => $P.bringToFront());
return { ok: !!r.ok, visible: await $P.evaluate(() => document.visibilityState) };`,
    chatgpt: `const r = await E(() => t.requestManualHandoff());
return { ok: !!r.ok, visible: await $P.evaluate(() => document.visibilityState) };`,
    better: {
      chatgpt: {
        reason: "cmux shows the tab in its pane so the user can take over; ChatGPT's manual handoff exists only for its Cloud Browser and fails on Chrome",
        check: (c, r) => c.ok && !r.ok,
      },
    },
    expect: { ok: true, visible: "visible" },
  },
  {
    id: "page.close",
    members: ["aside:Page.close", "aside:closeTab", "chatgpt:Tab.close"],
    path: null,
    code: `const p = await tabs.open(U("${LAB}"));
const id = p.id;
await p.close();
return { closed: p.isClosed(), listed: (await tabs.list()).some((t) => t.id === id), again: await E(() => p.title()) };`,
    aside: `const p = await openTab(U("${LAB}"));
const id = p.targetId ?? p._targetId ?? null;
await closeTab(p);
return { closed: !tabs.includes(p), listed: tabs.includes(p), again: await E(() => p.title()) };`,
    chatgpt: `await t.goto(U("${LAB}"));
const id = t.id;
await t.close();
return { closed: true, listed: (await b.tabs.list()).some((x) => x.id === id), again: await E(() => t.title()) };`,
    compare: ["closed", "listed"],
    expect: { closed: true, listed: false, again: { error: "closed" } },
  },
  {
    id: "page.video",
    members: ["aside:Page.video"],
    path: LAB,
    code: `const v = $P.video();
return { recording: v === null ? false : await v.path().then(() => true, () => false) };`,
    chatgpt: null,
    na: { chatgpt: "ChatGPT for Chrome does not record video" },
    expect: { recording: false },
  },
  {
    id: "page.keyboard-mouse-objects",
    members: ["aside:Page.keyboard", "aside:Page.mouse", "chatgpt:Tab.cua"],
    path: LAB,
    code: `const box = await $P.locator("#canvas").boundingBox();
await $P.mouse.click(box.x + 10, box.y + 10);
await $P.locator("#keys").focus();
await $P.keyboard.type("hi");
return { canvas: $LOG.filter((r) => r[1] === "canvas" && r[0] === "click").length, keys: await $P.locator("#keys").evaluate((e) => e.value) };`,
    chatgpt: `const box = await $P.locator("#canvas").evaluate((e) => { const r = e.getBoundingClientRect(); return { x: r.x, y: r.y }; });
await t.cua.click({ x: box.x + 10, y: box.y + 10 });
await $P.locator("#keys").click();
await t.cua.type({ text: "hi" });
return { canvas: $LOG.filter((r) => r[1] === "canvas" && r[0] === "click").length, keys: await $P.locator("#keys").evaluate((e) => e.value) };`,
    chatgptMode: "legacy",
    expect: { canvas: 1, keys: "hi" },
  },
];
