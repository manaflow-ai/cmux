#!/usr/bin/env node
// Repro for the capture scene table-split-edge-drag: on the mock daemon (the app's --showcase), a reply's
// "Open table" should open the side panel beside the chat. Logs every time the panel mounts or unmounts,
// the snapshot's session id around the click, and writes before/after captures to $FAST_CHECKS_OUT.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createServer } from "vite";
import { chromium, webkit } from "playwright";

const webviews = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const out = path.join(process.env.FAST_CHECKS_OUT ?? "/tmp", "open-table");
fs.mkdirSync(out, { recursive: true });
const prompt =
  "Retried rows by failure, last 24 hours:\n\n| Failure | Retried rows |\n| --- | ---: |\n| 5xx | 412 |\n| Timeout | 187 |\n| 4xx | 23 |";
const server = await createServer({
  configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
  server: { port: 0, strictPort: false },
  logLevel: "error",
});
await server.listen();
const url = server.resolvedUrls.local[0];
let failed = false;
try {
  for (const [name, engine] of [
    ["chromium", () => chromium.launch({ channel: "chrome" })],
    ["webkit", () => webkit.launch()],
  ]) {
    const browser = await engine();
    try {
      const page = await (await browser.newContext({ viewport: { width: 1600, height: 900 } })).newPage();
      const log = [];
      page.on("console", (m) => log.push(`console.${m.type()}: ${m.text()}`));
      page.on("pageerror", (e) => log.push(`pageerror: ${e.message}`));
      await page.addInitScript(() => {
        window.cmuxAcpmuxActions = { ready: async () => ({ protocolVersion: 1, transport: "mock" }) };
        window.__panelLog = [];
        new MutationObserver(() => {
          const open = !!document.querySelector(".acpmux-artifact");
          const last = window.__panelLog.at(-1);
          if (!last || last.open !== open) window.__panelLog.push({ open, t: Math.round(performance.now()) });
        }).observe(document, { childList: true, subtree: true });
      });
      await page.goto(url, { waitUntil: "networkidle" });
      await page.waitForFunction(() => window.cmuxAcpmuxBridge && window.cmuxAcpmuxActions?.["chat.send"]);
      await page.evaluate((text) => window.cmuxAcpmuxActions["chat.send"]({ text }), prompt);
      const button = page.locator('.cv-table-block:not(.cv-user .cv-table-block) button[aria-label="Open table"]').last();
      await button.waitFor({ timeout: 20_000 });
      await page.screenshot({ path: path.join(out, `${name}-before.png`) });
      const t0 = await page.evaluate(() => Math.round(performance.now()));
      // Open and Copy take the pointer only while the table is hovered (conversation.css .cv-table-tools).
      await page.locator(".cv-table-block:not(.cv-user .cv-table-block)").last().hover();
      await button.click();
      await page.waitForTimeout(1500);
      await page.screenshot({ path: path.join(out, `${name}-after.png`) });
      const panelLog = await page.evaluate(() => window.__panelLog);
      const open = await page.locator(".acpmux-artifact").count();
      const shells = await page.evaluate(() =>
        [...document.querySelectorAll(".acpmux-shell")].map((s) => ({ children: [...s.children].map((c) => c.className) })),
      );
      const report = { engine: name, clickAt: t0, panelOpenAfter: open, panelLog, shells, log: log.slice(-40) };
      console.log(JSON.stringify(report, null, 1));
      if (!open) failed = true;
    } finally {
      await browser.close();
    }
  }
} finally {
  await server.close();
}
process.exit(failed ? 1 : 0);
