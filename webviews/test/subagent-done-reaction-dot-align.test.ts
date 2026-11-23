// A finished subagent's compact line marks a reply the person has not seen with a dot
// (ReactionMark.tsx) and shows its duration only on hover (cmux#49580). The dot sits at the
// trailing edge in both states: at rest it is the row's last box, on the column edge every row's
// trailing column ends at, and on hover the time fades in before it without moving it.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("subagent-done-reaction-dot-align.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.subagent-done";
  const WIDTH = 760;

  if (!(await probeEngineOrSkip("subagent-done-reaction-dot-align", "chromium", chromium))) return;
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
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "reply" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Measure = {
    trail: number;
    dot: { left: number; right: number } | null;
    time: { right: number; opacity: number };
  };

  const open = async (): Promise<Page> => {
    const page = await browser.newPage({ viewport: { width: WIDTH + 40, height: 600 }, deviceScaleFactor: 2 });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: "reply", width: WIDTH, reducedMotion: "true" })}`,
    );
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.evaluate(() => document.fonts.ready);
    return page;
  };

  const measure = (page: Page): Promise<Measure[]> =>
    page.evaluate(() =>
      [...document.querySelectorAll('.cv-subagent-done-row[data-report-look="compact"]')].map((row) => {
        const dot = row.querySelector(".cv-reaction-mark")?.getBoundingClientRect();
        const time = row.querySelector(".cv-subagent-done__time")!;
        return {
          trail: row.querySelector(".cv-subagent-done__trail")!.getBoundingClientRect().right,
          dot: dot ? { left: dot.left, right: dot.right } : null,
          time: { right: time.getBoundingClientRect().right, opacity: Number(getComputedStyle(time).opacity) },
        };
      }),
    );

  test("the dot sits at the trailing edge at rest and stays put on hover", async () => {
    const page = await open();
    try {
      await page.mouse.move(0, 0);
      // The gallery's first line has the chat's unseen reply (its dot); the second has none.
      const [marked, plain] = await measure(page);
      expect(marked?.dot).not.toBeNull();
      expect(plain?.dot).toBeNull();
      const dot = marked!.dot!;
      // At rest the time is hidden and the dot ends the trailing column, not a time's width in:
      // on the edge the plain line's time ends at.
      expect(marked!.time.opacity).toBe(0);
      expect(Math.abs(dot.right - marked!.trail)).toBeLessThanOrEqual(0.5);
      expect(Math.abs(dot.right - plain!.time.right)).toBeLessThanOrEqual(0.5);
      // The time, when it shows, is before the dot.
      expect(marked!.time.right).toBeLessThanOrEqual(dot.left);

      await page.locator(".cv-subagent-done-row").first().hover();
      await page.waitForFunction(
        () =>
          getComputedStyle(document.querySelector(".cv-subagent-done-row .cv-subagent-done__time")!).opacity === "1",
      );
      const hovered = (await measure(page))[0]!;
      expect(Math.abs(hovered.dot!.left - dot.left)).toBeLessThanOrEqual(0.5);
      expect(Math.abs(hovered.dot!.right - hovered.trail)).toBeLessThanOrEqual(0.5);
      expect(hovered.time.right).toBeLessThanOrEqual(hovered.dot!.left);
    } finally {
      await page.close();
    }
  });
});
