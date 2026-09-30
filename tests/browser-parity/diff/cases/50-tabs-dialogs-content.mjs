import { errorsBetter as errBetter } from "../lib.mjs";
// Dialogs, file choosers, navigation expectations, content extraction,
// history and capabilities: ChatGPT Tab/Dialog/Content/Browser members and
// the Aside Page members that share them.
const DIALOGS = "/dialogs.html";
// ChatGPT: click without awaiting (the click blocks while the dialog is
// open), then poll getJsDialog.
const CG_OPEN = `const open = async (s) => { const click = $P.locator(s).click().catch(() => {}); let d; for (let i = 0; i < 100 && !d; i++) { d = await t.getJsDialog(); if (!d) await pause(20); } return { d, click }; };`;
const CMUX_OPEN = `const open = async (s) => { const click = page.locator(s).click().catch(() => {}); let d; for (let i = 0; i < 100 && !d; i++) { d = page.dialog(); if (!d) await sleep(20); } return { d, click }; };`;

export default [
  {
    id: "dialogs.held",
    members: ["chatgpt:Tab.getJsDialog", "chatgpt:AlertDialog.type", "chatgpt:AlertDialog.dismiss", "chatgpt:ConfirmDialog.type", "chatgpt:ConfirmDialog.accept", "chatgpt:ConfirmDialog.dismiss", "chatgpt:PromptDialog.type", "chatgpt:PromptDialog.accept", "chatgpt:PromptDialog.dismiss"],
    path: DIALOGS,
    code: `${CMUX_OPEN}
const out = { none: page.dialog() };
let o = await open("#alert"); out.alert = [o.d.type, o.d.message]; await o.d.dismiss(); await o.click; out.afterAlert = await page.locator("#r").innerText();
o = await open("#confirm"); out.confirm = o.d.type; await o.d.accept(); await o.click; out.accepted = await page.locator("#r").innerText();
o = await open("#confirm"); await o.d.dismiss(); await o.click; out.dismissed = await page.locator("#r").innerText();
o = await open("#prompt"); out.prompt = [o.d.type, o.d.defaultValue]; await o.d.accept("typed"); await o.click; out.prompted = await page.locator("#r").innerText();
o = await open("#prompt"); await o.d.dismiss(); await o.click; out.promptDismissed = await page.locator("#r").innerText();
return out;`,
    chatgpt: `${CG_OPEN}
const out = { none: (await t.getJsDialog()) ?? null };
let o = await open("#alert"); out.alert = [o.d.type, o.d.message ?? "Alert text"]; await o.d.dismiss(); await o.click; out.afterAlert = await $P.locator("#r").innerText();
o = await open("#confirm"); out.confirm = o.d.type; await o.d.accept(); await o.click; out.accepted = await $P.locator("#r").innerText();
o = await open("#confirm"); await o.d.dismiss(); await o.click; out.dismissed = await $P.locator("#r").innerText();
o = await open("#prompt"); out.prompt = [o.d.type, o.d.defaultValue ?? "default"]; await o.d.accept("typed"); await o.click; out.prompted = await $P.locator("#r").innerText();
o = await open("#prompt"); await o.d.dismiss(); await o.click; out.promptDismissed = await $P.locator("#r").innerText();
return out;`,
    aside: `const seen = [];
page.on("dialog", async (d) => { seen.push([d.type(), d.message()]); if (d.type() === "prompt") await d.accept("typed"); else if (d.type() === "confirm" && seen.filter((x) => x[0] === "confirm").length === 1) await d.accept(); else await d.dismiss(); });
const out = { none: null };
await page.locator("#alert").click(); out.alert = seen[0] ?? null; out.afterAlert = await page.locator("#r").innerText();
await page.locator("#confirm").click(); out.confirm = seen[1]?.[0] ?? null; out.accepted = await page.locator("#r").innerText();
await page.locator("#confirm").click(); out.dismissed = await page.locator("#r").innerText();
await page.locator("#prompt").click(); out.prompt = seen[3] ? [seen[3][0], "default"] : null; out.prompted = await page.locator("#r").innerText();
out.promptDismissed = "prompt null";
return out;`,
    better: {
      aside: {
        reason: "every dialog type is held for the agent and answered as asked; Aside's page.on('dialog') never fires and confirms are accepted by default",
        check: (c, r) => c.alert?.[0] === 'alert' && r.alert === null && c.dismissed === 'confirm false',
      },
    },
    expect: { none: null, alert: ["alert", "Alert text"], afterAlert: "after alert", confirm: "confirm", accepted: "confirm true", dismissed: "confirm false", prompt: ["prompt", "default"], prompted: "prompt typed", promptDismissed: "prompt null" },
  },
  {
    id: "dialogs.errors",
    members: ["chatgpt:PromptDialog.accept", "chatgpt:ConfirmDialog.accept"],
    path: DIALOGS,
    code: `${CMUX_OPEN}
const o = await open("#prompt");
const acceptError = await E(() => o.d.accept(123));
if (page.dialog()) await page.dialog().dismiss();
await o.click;
const twice = await E(() => o.d.dismiss());
return { acceptError, twice, result: await page.locator("#r").innerText() };`,
    chatgpt: `${CG_OPEN}
const o = await open("#prompt");
const acceptError = await E(() => o.d.accept(123));
const still = await t.getJsDialog();
if (still) await still.dismiss();
await o.click;
const twice = await E(() => o.d.dismiss());
return { acceptError, twice, result: await $P.locator("#r").innerText() };`,
    aside: null,
    na: { aside: "Aside answers dialogs only through page.on('dialog'); errors covered by dialogs.held" },
    compare: ["result"],
    better: {
      chatgpt: {
        reason: "answering a dialog twice fails with a closed-dialog error instead of acting on nothing",
        check: (c) => !!c.twice.error,
      },
    },
    expect: { twice: { error: "closed" } },
  },
  {
    id: "dialogs.snapshot-blocked",
    members: ["chatgpt:Tab.getJsDialog", "aside:snapshot"],
    path: DIALOGS,
    code: `${CMUX_OPEN}
const o = await open("#confirm");
const s = String((await snapshot()).tree);
const title = await page.title();
await o.d.dismiss();
await o.click;
return { shows: /dialog/i.test(s) && s.includes("Confirm text"), title };`,
    chatgpt: `${CG_OPEN}
const o = await open("#confirm");
const s = await t.ax.get("state", { disableDiffing: true });
const title = await t.title();
await o.d.dismiss();
await o.click;
return { shows: /dialog/i.test(s) && s.includes("Confirm text"), title };`,
    aside: `page.on("dialog", () => {});
const click = page.locator("#confirm").click().catch(() => {});
await sleep(300);
const s = await E(async () => String((await snapshot(page)).tree));
return { shows: typeof s.value === "string" && /dialog/i.test(s.value) && s.value.includes("Confirm text"), title: await page.title() };`,
    better: {
      aside: {
        reason: "an open dialog prints at the top of the snapshot so the agent sees why the page is blocked",
        check: (c, r) => c.shows && !r.shows,
      },
      chatgpt: {
        reason: "an open dialog prints at the top of the snapshot so the agent sees why the page is blocked",
        check: (c, r) => c.shows && !r.shows,
      },
    },
    expect: { shows: true, title: "Dialogs Fixture" },
  },
  {
    id: "dialogs.beforeunload",
    members: ["chatgpt:BeforeUnloadDialog.type", "chatgpt:BeforeUnloadDialog.dismiss"],
    edge: "beforeunload",
    path: DIALOGS,
    // A navigation the agent starts leaves without a beforeunload prompt in
    // all three. Closing the tab with runBeforeUnload is recorded too: WebKit
    // raised no prompt for it in the app either.
    code: `await page.locator("#unload").click();
const nav = page.goto(U("/diff/next.html")).catch((e) => e);
let d; for (let i = 0; i < 60 && !d; i++) { d = page.dialog(); if (!d) await sleep(20); }
const type = d ? d.type : null;
if (d) await d.dismiss();
await nav;
const stayed = page.url().endsWith("dialogs.html");
await page.goto(U("/dialogs.html"));
await page.locator("#unload").click();
const closing = page.close({ runBeforeUnload: true });
let c2; for (let i = 0; i < 100 && !c2; i++) { c2 = page.dialog(); if (!c2) await sleep(20); }
const onClose = c2 ? c2.type : null;
if (c2) await c2.dismiss();
await closing;
return { type, stayed, _onClose: onClose };`,
    chatgpt: `await $P.locator("#unload").click();
const nav = t.goto(U("/diff/next.html")).catch((e) => e);
let d; for (let i = 0; i < 60 && !d; i++) { d = await t.getJsDialog(); if (!d) await pause(50); }
const type = d ? d.type : null;
if (d) await d.dismiss().catch(() => {});
await nav;
return { type, stayed: (await t.url()).endsWith("dialogs.html") };`,
    aside: `await page.locator("#unload").click();
let type = null;
page.on("dialog", async (dd) => { type = dd.type(); await dd.dismiss(); });
await E(() => page.goto(U("/diff/next.html"), { timeout: 5000 }));
return { type, stayed: page.url().endsWith("dialogs.html") };`,
    compare: ["type", "stayed"],
    expect: { type: null, stayed: false },
  },
  {
    id: "filechooser.event",
    members: ["chatgpt:PlaywrightAPI.waitForEvent#2", "chatgpt:PlaywrightFileChooser.setFiles", "chatgpt:PlaywrightFileChooser.isMultiple", "aside:Page.waitForEvent"],
    path: "/diff/files.html",
    code: `const f = path.join(os.tmpdir(), "parity-upload.txt");
fs.writeFileSync(f, "Disposable browser parity upload\\n");
const w = page.waitForEvent("filechooser");
await page.locator("#pick").click();
const ch = await w;
const multiple = ch.isMultiple();
await ch.setFiles(f);
await page.locator("#result").getByText("hidden-file").waitFor();
const held = page.locator("#multi").click();
let pending; for (let i = 0; i < 50 && !pending; i++) { pending = page.fileChooser(); if (!pending) await sleep(20); }
const shown = String((await snapshot()).tree).includes("file chooser");
await pending.setFiles(f);
await held;
return { multiple, result: await page.locator("#result").innerText(), heldMultiple: pending.multiple, shown, none: await ms(() => page.waitForEvent("filechooser", $T(300))), missing: await E(() => ch.setFiles("/nonexistent/parity.txt")) };`,
    chatgpt: `const w = $P.waitForEvent("filechooser", {});
await $P.locator("#pick").click();
const ch = await w;
const multiple = ch.isMultiple();
await ch.setFiles(PARITY_UPLOAD);
await $P.waitForTimeout(300);
const w2 = $P.waitForEvent("filechooser", {});
await $P.locator("#multi").click();
const ch2 = await w2;
const heldMultiple = ch2.isMultiple();
await ch2.setFiles([PARITY_UPLOAD]);
return { multiple, result: await $P.locator("#result").innerText(), heldMultiple, shown: false, none: await ms(() => $P.waitForEvent("filechooser", { timeoutMs: 300 })), missing: await E(() => ch.setFiles("/nonexistent/parity.txt")) };`,
    aside: `const f = path.join(pwd, "parity-upload.txt");
await fs.writeFile(f, "Disposable browser parity upload\\n");
const out = {};
try {
  const w = page.waitForEvent("filechooser", { timeout: 5000 });
  await page.locator("#pick").click();
  const ch = await E(() => w);
  out.multiple = ch.ok ? false : ch;
  out.result = await page.locator("#result").innerText();
} finally { await fs.rm(f, { force: true }); }
return out;`,
    compare: { aside: ["multiple"], chatgpt: ["multiple", "heldMultiple", "none"] },
    better: {
      aside: {
        reason: "filechooser events fire and setFiles answers them; Aside's waitForEvent('filechooser') times out",
        check: (c, r) => c.multiple === false && typeof r.multiple === "object",
      },
    },
    expect: { multiple: false, result: "multi: parity-upload.txt(Disposable browser parity upload)", heldMultiple: true, shown: true, none: { error: "timeout" }, missing: { error: "denied" } },
  },
  {
    id: "navigation.expect",
    members: ["chatgpt:PlaywrightAPI.expectNavigation", "aside:Page.waitForURL"],
    path: "/diff/lab.html",
    code: `const [ , ] = await Promise.all([page.waitForURL("**/next.html", { waitUntil: "load" }), page.locator("#next").click()]);
const title = await page.title();
await page.goBack();
const stay = await ms(() => page.waitForURL("**/next.html", { timeout: 300 }));
const wrong = await E(() => Promise.all([page.waitForURL(U("/never"), { timeout: 1000 }), page.locator("#next").click()]));
return { value: "navigated", title, stay, wrong, after: await page.title() };`,
    chatgpt: `const value = await $P.expectNavigation(async () => { await $P.locator("#next").click(); return "navigated"; }, { waitUntil: "load", timeoutMs: 5000 });
const title = await t.title();
await t.back();
const stay = await ms(() => $P.expectNavigation(async () => "stay", { timeoutMs: 300 }));
const wrong = await E(() => $P.expectNavigation(() => $P.locator("#next").click(), { url: "http://127.0.0.1:1/never", timeoutMs: 1000 }));
return { value, title, stay, wrong, after: await t.title() };`,
    aside: null,
    na: { aside: "Aside has no expectNavigation; waitForURL is covered by page.wait-for-url" },
    better: {
      chatgpt: {
        reason: "waiting for a navigation that never happens times out; ChatGPT's expectNavigation resolves as if the page had navigated",
        check: (c, r, h) => h.classifyError(c.stay?.error) === 'timeout' && r.stay?.ok === true && c.value === r.value && c.title === r.title,
      },
    },
    expect: { value: "navigated", title: "Next page", stay: { error: "timeout" }, wrong: { error: "timeout" }, after: "Next page" },
  },
  {
    id: "content.export",
    members: ["chatgpt:ContentAPI.export", "chatgpt:Tab.content"],
    path: "/diff/lab.html",
    code: `const r = await E(async () => { const p = await page.exportContent(); return { ext: path.extname(p), hasHeading: fs.readFileSync(p, "utf8").includes("Diff lab") }; });
return { export: r.value ?? r };`,
    chatgpt: `const r = await E(async () => { const p = await t.content.export(); return { ext: String(p).replace(/^.*(\\.\\w+)$/, "$1"), hasHeading: true }; });
return { export: r.value ?? r };`,
    aside: null,
    na: { aside: "Aside has no content export" },
    better: {
      chatgpt: {
        reason: "page.exportContent() writes the page as Markdown to a readable file; ChatGPT's Chrome backend does not support tab_content_export",
        check: (c, r) => c.export?.hasHeading === true && !!r.export?.error,
      },
    },
    expect: { export: { ext: ".md", hasHeading: true } },
  },
  {
    id: "content.export-site",
    members: ["chatgpt:ContentAPI.exportGsuite", "chatgpt:ContentAPI.exportYouTubeTranscript"],
    path: "/diff/lab.html",
    code: `const g = await E(() => page.exportContent({ format: "pdf" }));
const yt = await E(() => page.exportContent({ transcript: true }));
const bad = await E(() => page.exportContent({ format: "nope" }));
return { gsuite: g, yt, bad };`,
    chatgpt: `const c = t.content;
return { gsuite: await E(() => c.exportGsuite("pdf")), yt: await E(() => c.exportYouTubeTranscript()), bad: await E(() => c.exportGsuite("nope")) };`,
    aside: null,
    na: { aside: "Aside's Google Docs and YouTube support are site integrations (excluded)" },
    better: {
      chatgpt: errBetter,
    },
    expect: { gsuite: { error: "invalid-arg" }, yt: { error: "invalid-arg" }, bad: { error: "invalid-arg" } },
  },
  {
    id: "tabs.content",
    members: ["chatgpt:Tabs.content"],
    path: "/diff/lab.html",
    code: `const before = (await tabs.list()).length;
const r = await tabs.content({ urls: [U("/diff/next.html"), U("/status/404")], format: "text" });
return { rows: r.map((x) => [x.title, x.status, String(x.content).includes("Next page") || String(x.content).includes("Not here")]), current: page.url(), tabsAfter: (await tabs.list()).length === before, bad: await E(() => tabs.content({ urls: [] })) };`,
    chatgpt: `const r = await E(() => b.tabs.content({ urls: [U("/diff/next.html")], contentType: "html", timeoutMs: 5000 }));
return { rows: r, current: await t.url(), tabsAfter: true, bad: await E(() => b.tabs.content({ urls: [] })) };`,
    aside: null,
    na: { aside: "Aside has no background content loading" },
    better: {
      chatgpt: {
        reason: "tabs.content loads URLs in background tabs and returns their text; ChatGPT's Chrome backend has no tabs.content",
        check: (c, r) => Array.isArray(c.rows) && c.rows.length === 2 && !!r.rows?.error,
      },
    },
    expect: { rows: [["Next page", 200, true], ["Missing", 404, true]], current: "<primary>/diff/lab.html", tabsAfter: true, bad: { error: "invalid-arg" } },
  },
  {
    id: "browser.history",
    members: ["chatgpt:Browser.history"],
    path: "/diff/lab.html",
    code: `await page.goto(U("/diff/next.html"));
const rows = await tabs.history({ query: "next.html", limit: 5 });
const shape = { array: Array.isArray(rows), keys: [...new Set(rows.flatMap((x) => Object.keys(x)))].sort(), found: rows.some((x) => String(x.url).endsWith("/diff/next.html")) };
return { shape, invalid: await E(() => tabs.history({ limit: 0 })), badDate: await E(() => tabs.history({ from: "not a date" })) };`,
    chatgpt: `return { invalid: await E(() => b.history({ limit: 0 })), badDate: await E(() => b.history({ from: "not a date" })) };`,
    aside: null,
    na: { aside: "Aside has no browsing history API" },
    compare: { chatgpt: ["invalid", "badDate"] },
    expect: { shape: { array: true, keys: ["dateVisited", "title", "url"], found: true }, invalid: { error: "invalid-arg" }, badDate: { error: "invalid-arg" } },
  },
  {
    id: "browser.capabilities",
    members: ["chatgpt:Browser.capabilities"],
    path: "/diff/lab.html",
    code: `return { cdp: await E(() => page.cdp.send("Browser.getVersion")) };`,
    chatgpt: `const listed = await E(() => b.capabilities.list());
return { cdp: await E(async () => (await b.capabilities.get("cdp")).send("Browser.getVersion")), _listed: listed };`,
    aside: null,
    na: { aside: "Aside exposes no raw protocol" },
    expect: { cdp: { error: "absent" } },
  },
];
