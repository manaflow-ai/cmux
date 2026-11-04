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
    const base = new URL(vite.resolvedUrls!.local[0]!).origin;
    const url = base + galleryFrame(s.entry, { variant: s.variant, theme: s.theme } as never);
    await page.goto(url, { waitUntil: "load" });
    await page.waitForSelector(".acpmux-row", { timeout: 60000 }).catch((e) => console.log("noready", String(e).slice(0, 120)));
    await page.waitForTimeout(1500);
    if (process.env.PROBE) console.log("PROBE", JSON.stringify(await page.evaluate(() => {
      const out: unknown[] = [];
      for (const row of [...document.querySelectorAll(".cv-sent, .cv-received > .cv-disclosure__line")].slice(0, 3)) {
        const kids = [...row.querySelectorAll("*")].filter((el) => el.getBoundingClientRect().width > 0 && el.childElementCount < 4).slice(0, 14);
        out.push({ row: row.className, w: row.getBoundingClientRect().width, kids: kids.map((el) => { const cs = getComputedStyle(el); return { c: el.className.toString().slice(0, 50), w: Math.round(el.getBoundingClientRect().width), sw: el.scrollWidth, flex: cs.flex, minw: cs.minWidth, maxw: cs.maxWidth, pad: cs.padding, disp: cs.display }; }) });
      }
      return out;
    })));
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
