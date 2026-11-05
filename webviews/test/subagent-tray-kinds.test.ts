// l10n-allow-file: gallery fixture tray labels are test data.
// Leo's tray (2026-11-03): four background commands and a finished subagent. Its header read only
// "4 commands 6m 47s"; the finished line's "Done · 29m 21s" ran into the empty Stop column, past
// every other line's time; and the list (border-box, its 2px top gap inside its five-line height)
// overflowed by that gap, so a classic scrollbar pulled the lines' Stop squares and chevrons in under
// the header's. Leo: "let's align the right + ... the top bit aka what the collapsed area shows i
// think can show much more interesting stuf fthan it does now + all that alignment can be done better
// with ... the chevrons with the stop symbols and whatnot and the times". In real Chromium (Playwright;
// CI fails the file when it cannot launch, requireBrowserLane).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("subagent-tray-kinds.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  let server: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const entry = "agent-pane.subagent-tray-kinds";

  beforeAll(async () => {
    server = await createServer({
      root: path.resolve(import.meta.dir, ".."),
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await server.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(server, entry, { browser, params: { variant: "leo-tray" } });
  });

  afterAll(async () => {
    await browser?.close();
    await server?.close();
  });

  for (const width of [760, 360]) {
    test(`Leo's tray: one time edge, one Stop column, one chevron column, no scrollbar, every kind counted at ${width}px`, async () => {
      const port = (server.httpServer!.address() as { port: number }).port;
      const page = await browser.newPage({
        viewport: { width, height: 440 },
        deviceScaleFactor: 2,
        reducedMotion: "reduce",
      });
      try {
        await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant: "leo-tray" })}`);
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        await page.locator(".acpmux-running-tray__head").waitFor();
        if ((await page.locator(".acpmux-running-tray__head").getAttribute("aria-expanded")) !== "true")
          await page.click(".acpmux-running-tray__head");
        await page.waitForFunction(
          () => document.querySelectorAll(".acpmux-running-tray__list .acpmux-agent-line").length === 5,
        );
        await page.evaluate(() => {
          for (const animation of document.getAnimations())
            if (Number.isFinite(animation.effect?.getComputedTiming().endTime as number)) animation.finish();
        });
        const geometry = await page.evaluate(() => {
          const tray = document.querySelector<HTMLElement>(".acpmux-running-tray")!;
          const list = tray.querySelector<HTMLElement>(".acpmux-running-tray__list")!;
          const rect = (node: Element | null) => {
            const box = node!.getBoundingClientRect();
            return { left: box.left, right: box.right };
          };
          return {
            title: tray.querySelector(".acpmux-running-tray__title")!.textContent,
            overflow: list.scrollHeight - list.clientHeight,
            head: rect(tray.querySelector(".acpmux-running-tray__status svg")),
            lines: [...list.querySelectorAll<HTMLElement>(".acpmux-agent-line")].map((line) => ({
              time: rect(line.querySelector(".acpmux-agent-line__time")),
              track: rect(line.querySelector(".acpmux-agent-line__stop-track")),
              chevron: rect(line.querySelector(".acpmux-agent-line__chevron svg")),
            })),
          };
        });
        expect(geometry.title).toBe("1 build · 2 waits · 1 command · 1 subagent done");
        // Five one-row lines fit the list: no scrollbar to take their right edge in. Narrow too: a line
        // stays one row there (Leo, 2026-11-04: "how Claude code just has one lines too").
        expect(geometry.overflow).toBeLessThanOrEqual(0);
        const [first] = geometry.lines;
        for (const line of geometry.lines) {
          expect(Math.abs(line.time.right - first!.time.right)).toBeLessThanOrEqual(0.5);
          expect(line.time.right).toBeLessThanOrEqual(line.track.left + 0.5);
          expect(Math.abs(line.track.left - first!.track.left)).toBeLessThanOrEqual(0.5);
          expect(Math.abs(line.chevron.right - geometry.head.right)).toBeLessThanOrEqual(0.5);
        }
      } finally {
        await page.close();
      }
    });
  }
});
