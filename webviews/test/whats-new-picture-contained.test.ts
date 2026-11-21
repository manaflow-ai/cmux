// cmux-web-test-timeout: 300
// What's New shows a change's picture as one clean, contained preview (#29876). Nightly
// 4122410931101's lead change carried a pull request's whole-window screenshot (1200×800, its tab
// menu open); the page boxed it at 16:9 with object-fit: cover, which cut the window and left the
// picture's size to a ratio the page picked. Now each picture is shown whole at its own shape,
// never larger than it was taken nor taller than 440 px, its glass frame is exactly the picture's
// box, and the title and cards under it start below it. The states are the real published notes
// (changelog.gallery.ts nightly-4122410931101, and -clip with the recorded clip its highlight now
// carries) and the Ledger's hero and row pictures.
// Real Chromium and WebKit (the app's engine) on the gallery stage. CI fails the file when it cannot
// launch them (requireBrowserLane). Locally: CMUX_BROWSER_TESTS=1 bun test test/whats-new-picture-contained.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("whats-new-picture-contained.test.ts", async () => {
  setDefaultTimeout(240_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`whats-new pictures: ${engine[0]} cannot launch here`);
    }
  }
  if (engines.length === 0) {
    describe.skip("whats-new pictures", () => test("browsers", () => {}));
    return;
  }

  const ENTRY = "pages.changelog";
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  const stageURL = (variant: string, width: number) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(ENTRY, { variant, frame: "component", width, theme: "Apple System Colors Light" })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    await warmGalleryFrame(vite, ENTRY, {
      browser: [...browsers.values()][0],
      params: { variant: "nightly-4122410931101" },
    });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  type Picture = {
    figure: [number, number, number, number];
    img: [number, number, number, number];
    natural: [number, number];
    /** The top of the first element after the picture's figure in its own block, if any. */
    next: number | null;
  };

  /** Every page picture once loaded: its frame, its drawn box, its file's size, what follows it. */
  const pictures = async (engine: string, variant: string, width: number) => {
    const page = await browsers.get(engine)!.newPage({ viewport: { width, height: 1400 } });
    await page.goto(stageURL(variant, width));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    // An inlined (data:) picture loads at once; ask any other to load too, without waiting on a
    // figure that has no size until its file arrives, then wait for every one to decode.
    await page.evaluate(() => {
      for (const img of document.querySelectorAll<HTMLImageElement>("figure.cl-media img")) img.loading = "eager";
    });
    await page.waitForFunction(
      () =>
        [...document.querySelectorAll<HTMLImageElement>("figure.cl-media img")].every(
          (img) => img.complete && img.naturalWidth > 0,
        ),
      undefined,
      { timeout: 60_000 },
    );
    const found = await page.evaluate(() => {
      const box = (el: Element) => {
        const r = el.getBoundingClientRect();
        return [r.left, r.top, r.width, r.height] as [number, number, number, number];
      };
      const after = (el: Element): number | null => {
        // The title and summary in the same card or row, else the block after the card or row.
        for (let node: Element | null = el; node && !node.matches("main, body"); node = node.parentElement) {
          const sibling = node.nextElementSibling;
          if (sibling && sibling.getBoundingClientRect().height > 0) return sibling.getBoundingClientRect().top;
        }
        return null;
      };
      return [...document.querySelectorAll("figure.cl-media")].map((figure) => {
        const img = figure.querySelector("img")!;
        return {
          figure: box(figure),
          img: box(img),
          natural: [img.naturalWidth, img.naturalHeight] as [number, number],
          next: after(figure),
        };
      });
    });
    await page.close();
    return found as Picture[];
  };

  const states: [variant: string, width: number, count: number][] = [
    ["nightly-4122410931101", 1000, 1],
    ["nightly-4122410931101", 560, 1],
    ["nightly-4122410931101-clip", 1000, 1],
    ["ledger-two-up", 1400, 2],
  ];
  for (const [engine] of engines)
    for (const [variant, width, count] of states)
      test(`${engine}, ${variant} at ${width}px: every picture shows whole in a frame of its own size, with nothing over it`, async () => {
        const found = await pictures(engine, variant, width);
        expect(found.length).toBeGreaterThanOrEqual(count);
        for (const { figure, img, natural, next } of found) {
          const [, imgTop, imgWidth, imgHeight] = img;
          const [figLeft, figTop, figWidth, figHeight] = figure;
          // Whole: drawn at the file's own shape, so nothing is cut (cover cut a 3:2 window to 16:9).
          expect(Math.abs(imgWidth / imgHeight - natural[0] / natural[1])).toBeLessThan(0.02);
          // Never larger than it was taken, never taller than the cap.
          expect(imgWidth).toBeLessThanOrEqual(natural[0] + 0.5);
          expect(imgHeight).toBeLessThanOrEqual(440.5);
          // Contained: the glass frame is the picture's box, no wider and no taller.
          expect(Math.abs(figWidth - imgWidth)).toBeLessThan(1);
          expect(Math.abs(figHeight - imgHeight)).toBeLessThan(1);
          expect(Math.abs(figTop - imgTop)).toBeLessThan(1);
          // Inside the page.
          expect(figLeft).toBeGreaterThanOrEqual(0);
          expect(figLeft + figWidth).toBeLessThanOrEqual(width + 0.5);
          // What follows starts below it.
          if (next !== null) expect(next).toBeGreaterThanOrEqual(figTop + figHeight - 0.5);
        }
      });
});
