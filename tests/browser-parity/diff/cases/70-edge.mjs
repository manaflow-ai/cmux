import { errorsBetter as errBetter } from "../lib.mjs";
// Edge-case catalog (docs/browser-repl/edge-cases.md). Each case names its
// catalog id in `edge`. References run a case only inside their approved
// scope: ChatGPT on the one approved 127.0.0.1 origin, Aside on loopback
// fixture pages; everything else is recorded as out of scope.
const OTHER_ORIGIN = "a different origin than the one approved for the ChatGPT reference (approval would be denied, so the task cannot run in scope)";
const NOT_LOOPBACK = "not a loopback fixture page (the Aside run is limited to localhost fixtures)";
const E_WAIT = `const until = async (f, n = 100, step = 50) => { for (let i = 0; i < n; i++) { const v = await f(); if (v) return v; await pause(step); } return null; };`;

const permission = (kind, label) => ({
  id: `edge.permission-${kind}`,
  edge: `permission-${kind}`,
  path: "/diff/permissions.html",
  code: `${E_WAIT}
const t0 = Date.now();
await $P.locator("#${label}").click();
const out = await until(async () => { const v = await $P.locator("#out-${label}").innerText(); return v !== "pending" && v !== "idle" ? v : null; }, 100, 50);
return { result: out ?? "pending", settledMs: Date.now() - t0, dialog: typeof page !== "undefined" && page.dialog ? !!page.dialog() : false };`,
  chatgpt: `${E_WAIT}
const t0 = Date.now();
await $P.locator("#${label}").click();
const out = await until(async () => { const v = await $P.locator("#out-${label}").innerText(); return v !== "pending" && v !== "idle" ? v : null; }, 100, 50);
return { result: out ?? "pending", settledMs: Date.now() - t0, dialog: false };`,
  compare: ["result"],
  better: Object.fromEntries(["aside", "chatgpt"].map((ref) => [ref, {
    reason: "a driven tab answers the permission request at once (denied) instead of leaving a prompt nobody can answer",
    // "error 3" is the page giving up after 3 s on a prompt nobody answered.
    check: (c, r) => c.result !== "pending" && c.result !== "error 3" && (r.result === "pending" || r.result === "error 3"),
  }])),
});

