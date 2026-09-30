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
    members: ["chatgpt:BrowserUser.claimTab", "chatgpt:BrowserUser.openTabs"],
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
      async chatgpt({ c, origins }) {
        await c.js(`var __u=await rb.tabs.new(); await __u.goto(${JSON.stringify(origins.primary + "/diff/lab.html")});`);
        const v = await c.value(`(async()=>{ const row=(await rb.user.openTabs()).find((x)=>x.id===__u.id); const t2=await rb.user.claimTab(row); await t2.playwright.locator("#counter").click(); return { listedAll: !!row, inOwnList: false, otherWorkspace: true, count: await t2.playwright.locator("#counter").innerText() }; })()`);
        return v;
      },
    },
    na: { aside: "Aside has no user-tab claim; attachBrowserTab is covered by tabs.attach" },
    compare: ["listedAll", "count"],
    expect: { listedAll: true, inOwnList: false, otherWorkspace: true, count: "Count 1" },
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
      async aside(ctx) {
        const code = (label) => `const __p = await openTab(U("/diff/lab.html")); await page.locator("#name").fill(${JSON.stringify(label)}); for (let i = 0; i < 3; i++) { await page.locator("#counter").click(); await sleep(50); } return { id: String(__p.url()) + ${JSON.stringify(label)}, name: await page.locator("#name").inputValue(), count: await page.locator("#counter").innerText() };`;
        const { wrap } = await import("../run.mjs");
        const [a, b] = await Promise.all([ctx.aside(wrap({ path: null, aside: code("session A") }, "aside", ctx.origins)), ctx.aside(wrap({ path: null, aside: code("session B") }, "aside", ctx.origins))]);
        return { a: [a.value?.name, a.value?.count], b: [b.value?.name, b.value?.count], distinct: !!a.value && !!b.value && a.value.id !== b.value.id };
      },
    },
    scope: { chatgpt: "the reference client drives one REPL session; a second concurrent session is outside the approved harness" },
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
        const b1 = await ctx.repl(ctx.wrap({ path: null, code: `globalThis.shared = await tabs.use(${JSON.stringify(id)}); await shared.locator("#counter").click(); return await shared.locator("#counter").innerText();` }), { session: B });
        const a1 = await ctx.repl(ctx.wrap({ path: null, code: `return await page.locator("#counter").innerText();` }), { session: A });
        // Both sessions click at once: both clicks land, neither is lost.
        const both = await Promise.all([A, B].map((s) => ctx.repl(ctx.wrap({ path: null, code: `await page.locator("#counter").click(); return true;` }), { session: s })));
        const a2 = await ctx.repl(ctx.wrap({ path: null, code: `return await page.locator("#counter").innerText();` }), { session: A });
        // The owner closes the tab; the other session's page reports closed.
        await ctx.repl(ctx.wrap({ path: null, code: `await page.close(); return true;` }), { session: A });
        const b2 = await ctx.repl(ctx.wrap({ path: null, code: `return await E(() => shared.title());` }), { session: B });
        return { bSaw: b1.value, aSaw: a1.value, concurrent: both.every((r) => r.value === true), after: a2.value, closedForB: b2.value?.error ? { error: b2.value.error } : "open" };
      },
    },
    na: { aside: "Aside has no named sessions; a one-shot run cannot share a tab with another session", chatgpt: "ChatGPT's REPL is one session per conversation" },
    expect: { bSaw: "Count 1", aSaw: "Count 1", concurrent: true, after: "Count 3", closedForB: { error: "closed" } },
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
    scope: { aside: "killing a browser renderer process is outside the approved Aside scope", chatgpt: "killing a Chrome renderer process is outside the approved ChatGPT scope" },
    expect: { killed: true, crashed: true, evaluate: { error: "crashed" }, recovered: "Count 1" },
  },
  {
    id: "edge.user-click-while-driving",
    edge: "user-click-while-driving",
    appOnly: true,
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
    scope: { aside: "a person acting in the user's own Aside or Chrome window is outside the approved scope", chatgpt: "a person acting in the user's own Aside or Chrome window is outside the approved scope" },
    expect: { userClick: true, status: "clicked", typedIntact: true },
  },
];
