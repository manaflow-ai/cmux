// TEMPORARY measurement for the strip's narrow-label breakpoints; removed before landing.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { warmViteServer } from "./support/warmDevServer";

setDefaultTimeout(600_000);
const webviews = path.resolve(import.meta.dir, "..");
const out = process.env.FAST_CHECKS_OUT ?? path.join(webviews, ".strip-measure");
fs.mkdirSync(out, { recursive: true });
const ENTRY_PATHS: Record<string, string> = {
  "agent-pane.composer-strip": "src/agent-session/acpmux/composerStrip.gallery.ts",
  "agent-pane.composer-context": "src/agent-session/acpmux/ComposerContext.gallery.tsx",
};
let vite: any;
let browser: Browser;
const url = (entry: string, variant: string) =>
  `http://127.0.0.1:${vite.httpServer.address().port}/gallery/frame.html?entry=${entry}&entryPath=${ENTRY_PATHS[entry]}&variant=${variant}`;
beforeAll(async () => {
  const { createServer } = await import("vite");
  vite = await createServer({
    configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
    server: { port: 0, host: "127.0.0.1", strictPort: false },
    logLevel: "error",
  });
  await vite.listen();
  for (const file of [...Object.values(ENTRY_PATHS), "src/gallery/frame/agentPane.ts", "src/gallery/frame/component.tsx"])
    await warmViteServer(vite, `/gallery/${file}`);
  browser = await chromium.launch({ headless: true });
  const warm = await browser.newPage({ viewport: { width: 720, height: 400 } });
  await warm.goto(url("agent-pane.composer-strip", "project"));
  for (;;) {
    try {
      await warm.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 0 });
      break;
    } catch (error) {
      if (!/context was destroyed|navigat/i.test(String(error))) throw error;
    }
  }
  await warm.close();
});
afterAll(async () => {
  await browser?.close();
  await vite?.close();
});

function measure() {
  const strip = document.querySelector<HTMLElement>(".acpmux-composer-strip")!;
  const cs = getComputedStyle(strip);
  const content = strip.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight);
  const chips = [...strip.querySelectorAll<HTMLElement>(".acpmux-location-picker")].map((p) => {
    const label = p.querySelector<HTMLElement>(".acpmux-location-label");
    let clipped: boolean | null = null;
    if (label && getComputedStyle(label).display !== "none") {
      const r = document.createRange();
      r.selectNodeContents(label);
      clipped = r.getBoundingClientRect().width > label.getBoundingClientRect().width + 0.01;
    }
    return {
      rows: p.dataset.rows ?? null,
      kind: p.dataset.kind ?? null,
      text: label?.textContent ?? null,
      shown: label ? getComputedStyle(label).display !== "none" : null,
      clipped,
      width: +p.getBoundingClientRect().width.toFixed(2),
      labelWidth: label ? +label.getBoundingClientRect().width.toFixed(2) : null,
    };
  });
  // Natural need: every label shown, nothing shrinks.
  const style = document.createElement("style");
  style.textContent = `.acpmux-location-label{display:inline-flex!important}
    .acpmux-composer-strip{width:max-content!important}
    .acpmux-composer-context,.acpmux-location-leading{flex:none!important;width:max-content!important}
    .acpmux-location-picker{flex:none!important}
    .acpmux-location-button,.acpmux-location-readonly{max-width:none!important}
    .acpmux-composer-context > .acpmux-location-picker:last-child{max-width:none!important;margin-left:0!important}`;
  document.head.append(style);
  const ctx = strip.querySelector<HTMLElement>(".acpmux-composer-context")!;
  const naturalChips = [...strip.querySelectorAll<HTMLElement>(".acpmux-location-picker")].map((p) => ({
    rows: p.dataset.rows ?? null,
    width: +p.getBoundingClientRect().width.toFixed(2),
    label: +(p.querySelector(".acpmux-location-label")?.getBoundingClientRect().width ?? 0).toFixed(2),
  }));
  const ctxNatural = +ctx.getBoundingClientRect().width.toFixed(2);
  style.remove();
  return { viewport: innerWidth, stripOuter: strip.getBoundingClientRect().width, content, chips, naturalChips, ctxNatural, text: strip.textContent };
}

const cases = [
  ["agent-pane.composer-context", "strip-where-machine"],
  ["agent-pane.composer-context", "strip-where-machine-cloud"],
  ["agent-pane.composer-context", "strip-where-machine-machine-picked"],
  ["agent-pane.composer-context", "strip-combined"],
  ["agent-pane.composer-strip", "project"],
  ["agent-pane.composer-strip", "no-project"],
  ["agent-pane.composer-strip", "mid-folder"],
] as const;
const widths = [300, 320, 340, 360, 380, 400, 420, 430, 440, 460, 461, 480, 520];

test("measure", async () => {
  const results: unknown[] = [];
  for (const [entry, variant] of cases)
    for (const width of widths) {
      const page = await browser.newPage({ viewport: { width, height: 360 }, deviceScaleFactor: 2 });
      await page.goto(url(entry, variant));
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      await page.evaluate(() => document.fonts.ready);
      await page.locator(".acpmux-composer-strip .acpmux-location-picker").first().waitFor();
      const m = await page.evaluate(measure);
      results.push({ entry, variant, width, ...m });
      if ([320, 360, 400, 430, 460].includes(width))
        await page.locator(".acpmux-composer-strip").screenshot({ path: path.join(out, `${variant}-${entry.split(".")[1]}-${width}.png`) });
      await page.close();
    }
  fs.writeFileSync(path.join(out, "measure.json"), JSON.stringify(results, null, 1));
  for (const r of results as any[])
    console.log(
      `${r.variant.padEnd(36)} ${r.width} content=${r.content.toFixed(1)} need=${r.ctxNatural} ` +
        r.chips.map((c: any) => `[${c.rows ?? c.kind}:${c.text}${c.shown ? "" : "(hidden)"}${c.clipped ? "(clipped)" : ""} ${c.width}]`).join(" ") +
        " natural " + r.naturalChips.map((c: any) => `${c.rows}:${c.width}/${c.label}`).join(" "),
    );
  expect(results.length).toBeGreaterThan(0);
});
