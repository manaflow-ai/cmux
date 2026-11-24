// Records the AutoCloud status icon designs being clicked through: each design's walk-through variant,
// every simulated state, then the popover open and a switch toggle, light then dark.
// Usage: bun scripts/gallery/autocloud-status-video.mjs OUT_DIR   (writes OUT_DIR/autocloud-status.webm)
import fs from "node:fs";
import path from "node:path";
import { chromium } from "playwright";
import { preview } from "vite";

const out = path.resolve(process.argv[2] ?? process.env.FAST_CHECKS_OUT ?? "autocloud-video");
fs.mkdirSync(out, { recursive: true });
const root = path.resolve(import.meta.dir, "../..");
const server = await preview({
  root,
  configFile: path.join(root, "vite.config.gallery.ts"),
  preview: { host: "127.0.0.1", port: 0 },
});
const address = server.httpServer.address();
const base = `http://127.0.0.1:${address.port}`;
const pause = (page, ms) => page.waitForTimeout(ms);
const states = ["synced", "syncing", "offline", "warming", "active", "here", "crowd", "off"];
const browser = await chromium.launch({ channel: "chrome" }).catch(() => chromium.launch());
try {
  for (const scheme of ["light", "dark"]) {
    const context = await browser.newContext({
      viewport: { width: 300, height: 420 },
      colorScheme: scheme,
      recordVideo: { dir: path.join(out, `raw-${scheme}`), size: { width: 300, height: 420 } },
    });
    const page = await context.newPage();
    for (const design of ["glyph", "pill", "split", "strip"]) {
      const query = new URLSearchParams({
        entry: "sidebar.autocloud-status",
        variant: `${design}-walkthrough`,
        colorScheme: scheme,
        frame: "component",
        width: "normal",
      });
      await page.goto(`${base}/frame.html?${query}`, { waitUntil: "domcontentloaded" });
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
        timeout: 90_000,
      });
      await pause(page, 600);
      for (const state of states) {
        await page.locator(".acs-sim button", { hasText: new RegExp(`^${state}$`) }).click();
        await pause(page, 900);
      }
      await page.locator(".acs-sim button", { hasText: /^crowd$/ }).click();
      await pause(page, 400);
      const target = design === "split" ? page.locator(".acs-people") : page.locator(".acs-btn, .acs-pill").first();
      await target.click();
      await pause(page, 1400);
      await page
        .locator(".acs-switch")
        .click()
        .catch(() => {});
      await pause(page, 900);
      await page
        .locator(".acs-switch")
        .click()
        .catch(() => {});
      await pause(page, 600);
    }
    await context.close();
    const raw = fs.readdirSync(path.join(out, `raw-${scheme}`)).find((f) => f.endsWith(".webm"));
    fs.renameSync(path.join(out, `raw-${scheme}`, raw), path.join(out, `autocloud-status-${scheme}.webm`));
    fs.rmdirSync(path.join(out, `raw-${scheme}`));
  }
} finally {
  await browser.close();
  await server.close();
}
