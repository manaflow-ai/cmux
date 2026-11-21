// Every iconed status row's words start on one column, the live line's words start on the icon
// column, and a session's name reads as the row's words.
//
// Leo, 2026-11-03 22:27Z, on "Thinking · 1m 23s total" set on the text column under "Sent a message,
// finished 3 background tasks": "the indent looks bad". The live line has no icon slot: its words
// start where the rows' icons do, as the shimmer stands in the Claude and ChatGPT apps (earlier that
// day it took the text column, #33157, after "weird indenting /cut off text?").
//
// Measured in Chromium on gallery entry agent-pane.transcript-spacing-table (Leo's captures,
// variants working-bottom and reply-received):
// - the first glyph of every status row with an icon (a tool run, a finished subagent, a received
//   line, the waiting messages' head) shares one x, and the live line's ("Thinking") is the x of
//   those rows' icon slots;
// - a session's name (the waiting head's senders, a session chip) takes no tabular figures, so it
//   is set as the row's words are.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("transcript-status-text-column.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.transcript-spacing-table";
  const VARIANTS = ["working-bottom", "reply-received"];
  const TOLERANCE = 0.5;

  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("transcript status text column", () => test("browser", () => {}));
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
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: VARIANTS[0] } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Measured = {
    rows: { kind: string; text: string; x: number; icon?: number }[];
    names: { text: string; numeric: string }[];
  };

  const measure = async (variant: string): Promise<Measured> => {
    const page = await browser.newPage({ viewport: { width: 800, height: 1100 }, deviceScaleFactor: 2 });
    try {
      const port = (vite!.httpServer!.address() as { port: number }).port;
      await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, width: 760, reducedMotion: "true" })}`);
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
        timeout: 120_000,
      });
      await page.evaluate(() => document.fonts.ready);
      await page.mouse.move(0, 0);
      return await page.evaluate(() => {
        /** The left edge of the first laid-out words in `scope`. */
        const firstWords = (scope: Element) => {
          const walker = document.createTreeWalker(scope, NodeFilter.SHOW_TEXT);
          for (let node = walker.nextNode(); node; node = walker.nextNode()) {
            if (!node.textContent?.trim()) continue;
            const range = document.createRange();
            range.selectNodeContents(node);
            const rect = range.getClientRects()[0];
            if (rect && rect.width > 0) return { x: rect.left, text: node.textContent.trim().slice(0, 40) };
          }
          return null;
        };
        const rows: Measured["rows"] = [];
        for (const row of document.querySelectorAll(".acpmux-row")) {
          if (!row.getBoundingClientRect().height) continue;
          // The rows that draw a leading icon, and the live line, which draws none.
          const live = row.matches(".acpmux-thinking");
          if (!live && !row.querySelector(":scope .cv-tool__icon, :scope .cv-received__mark")) continue;
          if (row.matches(".acpmux-user:not(.acpmux-row--line), .acpmux-turnSummary")) continue;
          const words = firstWords(row);
          const icon = row.querySelector(":scope .cv-tool__icon, :scope .cv-received__mark")?.getBoundingClientRect();
          if (words)
            rows.push({
              kind: live ? "live" : (row.className.split(" ")[1] ?? ""),
              ...words,
              ...(icon && icon.width > 0 ? { icon: icon.left } : {}),
            });
        }
        const names = [...document.querySelectorAll(".acpmux-row :is(.cv-message-group__senders, .cv-agent-tag)")].map(
          (name) => ({
            text: (name.textContent ?? "").trim().slice(0, 40),
            numeric: getComputedStyle(name.querySelector(".cv-agent-tag__label") ?? name).fontVariantNumeric,
          }),
        );
        return { rows, names };
      });
    } finally {
      await page.close();
    }
  };

  for (const variant of VARIANTS) {
    test(`${variant}: the iconed rows' words share one column, the live line's start on the icon column`, async () => {
      const { rows } = await measure(variant);
      const live = rows.filter((row) => row.kind === "live");
      const iconed = rows.filter((row) => row.kind !== "live");
      expect(live.length).toBeGreaterThan(0);
      expect(iconed.length).toBeGreaterThan(0);
      const column = iconed[0]!.x;
      expect(iconed.filter((row) => Math.abs(row.x - column) > TOLERANCE)).toEqual([]);
      const iconColumn = iconed.find((row) => row.icon !== undefined)!.icon!;
      expect(live.filter((row) => Math.abs(row.x - iconColumn) > TOLERANCE)).toEqual([]);
    });
    test(`${variant}: a session's name takes no tabular figures`, async () => {
      const { names } = await measure(variant);
      expect(names.length).toBeGreaterThan(0);
      expect(names.filter((name) => name.numeric.includes("tabular-nums"))).toEqual([]);
    });
  }
});
