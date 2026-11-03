// Scratch capture (not committed): screenshots gallery states into $OUT.
import path from "node:path";
import { mkdirSync } from "node:fs";
import { chromium } from "playwright";
import { galleryFrame, warmGalleryFrame } from "../test/support/galleryFrame";

const OUT = process.env.OUT ?? "/tmp/msgrows-shots";
mkdirSync(OUT, { recursive: true });
const SCENES = (process.env.SCENES ?? "").split(",").filter(Boolean).map((s) => {
  const [entry, variant, theme] = s.split(":");
  return { entry: entry!, variant: variant!, theme: theme ?? "dark" };
});
const webviews = path.resolve(import.meta.dir, "..");
const { createServer } = await import("vite");
const vite = await createServer({
  configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
  server: { port: 0, host: "127.0.0.1", strictPort: false },
  logLevel: "error",
});
await vite.listen();
const browser = await chromium.launch({ headless: true });
for (const s of SCENES) {
  try {
    await warmGalleryFrame(vite, s.entry, { browser, params: { variant: s.variant } });
    const page = await browser.newPage({ viewport: { width: Number(process.env.W ?? 760), height: 900 }, deviceScaleFactor: 2, colorScheme: s.theme === "light" ? "light" : "dark" });
    const base = vite.resolvedUrls!.local[0]!.replace(/\/$/, "");
    const url = base + galleryFrame(s.entry, { variant: s.variant, theme: s.theme } as never);
    await page.goto(url, { waitUntil: "load" });
    await page.waitForSelector("[data-gallery-ready], .acpmux-row", { timeout: 60000 }).catch(() => {});
    await page.waitForTimeout(1500);
    const file = path.join(OUT, `${s.entry}--${s.variant}--${s.theme}.png`);
    await page.screenshot({ path: file, fullPage: true });
    console.log("shot", file, url);
    await page.close();
  } catch (e) {
    console.log("FAIL", s.entry, s.variant, String(e).slice(0, 300));
  }
}
await browser.close();
await vite.close();
process.exit(0);
