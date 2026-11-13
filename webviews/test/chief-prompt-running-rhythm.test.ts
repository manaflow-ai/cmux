// cmux-web-test-timeout: 300
// l10n-allow-file: synthetic transcript assertions.
//
// https://github.com/manaflow-ai/cmux/issues/42444: in a chat the Chief started, its prompt card
// (the "Sent from" line over the bubble) sat tight over the running turn's "Working for" line. A
// prompt over "Working for" keeps the turn gap it keeps over "Worked for" once the turn ends, and its
// action row (time, copy) sits centred in that gap, the same for a Chief prompt as for a typed one.
// A prompt just sent, its live line under it, keeps the block gap, its action row centred in that.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("chief-prompt-running-rhythm.test.ts", async () => {
  setDefaultTimeout(180_000);
  const ENTRY = "agent-pane.chief-prompt";
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "running" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Rhythm = { bubbleBottom: number; nextTop: number; actionsTop: number; actionsBottom: number };
  async function measure(variant: string, interfaceScale: number): Promise<Rhythm> {
    const context = await browser.newContext({ viewport: { width: 900, height: 600 }, deviceScaleFactor: 2 });
    const page = await context.newPage();
    try {
      const base = `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}`;
      await page.goto(base + galleryFrame(ENTRY, { variant, interfaceScale, reducedMotion: "true" }));
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady !== undefined);
      expect(await page.getAttribute("html", "data-gallery-ready"), await page.locator("body").innerText()).toBe("1");
      await page.waitForSelector(".cv-user__bubble");
      // The action row shows on hover: hovered, the screenshot shows where it sits in the gap.
      await page.hover(".cv-user__bubble");
      if (process.env.FAST_CHECKS_OUT) {
        await mkdir(process.env.FAST_CHECKS_OUT, { recursive: true });
        await page.screenshot({
          path: path.join(process.env.FAST_CHECKS_OUT, `chief-${variant}-${interfaceScale}.png`),
        });
        await page.screenshot({
          path: path.join(process.env.FAST_CHECKS_OUT, `chief-${variant}-${interfaceScale}-prompt.png`),
          clip: { x: 450, y: 30, width: 450, height: 160 },
        });
      }
      return await page.evaluate(() => {
        const box = (selector: string) => {
          const element = document.querySelector(selector);
          if (!element) throw new Error(`missing ${selector}`);
          return element.getBoundingClientRect();
        };
        const bubble = box(".cv-user__bubble");
        const actions = box(".cv-user__actions");
        // The row drawn under the prompt ("Working for" or the live line): the stack places rows
        // absolutely, so the nearest row below the prompt's, not its next sibling.
        const prompt = box("article.acpmux-row:has(.cv-user__bubble)");
        const tops = [...document.querySelectorAll("article.acpmux-row")]
          .map((row) => row.getBoundingClientRect())
          .filter((row) => row.height > 0 && row.top >= prompt.bottom - 1)
          .map((row) => row.top);
        if (tops.length === 0) throw new Error("no row under the prompt");
        return {
          bubbleBottom: bubble.bottom,
          nextTop: Math.min(...tops),
          actionsTop: actions.top,
          actionsBottom: actions.bottom,
        };
      });
    } finally {
      await context.close();
    }
  }

  // The gap under the prompt (transcriptGrid.ts): the turn gap over "Working for", the block gap over
  // the live line of a prompt just sent.
  const variants = [
    { variant: "running", gap: 32 },
    { variant: "running-typed", gap: 32 },
    { variant: "waiting", gap: 24 },
  ];
  for (const interfaceScale of [1, 1.25])
    test(`a prompt's action row centres in the gap the layout leaves under it (${interfaceScale})`, async () => {
      // Every variant measured before any is checked, so a red run still has every screenshot.
      const rhythms: Rhythm[] = [];
      for (const { variant } of variants) rhythms.push(await measure(variant, interfaceScale));
      for (const [index, { variant, gap: want }] of variants.entries()) {
        const rhythm = rhythms[index]!;
        const gap = rhythm.nextTop - rhythm.bubbleBottom;
        expect({ variant, gap: Math.round(gap) }).toEqual({ variant, gap: Math.round(want * interfaceScale) });
        // The action row is centred in that gap: as far from the bubble as from the row under it.
        const above = rhythm.actionsTop - rhythm.bubbleBottom;
        const below = rhythm.nextTop - rhythm.actionsBottom;
        expect({ variant, above, below, centred: Math.abs(above - below) <= 1 }).toEqual({
          variant,
          above,
          below,
          centred: true,
        });
      }
    });
});
