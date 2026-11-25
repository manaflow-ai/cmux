import { chromium } from "playwright";
const b = await chromium.launch();
const p = await b.newPage({ viewport: { width: 560, height: 420 }, deviceScaleFactor: 2 });
for (const v of ["notices-before", "notices", "notices-look-tint", "notices-look-trailing", "notices-open"]) {
  await p.goto(`http://127.0.0.1:5199/gallery/frame.html?entry=agent-pane.inbox-notice&variant=${v}`, { waitUntil: "load", timeout: 240000 });
  const head = p.getByText(/Received \d+ messages/).first();
  await head.waitFor({ timeout: 240000 });
  await head.click();
  await p.waitForTimeout(1500);
  if (v === "notices-open") { await p.locator(".cv-notice .cv-agentmsg__toggle").first().click().catch(e => console.log("toggle", String(e).slice(0, 80))); await p.waitForTimeout(1500); }
  await p.screenshot({ path: `/tmp/notice-shots/${v}.png` });
  console.log(v, await p.locator(".cv-notice").count(), await p.locator(".cv-notice__repeats").allTextContents());
}
await b.close();
