// TEMP probe (not committed): screenshots and measures running-turn bottoms.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";

setDefaultTimeout(400_000);
const SCENES = (process.env.PROBE_SCENES ?? "agent-pane.transcript-spacing-table:working-bottom").split(",");
const webviews = path.resolve(import.meta.dir, "..");
let vite: any;
let browser: Browser;
beforeAll(async () => {
  const { createServer } = await import("vite");
  vite = await createServer({
    configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
    server: { port: 0, host: "127.0.0.1", strictPort: false },
    logLevel: "error",
  });
  await vite.listen();
  browser = await chromium.launch({ headless: true });
});
afterAll(async () => {
  await browser?.close();
  await vite?.close();
});
test("probe", async () => {
  const out = process.env.FAST_CHECKS_OUT ?? "/tmp/probe";
  await mkdir(out, { recursive: true });
  for (const scene of SCENES) {
    const [entry, variant] = scene.split(":");
    await warmGalleryFrame(vite, entry!, { browser, params: { variant } });
    for (const theme of ["Catppuccin Mocha", "Apple System Colors Light"]) {
      const page = await browser.newPage({ viewport: { width: 760, height: 900 }, deviceScaleFactor: 2 });
      const port = vite.httpServer.address().port;
      await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry!, { variant, width: 560, theme })}`);
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
        timeout: 200_000,
      });
      await page.evaluate(() => document.fonts.ready);
      await page.waitForTimeout(800);
      const rows = await page.evaluate(() =>
        [...document.querySelectorAll<HTMLElement>(".acpmux-row")].map((row) => {
          const box = row.getBoundingClientRect();
          const icon = row.querySelector(".cv-tool__icon, .cv-received__mark, .cv-pending__icon, .cv-worked__glyph");
          const ib = icon?.getBoundingClientRect();
          const walker = document.createTreeWalker(row, NodeFilter.SHOW_TEXT);
          const texts: string[] = [];
          for (let n = walker.nextNode(); n; n = walker.nextNode()) {
            if (!n.textContent?.trim() || icon?.contains(n)) continue;
            const r = document.createRange();
            r.selectNodeContents(n);
            const f = [...r.getClientRects()].find((x) => x.width > 0);
            if (f) texts.push(`${Math.round((f.left - box.left) * 10) / 10}@${Math.round(f.top - box.top)}:${n.textContent.trim().slice(0, 30)}`);
          }
          return {
            cls: row.className.slice(0, 90),
            top: Math.round(box.top),
            h: Math.round(box.height),
            icon: ib ? `${Math.round((ib.left - box.left) * 10) / 10}+${Math.round(ib.width)}` : "-",
            texts: texts.slice(0, 6),
          };
        }),
      );
      const name = `${variant}-${theme.startsWith("Cat") ? "dark" : "light"}`;
      await writeFile(path.join(out, `${name}.json`), JSON.stringify(rows, null, 2));
      console.log(name, JSON.stringify(rows, null, 1));
      await page.screenshot({ path: path.join(out, `${name}.png`), fullPage: true });
      await page.close();
    }
  }
  expect(true).toBe(true);
});
