// The person's prompt after a run of tool rows sits in the middle of its gap.
//
// Leo, 2026-11-01, on a steer whose bubble nearly touched the "Sent to …" tool line over it while its
// time row and the next call had far more room under it: "this is too close to tool calls, center it".
//
// In gallery entry agent-pane.prompt-after-tool-rows (a running turn: three one-line tool rows, a
// steer, two more calls), measured in Chromium in light and dark: the room from the tool line over
// the steer's bubble to the bubble's top equals the room from the bubble's bottom to the next tool
// line, to 0.5px. The bubble's meta row (time, Copy, Retry) shows on hover only, so the bubble's own
// box is its edge; the meta row sits inside the room under it. Both neighbours are 22px tool lines
// whose text is centred the same way in its line, so equal boxes mean equal ink.
// design/chat-transcript.md "Prompts after tool rows".
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("transcript-prompt-after-tools.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.prompt-after-tool-rows";
  const THEMES = [
    { name: "Apple System Colors Light", file: "light" },
    { name: "Catppuccin Mocha", file: "dark" },
  ];
  const TOLERANCE = 0.5;

  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("transcript prompt after tool rows", () => test("browser", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "centered" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Room = { above: number; below: number; over: string; under: string };

  /** The room over and under the steer's bubble, to the nearest tool line on each side. */
  const measure = (page: Page): Promise<Room | undefined> =>
    page.evaluate(() => {
      const bubble = [...document.querySelectorAll(".acpmux-row.acpmux-user .cv-user__bubble")].find((element) =>
        (element.textContent ?? "").includes("make sure we're not randomly wasting money"),
      );
      if (!bubble) return undefined;
      const box = bubble.getBoundingClientRect();
      const lines = [...document.querySelectorAll(".acpmux-row:not(.acpmux-user) .cv-tool")]
        .map((element) => ({ rect: element.getBoundingClientRect(), text: (element.textContent ?? "").trim() }))
        .filter(({ rect }) => rect.height > 0);
      const over = lines.filter(({ rect }) => rect.bottom <= box.top + 0.01).sort((a, b) => b.rect.bottom - a.rect.bottom)[0];
      const under = lines.filter(({ rect }) => rect.top >= box.bottom - 0.01).sort((a, b) => a.rect.top - b.rect.top)[0];
      if (!over || !under) return undefined;
      return {
        above: box.top - over.rect.bottom,
        below: under.rect.top - box.bottom,
        over: over.text.slice(0, 32),
        under: under.text.slice(0, 32),
      };
    });

  const open = async (variant: string, theme: string) => {
    const page = await browser.newPage({ viewport: { width: 900, height: 900 }, deviceScaleFactor: 2 });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, width: 720, theme, reducedMotion: "true" })}`,
    );
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.evaluate(() => document.fonts.ready);
    return page;
  };

  for (const theme of THEMES)
    test(`a prompt after tool rows is centred in its gap (${theme.name})`, async () => {
      const page = await open("centered", theme.name);
      const earlier = await open("tight", theme.name);
      try {
        const room = await measure(page);
        const before = await measure(earlier);
        console.log(`PROMPT_GAP centered ${theme.file} ${JSON.stringify(room)}`);
        console.log(`PROMPT_GAP tight ${theme.file} ${JSON.stringify(before)}`);
        expect(room).toBeDefined();
        expect(Math.abs(room!.above - room!.below)).toBeLessThanOrEqual(TOLERANCE);
        // Only the room over the bubble moves: under it nothing changes.
        expect(before).toBeDefined();
        expect(Math.abs(room!.below - before!.below)).toBeLessThanOrEqual(TOLERANCE);
      } finally {
        await page.close();
        await earlier.close();
      }
    });
});
