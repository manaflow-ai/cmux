// scratch: why cmuxAcpmuxDebug never appears (not committed)
import { chromium } from "./browsers";
import { servePane } from "./composer-arms";
const releases: (() => unknown)[] = [];
const port = await servePane(process.cwd(), {}, releases);
const browser = await chromium.launch({ headless: true });
const page = await browser.newPage();
page.on("console", (m) => console.log("console", m.type(), m.text().slice(0, 400)));
page.on("pageerror", (e) => console.log("pageerror", String(e).slice(0, 800)));
page.on("requestfailed", (r) => console.log("reqfail", r.url(), r.failure()?.errorText));
await page.goto(`http://127.0.0.1:${port}/?mock`);
await page.waitForTimeout(8000);
console.log("has debug:", await page.evaluate(() => "cmuxAcpmuxDebug" in window));
console.log("body:", (await page.evaluate(() => document.body.innerText)).slice(0, 300));
await browser.close();
for (const r of releases) await r();
process.exit(0);