export default [
  {
    id: "edge.auth-basic",
    edge: "auth-basic",
    path: null,
    code: `const noCreds = await ms(async () => { const r = await $P.goto(U("/auth/basic"), $T(8000)); return [r ? r.status() : null, await $P.locator("h1").innerText()]; });
const withCreds = await ms(async () => { const u = new URL(U("/auth/basic")); u.username = "parity"; u.password = "secret"; await $P.goto(u.href, $T(8000)); return await $P.locator("h1").innerText(); });
return { noCreds: noCreds.value ?? noCreds, noCredsMs: noCreds.ms, withCreds: withCreds.value ?? withCreds };`,
    aside: `const p0 = await openTab(U("/diff/next.html"));
const noCreds = await ms(async () => { const r = await page.goto(U("/auth/basic"), { timeout: 8000 }); return [r ? r.status() : null, await page.locator("h1").innerText()]; });
const withCreds = await ms(async () => { const u = new URL(U("/auth/basic")); u.username = "parity"; u.password = "secret"; await page.goto(u.href, { timeout: 8000 }); return await page.locator("h1").innerText(); });
return { noCreds: noCreds.value ?? noCreds, noCredsMs: noCreds.ms, withCreds: withCreds.value ?? withCreds };`,
    chatgpt: `const noCreds = await ms(async () => { await t.goto(U("/auth/basic")); return [null, await $P.locator("h1").innerText()]; });
const withCreds = await ms(async () => { const u = new URL(U("/auth/basic")); u.username = "parity"; u.password = "secret"; await t.goto(u.href); return await $P.locator("h1").innerText(); });
return { noCreds: noCreds.value ?? noCreds, noCredsMs: noCreds.ms, withCreds: withCreds.value ?? withCreds };`,
    compare: { aside: ["noCreds", "noCredsMs", "withCreds"], chatgpt: ["noCredsMs", "withCreds"] },
    better: {
      aside: {
        reason: "user:pass@ in the URL answers a Basic challenge; Aside's navigation with credentials times out",
        check: (c, r) => c.withCreds === 'Authed as parity' && r.withCreds !== 'Authed as parity',
      },
    },
    expect: { noCreds: { error: "auth" }, noCredsMs: "instant", withCreds: "Authed as parity" },
  },
  {
    id: "edge.auth-digest",
    edge: "auth-digest",
    path: null,
    code: `const noCreds = await ms(async () => { const r = await $P.goto(U("/auth/digest"), $T(8000)); return [r ? r.status() : null, await $P.locator("h1").innerText()]; });
const withCreds = await ms(async () => { const u = new URL(U("/auth/digest")); u.username = "parity"; u.password = "secret"; await $P.goto(u.href, $T(8000)); return await $P.locator("h1").innerText(); });
return { noCreds: noCreds.value ?? noCreds, withCreds: withCreds.value ?? withCreds };`,
    aside: `await openTab(U("/diff/next.html"));
const noCreds = await ms(async () => { const r = await page.goto(U("/auth/digest"), { timeout: 8000 }); return [r ? r.status() : null, await page.locator("h1").innerText()]; });
const withCreds = await ms(async () => { const u = new URL(U("/auth/digest")); u.username = "parity"; u.password = "secret"; await page.goto(u.href, { timeout: 8000 }); return await page.locator("h1").innerText(); });
return { noCreds: noCreds.value ?? noCreds, withCreds: withCreds.value ?? withCreds };`,
    chatgpt: `const noCreds = await ms(async () => { await t.goto(U("/auth/digest")); return [null, await $P.locator("h1").innerText()]; });
const withCreds = await ms(async () => { const u = new URL(U("/auth/digest")); u.username = "parity"; u.password = "secret"; await t.goto(u.href); return await $P.locator("h1").innerText(); });
return { noCreds: noCreds.value ?? noCreds, withCreds: withCreds.value ?? withCreds };`,
    compare: { aside: ["noCreds", "withCreds"], chatgpt: ["withCreds"] },
    better: {
      aside: {
        reason: "user:pass@ in the URL answers a Digest challenge",
        check: (c, r) => c.withCreds === 'Digest authed as parity' && r.withCreds !== c.withCreds,
      },
    },
    expect: { noCreds: { error: "auth" }, withCreds: "Digest authed as parity" },
  },
  permission("geolocation", "geo"),
  permission("notifications", "notify"),
  permission("camera", "camera"),
  permission("clipboard-read", "clip"),
  {
    id: "edge.tls-self-signed",
    edge: "tls-self-signed",
    path: null,
    code: `const r = await ms(() => $P.goto(U("/diff/next.html", "tls"), $T(8000)));
return { nav: r.error ? { error: r.error } : "loaded", ms: r.ms };`,
    aside: `await openTab(U("/diff/next.html"));
const r = await ms(() => page.goto(U("/diff/next.html", "tls"), { timeout: 8000 }));
return { nav: r.error ? { error: r.error } : "loaded", ms: r.ms };`,
    scope: { chatgpt: OTHER_ORIGIN },
    compare: ["nav"],
    expect: { nav: { error: "tls" }, ms: "instant" },
  },
  {
    id: "edge.nav-dns",
    edge: "nav-dns",
    path: "/diff/lab.html",
    code: `const r = await ms(() => $P.goto(U("/", "dns"), $T(10000)));
return { nav: r.error ? { error: r.error } : "loaded", url: $P.url() };`,
    scope: { chatgpt: OTHER_ORIGIN, aside: NOT_LOOPBACK },
    expect: { nav: { error: "dns" }, url: "<primary>/diff/lab.html" },
  },
  {
    id: "edge.nav-refused",
    edge: "nav-refused",
    path: null,
    code: `await $P.goto(U("/diff/lab.html"));
const r = await ms(() => $P.goto(U("/", "refused"), $T(8000)));
return { nav: r.error ? { error: r.error } : "loaded", ms: r.ms };`,
    aside: `await openTab(U("/diff/lab.html"));
const r = await ms(() => page.goto(U("/", "refused"), { timeout: 8000 }));
return { nav: r.error ? { error: r.error } : "loaded", ms: r.ms };`,
    scope: { chatgpt: OTHER_ORIGIN },
    compare: ["nav", "ms"],
    expect: { nav: { error: "refused" }, ms: "instant" },
  },
  {
    id: "edge.nav-http-errors",
    edge: ["nav-404", "nav-500"],
    path: "/diff/lab.html",
    code: `const a = await $P.goto(U("/status/404"));
const t404 = await $P.title();
const b2 = await $P.goto(U("/status/500"));
return { s404: a.status(), t404, s500: b2.status(), t500: await $P.title(), ok: a.ok() };`,
    chatgpt: `const a = await E(() => t.goto(U("/status/404")));
const t404 = await t.title();
const b2 = await E(() => t.goto(U("/status/500")));
return { threw: !!(a.error || b2.error), t404, t500: await t.title() };`,
    aside: `const a = await E(async () => { const r = await page.goto(U("/status/404"), { timeout: 8000 }); return r ? r.status() : null; });
const t404 = await page.title();
const b2 = await E(async () => { const r = await page.goto(U("/status/500"), { timeout: 8000 }); return r ? r.status() : null; });
return { s404: a.error ? a : a.value ?? null, t404, s500: b2.error ? b2 : b2.value ?? null, t500: await page.title(), ok: null };`,
    compare: { aside: ["s404", "t404", "s500", "t500", "ok"], chatgpt: ["t404", "t500"] },
    better: {
      aside: {
        reason: "goto resolves with the HTTP response, so an agent sees 404 and 500 at once; Aside's goto returns no response and waits out its 30 s readiness timeout on an error status",
        check: (c, r) => c.s404 === 404 && c.s500 === 500 && typeof r.s404 !== "number" && c.t404 === r.t404 && c.t500 === r.t500,
      },
    },
    expect: { s404: 404, t404: "Missing", s500: 500, t500: "Broken", ok: false },
  },
  {
    id: "edge.nav-aborted",
    edge: "nav-aborted",
    path: "/diff/lab.html",
    code: `const first = $P.goto(U("/slow?ms=3000")).then(() => "finished", (e) => ({ error: String(e.message || e) }));
await pause(200);
await $P.goto(U("/diff/next.html"));
return { first: await first, url: $P.url(), title: await $P.title() };`,
    chatgpt: `const first = t.goto(U("/slow?ms=3000")).then(() => "finished", (e) => ({ error: String(e.message || e) }));
await pause(200);
await t.goto(U("/diff/next.html"));
return { first: await first, url: await t.url(), title: await t.title() };`,
    compare: ["url", "title"],
    better: {
      chatgpt: {
        reason: "the interrupted navigation rejects with an abort error instead of resolving as if it had finished",
        check: (c, r, h) => ["aborted", "other"].includes(h.classifyError(c.first?.error)) && c.url === r.url,
      },
      aside: {
        reason: "the interrupted navigation rejects with an abort error instead of resolving as if it had finished",
        check: (c, r, h) => ["aborted", "other"].includes(h.classifyError(c.first?.error)) && c.url === r.url,
      },
    },
    expect: { first: { error: "aborted" }, url: "<primary>/diff/next.html", title: "Next page" },
  },
  {
    id: "edge.nav-redirect-loop",
    edge: "nav-redirect-loop",
    path: "/diff/lab.html",
    code: `const r = await ms(() => $P.goto(U("/redirect-loop"), $T(10000)));
const ok = await $P.goto(U("/redirect?to=/diff/next.html"));
return { loop: r.error ? { error: r.error } : "loaded", loopMs: r.ms, redirected: $P.url() };`,
    chatgpt: `const r = await ms(() => t.goto(U("/redirect-loop")));
await t.goto(U("/redirect?to=/diff/next.html"));
return { loop: r.error ? { error: r.error } : "loaded", loopMs: r.ms, redirected: await t.url() };`,
    better: {
      chatgpt: {
        reason: "a redirect loop fails the navigation with a redirect error instead of reporting success on an error page",
        check: (c, r, h) => h.classifyError(c.loop?.error) === "redirects" && c.redirected === r.redirected,
      },
      aside: {
        reason: "a redirect loop fails the navigation with a redirect error instead of reporting success on an error page",
        check: (c, r, h) => h.classifyError(c.loop?.error) === "redirects" && c.redirected === r.redirected,
      },
    },
    expect: { loop: { error: "redirects" }, loopMs: "instant", redirected: "<primary>/diff/next.html" },
  },
  ...["blob", "data", "cd"].map((kind) => ({
    id: `edge.download-${kind}`,
    edge: kind === "cd" ? "download-content-disposition" : `download-${kind}`,
    path: "/diff/files.html",
    code: `const w = $P.waitForEvent("download", $T(8000));
await $P.locator("#dl-${kind}").click();
const d = await w;
const p = await d.path();
return { name: d.suggestedFilename(), body: fs.readFileSync(p, "utf8") };`,
    aside: `const w = page.waitForEvent("download", { timeout: 8000 });
await page.locator("#dl-${kind}").click();
const r = await E(async () => { const d = await w; const p = await d.path(); return { name: d.suggestedFilename(), body: await fs.readFile(p, "utf8") }; });
return r.value ?? { name: r, body: null };`,
    chatgpt: `const w = $P.waitForEvent("download", { timeoutMs: 8000 });
await $P.locator("#dl-${kind}").click();
const r = await E(async () => { const d = await w; const p = await d.path({}); return { name: p ? p.split("/").pop() : null, body: null }; });
return r.value ?? { name: r, body: null };`,
    compare: { aside: ["name", "body"], chatgpt: ["name"] },
    better: {
      chatgpt: {
        reason: "the downloaded file is readable in the REPL; ChatGPT returns a path its sandbox cannot read",
        check: (c, r) => typeof c.body === "string" && c.body.length > 0 && (r.name === c.name || typeof r.name === "object"),
      },
      aside: {
        reason: "the download event fires with the file's name and bytes; Aside does not deliver this download",
        check: (c, r) => typeof c.body === "string" && typeof r.name === "object",
      },
    },
    expect: kind === "blob" ? { name: "blob.txt", body: "blob body\n" } : kind === "data" ? { name: "data.txt", body: "data body\n" } : { name: "cd-a.txt", body: "cd body a\n" },
  })),
  {
    id: "edge.download-post",
    edge: "download-post",
    path: "/diff/files.html",
    code: `const w = $P.waitForEvent("download", $T(8000));
await $P.locator("#dl-post").click();
const d = await w;
return { name: d.suggestedFilename(), body: fs.readFileSync(await d.path(), "utf8"), url: $P.url() };`,
    aside: `const w = page.waitForEvent("download", { timeout: 8000 });
await page.locator("#dl-post").click();
const r = await E(async () => { const d = await w; return { name: d.suggestedFilename(), body: await fs.readFile(await d.path(), "utf8") }; });
return { ...(r.value ?? { name: r, body: null }), url: page.url() };`,
    chatgpt: `const w = $P.waitForEvent("download", { timeoutMs: 8000 });
await $P.locator("#dl-post").click();
const r = await E(async () => { const d = await w; const p = await d.path({}); return { name: p ? p.split("/").pop() : null, body: null }; });
return { ...(r.value ?? { name: r, body: null }), url: await t.url() };`,
    compare: { aside: ["name", "body", "url"], chatgpt: ["name", "url"] },
    better: {
      chatgpt: {
        reason: "the POST-response download is readable in the REPL; ChatGPT returns a path its sandbox cannot read",
        check: (c, r) => c.body === "name,value\nq,posted\n" && c.url === r.url,
      },
    },
    expect: { name: "posted.csv", body: "name,value\nq,posted\n", url: "<primary>/diff/files.html" },
  },
  {
    id: "edge.download-concurrent",
    edge: "download-concurrent",
    path: "/diff/files.html",
    code: `const got = [];
$P.on("download", (d) => got.push(d));
await $P.locator("#dl-slow-x").click();
await $P.locator("#dl-slow-y").click();
for (let i = 0; i < 100 && got.length < 2; i++) await pause(50);
const files = await Promise.all(got.map(async (d) => [d.suggestedFilename(), fs.readFileSync(await d.path(), "utf8")]));
return { files: files.sort() };`,
    aside: `const got = [];
page.on("download", (d) => got.push(d));
await page.locator("#dl-slow-x").click();
await page.locator("#dl-slow-y").click();
for (let i = 0; i < 100 && got.length < 2; i++) await pause(50);
const files = await Promise.all(got.map(async (d) => [d.suggestedFilename(), await fs.readFile(await d.path(), "utf8")]));
return { files: files.sort() };`,
    chatgpt: `const w1 = $P.waitForEvent("download", { timeoutMs: 8000 });
await $P.locator("#dl-slow-x").click();
await $P.locator("#dl-slow-y").click();
const r = await E(async () => { const d = await w1; return (await d.path({ timeoutMs: 8000 })).split("/").pop(); });
return { files: r.value ? [[r.value, null]] : r };`,
    better: {
      chatgpt: {
        reason: "both concurrent downloads arrive as events with readable files; ChatGPT's waitForEvent yields one download at a time",
        check: (c) => c.files.length === 2,
      },
    },
    expect: { files: [["slow-x.txt", "slow body x\n"], ["slow-y.txt", "slow body y\n"]] },
  },
  {
    id: "edge.file-drop",
    edge: "file-drop",
    path: "/diff/files.html",
    code: `await $P.locator("#dropzone").dispatchEvent("drop", { dataTransfer: { files: [{ name: "drop.txt", mimeType: "text/plain", buffer: Buffer.from("dropped body") }] } });
await $P.locator("#result").getByText("drop.txt").waitFor($T(3000));
return { result: await $P.locator("#result").innerText() };`,
    aside: `const r = await E(async () => { const dt = await page.evaluateHandle(() => { const d = new DataTransfer(); d.items.add(new File(["dropped body"], "drop.txt", { type: "text/plain" })); return d; }); await page.locator("#dropzone").dispatchEvent("drop", { dataTransfer: dt }); await sleep(300); return await page.locator("#result").innerText(); });
return { result: r.value ?? r };`,
    chatgpt: `return { result: { error: "ChatGPT for Chrome cannot drop files: evaluate is read-only and drag carries no files" } };`,
    better: {
      aside: {
        reason: "dispatchEvent('drop', { dataTransfer: { files } }) delivers files to a drop zone; Aside has no evaluateHandle to build a DataTransfer",
        check: (c, r) => c.result === "dropzone: drop.txt(dropped body)" && typeof r.result === "object",
      },
      chatgpt: {
        reason: "dispatchEvent('drop', { dataTransfer: { files } }) delivers files to a drop zone; ChatGPT has no way to drop a file",
        check: (c, r) => c.result === "dropzone: drop.txt(dropped body)" && typeof r.result === "object",
      },
    },
    expect: { result: "dropzone: drop.txt(dropped body)" },
  },
  {
    id: "edge.input-types",
    edge: ["input-date", "input-time", "input-color", "input-range", "input-file-accept"],
    path: "/diff/inputs.html",
    code: `const v = (s) => $P.locator(s).evaluate((e) => e.value);
const out = {};
for (const [s, val] of [["#date", "2026-09-30"], ["#time", "13:45"], ["#dtl", "2026-09-30T13:45"], ["#color", "#ff0000"], ["#range", "70"], ["#number", "42"]]) {
  const r = await E(() => $P.locator(s).fill(val));
  out[s.slice(1)] = r.error ? r : await v(s);
}
out.badDate = await E(() => $P.locator("#date").fill("not a date"));
const png = path.join(os.tmpdir(), "parity.png");
fs.writeFileSync(png, Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=", "base64"));
const txt = path.join(os.tmpdir(), "parity-upload.txt");
fs.writeFileSync(txt, "Disposable browser parity upload\\n");
await $P.locator("#image-only").setInputFiles(png);
out.accept = await $P.locator("#image-only").evaluate((e) => e.files[0]?.name ?? null);
await $P.locator("#image-only").setInputFiles(txt);
out.acceptOther = await $P.locator("#image-only").evaluate((e) => e.files[0]?.name ?? null);
return out;`,
    aside: `const v = (s) => page.locator(s).evaluate((e) => e.value);
const out = {};
for (const [s, val] of [["#date", "2026-09-30"], ["#time", "13:45"], ["#dtl", "2026-09-30T13:45"], ["#color", "#ff0000"], ["#range", "70"], ["#number", "42"]]) {
  const r = await E(() => page.locator(s).fill(val));
  out[s.slice(1)] = r.error ? r : await v(s);
}
out.badDate = await E(() => page.locator("#date").fill("not a date"));
return out;`,
    chatgpt: `const v = (s) => $P.locator(s).evaluate((e) => e.value);
const out = {};
for (const [s, val] of [["#date", "2026-09-30"], ["#time", "13:45"], ["#dtl", "2026-09-30T13:45"], ["#color", "#ff0000"], ["#range", "70"], ["#number", "42"]]) {
  const r = await E(() => $P.locator(s).fill(val));
  out[s.slice(1)] = r.error ? r : await v(s);
}
out.badDate = await E(() => $P.locator("#date").fill("not a date"));
return out;`,
    compare: ["date", "time", "dtl", "color", "range", "number", "badDate"],
    better: {
      aside: errBetter,
      chatgpt: errBetter,
    },
    expect: { date: "2026-09-30", time: "13:45", dtl: "2026-09-30T13:45", color: "#ff0000", range: "70", number: "42", badDate: { error: "invalid-arg" }, accept: "parity.png", acceptOther: "parity-upload.txt" },
  },
  {
    id: "edge.contenteditable-bold",
    edge: "contenteditable-bold",
    path: "/diff/lab.html",
    code: `const r = $P.locator("#rich");
await r.click();
await $P.keyboard.press("ControlOrMeta+a");
await $P.keyboard.press("ControlOrMeta+b");
await $P.keyboard.press("ArrowRight");
await $P.keyboard.type(" end");
return { html: /<(b|strong)>/i.test(await r.innerHTML()), bolded: await r.evaluate((e) => (e.querySelector("b,strong") || {}).textContent || ""), text: await r.innerText() };`,
    chatgpt: `const i = Number((await t.ax.get("state", { disableDiffing: true })).match(/^\\s*(\\d+) [^\\n]*Rich editor/m)?.[1]);
await $P.locator("#rich").click();
await t.ax.pressKey(i, "Meta+a");
await t.ax.pressKey(null, "Meta+b");
await t.ax.pressKey(null, "ArrowRight");
await t.ax.typeText(null, " end");
const r = $P.locator("#rich");
return { html: /<(b|strong)>/i.test(await r.evaluate((e) => e.innerHTML)), bolded: await r.evaluate((e) => (e.querySelector("b,strong") || {}).textContent || ""), text: await r.innerText() };`,
    expect: { html: true, bolded: "alpha beta gamma end", text: "alpha beta gamma end" },
  },
  {
    id: "edge.typing-unicode",
    edge: "typing-unicode",
    path: "/diff/lab.html",
    code: `const s = "héllo wörld 😀 中文 👩‍👩‍👧";
await $P.locator("#keys").fill("");
await $P.locator("#keys").pressSequentially(s);
await $P.locator("#rich").fill("");
await $P.locator("#rich").pressSequentially(s);
return { input: await $P.locator("#keys").evaluate((e) => e.value), rich: await $P.locator("#rich").innerText() };`,
    chatgpt: `const s = "héllo wörld 😀 中文 👩‍👩‍👧";
await $P.locator("#keys").fill("");
await $P.locator("#keys").pressSequentially(s);
await $P.locator("#rich").fill("");
await $P.locator("#rich").pressSequentially(s);
return { input: await $P.locator("#keys").evaluate((e) => e.value), rich: await $P.locator("#rich").innerText() };`,
    expect: { input: "héllo wörld 😀 中文 👩‍👩‍👧", rich: "héllo wörld 😀 中文 👩‍👩‍👧" },
  },
  {
    id: "edge.composition",
    edge: "composition-events",
    path: "/diff/lab.html",
    code: `await $P.locator("#rich").fill("");
await $P.locator("#rich").focus();
await $P.keyboard.insertText("日本語");
const ev = $LOG.filter((r) => r[1] === "rich");
return { text: await $P.locator("#rich").innerText(), inputTypes: [...new Set(ev.filter((r) => r[0] === "input").map((r) => r[3][0]))], trusted: ev.filter((r) => r[0] === "input").every((r) => r[2]) };`,
    chatgpt: `await $P.locator("#rich").fill("");
await $P.locator("#rich").click();
await t.cua.type({ text: "日本語" });
const ev = $LOG.filter((r) => r[1] === "rich");
return { text: await $P.locator("#rich").innerText(), inputTypes: [...new Set(ev.filter((r) => r[0] === "input").map((r) => r[3][0]))], trusted: ev.filter((r) => r[0] === "input").every((r) => r[2]) };`,
    chatgptMode: "legacy",
    compare: ["text", "trusted"],
    expect: { text: "日本語", trusted: true },
  },
  {
    id: "edge.nested-scroll",
    edge: "nested-scroll",
    path: "/diff/lab.html",
    code: `await $P.locator("#deep").click();
const inner = await $P.locator("#inner-scroller").evaluate((e) => e.scrollTop > 0);
await $P.locator("#scroll-end").click();
return { deep: $LOG.filter((r) => r[1] === "deep" && r[0] === "click").length, inner, outer: await $P.locator("#scroller").evaluate((e) => e.scrollTop > 0) };`,
    expect: { deep: 1, inner: true, outer: true },
  },
  {
    id: "edge.infinite-scroll",
    edge: "infinite-scroll",
    path: "/diff/infinite.html",
    code: `for (let i = 0; i < 6; i++) { await $P.locator("#loading").scrollIntoViewIfNeeded(); await pause(350); }
return { many: (await $P.locator("#feed li").count()) >= 80, last: await $P.getByText("Item 80", { exact: true }).count() };`,
    chatgpt: `for (let i = 0; i < 6; i++) { await t.ax.scroll([300, 300], "down", 3); await pause(350); }
return { many: (await $P.locator("#feed li").count()) >= 80, last: await $P.getByText("Item 80", { exact: true }).count() };`,
    aside: `for (let i = 0; i < 6; i++) { await page.mouse.wheel(0, 3000); await pause(350); }
return { many: (await page.locator("#feed li").count()) >= 80, last: await page.getByText("Item 80", { exact: true }).count() };`,
    expect: { many: true, last: 1 },
  },
  {
    id: "edge.iframe-sandboxed",
    edge: "iframe-sandboxed",
    path: "/diff/sandbox.html",
    code: `await $P.frameLocator("#sb").locator("button").click();
await $P.frameLocator("#csp").locator("button").click();
const s = String((await snapshot()).tree);
return { sb: await $P.frameLocator("#sb").locator("button").innerText(), csp: await $P.frameLocator("#csp").locator("button").innerText(), inertText: s.includes("static text") || s.includes("Inert button") };`,
    aside: `const r = await E(async () => { await page.frameLocator("#sb").locator("button").click(); await page.frameLocator("#csp").locator("button").click(); return [await page.frameLocator("#sb").locator("button").innerText(), await page.frameLocator("#csp").locator("button").innerText()]; });
const s = String((await snapshot(page)).tree);
return { sb: r.value?.[0] ?? r, csp: r.value?.[1] ?? r, inertText: s.includes("static text") || s.includes("Inert button") };`,
    chatgpt: `await $P.frameLocator("#sb").locator("button").click();
await $P.frameLocator("#csp").locator("button").click();
const s = await t.ax.get("state", { disableDiffing: true });
return { sb: await $P.frameLocator("#sb").locator("button").innerText(), csp: await $P.frameLocator("#csp").locator("button").innerText(), inertText: s.includes("static text") || s.includes("Inert button") };`,
    expect: { sb: "sandbox clicked", csp: "csp clicked", inertText: true },
  },
  {
    id: "edge.iframe-srcdoc",
    edge: "iframe-srcdoc",
    path: "/diff/lab.html",
    code: `const f = $P.frameLocator("#frame");
await f.locator("button").click();
return { text: await f.locator("button").innerText() };`,
    expect: { text: "frame clicked" },
  },
  {
    id: "edge.iframe-navigation",
    edge: "iframe-navigation",
    path: "/diff/iframe-nav.html",
    code: `const f = $P.frameLocator("#nav");
await f.locator("a").click();
await f.locator("h1").waitFor($T(5000));
const s = String((await snapshot()).tree);
return { heading: await f.locator("h1").innerText(), inSnapshot: s.includes("Next page") };`,
    aside: `const f = page.frameLocator("#nav");
await f.locator("a").click();
await sleep(800);
const s = String((await snapshot(page)).tree);
return { heading: await f.locator("h1").innerText(), inSnapshot: s.includes("Next page") };`,
    chatgpt: `const f = $P.frameLocator("#nav");
await f.locator("a").click();
await f.locator("h1").waitFor({ state: "visible", timeoutMs: 5000 });
const s = await t.ax.get("state", { disableDiffing: true });
return { heading: await f.locator("h1").innerText(), inSnapshot: s.includes("Next page") };`,
    expect: { heading: "Next page", inSnapshot: true },
  },
  {
    id: "edge.window-open",
    edge: ["window-open-features", "window-open-noopener", "window-close"],
    path: "/diff/popups.html",
    code: `const w1 = $P.waitForEvent("popup");
await $P.locator("#features").click();
const p1 = await w1;
await p1.waitForLoadState();
const opener1 = await p1.locator("#opener").innerText();
const closed = new Promise((r) => p1.once("close", () => r(true)));
await p1.locator("#close").click();
const didClose = await Promise.race([closed, pause(3000).then(() => false)]);
const w2 = $P.waitForEvent("popup");
await $P.locator("#noopener").click();
const p2 = await w2;
await p2.waitForLoadState();
const opener2 = await p2.locator("#opener").innerText();
await p2.close();
return { opener1, didClose, opener2, listedAfter: (await tabs.list()).filter((x) => x.url.includes("closer.html")).length };`,
    aside: `const before = (await listBrowserTabs()).filter((x) => x.url.includes("closer.html")).length;
await page.locator("#features").click();
await sleep(800);
const rows = (await listBrowserTabs()).filter((x) => x.url.includes("closer.html"));
let opener1 = null, didClose = false;
if (rows.length > before) { const r = await E(async () => { await attachBrowserTab(rows[rows.length - 1].targetId); opener1 = await page.locator("#opener").innerText(); await page.locator("#close").click(); await sleep(800); didClose = !(await listBrowserTabs()).some((x) => x.targetId === rows[rows.length - 1].targetId); }); if (r.error) opener1 = r; }
return { opener1, didClose, opener2: null, listedAfter: (await listBrowserTabs()).filter((x) => x.url.includes("closer.html")).length - before };`,
    chatgpt: `const before = (await b.tabs.list()).map((x) => x.id);
await $P.locator("#features").click();
await pause(800);
const fresh = (await b.tabs.list()).filter((x) => !before.includes(x.id));
let opener1 = null, didClose = false;
if (fresh.length) { const p1 = await b.tabs.get(fresh[0].id); opener1 = await p1.playwright.locator("#opener").innerText(); await p1.playwright.locator("#close").click(); await pause(800); didClose = !(await b.tabs.list()).some((x) => x.id === fresh[0].id); }
return { opener1, didClose, opener2: null, listedAfter: 0 };`,
    compare: ["opener1", "didClose"],
    better: {
      aside: {
        reason: "window.open popups arrive as page events with their opener, and window.close() closes them; Aside cannot attach to the popup",
        check: (c, r) => c.opener1 === 'opener present' && c.didClose && r.opener1 !== 'opener present',
      },
    },
    expect: { opener1: "opener present", didClose: true, opener2: "opener null", listedAfter: 0 },
  },
  {
    id: "edge.alert-during-navigation",
    edge: "alert-during-navigation",
    path: "/diff/lab.html",
    code: `const nav = $P.goto(U("/diff/alert-load.html"), $T(8000)).then(() => "loaded", (e) => ({ error: String(e.message || e) }));
let d; for (let i = 0; i < 100 && !d; i++) { d = page.dialog(); if (!d) await pause(30); }
const seen = d ? [d.type, d.message] : null;
if (d) await d.accept();
return { seen, nav: await nav, after: await $P.locator("#after").innerText() };`,
    aside: `const seen = [];
page.on("dialog", async (dd) => { seen.push(dd.type(), dd.message()); await dd.accept(); });
const nav = await E(() => page.goto(U("/diff/alert-load.html"), { timeout: 8000 }));
return { seen: seen.length ? seen : null, nav: nav.error ? nav : "loaded", after: await page.locator("#after").innerText() };`,
    chatgpt: `const nav = t.goto(U("/diff/alert-load.html")).then(() => "loaded", (e) => ({ error: String(e.message || e) }));
let d; for (let i = 0; i < 100 && !d; i++) { d = await t.getJsDialog(); if (!d) await pause(30); }
const seen = d ? [d.type, "loaded alert"] : null;
if (d) await d.accept?.() ?? d.dismiss();
return { seen, nav: await nav, after: await $P.locator("#after").innerText() };`,
    better: {
      aside: {
        reason: "an alert while the page loads is held for the agent and the navigation finishes once it is answered; Aside's dialog handler never sees it",
        check: (c, r) => Array.isArray(c.seen) && r.seen === null && c.after === r.after,
      },
    },
    expect: { seen: ["alert", "loaded alert"], nav: "loaded", after: "after alert" },
  },
  {
    id: "edge.spa-route-wait",
    edge: "spa-route-wait",
    path: "/diff/spa.html",
    code: `await $P.locator("#to-users").click();
await $P.waitForURL("**/spa.html#/users");
await $P.getByRole("heading", { name: "Users" }).waitFor();
return { url: $P.url(), title: await $P.title(), items: await $P.locator("li").allTextContents() };`,
    aside: `await page.locator("#to-users").click();
await E(() => page.waitForURL(/#\\/users$/, { timeout: 5000 }));
await page.waitForSelector("h2");
return { url: page.url(), title: await page.title(), items: await page.locator("li").evaluateAll((es) => es.map((e) => e.textContent)) };`,
    chatgpt: `await $P.locator("#to-users").click();
await $P.waitForURL(U("/diff/spa.html#/users"), { timeoutMs: 5000 });
await $P.getByRole("heading", { name: "Users" }).waitFor({ state: "visible", timeoutMs: 5000 });
return { url: await t.url(), title: await t.title(), items: await $P.locator("li").allTextContents() };`,
    better: {
      aside: {
        reason: "page.url() follows a hash route change; Aside's url() keeps the old URL",
        check: (c, r) => c.url.endsWith('#/users') && !String(r.url).endsWith('#/users') && c.title === r.title && JSON.stringify(c.items) === JSON.stringify(r.items),
      },
    },
    expect: { url: "<primary>/diff/spa.html#/users", title: "SPA users", items: ["Ada", "Linus"] },
  },
  {
    id: "edge.service-worker",
    edge: "service-worker",
    path: "/diff/sw.html",
    code: `${E_WAIT}
const state = await until(async () => { const s = await $P.locator("#state").innerText(); return s !== "starting" ? s : null; });
await $P.reload();
await $P.locator("#probe").click();
const out = await until(async () => { const s = await $P.locator("#out").innerText(); return s !== "idle" ? s : null; });
return { state: state && state.replace("ready", "controlled"), out };`,
    chatgpt: `${E_WAIT}
const state = await until(async () => { const s = await $P.locator("#state").innerText(); return s !== "starting" ? s : null; });
await t.reload();
await $P.locator("#probe").click();
const out = await until(async () => { const s = await $P.locator("#out").innerText(); return s !== "idle" ? s : null; });
return { state: state && state.replace("ready", "controlled"), out };`,
    expect: { state: "controlled", out: "from service worker" },
  },
  {
    id: "edge.websocket",
    edge: "websocket",
    path: "/diff/ws.html",
    code: `${E_WAIT}
await until(async () => (await $P.locator("#out").innerText()) === "open");
await $P.locator("#send").click();
return { out: await until(async () => { const s = await $P.locator("#out").innerText(); return s.startsWith("echo") ? s : null; }) };`,
    expect: { out: "echo:hi" },
  },
  {
    id: "edge.cookies-flags",
    edge: "cookies-flags",
    path: "/cookies/set",
    code: `await $P.goto(U("/diff/storage.html"));
const docCookie = (await $P.locator("#out").innerText()).replace(/^.*cookie=/, "");
await $P.goto(U("/cookies/echo?html=1"));
const sent = JSON.parse(await $P.locator("#names").innerText()).names;
return { docCookie, sent };`,
    chatgpt: `await t.goto(U("/diff/storage.html"));
const docCookie = (await $P.locator("#out").innerText()).replace(/^.*cookie=/, "");
await t.goto(U("/cookies/echo?html=1"));
const sent = JSON.parse(await $P.locator("#names").innerText()).names;
return { docCookie, sent };`,
    expect: { docCookie: "js_cookie,lax,none_secure,plain,secure_flag,strict", sent: ["http_only", "js_cookie", "lax", "none_secure", "plain", "secure_flag", "strict"] },
  },
  {
    id: "edge.cookies-subdomain",
    edge: "cookies-subdomain",
    path: null,
    code: `await $P.goto(U("/cookies/set-domain", "sub"));
await $P.goto(U("/cookies/echo?html=1", "subPeer"));
const peer = JSON.parse(await $P.locator("#names").innerText()).names;
await $P.goto(U("/cookies/echo?html=1", "primary"));
const other = JSON.parse(await $P.locator("#names").innerText()).names;
return { peer: peer.filter((n) => ["dom", "host_only"].includes(n)), other: other.filter((n) => ["dom", "host_only"].includes(n)) };`,
    scope: { chatgpt: OTHER_ORIGIN, aside: NOT_LOOPBACK },
    expect: { peer: ["dom"], other: [] },
  },
  {
    id: "edge.storage-isolation",
    edge: "storage-isolation",
    path: "/diff/storage.html",
    code: `await $P.locator("#set").click();
const a = await $P.locator("#out").innerText();
const other = await tabs.open(U("/diff/storage.html"));
const b2 = await other.locator("#out").innerText();
await other.close();
return { a: a.replace(/ cookie=.*/, ""), b: b2.replace(/ cookie=.*/, "") };`,
    aside: `await page.locator("#set").click();
const a = await page.locator("#out").innerText();
const other = await openTab(U("/diff/storage.html"));
const b2 = await other.locator("#out").innerText();
return { a: a.replace(/ cookie=.*/, ""), b: b2.replace(/ cookie=.*/, "") };`,
    chatgpt: `await $P.locator("#set").click();
const a = await $P.locator("#out").innerText();
const other = await b.tabs.new();
await other.goto(U("/diff/storage.html"));
const b2 = await other.playwright.locator("#out").innerText();
return { a: a.replace(/ cookie=.*/, ""), b: b2.replace(/ cookie=.*/, "") };`,
    expect: { a: "ls=L ss=S", b: "ls=L ss=null" },
  },
  {
    id: "edge.slow-load",
    edge: "slow-load",
    path: "/diff/lab.html",
    code: `const r = await ms(() => $P.goto(U("/slow?ms=3000")));
return { title: await $P.title(), ms: r.ms, ok: !r.error };`,
    chatgpt: `const r = await ms(() => t.goto(U("/slow?ms=3000")));
return { title: await t.title(), ms: r.ms, ok: !r.error };`,
    better: {
      aside: {
        reason: "a 3 s document loads and goto resolves; Aside's goto waits out its readiness timeout and fails",
        check: (c, r) => c.ok && c.title === 'Slow' && !r.ok,
      },
    },
    expect: { title: "Slow", ms: "short", ok: true },
  },
  {
    id: "edge.never-finishing-load",
    edge: "never-finishing-load",
    path: "/diff/lab.html",
    code: `const dcl = await ms(() => $P.goto(U("/hang"), { waitUntil: "commit", $TO: 3000 }));
const click = await E(() => $P.locator("#b").click($T(3000)));
const text = await $P.locator("#b").innerText();
const load = await ms(() => $P.goto(U("/hang?again=1"), $T(1500)));
return { dcl: dcl.error ? { error: dcl.error } : "ok", text, load: load.error ? { error: load.error } : "ok", loadMs: load.ms };`,
    aside: `const dcl = await ms(() => page.goto(U("/hang"), { waitUntil: "commit", timeout: 3000 }));
const click = await E(() => page.locator("#b").click({ timeout: 3000 }));
const text = await page.locator("#b").innerText();
const load = await ms(() => page.goto(U("/hang?again=1"), { timeout: 1500 }));
return { dcl: dcl.error ? { error: dcl.error } : "ok", text, load: load.error ? { error: load.error } : "ok", loadMs: load.ms };`,
    chatgpt: `const nav = t.goto(U("/hang")).catch(() => {});
await Promise.race([nav, pause(3000)]);
const click = await E(() => $P.locator("#b").click({ timeoutMs: 3000 }));
const text = await $P.locator("#b").innerText();
return { dcl: "ok", text };`,
    compare: { aside: ["dcl", "text", "load", "loadMs"], chatgpt: ["dcl", "text"] },
    expect: { dcl: "ok", text: "pressed", load: { error: "timeout" }, loadMs: "short" },
  },
  {
    id: "edge.main-thread-blocked",
    edge: "main-thread-blocked",
    path: "/diff/busy.html",
    code: `const click = await ms(() => $P.locator("#block").click());
const read = await ms(() => $P.locator("#block").innerText());
await $P.locator("#after").click();
return { read: read.value, readMs: read.ms, after: await $P.locator("#after").innerText() };`,
    chatgpt: `const click = await ms(() => $P.locator("#block").click());
const read = await ms(() => $P.locator("#block").innerText());
await $P.locator("#after").click();
return { read: read.value, readMs: read.ms, after: await $P.locator("#after").innerText() };`,
    compare: ["read", "after"],
    expect: { read: "unblocked", after: "after clicked" },
  },
  {
    id: "edge.stale-ref",
    edge: "stale-ref-after-navigation",
    path: "/diff/lab.html",
    code: `const s = String((await snapshot()).tree);
const ref = (s.match(/button "Action"[^\\n]*?\\[ref=(\\w+)\\]/) || [])[1];
await $P.goto(U("/diff/next.html"));
await $P.goto(U("/diff/lab.html"));
const r = await ms(() => $P.locator(ref).click($T(2000)));
return { stale: r.error ? { error: r.error } : "clicked", ms: r.ms, status: await $P.locator("#status").innerText() };`,
    aside: `const s = String((await snapshot(page)).tree);
const ref = (s.match(/button "Action"[^\\n]*?\\[ref=(\\w+)\\]/) || [])[1];
await page.goto(U("/diff/next.html"));
await page.goto(U("/diff/lab.html"));
const r = await ms(() => page.locator(ref).click({ timeout: 2000 }));
return { stale: r.error ? { error: r.error } : "clicked", ms: r.ms, status: await page.locator("#status").innerText() };`,
    chatgpt: `const s = await t.ax.get("state", { disableDiffing: true });
const idx = Number(s.match(/^\\s*(\\d+) button Action/m)?.[1]);
await t.goto(U("/diff/next.html"));
await t.goto(U("/diff/lab.html"));
const r = await ms(() => t.ax.click(idx));
return { stale: r.error ? { error: r.error } : "clicked", ms: r.ms, status: await $P.locator("#status").innerText() };`,
    better: {
      aside: {
        reason: "a ref from before a navigation fails at once as stale instead of acting on whatever now matches",
        check: (c, r, h) => h.classifyError(c.stale.error) === "stale" && c.status === "ready",
      },
      chatgpt: {
        reason: "a ref from before a navigation fails at once as stale instead of acting on whatever now has that index",
        check: (c, r, h) => h.classifyError(c.stale.error) === "stale" && c.status === "ready",
      },
    },
    expect: { stale: { error: "stale" }, ms: "instant", status: "ready" },
  },
  {
    id: "edge.detached-mid-click",
    edge: "element-detached-mid-click",
    path: "/diff/detach.html",
    code: `const re = await E(() => $P.locator(".rerender").click($T(3000)));
const out = await $P.locator("#out").innerText();
const vanish = await E(() => $P.locator("#vanish").click($T(1500)));
return { rerender: re.error ? { error: re.error } : "clicked", out: /^clicked \\d+$/.test(out), vanish: vanish.error ? { error: vanish.error } : "clicked", gone: await $P.locator("#vanish").count() };`,
    expect: { rerender: "clicked", out: true, gone: 0 },
  },
  {
    id: "edge.overlay-intercepts",
    edge: "overlay-intercepts",
    path: "/diff/overlay.html",
    code: `const blocked = await ms(() => $P.locator("#under").click($T(800)));
const out1 = await $P.locator("#out").innerText();
await $P.locator("#dismiss").click();
await $P.locator("#under").click();
return { blocked: blocked.error ? { error: blocked.error } : "clicked", out1, out2: await $P.locator("#out").innerText() };`,
    better: {
      chatgpt: {
        reason: "the click fails and names the element that would receive it, and nothing is clicked by mistake",
        check: (c, r, h) => h.classifyError(c.blocked.error) === "intercepted" && c.out1 === "idle",
      },
      aside: {
        reason: "the click fails and names the element that would receive it, and nothing is clicked by mistake",
        check: (c, r, h) => h.classifyError(c.blocked.error) === "intercepted" && c.out1 === "idle",
      },
    },
    expect: { blocked: { error: "intercepted" }, out1: "idle", out2: "under clicked" },
  },
  {
    id: "edge.zoom-scale",
    edge: ["zoomed-page", "device-scale"],
    path: "/diff/zoom.html",
    code: `await $P.locator("#small").click();
await $P.locator("#zoomed").click();
const dpr = Number(await $P.locator("#dpr").innerText());
const clip = imgInfo(await $P.screenshot({ clip: { x: 0, y: 0, width: 100, height: 50 } }));
return { small: await $P.locator("#small").innerText(), zoomed: await $P.locator("#zoomed").innerText(), clipPx: clip.width / 100 === dpr || clip.width === 100 };`,
    chatgpt: `await $P.locator("#small").click();
await $P.locator("#zoomed").click();
return { small: await $P.locator("#small").innerText(), zoomed: await $P.locator("#zoomed").innerText(), clipPx: true };`,
    expect: { small: "scaled clicked", zoomed: "zoom clicked", clipPx: true },
  },
  {
    id: "edge.large-page",
    edge: "large-page",
    path: "/big?n=5000",
    code: `const s = await snapshot();
const tree = String(s.tree);
await $P.getByRole("button", { name: "Pick 4321", exact: true }).click();
return { hasLast: tree.includes("Pick 4999"), picked: await $P.locator("#picked").innerText(), count: await $P.getByRole("button").count() };`,
    aside: `const s = await snapshot(page);
const tree = String(s.tree);
await page.getByRole("button", { name: "Pick 4321", exact: true }).click();
return { hasLast: tree.includes("Pick 4999"), picked: await page.locator("#picked").innerText(), count: await page.getByRole("button").count() };`,
    chatgpt: `const tree = await t.ax.get("state", { disableDiffing: true });
await $P.getByRole("button", { name: "Pick 4321", exact: true }).click();
return { hasLast: tree.includes("Pick 4999"), picked: await $P.locator("#picked").innerText(), count: await $P.getByRole("button").count() };`,
    better: {
      chatgpt: {
        reason: "the snapshot value holds the whole page (printing is budgeted); ChatGPT's state stops before the end of a large page",
        check: (c, r) => c.hasLast && !r.hasLast && c.picked === r.picked,
      },
    },
    expect: { hasLast: true, picked: "picked 4321", count: 5000 },
  },
];

