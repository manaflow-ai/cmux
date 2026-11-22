// Temporary measuring harness for the transcript tuck (not committed).
import { mkdirSync } from "node:fs";
import path from "node:path";
import { chromium } from "playwright";
import { galleryFrame, warmGalleryFrame } from "../test/support/galleryFrame";

const webviews = path.resolve(import.meta.dir, "..");
const out = process.argv[2] ?? "/tmp/tuck";
const shots = (process.env.SHOTS ?? "1") === "1";
const specs = (process.argv[3] ?? "agent-pane.claude-desktop-organization:mixed-claude").split(",");
const widths = (process.env.WIDTHS ?? "1100,420").split(",").map(Number);
mkdirSync(out, { recursive: true });
const { createServer } = await import("vite");
const vite = await createServer({
  configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
  server: { port: 0, host: "127.0.0.1", strictPort: false },
  logLevel: "error",
});
await vite.listen();
const browser = await chromium.launch({ headless: true });
await warmGalleryFrame(vite, [...new Set(specs.map((s) => s.split(":")[0]!))], { browser });
const port = (vite.httpServer!.address() as { port: number }).port;
for (const spec of specs) {
  const [entry, variant] = spec.split(":");
  for (const width of widths) {
    const page = await browser.newPage({ viewport: { width, height: Number(process.env.H ?? 900) }, deviceScaleFactor: 2 });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry!, { variant, width })}`);
    await page.locator(".acpmux-composer-box").first().waitFor({ timeout: 90_000 });
    if (process.env.INJECT) await page.addStyleTag({ path: process.env.INJECT });
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, { timeout: 60_000 }).catch(() => {});
    await page.waitForTimeout(600);
    const m = await page.evaluate(() => {
      const box = document.querySelector(".acpmux-composer-box")!.getBoundingClientRect();
      const plus = document.querySelector(".acpmux-composer-box .acpmux-plus svg, .acpmux-composer-box [data-composer-plus] svg, .acpmux-composer-box button svg");
      const pr = plus?.getBoundingClientRect();
      const inkLeft = (el: Element) => {
        let best = Infinity;
        const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT);
        let n: Node | null = walker.currentNode;
        while ((n = walker.nextNode())) {
          if (n.nodeType === 3) {
            if (!n.textContent?.trim()) continue;
            const r = document.createRange();
            r.selectNodeContents(n);
            for (const rect of r.getClientRects()) if (rect.width > 0) best = Math.min(best, rect.left);
          } else if ((n as Element).tagName === "svg" || (n as Element).tagName === "IMG") {
            const r = (n as Element).getBoundingClientRect();
            if (r.width > 0 && getComputedStyle(n as Element).visibility !== "hidden") best = Math.min(best, r.left);
          }
        }
        return best;
      };
      const rows = [...document.querySelectorAll(".acpmux-row:not(.acpmux-user)")].map((row) => ({
        cls: row.className.toString().split(" ").filter((c) => c !== "acpmux-row").slice(0, 2).join("."),
        box: Math.round(row.getBoundingClientRect().left * 10) / 10,
        ink: Math.round(inkLeft(row) * 10) / 10,
      })).filter((r) => Number.isFinite(r.ink));
      const tray = document.querySelector(".acpmux-dock > .acpmux-running-tray")?.getBoundingClientRect();
      const cs = getComputedStyle(document.querySelector(".acpmux-composer-box")!);
      return {
        composerLeft: box.left, composerRight: box.right, plusInk: pr?.left, plusCenter: pr ? (pr.left + pr.right) / 2 : null,
        radius: cs.borderTopLeftRadius + "/" + cs.borderBottomLeftRadius,
        trayRadius: tray ? getComputedStyle(document.querySelector(".acpmux-dock > .acpmux-running-tray")!).borderTopLeftRadius : null,
        rows,
      };
    });
    console.log(JSON.stringify({ entry, variant, width, ...m }));
    if (shots) await page.screenshot({ path: path.join(out, `${entry}-${variant}-${width}.png`) });
    await page.close();
  }
}
await browser.close();
await vite.close();
process.exit(0);
