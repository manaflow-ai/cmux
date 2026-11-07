// A lone system line between turns against its settled spacing (src/agent-session/acpmux/transcriptSpacing.ts
// LONE_SYSTEM_ROWS, leo-workspace design/transcript-spacing.md "Lone system rows"). Leo, 2026-11-04, on a
// lone "Background update" a block gap under the footer and a turn gap over the next prompt: "this bare
// background update tool call floating in teh air is so weird loking proportionally".
//
// Gallery entry agent-pane.lone-system-rows draws each kind of line (a quiet and a running background
// turn, a background task's end, a folded run of them, a subagent's end) under a turn's footer row, then
// the next prompt; and another agent's line, which keeps the block gap. The test measures, in Chromium,
// the footer's glyph centre to the line's centre and the line's centre to the next bubble's top edge.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { LONE_LINE } from "../src/agent-session/acpmux/conversation/LoneSystemRows.gallery";
import { LONE_SYSTEM_ROWS } from "../src/agent-session/acpmux/transcriptSpacing";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("transcript-lone-system-rows.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.lone-system-rows";
  const VARIANTS = [...LONE_SYSTEM_ROWS.variants, "received-message"];

  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("lone system rows", () => test("browser", () => {}));
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
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: VARIANTS[0]! } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const measure = async (variant: string) => {
    const page = await browser.newPage({ viewport: { width: 1000, height: 900 }, deviceScaleFactor: 2 });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, width: 900, theme: "Catppuccin Mocha", reducedMotion: "true" })}`,
    );
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.evaluate(() => document.fonts.ready);
    await page.mouse.move(0, 0);
    const result = await page.evaluate((line) => {
      const row = (id: string) => document.querySelector(`[data-row-id="${id}"]`);
      /** The centre of the first shown text line under the row. */
      const firstLine = (id: string) => {
        const scope = row(id);
        if (!scope) return null;
        const walker = document.createTreeWalker(scope, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          if (!node.textContent?.trim()) continue;
          const range = document.createRange();
          range.selectNodeContents(node);
          const rect = [...range.getClientRects()].find((box) => box.width > 0 && box.height > 0);
          if (rect) return (rect.top + rect.bottom) / 2;
        }
        return null;
      };
      const svg = row("lone-footer")?.querySelector<SVGElement>(".cv-turn-actions button svg");
      const box = svg?.getBoundingClientRect();
      const glyph = box && box.height > 0 ? (box.top + box.bottom) / 2 : null;
      const bubble = row("lone-next")?.querySelector(".cv-user__bubble")?.getBoundingClientRect();
      const centre = firstLine(line);
      const rows = [...document.querySelectorAll<HTMLElement>("[data-row-id]")].map(
        (element) => `${element.getBoundingClientRect().top.toFixed(1)} ${element.dataset.rowId}`,
      );
      return { glyph, centre, prompt: bubble ? bubble.top : null, rows };
    }, LONE_LINE[variant]!);
    await page.close();
    return result;
  };

  for (const variant of VARIANTS)
    test(variant, async () => {
      const { glyph, centre, prompt, rows } = await measure(variant);
      expect(glyph, `no footer glyph; rows:\n${rows.join("\n")}`).not.toBeNull();
      expect(centre, `no ${LONE_LINE[variant]} line; rows:\n${rows.join("\n")}`).not.toBeNull();
      const expected =
        variant === "received-message" ? LONE_SYSTEM_ROWS.footerToReceived : LONE_SYSTEM_ROWS.footerToLine;
      expect(Math.abs(centre! - glyph! - expected)).toBeLessThanOrEqual(LONE_SYSTEM_ROWS.tolerance);
      if (prompt !== null)
        expect(Math.abs(prompt - centre! - LONE_SYSTEM_ROWS.lineToPrompt)).toBeLessThanOrEqual(
          LONE_SYSTEM_ROWS.tolerance,
        );
    });
});
