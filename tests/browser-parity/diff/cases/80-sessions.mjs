// Sessions, concurrency, crashes and the user acting in a driven pane.
// These run as custom flows: several REPL calls, in parallel where the case
// is about concurrency.
const MY = (label) => `await page.goto(U("/diff/lab.html"));
await page.locator("#name").fill(${JSON.stringify(label)});
for (let i = 0; i < 3; i++) { await page.locator("#counter").click(); await sleep(50); }
return { id: page.id, name: await page.locator("#name").inputValue(), count: await page.locator("#counter").innerText() };`;

export default [
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
        const b1 = await ctx.repl(ctx.wrap({ path: null, code: `const p = await tabs.use(${JSON.stringify(id)}); await p.locator("#counter").click(); return await p.locator("#counter").innerText();` }), { session: B });
        const a1 = await ctx.repl(ctx.wrap({ path: null, code: `return await page.locator("#counter").innerText();` }), { session: A });
        // Both sessions click at once: both clicks land, neither is lost.
        const both = await Promise.all([A, B].map((s) => ctx.repl(ctx.wrap({ path: null, code: `await page.locator("#counter").click(); return true;` }), { session: s })));
        const a2 = await ctx.repl(ctx.wrap({ path: null, code: `return await page.locator("#counter").innerText();` }), { session: A });
        // The owner closes the tab; the other session's page reports closed.
        await ctx.repl(ctx.wrap({ path: null, code: `await page.close(); return true;` }), { session: A });
        const b2 = await ctx.repl(ctx.wrap({ path: null, code: `return await E(() => page.title());` }), { session: B });
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
