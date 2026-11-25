// cmux-web-test-timeout: 900
// l10n-allow-file: test labels, not shipped UI.
// The band at the chat's foot, behind the composer (dockBand.experiment.ts, conversation/besideStack.ts).
// Leo, 2026-11-22, scrolled up in a chat: "AND I KINDA HATE HOW MUCH SOLID + BLUR THERE IS AT
// THE BOTTOM [image] OF THE BOX. FIGURE OUT HOW WE CAN HAVE MORE STUFF THERE."
//
// Real gallery frames (agent-pane.dock-band, one variant per arm), a long chat parked mid-transcript.
// For every arm it counts the pixel rows, from the card's top edge to the pane's bottom edge, where the
// transcript draws anything (the frame against the same frame with the transcript hidden), under the
// card and under it (the quiet row's band), at Default density, light and dark.
// Over an opaque window and over a picture (see-through, where the card's glass blurs):
// - the shipped arm (the before) shows no row there, inside the card's column;
// - the default arm, while it is `shipped`, too. The frost arms are measured and captured only.
// With FAST_CHECKS_OUT (cmux-ci) or CMUX_DOCK_BAND_CAPTURE set, it writes band.json and 2x stills of
// the pane's bottom 200 px for every arm, light and dark.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { PNG } from "pngjs";
import { dockBand } from "../src/agent-session/acpmux/dockBand.experiment";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Band = {
  pane: number;
  cardTop: number;
  cardBottom: number;
  cardHeight: number;
  /** Pixel rows (CSS px) with transcript ink, in the card's column: under the card, and under it. */
  underCard: number;
  belowCard: number;
  /** The same, in the gutters beside the card's column, from the card's top to the pane's bottom. */
  gutters: number;
  /** How far under the card's top edge the deepest row with transcript ink lies (CSS px). */
  reach: number;
};

await requireBrowserLane("agent-pane-dock-band.test.ts", async () => {
  setDefaultTimeout(840_000);
  const ENTRY = "agent-pane.dock-band";
  const out = process.env.CMUX_DOCK_BAND_CAPTURE ?? process.env.FAST_CHECKS_OUT;
  const ARMS = Object.keys(dockBand.arms);
  const SCALE = 2;
  const WIDTH = 760;
  const HEIGHT = 640;
  const THEMES = [
    ["Apple System Colors", "dark", undefined],
    ["Apple System Colors Light", "light", undefined],
    ["Apple System Colors", "art-dark", "dark"],
    ["Apple System Colors Light", "art-light", "light"],
  ] as const;
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const record: Record<string, Band> = {};

  beforeAll(async () => {
    if (out) mkdirSync(path.join(out, "band"), { recursive: true });
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, [ENTRY], { browser });
  });
  afterAll(async () => {
    if (out) writeFileSync(path.join(out, "band", "band.json"), JSON.stringify(record, null, 2));
    console.log(`dock-band: ${JSON.stringify(record)}`);
    await browser?.close();
    await vite?.close();
  });

  async function open(variant: string, theme: string, background?: string): Promise<Page> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: WIDTH, height: HEIGHT }, deviceScaleFactor: SCALE });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, width: WIDTH, theme, background })}`);
    await page.locator(".acpmux-composer-foot").first().waitFor({ timeout: 90_000 });
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 60_000,
    });
    // Two frames for the mask's last write (useBesideStack paints on the stack's resize).
    await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
    return page;
  }

  const png = async (page: Page, clip: { x: number; y: number; width: number; height: number }) =>
    PNG.sync.read(await page.screenshot({ clip, animations: "disabled", caret: "hide" }));

  async function measure(page: Page, still?: string): Promise<Band> {
    const geometry = await page.evaluate(() => {
      const rect = (selector: string) => document.querySelector(selector)!.getBoundingClientRect();
      const main = rect(".acpmux-main");
      const card = rect(".acpmux-composer-box");
      return {
        bottom: main.bottom,
        left: main.left,
        width: main.width,
        card: { top: card.top, bottom: card.bottom, left: card.left, right: card.right },
      };
    });
    const top = Math.floor(geometry.bottom - 200);
    const clip = { x: geometry.left, y: top, width: geometry.width, height: geometry.bottom - top };
    if (still) await page.screenshot({ path: still, clip, animations: "disabled", caret: "hide" });
    const shown = await png(page, clip);
    await page.addStyleTag({ content: ".acpmux-scroll { opacity: 0 !important; transition: none !important; }" });
    await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
    const hidden = await png(page, clip);
    const differs = (x: number, y: number) => {
      const at = (y * shown.width + x) * 4;
      return (
        Math.abs(shown.data[at]! - hidden.data[at]!) +
          Math.abs(shown.data[at + 1]! - hidden.data[at + 1]!) +
          Math.abs(shown.data[at + 2]! - hidden.data[at + 2]!) >
        12
      );
    };
    const col = [
      Math.round((geometry.card.left - geometry.left) * SCALE),
      Math.round((geometry.card.right - geometry.left) * SCALE),
    ] as const;
    const yOf = (client: number) => Math.round((client - top) * SCALE);
    const inked = (y: number, from: number, to: number) => {
      let count = 0;
      for (let x = from; x < to; x++) if (differs(x, y)) count++;
      return count >= Math.max(2, (to - from) * 0.004);
    };
    let underCard = 0;
    let belowCard = 0;
    let gutters = 0;
    let reach = 0;
    for (let y = Math.max(0, yOf(geometry.card.top)); y < shown.height; y++) {
      const inCard = inked(y, col[0] + 2 * SCALE, col[1] - 2 * SCALE);
      if (inCard) {
        if (y < yOf(geometry.card.bottom)) underCard++;
        else belowCard++;
        reach = y - yOf(geometry.card.top);
      }
      if (inked(y, 0, col[0]) || inked(y, col[1], shown.width)) gutters++;
    }
    return {
      pane: geometry.bottom,
      cardTop: geometry.card.top,
      cardBottom: geometry.card.bottom,
      cardHeight: geometry.card.bottom - geometry.card.top,
      underCard: underCard / SCALE,
      belowCard: belowCard / SCALE,
      gutters: gutters / SCALE,
      reach: reach / SCALE,
    };
  }

  test("every arm: the transcript rows that read in the band", async () => {
    for (const arm of ARMS)
      for (const [theme, name, background] of THEMES) {
        const page = await open(arm, theme, background);
        record[`${arm}-${name}`] = await measure(page, out ? path.join(out, "band", `${arm}-${name}.png`) : undefined);
        await page.close();
      }
    for (const [, name, background] of THEMES) {
      const shipped = record[`shipped-${name}`]!;
      expect(shipped.underCard + shipped.belowCard).toBeLessThan(2);
      // The shipped default keeps the rows out from under the card until a frost arm ships.
      void background;
      const chosen = record[`${dockBand.defaultArm}-${name}`]!;
      if (dockBand.defaultArm === "shipped") expect(chosen.underCard + chosen.belowCard).toBeLessThan(2);
    }
  });
});
