// Page events for console, errors and requests; console and error history;
// fetch with the tab's cookies.
await page.goto(`${PRIMARY}/dynamic.html`);
const events = [];
page.on("console", (m) => events.push(`console:${m.type()}:${m.text()}`));
page.on("pageerror", (e) => events.push(`pageerror:${e.message}`));
page.on("request", (r) => { if (r.url().includes("/api/")) events.push(`request:${r.method()}:${new URL(r.url()).pathname}`); });
page.on("response", (r) => { if (r.url().includes("/api/")) events.push(`response:${r.status()}`); });
await page.locator("#log").click();
await page.locator("#fetch").click();
await page.waitForFunction(() => document.getElementById("net").textContent.startsWith("fetched"));
await sleep(300);
emit("events", events.sort());
const all = await page.consoleMessages();
emit("history", all.map((m) => `${m.type()}:${m.text()}`).filter((t) => t.includes("parity")));
emit("history-level", (await page.consoleMessages({ level: "warning" })).map((m) => m.text()));
emit("history-warn-alias", (await page.consoleMessages({ level: "warn" })).map((m) => m.text()));
emit("history-filter", (await page.consoleMessages({ filter: /error/ })).map((m) => m.text()));
emit("history-limit", (await page.consoleMessages({ limit: 1 })).length);
emit("errors", (await page.errors()).map((e) => e.message));
await page.goto(`${PRIMARY}/set-cookie`);
const res = await fetch(`/api/data?q=repl`);
emit("fetch-json", await res.json());
emit("fetch-status", [res.ok, res.status, res.headers.get("content-type")]);
const cookies = await page.context().cookies();
emit("cookie-set", cookies.some((c) => c.name === "parity" && c.value === "1"));
// Whether the page's cookie went with the request. A real profile has other
// localhost cookies, so the whole header is not compared, and no cookie
// value is printed.
emit("fetch-sends-cookies", String((await (await fetch(`${PRIMARY}/echo-cookie`)).json()).cookie || "").split(/;\s*/).includes("parity=1"));
