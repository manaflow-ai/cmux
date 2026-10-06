// Sessions, concurrency, crashes and the user acting in a driven pane.
// These run as custom flows: several REPL calls, in parallel where the case
// is about concurrency.
const MY = (label) => `await page.goto(U("/diff/lab.html"));
await page.locator("#name").fill(${JSON.stringify(label)});
for (let i = 0; i < 3; i++) { await page.locator("#counter").click(); await sleep(50); }
return { id: page.id, name: await page.locator("#name").inputValue(), count: await page.locator("#counter").innerText() };`;

export default [
  {
    id: "tabs.claim-other-workspace",
    members: ["reference-b:BrowserUser.claimTab", "reference-b:BrowserUser.openTabs"],
    appOnly: true,
    // A browser tab the user has open in another workspace: listed with
    // tabs.list({ all: true }), claimed with tabs.use(id), then driven.
    custom: {
      async cmux(ctx) {
        const url = `${ctx.origins.primary}/diff/lab.html?claim=${Date.now()}`;
        const ws = await ctx.cli(["new-workspace", "--name", "parity-claim", "--focus", "false"]);
        const wsRef = (ws.out.match(/workspace:\d+|[0-9A-F]{8}-[0-9A-F-]{27}/i) || [])[0];
        if (!wsRef) return { error: `new-workspace printed no id: ${ws.out.trim()} ${ws.err.trim()}`.slice(0, 300) };
        try {
          await ctx.cli(["new-surface", "--type", "browser", "--workspace", wsRef, "--url", url, "--focus", "false"]);
          const r = await ctx.repl(ctx.wrap({ path: null, code: `let row;
for (let i = 0; i < 50 && !row; i++) { row = (await tabs.list({ all: true })).find((t) => t.url === ${JSON.stringify(url)}); if (!row) await sleep(100); }
const own = (await tabs.list()).some((t) => t.url === ${JSON.stringify(url)});
const p = await tabs.use(row.id);
await p.locator("#counter").click();
return { listedAll: !!row, inOwnList: own, otherWorkspace: !!row.workspace, count: await p.locator("#counter").innerText() };` }));
          return r.value ?? r;
        } finally {
          await ctx.cli(["workspace-action", "--action", "close", "--workspace", wsRef]);
        }
      },
      async "reference-b"({ c, origins }) {
        await c.js(`var __u=await rb.tabs.new(); await __u.goto(${JSON.stringify(origins.primary + "/diff/lab.html")});`);
        const v = await c.value(`(async()=>{ const row=(await rb.user.openTabs()).find((x)=>x.id===__u.id); const t2=await rb.user.claimTab(row); await t2.playwright.locator("#counter").click(); return { listedAll: !!row, inOwnList: false, otherWorkspace: true, count: await t2.playwright.locator("#counter").innerText() }; })()`);
        return v;
      },
    },
    na: { "reference-a": "Reference A has no user-tab claim; attachBrowserTab is covered by tabs.attach" },
    compare: ["listedAll", "count"],
    expect: { listedAll: true, inOwnList: false, otherWorkspace: true, count: "Count 1" },
  },
  {
    id: "tabs.legacy-socket-refused",
    edge: "legacy-socket-refused",
    appOnly: true,
    // The older browser.* socket methods (`cmux browser <surface> eval`,
    // `click` and the rest) carry no session, so no ownership check or
    // secret masking: they are refused every tab a session drives (one it
    // opened, a user's tab it drives with tabs.use()), with an error that
    // names `cmux browser repl`. A user's tab no session drives stays
    // theirs, also once the session that drove it ends, and the tab list
    // still shows a session's tab. The user's tab opens in the caller's
    // workspace, the one the session binds to.
    custom: {
      async cmux(ctx) {
        const url = `${ctx.origins.primary}/diff/lab.html?legacy=${Date.now()}`;
        const legacy = async (surface, ...argv) => {
          const r = await ctx.cli(["browser", surface, ...argv]);
          const text = `${r.out}\n${r.err}`;
          if (r.code === 0) return "ok";
          return /browser REPL session/.test(text) && /cmux browser repl/.test(text) ? "refused" : `failed: ${text.trim().slice(0, 200)}`;
        };
        const S = ctx.session("legacy");
        let user = null;
        let workspace = null;
        try {
          await ctx.cli(["new-surface", "--type", "browser", "--url", url, "--focus", "false"]);
          const opened = await ctx.repl(ctx.wrap({ path: null, code: `const own = await tabs.open(U("/diff/lab.html"));
let row;
for (let i = 0; i < 50 && !row; i++) { row = (await tabs.list({ all: true })).find((t) => t.url === ${JSON.stringify(url)}); if (!row) await sleep(100); }
return { own: own.id, user: row ? row.id : null, workspace: row ? row.workspace : null };` }), { session: S });
          const own = opened.value?.own;
          user = opened.value?.user ?? null;
          workspace = opened.value?.workspace ?? null;
          if (!own || !user) return { error: JSON.stringify(opened).slice(0, 300) };
          const userBefore = await legacy(user, "eval", "document.title");
          const ownEval = await legacy(own, "eval", "document.title");
          const ownClick = await legacy(own, "click", "#counter");
          const ownSnapshot = await legacy(own, "snapshot");
          const listing = await ctx.cli(["browser", own, "tab", "list", "--json", "--id-format", "both"]);
          const listed = listing.code === 0 && listing.out.toLowerCase().includes(String(own).toLowerCase());
          const used = await ctx.repl(ctx.wrap({ path: null, code: `const p = await tabs.use(${JSON.stringify(user)}); return await p.title();` }), { session: S });
          const userDriven = await legacy(user, "eval", "document.title");
          await ctx.cli(["browser", "repl", "reset", S]);
          const userAfter = await legacy(user, "eval", "document.title");
          return { userBefore, ownEval, ownClick, ownSnapshot, listed, used: typeof used.value === "string", userDriven, userAfter };
        } finally {
          if (user && workspace) await ctx.cli(["close-surface", "--workspace", workspace, "--surface", user]);
        }
      },
    },
    scope: { "reference-a": "Reference A has no second client protocol beside its REPL", "reference-b": "Reference B has no second client protocol beside its REPL" },
    expect: { userBefore: "ok", ownEval: "refused", ownClick: "refused", ownSnapshot: "refused", listed: true, used: true, userDriven: "refused", userAfter: "ok" },
  },
  {
    id: "edge.sessions-two-tabs",
    edge: "sessions-two-tabs",
    custom: {
      async cmux(ctx) {
        const [a, b] = await Promise.all([
          ctx.repl(ctx.wrap({ path: null, code: MY("session A") }), { session: ctx.session("two-a") }),
          ctx.repl(ctx.wrap({ path: null, code: MY("session B") }), { session: ctx.session("two-b") }),
        ]);
        return { a: [a.value?.name, a.value?.count], b: [b.value?.name, b.value?.count], distinct: !!a.value && !!b.value && a.value.id !== b.value.id, _raw: [a.uncaught, b.uncaught] };
      },
      async "reference-a"(ctx) {
        const code = (label) => `const __p = await openTab(U("/diff/lab.html")); await page.locator("#name").fill(${JSON.stringify(label)}); for (let i = 0; i < 3; i++) { await page.locator("#counter").click(); await sleep(50); } return { id: String(__p.url()) + ${JSON.stringify(label)}, name: await page.locator("#name").inputValue(), count: await page.locator("#counter").innerText() };`;
        const { wrap } = await import("../run.mjs");
        const [a, b] = await Promise.all([ctx["reference-a"](wrap({ path: null, "reference-a": code("session A") }, "reference-a", ctx.origins)), ctx["reference-a"](wrap({ path: null, "reference-a": code("session B") }, "reference-a", ctx.origins))]);
        return { a: [a.value?.name, a.value?.count], b: [b.value?.name, b.value?.count], distinct: !!a.value && !!b.value && a.value.id !== b.value.id };
      },
    },
    scope: { "reference-b": "the reference client drives one REPL session; a second concurrent session is outside the approved harness" },
    expect: { a: ["session A", "Count 3"], b: ["session B", "Count 3"], distinct: true },
  },
  {
    id: "edge.sessions-same-tab",
    edge: "sessions-same-tab",
    custom: {
      async cmux(ctx) {
        const A = ctx.session("same-a");
        const B = ctx.session("same-b");
        const opened = await ctx.repl(ctx.wrap({ path: null, code: `const p = await tabs.open(U("/diff/lab.html")); return p.id;` }), { session: A });
        const id = opened.value;
        // Another session lists the tab as A's and cannot drive it.
        const b1 = await ctx.repl(ctx.wrap({ path: null, code: `const row = (await tabs.list({ all: true })).find((t) => t.id === ${JSON.stringify(id)}); const used = await E(() => tabs.use(${JSON.stringify(id)})); return { owned: !!(row && row.ownedBy), refused: !!used.error && /belongs to the REPL session/.test(used.error) };` }), { session: B });
        // A still drives it; concurrent calls of the one session both land.
        const both = await Promise.all([0, 1].map(() => ctx.repl(ctx.wrap({ path: null, code: `await page.locator("#counter").click(); return true;` }), { session: A })));
        const a1 = await ctx.repl(ctx.wrap({ path: null, code: `return await page.locator("#counter").innerText();` }), { session: A });
        await ctx.repl(ctx.wrap({ path: null, code: `await page.close(); return true;` }), { session: A });
        return { listedAsOther: b1.value?.owned, refused: b1.value?.refused, concurrent: both.every((r) => r.value === true), after: a1.value };
      },
    },
    na: { "reference-a": "Reference A has no named sessions; a one-shot run cannot share a tab with another session", "reference-b": "Reference B's REPL is one session per conversation" },
    expect: { listedAsOther: true, refused: true, concurrent: true, after: "Count 2" },
  },
  {
    id: "edge.web-process-crash",
    edge: "web-process-crash",
    appOnly: true,
    custom: {
      async cmux(ctx) {
        const S = ctx.session("crash");
        const first = await ctx.repl(ctx.wrap({ path: null, code: `const p = await tabs.open(U("/diff/lab.html")); await p.locator("#counter").click(); return await p._webProcessId();` }), { session: S });
        const pid = first.value;
        if (!Number.isInteger(pid) || pid <= 0) return { killed: false, _first: first };
        process.kill(pid, "SIGKILL");
        const during = await ctx.repl(ctx.wrap({ path: null, code: `const crashed = page._crashed || await Promise.race([new Promise((r) => page.once("crash", () => r(true))), sleep(3000).then(() => false)]); return { crashed, evaluate: await E(() => page.evaluate(() => 1)) };` }), { session: S });
        const after = await ctx.repl(ctx.wrap({ path: null, code: `await page.reload(); await page.locator("#counter").click(); return await page.locator("#counter").innerText();` }), { session: S });
        return { killed: true, crashed: during.value?.crashed ?? during, evaluate: during.value?.evaluate?.error ? { error: during.value.evaluate.error } : "ok", recovered: after.value ?? after };
      },
    },
    scope: { "reference-a": "killing a browser renderer process is outside the approved reference A scope", "reference-b": "killing a Chrome renderer process is outside the approved reference B scope" },
    expect: { killed: true, crashed: true, evaluate: { error: "crashed" }, recovered: "Count 1" },
  },
  {
    id: "edge.user-click-while-driving",
    edge: "user-click-while-driving",
    appOnly: true,
    // Needs a person (or computer use against the tagged app) to click while
    // it runs; the unit test lists it as unverified until such a run records
    // a result.
    requiresPerson: "run with PARITY_USER_CLICK_MARKER and click the lab page's Action button in the tagged app's pane while the case waits",
    // A person clicks the Action button in the pane (computer use against the
    // tagged app) while this session types into the name field; the session
    // sees the trusted user click and its own typing is intact.
    custom: {
      async cmux(ctx) {
        const S = ctx.session("user");
        const setup = await ctx.repl(ctx.wrap({ path: null, code: `const p = await tabs.open(U("/diff/lab.html")); await p.bringToFront(); return p.id;` }), { session: S });
        const marker = process.env.PARITY_USER_CLICK_MARKER;
        if (marker) (await import("node:fs")).writeFileSync(marker, JSON.stringify({ tab: setup.value, url: ctx.origins.primary }));
        const r = await ctx.repl(ctx.wrap({ path: null, code: `let userClick = false;
for (let i = 0; i < 600 && !userClick; i++) {
  await page.locator("#keys").pressSequentially(String(i % 10));
  userClick = (await page.evaluate(() => JSON.parse(document.body.dataset.log || "[]"))).some((r) => r[1] === "action" && r[0] === "click" && r[2]);
  if (!userClick) await sleep(100);
}
const typed = await page.locator("#keys").inputValue();
return { userClick, status: await page.locator("#status").innerText(), typedIntact: /^[0-9]+$/.test(typed) && typed.length > 0 };` }), { session: S });
        return r.value ?? r;
      },
    },
    scope: { "reference-a": "a person acting in the user's own reference A or Chrome window is outside the approved scope", "reference-b": "a person acting in the user's own reference A or Chrome window is outside the approved scope" },
    expect: { userClick: true, status: "clicked", typedIntact: true },
  },
  {
    id: "edge.context-options",
    edge: "context-options",
    appOnly: true,
    // session.configure: user agent, extra headers on navigations, granted
    // permissions, and a proxy for tabs opened afterwards (a CONNECT proxy in
    // this process that counts the tunnels it opened).
    custom: {
      async cmux(ctx) {
        const net = await import("node:net");
        const tunnels = [];
        const proxy = net.createServer((client) => {
          client.once("data", (head) => {
            const m = /^CONNECT ([^ ]+) HTTP/.exec(head.toString("latin1"));
            if (!m) return client.destroy();
            tunnels.push(m[1]);
            const [host, port] = m[1].split(":");
            const upstream = net.connect(Number(port), host === "a.lvh.me" || host === "b.lvh.me" ? "127.0.0.1" : host, () => {
              client.write("HTTP/1.1 200 Connection Established\r\n\r\n");
              upstream.pipe(client);
              client.pipe(upstream);
            });
            upstream.on("error", () => client.destroy());
          });
          client.on("error", () => {});
        });
        await new Promise((r) => proxy.listen(0, "127.0.0.1", r));
        const S = ctx.session("context");
        try {
          const r = await ctx.repl(ctx.wrap({ path: null, code: `const until = async (f) => { for (let i = 0; i < 60; i++) { const v = await f(); if (v) return v; await sleep(50); } return null; };
const configured = await session.configure({ userAgent: "cmux-parity-agent/1.0", extraHTTPHeaders: { "X-Parity": "on" }, permissions: ["notifications"] });
await page.goto(U("/headers"));
const nav = JSON.parse(await page.locator("#headers").innerText());
const asset = await until(() => page.evaluate(() => window.__assetHeaders));
const ua = await page.evaluate(() => navigator.userAgent);
const notify = await page.evaluate(() => Notification.requestPermission());
const camera = await page.evaluate(() => navigator.mediaDevices.getUserMedia({ video: true }).then(() => "granted", (e) => e.name));
await session.configure({ userAgent: null, extraHTTPHeaders: null, permissions: null });
await page.goto(U("/headers") + "?after");
const after = JSON.parse(await page.locator("#headers").innerText());
await session.configure({ proxy: { server: "http://127.0.0.1:${proxy.address().port}" } });
const proxied = await tabs.open(U("/diff/next.html", "sub"));
const proxiedTitle = await proxied.title();
await proxied.close();
await session.configure({ proxy: null });
return { configured, nav, asset, ua, notify, camera, after: { userAgent: after.userAgent === "cmux-parity-agent/1.0" ? "still set" : "restored", parity: after.parity }, proxiedTitle };` }), { session: S });
          const v = r.value ?? r;
          if (v && typeof v === "object" && "proxiedTitle" in v) v.proxied = tunnels.some((t) => t.startsWith("a.lvh.me:")) ? "through the proxy" : `direct (${tunnels.join(", ") || "no tunnels"})`;
          return v;
        } finally {
          proxy.close();
        }
      },
    },
    scope: { "reference-a": "browser-context options of a running reference A session are fixed at launch", "reference-b": "Reference B drives the user's Chrome profile and exposes no context options" },
    expect: {
      configured: { userAgent: "cmux-parity-agent/1.0", extraHTTPHeaders: { "X-Parity": "on" }, permissions: ["notifications"] },
      nav: { userAgent: "cmux-parity-agent/1.0", parity: "on" },
      asset: { userAgent: "cmux-parity-agent/1.0", parity: null },
      ua: "cmux-parity-agent/1.0",
      notify: "granted",
      camera: "NotAllowedError",
      after: { userAgent: "restored", parity: null },
      proxiedTitle: "Next page",
      proxied: "through the proxy",
    },
  },
];
