// Page events for console, errors, requests; cookie-bearing fetch.
await openTab(`${PRIMARY}/dynamic.html`);
const events = [];
page.on("console", (m) => events.push(`console:${m.type()}:${m.text()}`));
page.on("pageerror", (e) => events.push(`pageerror:${e.message}`));
page.on("request", (r) => { if (r.url().includes("/api/")) events.push(`request:${r.method()}:${new URL(r.url()).pathname}`); });
page.on("response", (r) => { if (r.url().includes("/api/")) events.push(`response:${r.status()}`); });
await page.locator("#log").click();
await page.locator("#fetch").click();
await page.waitForFunction(() => document.getElementById("net").textContent.startsWith("fetched"));
await sleep(200);
emit("events", events.sort());
const res = await fetch(`${PRIMARY}/api/data?q=repl`);
emit("repl-fetch", await res.json());
