// TEMPORARY diagnostics (not committed): what moves in Settings in real Chromium.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { warmViteServer } from "./support/warmDevServer";
import { galleryFrame } from "./support/galleryFrame";

setDefaultTimeout(240_000);
const webviews = path.resolve(import.meta.dir, "..");
const { createServer } = await import("vite");
let vite: Awaited<ReturnType<typeof createServer>> | undefined;
let gallery: Awaited<ReturnType<typeof createServer>> | undefined;
let base = "";
let browser: Browser;

beforeAll(async () => {
  vite = await createServer({
    configFile: path.join(webviews, "vite.config.settings-page.mjs"),
    server: { port: 0, host: "127.0.0.1", strictPort: false },
    logLevel: "error",
  });
  await vite.listen();
  base = `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}`;
  await warmViteServer(vite, "/");
  gallery = await createServer({
    root: webviews,
    configFile: path.join(webviews, "vite.config.ts"),
    server: { port: 0, host: "127.0.0.1", strictPort: false },
    logLevel: "error",
  });
  await gallery.listen();
  browser = await chromium.launch({ headless: true });
}, 200_000);
afterAll(async () => {
  await browser?.close();
  await vite?.close();
  await gallery?.close();
});

const snapshot = (page: Page) =>
  page.evaluate(() => {
    const out: Record<string, string> = {};
    const content = document.querySelector(".content")!;
    let i = 0;
    for (const el of content.querySelectorAll<HTMLElement>("*")) {
      i++;
      if (i > 4000) break;
      const r = el.getBoundingClientRect();
      const key = `${el.tagName.toLowerCase()}.${String(el.className).slice(0, 60)}${el.dataset.rowKey ? `[${el.dataset.rowKey}]` : ""}#${i}`;
      out[key] = `${Math.round(r.top + content.scrollTop)}/${Math.round(r.height)}/${(el as HTMLElement).offsetTop}/${(el.offsetParent as HTMLElement | null)?.className?.slice?.(0, 40) ?? "null"}`;
    }
    return out;
  });
const diff = (a: Record<string, string>, b: Record<string, string>) =>
  Object.keys({ ...a, ...b })
    .filter((k) => a[k] !== b[k])
    .slice(0, 40)
    .map((k) => `${k}: ${a[k]} -> ${b[k]}`);

test("diag: open frames", async () => {
  const page = await browser.newPage({ viewport: { width: 1100, height: 760 } });
  await installPaintedFrames(page);
  await page.addInitScript(() => {
    const log: string[] = [];
    (window as unknown as { diagLog: string[] }).diagLog = log;
    let last = "";
    const tick = () => {
      const rows = [...document.querySelectorAll<HTMLElement>("[data-row-key]")].filter((r) => !r.inert).slice(0, 40);
      const first = rows[0];
      const chain: string[] = [];
      if (first) {
        // Every ancestor's previous siblings, with their heights: what sits above the first row.
        for (let node: Element | null = first; node && node !== document.body; node = node.parentElement) {
          let sib = node.previousElementSibling;
          const sibs: string[] = [];
          while (sib) {
            sibs.push(`${sib.tagName.toLowerCase()}.${String(sib.className).slice(0, 40)}=${Math.round(sib.getBoundingClientRect().height)}`);
            sib = sib.previousElementSibling;
          }
          chain.push(`${node.tagName.toLowerCase()}.${String(node.className).slice(0, 30)} pt=${getComputedStyle(node).paddingTop} mt=${getComputedStyle(node).marginTop} [${sibs.join(" ")}]`);
        }
      }
      const now = rows.slice(0, 3).map((r) => `${r.dataset.rowKey}@${r.offsetTop}`).join(",") + "\n   " + chain.join("\n   ");
      if (now !== last) log.push(`${performance.now().toFixed(0)}: ${now}`);
      last = now;
      if (performance.now() < 3000) requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  });
  await page.goto(`${base}/?mock&latency=30`);
  await page.waitForTimeout(3500);
  console.log("DIAG cold\n" + (await page.evaluate(() => (window as unknown as { diagLog: string[] }).diagLog)).join("\n"));
  await page.goto(`${base}/?mock&latency=30#/settings/editor`);
  await page.waitForTimeout(3500);
  const log = await page.evaluate(() => (window as unknown as { diagLog: string[] }).diagLog);
  console.log("DIAG editor open\n" + log.join("\n"));
  await page.close();
});

test("diag: update channel select", async () => {
  const port = (gallery!.httpServer!.address() as { port: number }).port;
  const page = await browser.newPage({ viewport: { width: 900, height: 640 }, reducedMotion: "reduce" });
  await page.goto(
    `http://127.0.0.1:${port}${galleryFrame("pages.settings", { variant: "updates", width: 900, height: 640 })}`,
  );
  await page.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 120_000 });
  const trigger = page.locator('[data-row-key="updates.channel"] .ui-select-button');
  await trigger.scrollIntoViewIfNeeded();
  await trigger.click();
  await page.waitForSelector(".ui-select-popup .ui-menu-item");
  const info = await page.evaluate(() => {
    const b = document.querySelector('[data-row-key="updates.channel"] .ui-select-button')!;
    const p = document.querySelector(".ui-select-popup")!;
    const pos = p.closest(".ui-positioner") ?? p.parentElement!;
    const br = b.getBoundingClientRect();
    const pr = p.getBoundingClientRect();
    return {
      trigger: [br.left, br.width],
      popup: [pr.left, pr.width],
      positioner: pos.getAttribute("style"),
      side: p.getAttribute("data-side"),
      align: p.getAttribute("data-align"),
      popupClass: p.className,
      html: p.outerHTML.slice(0, 1500),
    };
  });
  console.log("DIAG select " + JSON.stringify(info, null, 1));
  await page.close();
}, 200_000);
