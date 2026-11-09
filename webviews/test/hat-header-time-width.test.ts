// l10n-allow-file: gallery fixture names are test data.
// The folded composer hat's header holds still while its time ticks into a wider form: "59s" to
// "1m 1s", "1m 9s" to "1m 10s". A fleet capture of the DEV build (cmux#39104, cmux#39142) showed the
// header's names cut one word shorter, its "+2 more" step left and a mark beside the icons drop out
// each time the time's text grew (Leo, 2026-11-09: "im still sometimes seeing a flicker on the
// composer/composer hat when scrolling and things are running in background aka time is ticking").
// The time's slot keeps room for any time under an hour, so a tick changes one text node and
// nothing beside it moves. Real Chromium from Playwright; the tick is the text change Elapsed.tsx
// makes in place.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("hat-header-time-width.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  let server: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const entry = "agent-pane.subagent-tray";
  const variant = "several-running";

  beforeAll(async () => {
    server = await createServer({
      root: path.resolve(import.meta.dir, ".."),
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await server.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(server, entry, { browser, params: { variant } });
  });

  afterAll(async () => {
    await browser?.close();
    await server?.close();
  });

  // The capture's pane was about 415 px wide: the header's names truncate there.
  for (const width of [420, 760])
    test(`the folded header's names and counts hold still as its time grows (${width} px)`, async () => {
      const port = (server.httpServer!.address() as { port: number }).port;
      const page = await browser.newPage({ viewport: { width, height: 560 }, reducedMotion: "reduce" });
      try {
        await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant })}`);
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        const time = page.locator(".acpmux-running-tray__head > .acpmux-running-tray__time").first();
        await time.waitFor();
        // The header's counts slide in once (trayMotion.tsx `Tick`): measure after its row has painted
        // the same for ten frames.
        await installPaintedFrames(page);
        await page.waitForFunction(
          () =>
            new Promise<boolean>((resolve) => {
              const head = document.querySelector(".acpmux-running-tray__head")!;
              const shape = () =>
                JSON.stringify([...head.children].map((child) => child.getBoundingClientRect().toJSON()));
              let last = "";
              let still = 0;
              window.cmuxAfterPaint(() => {
                const next = shape();
                still = next === last ? still + 1 : 0;
                last = next;
                if (still < 10 || head.querySelector(".acpmux-tick__out")) return true;
                resolve(true);
                return false;
              });
            }),
          null,
          { timeout: 20_000 },
        );
        const at = async (text: string) =>
          time.evaluate((node, text) => {
            // A tick: the time's one text node changes in place.
            const walker = document.createTreeWalker(node, NodeFilter.SHOW_TEXT);
            const leaf = walker.nextNode();
            if (leaf) leaf.textContent = text;
            else node.textContent = text;
            const head = node.closest(".acpmux-running-tray__head")!;
            const box = (element: Element | null) => {
              if (!element) return undefined;
              const rect = element.getBoundingClientRect();
              return { left: rect.left, right: rect.right, width: rect.width };
            };
            return {
              text: node.textContent,
              time: box(node),
              title: box(head.querySelector(".acpmux-running-tray__title")),
              stack: box(head.querySelector(".acpmux-running-tray__stack")),
              more: box(head.querySelector(".acpmux-running-tray__more")),
              timeCut: node.scrollWidth > node.clientWidth + 1,
            };
          }, text);
        const ticks = ["9s", "59s", "1m", "1m 1s", "1m 9s", "1m 10s", "10m 10s", "59m 59s"];
        const shown: Awaited<ReturnType<typeof at>>[] = [];
        for (const text of ticks) shown.push(await at(text));
        const first = shown[0]!;
        for (const [index, step] of shown.entries()) {
          expect(step.text).toBe(ticks[index]!);
          expect(step.timeCut, `the time was cut at ${step.text}`).toBe(false);
          expect(step.time!.left, `the time moved at ${step.text}`).toBe(first.time!.left);
          expect(step.title, `the names moved or resized at ${step.text}`).toEqual(first.title);
          expect(step.stack, `the marks moved or resized at ${step.text}`).toEqual(first.stack);
          expect(step.more, `the count moved at ${step.text}`).toEqual(first.more);
        }
      } finally {
        await page.close();
      }
    });
});
