// A closing popover, menu, tooltip or hover card leaves no trace where it was (Leo, 2026-11-11, of
// the context window card over the composer: "the fade-in, the fade-out, is just so stupid... It
// just looks so bad when it's so slow like this... sometimes you get this trace of something").
// Each surface closes the way Base UI closes it: it takes `data-ending-style` and stays mounted until
// its transitions end. The frame painted right after the close starts must be the page as it is with
// no surface at all: no fading card, no glass, no shadow, no backdrop blur.
//
// The page is the real shared stylesheets (pages/shared/desktop.css, ui/popupSurface.css, ui/ui.css,
// ui/glass/glass.css) in Chromium, over bars of ink, each surface as its component draws it.
// The page's animation clock is stopped as the close starts (CDP Animation.setPlaybackRate 0), so the
// frame read is the close's first, as a person sees it, whatever a screenshot costs. Screenshots are
// frames Chromium painted; a surface is read in its own rect and its shadow's reach,
// against the same page with the surface there but hidden (so the page's own layers, and its text's
// antialiasing, are the same in both).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { PNG } from "pngjs";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("popover-close-trace.test.ts", async () => {
  setDefaultTimeout(120_000);
  const source = path.resolve(import.meta.dir, "../src");
  const css = ["pages/shared/desktop.css", "ui/popupSurface.css", "ui/ui.css", "ui/glass/glass.css"]
    .map((file) => fs.readFileSync(path.join(source, file), "utf8"))
    .join("\n")
    .replace(/^@import .*$/gm, "");

  let browser: Browser;
  try {
    browser = await chromium.launch({ headless: true });
    await browser.close();
  } catch {
    describe.skip("popover close trace", () => test("chromium", () => {}));
    return;
  }
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => browser?.close());

  const theme =
    "--cmux-surface-solid:rgb(30, 30, 46);--cmux-popup-surface:rgb(52, 49, 68);--cmux-text:rgb(224, 222, 244);" +
    "--cmux-separator:rgba(128, 128, 128, 0.25);--cmux-tooltip-tint:rgba(52, 49, 68, 0.9)";
  // What the surface covers: bars of the chat's ink, not text, whose antialiasing Chromium may
  // switch when a layer comes or goes over it. A blur, a tint or a shadow left behind shows on their
  // edges as surely as on text.
  const text = Array.from(
    { length: 14 },
    (_, n) =>
      `<div style="height:8px;margin:0 0 13px;width:${220 + ((n * 37) % 160)}px;background:var(--cmux-text)"></div>`,
  ).join("");

  /// Each surface as its component mounts it, placed over the page's text.
  const SURFACES: Record<string, string> = {
    // ui/Tooltip.tsx AnchoredCard: the context window card, a link or pull request card.
    "hover card": `<div class="ui-tooltip ui-card ui-glass" role="dialog" style="width:260px;height:140px">Context window</div>`,
    // ui/Popover.tsx, ui/Menu.tsx: the composer's pickers, the header's ... menu.
    popover: `<div class="ui-popup ui-popover ui-glass" style="width:260px;height:140px">Model</div>`,
    menu: `<div class="ui-popup ui-menu ui-glass" role="menu" style="width:200px;height:120px">Open</div>`,
    // ui/Tooltip.tsx Tooltip and ui/titleTooltips.ts.
    tooltip: `<div class="ui-tooltip ui-glass" role="tooltip">Send</div>`,
    "title tooltip": `<div class="ui-title-tooltip ui-glass">Context window</div>`,
  };

  async function open(surface: string): Promise<Page> {
    const page = await browser.newPage({ viewport: { width: 480, height: 320 }, deviceScaleFactor: 1 });
    await page.setContent(
      `<!doctype html><html style="${theme}"><head><style>${css}</style></head>
       <body style="margin:0;padding:12px;background:var(--cmux-surface-solid);color:var(--cmux-text);font:13px sans-serif">
         ${text}
         <div id="host" style="position:fixed;left:60px;top:60px">${surface}</div>
       </body></html>`,
    );
    return page;
  }

  /// The pixels in `rect`, as RGBA.
  const pixels = (png: Buffer, rect: { x: number; y: number; width: number; height: number }) => {
    const image = PNG.sync.read(png);
    const out: number[] = [];
    for (let y = rect.y; y < rect.y + rect.height; y++)
      for (let x = rect.x; x < rect.x + rect.width; x++) {
        const at = (y * image.width + x) * 4;
        out.push(image.data[at]!, image.data[at + 1]!, image.data[at + 2]!);
      }
    return out;
  };

  for (const [name, markup] of Object.entries(SURFACES))
    for (const reducedMotion of ["no-preference", "reduce"] as const)
      test(`a ${name} leaves no ink where it was in the frame its close starts (${reducedMotion})`, async () => {
        const page = await open(markup);
        try {
          await page.emulateMedia({ reducedMotion });
          const surface = page.locator("#host > *");
          const box = (await surface.boundingBox())!;
          // The rect with its shadow's reach.
          const rect = {
            x: Math.max(0, Math.floor(box.x) - 8),
            y: Math.max(0, Math.floor(box.y) - 8),
            width: Math.ceil(box.width) + 16,
            height: Math.ceil(box.height) + 16,
          };
          // The page with nothing of the surface drawn: what must show once it closes. Hidden, not
          // removed, so the page keeps the same layers and its text the same antialiasing.
          await surface.evaluate((element) =>
            (element as HTMLElement).style.setProperty("visibility", "hidden", "important"),
          );
          const bare = pixels(await page.screenshot(), rect);
          await surface.evaluate((element) => (element as HTMLElement).style.removeProperty("visibility"));
          const shown = pixels(await page.screenshot(), rect);
          // The surface draws something there while open (the control: a missing surface passes nothing).
          expect(shown.some((value, index) => Math.abs(value - bare[index]!) > 24)).toBe(true);
          // The page's animation clock stands still, so the frame read is the close's first however
          // long a screenshot takes: a fade, however short, would still show the whole surface.
          const cdp = await page.context().newCDPSession(page);
          await cdp.send("Animation.enable");
          await cdp.send("Animation.setPlaybackRate", { playbackRate: 0 });
          // The close starts, as Base UI starts it, and the next frame paints.
          await surface.evaluate(async (element) => {
            element.setAttribute("data-ending-style", "");
            // raf-read: waits for the frame the close paints in; reads nothing from layout.
            await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
          });
          const closing = pixels(await page.screenshot(), rect);
          const worst = closing.reduce((most, value, index) => Math.max(most, Math.abs(value - bare[index]!)), 0);
          // Nothing of the surface: no channel more than 2 levels from the bare page.
          expect({ name, reducedMotion, worst: worst <= 2 ? "none" : worst }).toEqual({
            name,
            reducedMotion,
            worst: "none",
          });
        } finally {
          await page.close();
        }
      });
});
