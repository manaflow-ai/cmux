// l10n-allow-file: browser fixture labels and diagnostics, not shipped UI.
// cmux-web-test-timeout: 300
//
// The Background activity placements board (agent-pane.background-activity, cmuxterm-hq#5594): an
// open command row's terminal output was squeezed into a strip about 10px wide, its Follow tail,
// Stop and Open in terminal stacked one per line, and the board ran past the bottom of its frame.
// The row is a <details> laid out as a three-column grid; Chromium puts everything after the
// <summary> in one ::details-content box, which took the grid's first, 10px column, so the
// `grid-column: 1 / -1` on the output never applied. Output should read at the row's full width, as
// tool output does in ChatGPT and Claude.
//
// At each of the entry's gallery widths, in real Chromium on the gallery frame: the open output
// fills its row, the row's controls sit on one line (or wrap with several to a line, never one per
// line), and nothing draws past the frame's right edge or runs past its bottom (a
// longer board scrolls inside the frame, as a chat pane does). CI fails the file when Chromium
// cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("background-activity-gallery-width-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.background-activity";
  // The entry's own frame: `height: 760`, `widths: { narrow: 420, normal: 760, wide: 1040 }`.
  const HEIGHT = 760;
  const WIDTHS = [420, 760, 1040];
  // The placements that open a command's output: the compact pill opens on a click.
  const SURFACES = ["pinned-live-tail", "after-latest-message", "compact-pill", "side-panel"] as const;
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "pinned-live-tail-light" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  describe("background activity placements at the gallery widths", () => {
    for (const surface of SURFACES)
      for (const mode of ["light", "dark"] as const)
        for (const width of WIDTHS)
          test(`${surface}-${mode} at ${width}px: output at full width, controls in a row, inside the frame`, async () => {
            const page = await browser!.newPage({ viewport: { width, height: HEIGHT } });
            const errors: string[] = [];
            page.on("pageerror", (error) => errors.push(error.message));
            try {
              const base = `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;
              await page.goto(base + galleryFrame(ENTRY, { variant: `${surface}-${mode}`, width, height: HEIGHT }));
              await page.waitForFunction(
                () => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""),
                undefined,
                { timeout: 90_000 },
              );
              expect(await page.evaluate(() => document.documentElement.dataset.galleryReady)).toBe("1");
              if (surface === "compact-pill") await page.locator("[data-activity-pill]").click();
              // The side panel opens none of its rows: open the first, as a reader would.
              if (surface === "side-panel") await page.locator(".bg-gallery__command > summary").first().click();
              await page.locator(".bg-gallery__command[open] .bg-gallery__tail-body").first().waitFor();

              const layout = await page.evaluate(() => {
                const rect = (el: Element) => el.getBoundingClientRect();
                const rows = [...document.querySelectorAll(".bg-gallery__command[open]")].map((row) => {
                  const output = row.querySelector(".bg-gallery__tail-body")!;
                  const controls = [...row.querySelectorAll(".bg-gallery__tail-foot > *")].map(rect);
                  const lines = new Set(controls.map((box) => Math.round(box.top + box.height / 2)));
                  return {
                    row: rect(row).width,
                    output: rect(output).width,
                    controls: controls.length,
                    lines: lines.size,
                  };
                });
                const board = document.querySelector("[data-bg-gallery]")!;
                // Nothing draws past the right edge (the output scrolls inside its own block).
                let right = 0;
                for (const el of [board, ...board.querySelectorAll("*")]) {
                  const box = rect(el);
                  if (box.width === 0 && box.height === 0) continue;
                  right = Math.max(right, box.right);
                }
                return {
                  rows,
                  right,
                  bottom: rect(board).bottom,
                  scrollWidth: document.documentElement.scrollWidth,
                  scrollHeight: document.documentElement.scrollHeight,
                };
              });

              expect(layout.rows.length).toBeGreaterThan(0);
              for (const row of layout.rows) {
                // The output takes the row's width (its border aside), not a strip of it.
                expect(row.output).toBeGreaterThanOrEqual(row.row - 2);
                // Follow tail, Stop and Open in terminal: one line, or two at most, never one per line.
                expect(row.lines).toBeLessThanOrEqual(2);
                if (row.controls > 1) expect(row.lines).toBeLessThan(row.controls);
              }
              expect({ right: Math.ceil(layout.right), scrollWidth: layout.scrollWidth }).toEqual({
                right: Math.min(Math.ceil(layout.right), width),
                scrollWidth: width,
              });
              // The board ends at the frame's bottom; what is longer scrolls inside it.
              expect({ bottom: Math.floor(layout.bottom), scrollHeight: layout.scrollHeight }).toEqual({
                bottom: Math.min(Math.floor(layout.bottom), HEIGHT),
                scrollHeight: HEIGHT,
              });
              expect(errors).toEqual([]);
            } finally {
              await page.close();
            }
          });
  });
});
