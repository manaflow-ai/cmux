// The drawn rows' gaps in Chromium (design/chat-row-rhythm.md; Leo, 2026-11-21: "the spacing is just insanely shit
// here. way too close ... we can measure all of these."). Gallery agent-pane.chat-row-spacing, one variant per look.
// The model-level table is src/agent-session/acpmux/rowGapTable.test.ts.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("chat-row-spacing.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.chat-row-spacing";
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("chat row spacing", () => test("browser", () => {}));
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
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "closed-shipped" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** Row id -> px from the row above's bottom, in order. */
  const gaps = async (variant: string, colorScheme: "light" | "dark"): Promise<Record<string, number>> => {
    const address = vite!.httpServer!.address() as { port: number };
    const page = await browser.newPage({ viewport: { width: 760, height: 900 } });
    try {
      await page.goto(`http://127.0.0.1:${address.port}${galleryFrame(ENTRY, { variant, colorScheme })}`, {
        waitUntil: "load",
      });
      await page.waitForSelector("[data-row-id]");
      if (variant.startsWith("open-")) await page.waitForSelector(".acpmux-messageRun button[aria-expanded=true]");
      // Measured once the rows hold still: their boxes unchanged over 10 frames (a fold's motion and the
      // fonts' late layout have ended), not after a guessed time.
      await page.evaluate(() => document.fonts.ready.then(() => undefined));
      await page.waitForFunction(
        () => {
          const w = window as unknown as { crsLast?: string; crsStill?: number };
          const now = [...document.querySelectorAll("[data-row-id]")]
            .map((e) => {
              const box = e.getBoundingClientRect();
              return `${box.top},${box.bottom}`;
            })
            .join("|");
          w.crsStill = now === w.crsLast ? (w.crsStill ?? 0) + 1 : 0;
          w.crsLast = now;
          return w.crsStill >= 10;
        },
        undefined,
        { polling: "raf" },
      );
      return await page.evaluate(() => {
        const rows = [...document.querySelectorAll("[data-row-id]")].map((e) => ({
          id: e.getAttribute("data-row-id")!,
          box: e.getBoundingClientRect(),
        }));
        const out: Record<string, number> = {};
        rows.forEach((row, i) => {
          if (i) out[row.id] = Math.round((row.box.top - rows[i - 1]!.box.bottom) * 2) / 2;
        });
        return out;
      });
    } finally {
      await page.close();
    }
  };

  for (const scheme of ["light", "dark"] as const) {
    describe(`chat row spacing (${scheme})`, () => {
      test('shipped: the opened group\'s children and the lines under it stand flush, "Worked for" the run gap over them', async () => {
        const g = await gaps("open-shipped", scheme);
        expect(g["crs-work-1"]).toBe(0);
        expect(g["worked-crs-recv-1"]).toBe(16);
        expect(g["messageRun-crs-work-1"]).toBe(0);
        expect(g["crs-reply-2"]).toBe(0);
      });
      test('shipped, closed: the group\'s head and "Worked for" stand the run gap', async () => {
        const g = await gaps("closed-shipped", scheme);
        expect(g["worked-crs-recv-1"]).toBe(16);
        expect(g["crs-footer-2"]).toBe(8);
      });
      test('before: the blank band above an opened group\'s first child, and "Worked for" flush', async () => {
        const g = await gaps("open-before", scheme);
        expect(g["crs-work-1"]).toBe(32);
        expect(g["worked-crs-recv-1"]).toBe(0);
      });
    });
  }
});
