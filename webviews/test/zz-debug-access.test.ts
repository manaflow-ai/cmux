// temporary debug probe (not committed)
import { afterAll, beforeAll, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
let vite: any; let browser: Browser;
beforeAll(async () => {
  const { createServer } = await import("vite");
  vite = await createServer({ configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"), server: { port: 0, host: "127.0.0.1" }, logLevel: "error" });
  await vite.listen(); browser = await chromium.launch({ headless: true });
  await warmGalleryFrame(vite, "agent-pane.composer-pickers", { browser, params: { variant: "closed" } });
}, 240_000);
afterAll(async () => { await browser?.close(); await vite?.close(); });
test("dump access menu", async () => {
  const page = await browser.newPage({ viewport: { width: 640, height: 640 } });
  const port = vite.httpServer.address().port;
  await page.goto(`http://127.0.0.1:${port}${galleryFrame("agent-pane.composer-pickers", { variant: "closed", frame: "component", width: 640, theme: "Catppuccin Mocha" })}`);
  await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, { timeout: 120_000 });
  await page.getByRole("button", { name: "Mode", exact: true }).click();
  await page.locator(".acpmux-access-grants .acpmux-access-grant").first().waitFor();
  const out = await page.evaluate(() => {
    const m = document.querySelector(".acpmux-access-menu")!; const e = m.getBoundingClientRect();
    const r = (el: Element | null) => { if (!el) return null; const b = el.getBoundingClientRect(); const cs = getComputedStyle(el); return { l: b.left - e.left, r: e.right - b.right, w: b.width, pl: cs.paddingInlineStart, mis: cs.minInlineSize, cls: el.className }; };
    return { menu: { w: e.width, cls: m.className }, rows: [...m.querySelectorAll(".acpmux-access-item")].map((row) => ({ row: r(row), sc: r(row.querySelector(".ui-menu-shortcut")), ck: r(row.querySelector(".ui-menu-check")), tx: r(row.querySelector(".acpmux-menu-text")) })), grants: r(m.querySelector(".acpmux-access-grants")), grant: r(m.querySelector(".acpmux-access-grant")), x: r(m.querySelector(".acpmux-access-grant-remove")) };
  });
  console.log("DEBUG-ACCESS " + JSON.stringify(out));
  await page.close();
}, 240_000);
