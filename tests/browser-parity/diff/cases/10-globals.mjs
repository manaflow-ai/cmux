import { errorsBetter as errBetter } from "../lib.mjs";
// REPL globals and tab management: reference A globals (page, tabs, openTab,
// snapshot, fetch, fs, ...) and reference B's browser, tabs, user and snapshot
// (AXAPI) members.
const LAB = "/diff/lab.html";
const REF_CMUX = (label, role = "button") => `((s) => (s.match(new RegExp('${role} "${label}"[^\\\\n]*?\\\\[ref=(\\\\w+)\\\\]')) || [])[1])`;
const IDX_CG = (label, role = "button") => `((s) => { const m = s.match(new RegExp("^\\\\s*(\\\\d+) ${role} ${label}", "m")); return m ? Number(m[1]) : null; })`;

export default [
  {
    id: "tabs.open-current",
    members: ["reference-a:openTab", "reference-a:page", "reference-b:Tabs.new", "reference-b:Tabs.selected", "reference-b:Browser.tabs", "reference-b:Agent.browsers", "reference-b:Browsers.getDefault"],
    path: null,
    code: `const p = await tabs.open(U("${LAB}"));
return { same: page === p || page.id === p.id, url: page.url(), title: await page.title() };`,
    "reference-a": `const p = await openTab(U("${LAB}"));
return { same: page === p, url: page.url(), title: await page.title() };`,
    "reference-b": `const br = await agent.browsers.getDefault();
const nt = await br.tabs.new();
await nt.goto(U("${LAB}"));
const sel = await br.tabs.selected();
return { same: !!sel && sel.id === nt.id, url: await nt.url(), title: await nt.title() };`,
    expect: { same: true, url: "<primary>/diff/lab.html", title: "Diff lab" },
  },
  {
    id: "tabs.list-get",
    members: ["reference-a:tabs", "reference-a:listBrowserTabs", "reference-a:getTabByTargetId", "reference-b:Tabs.list", "reference-b:Tabs.get", "reference-b:Tab.id", "reference-b:BrowserUser.openTabs", "reference-b:Browser.user"],
    path: null,
    code: `const a = await tabs.open(U("${LAB}"));
const b2 = await tabs.open(U("/diff/next.html"));
const mine = (await tabs.list()).filter((x) => x.url.startsWith(ORIGINS.primary));
const got = await tabs.get(a.id);
return { count: mine.length, keys: Object.keys(mine[0]).sort(), titles: mine.map((x) => x.title).sort(), getTitle: await got.title(), active: mine.filter((x) => x.active).length, missing: await E(() => tabs.get("nope")) };`,
    "reference-a": `const a = await openTab(U("${LAB}"));
const b2 = await openTab(U("/diff/next.html"));
const mine = (await listBrowserTabs()).filter((x) => x.url.startsWith(ORIGINS.primary));
const id = mine.find((x) => x.url.endsWith("lab.html")).targetId;
const got = await getTabByTargetId(id);
return { count: mine.length, sessionTabs: tabs.length, keys: Object.keys(mine[0]).sort(), titles: mine.map((x) => x.title).sort(), getTitle: await got.title(), active: mine.filter((x) => x.active).length, missing: await E(() => getTabByTargetId("nope")) };`,
    "reference-b": `await t.goto(U("${LAB}"));
const t2 = await b.tabs.new();
await t2.goto(U("/diff/next.html"));
const mine = (await b.tabs.list()).filter((x) => String(x.url).startsWith(ORIGINS.primary));
const got = await b.tabs.get(t.id);
const user = (await b.user.openTabs()).filter((x) => String(x.url).startsWith(ORIGINS.primary));
return { count: mine.length, keys: Object.keys(mine[0]).sort(), titles: mine.map((x) => x.title).sort(), getTitle: await got.title(), userRows: user.length, missing: await E(() => b.tabs.get("nope")) };`,
    compare: ["count", "titles", "getTitle", "missing"],
    better: {
      "reference-b": errBetter,
      "reference-a": errBetter,
    },
    expect: { count: 2, titles: ["Diff lab", "Next page"], getTitle: "Diff lab", active: 1, missing: { error: "closed" } },
  },
  {
    id: "tabs.attach",
    members: ["reference-a:attachBrowserTab", "reference-a:attachActiveBrowserTab", "reference-b:BrowserUser.claimTab", "reference-b:BrowserUser.getTabContext"],
    path: null,
    code: `const a = await tabs.open(U("${LAB}"));
const other = await tabs.open(U("/diff/next.html"), { background: true });
const byId = await tabs.use(other.id);
const afterId = page.url();
const active = (await tabs.list()).find((x) => x.active);
const activeIsOurs = !!active && active.url.startsWith(ORIGINS.primary);
if (activeIsOurs) await tabs.use(active.id);
const ctx = await snapshot(await tabs.get(a.id));
return { afterId, activeIsOurs, activeUrl: activeIsOurs ? page.url() : null, context: String(ctx).includes("Action"), bad: await E(() => tabs.use("nope")) };`,
    "reference-a": `const a = await openTab(U("${LAB}"));
const b2 = await openTab(U("/diff/next.html"));
const row = (await listBrowserTabs()).find((x) => x.url === U("/diff/next.html"));
await attachBrowserTab(row.targetId);
const afterId = page.url();
const act = (await listBrowserTabs()).find((x) => x.active);
const activeIsOurs = !!act && act.url.startsWith(ORIGINS.primary);
if (activeIsOurs) await attachActiveBrowserTab();
return { afterId, activeIsOurs, activeUrl: activeIsOurs ? page.url() : null, context: String((await snapshot(a)).tree).includes("Action"), bad: await E(() => attachBrowserTab("nope")) };`,
    "reference-b": `await t.goto(U("/diff/next.html"));
const row = (await b.user.openTabs()).find((x) => x.id === t.id);
const byId = await E(async () => (await b.user.claimTab(row.id)).id === t.id);
const byRow = await E(async () => (await b.user.claimTab(row)).id === t.id);
const ctx = await E(() => b.user.getTabContext(row.id));
return { afterId: await t.url(), byId: byId.value ?? byId, byRow: byRow.value ?? byRow, context: ctx.error ? ctx : String(JSON.stringify(ctx.value)).includes("Next"), bad: await E(() => b.user.claimTab("nope")) };`,
    // Which tab is active in the user's reference A browser is not ours to set, so
    // the attach-active branch is not compared.
    compare: { "reference-a": ["afterId", "context", "bad"], "reference-b": ["afterId", "bad"] },
    better: {
      "reference-a": errBetter,
      "reference-b": {
        reason: "tabs.get(id) plus snapshot() reads a tab without switching to it; reference B's Chrome backend has no getTabContext",
        check: (c, r) => c.context === true && typeof r.context === "object",
      },
    },
    expect: { afterId: "<primary>/diff/next.html", context: true, bad: { error: "closed" } },
  },
  {
    id: "tabs.open-errors",
    members: ["reference-a:openTab", "reference-b:Tabs.new", "reference-b:Browsers.get", "reference-b:Browsers.getForUrl", "reference-b:Browsers.list", "reference-b:Browser.browserId"],
    path: null,
    code: `return { bad: await E(() => tabs.open("not a url")), session: typeof session.id };`,
    "reference-a": `return { bad: await E(() => openTab("not a url")), session: "string" };`,
    "reference-b": `const list = await agent.browsers.list();
const chrome = await agent.browsers.get("chrome");
const forUrl = await E(() => agent.browsers.getForUrl("not a url"));
return { bad: await E(() => agent.browsers.get("")), session: typeof chrome.browserId, listed: list.some((x) => x.id === chrome.browserId || x.type === "extension"), forUrl };`,
    compare: ["bad", "session"],
    better: {
      "reference-a": errBetter,
      "reference-b": {
        reason: "an invalid URL is rejected as such; reference B's browser lookup errors are unrelated to the URL",
        check: (c, r, h) => h.classifyError(c.bad.error) === "invalid-arg" && c.session === r.session,
      },
    },
    expect: { bad: { error: "invalid-arg" }, session: "string" },
  },
  {
    id: "session.name-docs",
    members: ["reference-b:Browser.nameSession", "reference-b:Browser.documentation", "reference-b:Agent.documentation", "reference-b:Documentation.get"],
    path: LAB,
    code: `const named = await session.name("🧪 cmux parity");
const guide = session.guide();
return { named: typeof named, docs: typeof guide === "string" && guide.length > 1000, empty: await E(() => session.name(" ")) };`,
    "reference-b": `const named = await b.nameSession("🧪 cmux parity");
const docs = await b.documentation();
const topic = await E(() => agent.documentation.get("screenshots"));
const missing = await E(() => agent.documentation.get("nope-doc"));
return { named: typeof named, docs: typeof docs === "string" && docs.length > 1000, empty: await E(() => b.nameSession(" ")), topic: !!topic.ok, missing };`,
    "reference-a": null,
    na: { "reference-a": "Reference A has no session naming or packaged documentation global (its REPL guide is a CLI command)" },
    compare: ["docs"],
    expect: { docs: true },
  },
  {
    id: "tabs.keep-deliverable",
    members: ["reference-b:Tab.markDeliverable", "reference-b:Tab.markHandoff"],
    custom: {
      async cmux(ctx) {
        const code = `${ctx.wrap({ path: null, code: `const p = await tabs.open(U("/diff/lab.html")); await p.keep(); return p.id;` })}`;
        const r = await ctx.repl(code);
        const id = r.value;
        const after = await ctx.repl(ctx.wrap({ path: null, code: `const l = await tabs.list(); const hit = l.find((x) => x.id === ${JSON.stringify(id)}); if (hit) { const p = await tabs.use(hit.id); await p.close(); } return !!hit;` }));
        return { kept: after.value === true };
      },
      async "reference-b"({ c, origins }) {
        await c.js(`var __k=await rb.tabs.new(); await __k.goto(${JSON.stringify(origins.primary + "/diff/lab.html")}); var __kd=await __k.markDeliverable().then(()=>"ok",(e)=>String(e)); var __kh=await __k.markHandoff().then(()=>"ok",(e)=>String(e));`);
        const v = await c.value(`(async()=>({ deliverable: __kd, handoff: __kh, listed: (await rb.tabs.list()).some((x)=>x.id===__k.id) }))()`);
        return { kept: v.deliverable === "ok" && v.listed, _raw: v };
      },
    },
    scope: { "reference-a": "Reference A's one-shot REPL has no keep/deliverable marker; tabs outlive the call unless closed" },
    expect: { kept: true },
  },
  {
    id: "snapshot.full",
    members: ["reference-a:snapshot", "reference-a:snapshot.ref", "reference-b:AXAPI.get", "reference-b:Tab.ax", "reference-b:AXAPI.click"],
    path: LAB,
    code: `const s = String((await snapshot()).tree);
const ref = ${REF_CMUX("Action")}(s);
await page.locator(ref).click();
return { heading: s.includes("Diff lab"), frame: s.includes("Frame action"), shadow: s.includes("Shadow action"), offscreen: s.includes("Far away"), typed: s.includes("initial"), clicked: await page.locator("#status").innerText() };`,
    "reference-a": `const s = String((await snapshot(page)).tree);
const ref = ${REF_CMUX("Action")}(s);
await page.locator(ref).click();
return { heading: s.includes("Diff lab"), frame: s.includes("Frame action"), shadow: s.includes("Shadow action"), offscreen: s.includes("Far away"), typed: s.includes("initial"), clicked: await page.locator("#status").innerText() };`,
    "reference-b": `const s = await t.ax.get("state", { disableDiffing: true });
const idx = ${IDX_CG("Action")}(s);
await t.ax.click(idx);
return { heading: s.includes("Diff lab"), frame: s.includes("Frame action"), shadow: s.includes("Shadow action"), offscreen: s.includes("Far away"), typed: s.includes("initial"), clicked: await $P.locator("#status").innerText() };`,
    expect: { heading: true, frame: true, shadow: true, offscreen: true, typed: true, clicked: "clicked" },
  },
  {
    id: "snapshot.interactive",
    members: ["reference-a:snapshot.interactive", "reference-b:DomCUAAPI.get_visible_dom"],
    path: LAB,
    code: `const full = String((await snapshot()).tree);
const s = String((await snapshot({ interactive: true })).tree);
return { button: s.includes("Action"), listText: s.includes("Second"), smaller: s.length < full.length };`,
    "reference-a": `const full = String((await snapshot(page)).tree);
const s = String((await snapshot(page, { interactive: true })).tree);
return { button: s.includes("Action"), listText: s.includes("Second"), smaller: s.length < full.length };`,
    "reference-b": `const full = JSON.stringify(await t.dom_cua.get_visible_dom());
const s = full;
return { button: s.includes("Action"), listText: s.includes("Second"), smaller: true };`,
    referenceBMode: "legacy",
    // Reference A's interactive tree keeps list text; cmux keeps controls and the
    // outline. Both keep the controls and shrink the tree.
    compare: { "reference-a": ["button", "smaller"], "reference-b": ["button"] },
    expect: { button: true, listText: false, smaller: true },
  },
  {
    id: "snapshot.show-hidden",
    members: ["reference-a:snapshot.showHidden"],
    path: LAB,
    code: `const plain = String((await snapshot()).tree);
const all = String((await snapshot({ showHidden: true })).tree);
return { plain: plain.includes('"Hidden"'), all: all.includes('"Hidden"') };`,
    "reference-a": `const plain = String((await snapshot(page)).tree);
const all = String((await snapshot(page, { showHidden: true })).tree);
return { plain: plain.includes('"Hidden"'), all: all.includes('"Hidden"') };`,
    "reference-b": null,
    na: { "reference-b": "AXStateOptions has no hidden-element option" },
    expect: { plain: false, all: true },
  },
  {
    id: "snapshot.scoped",
    members: ["reference-a:snapshot.ref", "reference-a:snapshot.selector"],
    path: LAB,
    code: `const s = String((await snapshot()).tree);
const frameRef = (s.match(/iframe[^\\n]*\\[ref=(\\w+)\\]/) || [])[1];
const byRef = String((await snapshot(frameRef)).tree);
const bySel = String((await snapshot(page.locator("#items"))).tree);
return { refFrame: byRef.includes("Frame action"), refMain: byRef.includes('"Action"'), selItems: bySel.includes("Second"), selMain: bySel.includes('"Action"'), badRef: await E(() => snapshot("e9999")) };`,
    "reference-a": `const s = String((await snapshot(page)).tree);
const frameRef = (s.match(/iframe[^\\n]*\\[ref=(\\w+)\\]/) || [])[1];
const byRef = String((await snapshot(page, { ref: frameRef })).tree);
const bySel = String((await snapshot(page, { selector: "#items" })).tree);
return { refFrame: byRef.includes("Frame action"), refMain: byRef.includes('"Action"'), selItems: bySel.includes("Second"), selMain: bySel.includes('"Action"'), badRef: await E(() => snapshot(page, { ref: "e9999" })) };`,
    "reference-b": null,
    na: { "reference-b": "AXStateOptions cannot scope the state to an element" },
    better: {
      "reference-a": {
        reason: "an unknown ref fails with `ref e9999 does not exist`; reference A returns an empty tree",
        check: (c, r) => c.refFrame && !c.refMain && c.selItems && !c.selMain && !!c.badRef.error && !r.badRef?.error,
      },
    },
    expect: { refFrame: true, refMain: false, selItems: true, selMain: false, badRef: { error: "no-element" } },
  },
  {
    id: "snapshot.diff",
    members: ["reference-a:snapshot.diff", "reference-b:AXAPI.get", "reference-b:AXAPI.write"],
    path: LAB,
    code: `await snapshot();
await page.locator("#counter").click();
const s2 = await snapshot();
return { diffMentions: String(s2.diff).includes("Count 1"), diffShort: String(s2.diff).length < String(s2.tree).length, printed: String(s2).includes("Count 1") };`,
    "reference-a": `await snapshot(page);
await page.locator("#counter").click();
const s2 = await snapshot(page);
return { diffMentions: String(s2.diff).includes("Count 1"), diffShort: String(s2.diff).length < String(s2.tree).length, printed: true };`,
    "reference-b": `await t.ax.get("state", { disableDiffing: true });
await t.ax.get();
await $P.locator("#counter").click();
const d = await t.ax.get();
const w = await E(() => t.ax.write());
return { diffMentions: d.includes("Count 1"), diffShort: d.length < (await t.ax.get("state", { disableDiffing: true })).length, printed: !!w.ok };`,
    expect: { diffMentions: true, diffShort: true, printed: true },
  },
  {
    id: "snapshot.ax-get-modes",
    members: ["reference-b:AXAPI.get#2", "reference-b:AXAPI.get#3", "reference-b:AXAPI.write#2", "reference-b:AXAPI.write#3"],
    path: LAB,
    code: `const shot = await screenshot();
const snap = await snapshot();
display(snap); display(shot);
return { shot: shot.width > 0 && shot.type === "png", state: String(snap.tree).includes("Action"), both: true };`,
    "reference-b": `const shot = await t.ax.get("screenshot");
const both = await t.ax.get("both");
await t.ax.write("screenshot"); await t.ax.write("both");
return { shot: shot instanceof Uint8Array && shot.length > 0, state: String(both.state).includes("Action"), both: both.screenshot instanceof Uint8Array };`,
    "reference-a": null,
    na: { "reference-a": "covered by reference-a:annotatedScreenshot and snapshot cases" },
    expect: { shot: true, state: true, both: true },
  },
  {
    id: "snapshot.ax-errors",
    members: ["reference-b:AXAPI.get", "reference-b:AXAPI.write", "reference-b:AXAPI.click"],
    path: LAB,
    code: `return { click: await E(() => page.locator("e99999").click($T(300))), get: await E(() => snapshot({ interactive: "x" })), unknownRef: await E(() => page.ref("e99999").fill("v", $T(300))) };`,
    "reference-b": `return { click: await E(() => t.ax.click(99999)), get: await E(() => t.ax.get("state", { disableDiffing: "x" })), unknownRef: await E(() => t.ax.setValue(99999, "v")) };`,
    "reference-a": null,
    na: { "reference-a": "ref errors for reference A are covered by snapshot.scoped and edge.stale-ref" },
    better: {
      "reference-b": {
        reason: "an unknown ref fails immediately with `ref e99999 does not exist`",
        check: (c, r, h) => h.classifyError(c.click.error) === "no-element" && h.classifyError(c.unknownRef.error) === "no-element",
      },
    },
    expect: { click: { error: "no-element" }, unknownRef: { error: "no-element" } },
  },
  {
    id: "screenshot.annotated",
    members: ["reference-a:annotatedScreenshot", "reference-b:PlaywrightAPI.elementScreenshot"],
    path: LAB,
    code: `const a = await screenshot({ annotate: true });
const plain = await screenshot();
return { image: a.type === "png" && a.width > 0, differs: a.base64 !== plain.base64 };`,
    "reference-a": `const a = await annotatedScreenshot(page);
const plain = await page.screenshot();
return { image: !!(a && a.base64Image), differs: a.base64Image !== Buffer.from(plain).toString("base64") };`,
    "reference-b": `const r = await E(() => $P.elementScreenshot({ x: 20, y: 20, includeNonInteractable: true }));
return { image: !!r.ok, differs: !!r.ok };`,
    better: {
      "reference-b": {
        reason: "screenshot({ annotate: true }) labels every ref's box; reference B's Chrome backend does not support elementScreenshot",
        check: (c, r) => c.image && c.differs && !r.image,
      },
    },
    expect: { image: true, differs: true },
  },
  {
    id: "element-at",
    members: ["reference-b:PlaywrightAPI.elementInfo"],
    path: LAB,
    code: `const box = await page.locator("#action").boundingBox();
const info = await page.elementAt(box.x + 5, box.y + 5);
return { role: info.role, name: info.name, ref: /^e\\d+$/.test(info.ref) };`,
    "reference-b": `const box = await $P.locator("#action").evaluate((e) => { const r = e.getBoundingClientRect(); return { x: r.x, y: r.y }; });
const r = await E(() => $P.elementInfo({ x: box.x + 5, y: box.y + 5 }));
return r.error ? { role: r } : { role: r.value?.[0]?.role, name: r.value?.[0]?.name, ref: true };`,
    "reference-a": null,
    na: { "reference-a": "Reference A has no element-at-point lookup" },
    better: {
      "reference-b": {
        reason: "page.elementAt(x, y) returns the element's ref, role and name; reference B's Chrome backend does not support elementInfo",
        check: (c, r) => c.role === "button" && typeof r.role === "object",
      },
    },
    expect: { role: "button", name: "Action", ref: true },
  },
  {
    id: "fetch.cookies",
    members: ["reference-a:fetch"],
    path: "/cookies/set",
    code: `const g = await fetch(U("/api/echo?q=1"));
const json = await g.json();
const c = await (await fetch(U("/cookies/echo"))).json();
const post = await fetch(U("/api/echo?q=2"), { method: "POST", body: "x" });
return { status: g.status, ok: g.ok, type: g.headers.get("content-type"), json, cookieNames: c.names.filter((n) => n !== "js_cookie"), post: (await post.json()).method, missing: (await fetch(U("/status/404"))).status };`,
    "reference-b": null,
    na: { "reference-b": "Reference B has no cookie-bearing fetch in the REPL" },
    expect: { status: 200, ok: true, type: "application/json", json: { q: "1", method: "GET" }, cookieNames: ["http_only", "lax", "none_secure", "plain", "secure_flag", "strict"], post: "POST", missing: 404 },
  },
  {
    id: "node.fs-path-buffer",
    members: ["reference-a:fs", "reference-a:path", "reference-a:Buffer", "reference-a:pwd"],
    path: null,
    code: `const dir = path.resolve(".");
const f = path.join(os.tmpdir(), "brepl-diff-fs.txt");
await fs.promises.writeFile(f, "hello fs");
const back = await fs.promises.readFile(f, "utf8");
await fs.promises.rm(f);
return { abs: path.isAbsolute(dir), back, join: path.join("a", "b", "..", "c.txt"), base: path.basename("/x/y.txt", ".txt"), ext: path.extname("a.tar.gz"), b64: Buffer.from("hi").toString("base64"), fromB64: Buffer.from("aGk=", "base64").toString(), missing: await E(() => fs.promises.readFile(path.join(os.tmpdir(), "nope-brepl.txt"))) };`,
    "reference-a": `const dir = pwd;
const f = path.join(dir, "brepl-diff-fs.txt");
await fs.writeFile(f, "hello fs");
const back = await fs.readFile(f, "utf8");
await fs.rm(f);
return { abs: path.isAbsolute(dir), back, join: path.join("a", "b", "..", "c.txt"), base: path.basename("/x/y.txt", ".txt"), ext: path.extname("a.tar.gz"), b64: Buffer.from("hi").toString("base64"), fromB64: Buffer.from("aGk=", "base64").toString(), missing: await E(() => fs.readFile(path.join(dir, "nope-brepl.txt"))) };`,
    "reference-b": null,
    na: { "reference-b": "the reference B REPL's node modules are outside its browser API" },
    expect: { abs: true, back: "hello fs", join: "a/c.txt", base: "y", ext: ".gz", b64: "aGk=", fromB64: "hi", missing: { error: "no-element" } },
  },
  {
    id: "print.display-console",
    members: ["reference-a:display", "reference-a:console"],
    custom: {
      async cmux(ctx) {
        const r = await ctx.cli(["browser", "repl", "--eval", "-"], "console.log('plain', 1); display({ a: 1 }); ({ last: true })");
        return { log: r.out.includes("plain 1"), display: /\{ a: 1 \}/.test(r.out), autoPrint: /last: true/.test(r.out) };
      },
      async "cmux-dev"(ctx) {
        const out = [];
        const code = "console.log('plain', 1); display({ a: 1 }); ({ last: true })";
        const dev = await import("../../lib/dev-driver.mjs");
        const text = await dev.runDevRepl(code);
        out.push(text);
        return { log: text.includes("plain 1"), display: /\{ a: 1 \}/.test(text), autoPrint: /last: true/.test(text) };
      },
      async "reference-a"() {
        const { exec } = await import("../run.mjs");
        const { referenceACli } = await import("../../lib/references.mjs");
        const r = await exec(referenceACli(), ["repl", "console.log('plain', 1); display({ a: 1 }); ({ last: true })"]);
        return { log: r.out.includes("plain 1"), display: /a:?\s*1|"a":\s*1/.test(r.out), autoPrint: /last/.test(r.out) };
      },
    },
    na: { "reference-b": "covered by snapshot.diff and snapshot.ax-get-modes (AXAPI.write)" },
    better: {
      "reference-a": {
        reason: "the REPL prints the last expression's value; reference A prints only what console.log writes",
        check: (c, r) => c.log && c.display && c.autoPrint && !r.autoPrint,
      },
    },
    expect: { log: true, display: true, autoPrint: true },
  },
];
