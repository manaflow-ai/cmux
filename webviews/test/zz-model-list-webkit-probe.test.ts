// TEMPORARY probe for cmuxterm-hq#7707 (never merged): the Model column's rows in WebKit, and what
// elementFromPoint finds at each row's trailing edge, under several style variants.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { webkit, chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";

setDefaultTimeout(400_000);
const webviews = path.resolve(import.meta.dir, "..");
let vite: any;
const browsers: Record<string, Browser> = {};

beforeAll(async () => {
  const { createServer } = await import("vite");
  vite = await createServer({
    configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
    server: { port: 0, host: "127.0.0.1", strictPort: false },
    logLevel: "error",
  });
  await vite.listen();
  browsers.webkit = await webkit.launch({ headless: true });
  browsers.chromium = await chromium.launch({ headless: true });
  await warmGalleryFrame(vite, "agent-pane.composer", { browser: browsers.chromium, params: { variant: "picker-toggle" } });
});
afterAll(async () => {
  for (const b of Object.values(browsers)) await b.close();
  await vite?.close();
});

const VARIANTS: Record<string, string> = {
  base: "",
  noMask: ".acpmux-cols-list { -webkit-mask: none !important; mask: none !important; }",
  scrollY: ".acpmux-cols-list[data-cmux-card-scroll] { overflow-y: scroll !important; }",
  noScrollbar: ".acpmux-cols-list::-webkit-scrollbar { display: none !important; width: 0 !important; }",
  rowsMaxWidth: ".acpmux-cols-list > * { max-width: 100% !important; box-sizing: border-box !important; }",
  listContain: ".acpmux-cols-list { contain: inline-size !important; }",
  noMinWidth: "",
};

for (const engine of ["webkit", "chromium"])
  for (const [variant, css] of Object.entries(VARIANTS))
    test(`${engine} ${variant}`, async () => {
      const port = vite.httpServer.address().port;
      const page = await browsers[engine]!.newPage({ viewport: { width: 760, height: 600 } });
      if (css) await page.addInitScript((css) => {
        addEventListener("DOMContentLoaded", () => {
          const s = document.createElement("style");
          s.textContent = css;
          document.head.appendChild(s);
        });
      }, css);
      await page.goto(`http://127.0.0.1:${port}${galleryFrame("agent-pane.composer", { variant: "new-chat-reasoning", frame: "component", width: 760, theme: "Catppuccin Mocha" })}`);
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, { timeout: 120_000 });
      const chip = page.locator('button[aria-haspopup][aria-label="Model"]').first();
      await chip.waitFor();
      await page.evaluate(() => document.fonts.ready);
      const box = (await chip.boundingBox())!;
      await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
      await page.mouse.down();
      await page.mouse.up();
      await page.waitForFunction(() => document.querySelector('button[aria-haspopup][aria-label="Model"]')?.getAttribute("aria-expanded") === "true");
      await page.waitForTimeout(800);
      console.log(`PROBE-DOM ${engine} ${variant} ${await page.evaluate(() => [...new Set([...document.querySelectorAll('[role^="menuitem"], [role="option"]')].map((r) => `${r.getAttribute("role")}<${r.parentElement?.className}>`))].join(" | "))}`);
      if (variant === "noMinWidth")
        await page.evaluate(() => {
          for (const el of document.querySelectorAll<HTMLElement>("[style*=min-width]")) el.style.minWidth = "";
        });
      const report = await page.evaluate(() => {
        const list = (document.querySelector<HTMLElement>('.acpmux-cols-list[data-cmux-card-scroll]') ?? [...document.querySelectorAll<HTMLElement>('[role^="menuitem"], [role="option"]')].map((r) => { let e = r.parentElement; while (e && e !== document.body && !/(auto|scroll)/.test(getComputedStyle(e).overflowY)) e = e.parentElement; return e; }).find((e) => e && e !== document.body)) as HTMLElement | undefined;
        if (!list) return { error: "no list" };
        const lb = list.getBoundingClientRect();
        const cs = getComputedStyle(list);
        const rows = [...list.querySelectorAll<HTMLElement>('[role^="menuitem"], [role="option"]')];
        const out: any = {
          list: { x: lb.x, w: lb.width, offsetW: list.offsetWidth, clientW: list.clientWidth, scrollW: list.scrollWidth, scrollLeft: list.scrollLeft, padL: cs.paddingLeft, padR: cs.paddingRight, borderR: cs.borderRightWidth, attrs: [...list.attributes].map((a) => a.name).join(" "), cls: list.className, scroller: getComputedStyle(list, "::-webkit-scrollbar").width },
          rows: [] as any[],
        };
        for (const row of rows.slice(0, 14)) {
          row.scrollIntoView({ block: "nearest", inline: "nearest" });
          const b = row.getBoundingClientRect();
          const y = b.y + b.height / 2;
          const at = document.elementFromPoint(b.x + b.width - 1, y);
          out.rows.push({ w: +b.width.toFixed(2), right: +(b.x + b.width).toFixed(2), scrollLeft: list.scrollLeft, hit: !!at && row.contains(at), at: at ? `${at.tagName}.${at.className}`.slice(0, 50) : null, rowCss: getComputedStyle(row).width });
        }
        return out;
      });
      console.log(`PROBE ${engine} ${variant} ${JSON.stringify(report)}`);
      await page.close();
      expect(true).toBe(true);
    });
