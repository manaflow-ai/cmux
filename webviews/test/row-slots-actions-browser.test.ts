// l10n-allow-file: test fixtures.
// A row's actions sit in RowFrame's fixed end slot (RowSlots.tsx; doc transcript-motion-model.md
// rule 10, invariant I10): a prompt's Copy is drawn at the same right edge at every text length, on
// its way (its delivery note under the bubble's text) and landed alike, never after the words (Leo,
// 2026-11-17: "STOP MAKING THE COPY BUTTON MOVE WITH THE TEXT WHY WAS IT NOT JUST AT THE RIGHT
// EDGE"). Real Chromium on the pane's CSS (browser/row-slots-actions.html).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("row-slots-actions-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser | undefined;
  let page: Page;
  beforeAll(async () => {
    const root = path.resolve(import.meta.dir, "..");
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/row-slots-actions.html");
    browser = await chromium.launch({ headless: true });
    page = await browser.newPage({ viewport: { width: 800, height: 1000 } });
    const port = (vite.httpServer!.address() as { port: number }).port;
    await page.goto(`http://127.0.0.1:${port}/test/browser/row-slots-actions.html`);
    await page.waitForFunction(() => document.documentElement.dataset.harnessReady === "true");
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /// Where `id`'s Copy and its end slot are drawn, and where its delivery note starts.
  const drawn = (id: string) =>
    page.getByTestId(id).evaluate((row) => {
      const copy = row.querySelector(".cv-row-slots__actions .cv-copy-button, .cv-row-slots__actions button");
      const slot = row.querySelector(".cv-row-slots__actions");
      const note = row.querySelector(".cv-user__pending-state");
      const words = row.querySelector(".cv-user__bubble");
      return {
        noteRight: note?.getBoundingClientRect().right,
        slotLeft: slot?.getBoundingClientRect().left ?? Number.NaN,
        copyRight: copy?.getBoundingClientRect().right ?? Number.NaN,
        slotRight: slot?.getBoundingClientRect().right ?? Number.NaN,
        noteLeft: note?.getBoundingClientRect().left,
        bubbleLeft: words?.getBoundingClientRect().left ?? Number.NaN,
        bubbleRight: words?.getBoundingClientRect().right ?? Number.NaN,
      };
    });

  /// Where `id`'s line actions (its hover row's last button) and their slot are drawn, and its line.
  const lineActions = (id: string) =>
    page.getByTestId(id).evaluate((row) => {
      const slot = row.querySelector(".cv-received__hover, .cv-row-slots__actions");
      const buttons = slot?.querySelectorAll("button") ?? [];
      const last = buttons[buttons.length - 1];
      const line = row.querySelector(".cv-agentmsg__line, .cv-disclosure__line");
      const preview = row.querySelector(".cv-received__preview");
      return {
        slotRight: slot?.getBoundingClientRect().right ?? Number.NaN,
        buttonRight: last?.getBoundingClientRect().right ?? Number.NaN,
        lineRight: line?.getBoundingClientRect().right ?? Number.NaN,
        previewWidth: preview?.getBoundingClientRect().width ?? Number.NaN,
      };
    });

  describe("row slots", () => {
    // Every other kind that draws actions on its line: the actions keep one right edge whatever the
    // text's length (rule 10, I10).
    for (const kind of ["received", "notice"]) {
      test(`${kind}: the line's actions keep one right edge at two text lengths`, async () => {
        const short = await lineActions(`${kind}-short`);
        const long = await lineActions(`${kind}-long`);
        // The two lines' words differ in width, so actions that followed them would differ too.
        expect(long.previewWidth).toBeGreaterThan(short.previewWidth + 40);
        expect(Number.isFinite(short.buttonRight)).toBe(true);
        expect(long.buttonRight).toBeCloseTo(short.buttonRight, 0);
        expect(long.slotRight).toBeCloseTo(short.slotRight, 0);
      });
    }

    test("a prompt on its way keeps Copy at the same right edge at two text lengths", async () => {
      const short = await drawn("pending-short");
      const long = await drawn("pending-long");
      expect(short.noteLeft).toBeDefined();
      // The two bubbles differ in width, so a Copy that followed the note's words would differ too.
      expect(long.bubbleLeft).toBeLessThan(short.bubbleLeft - 40);
      expect(Number.isFinite(short.copyRight)).toBe(true);
      expect(long.copyRight).toBeCloseTo(short.copyRight, 0);
      expect(long.slotRight).toBeCloseTo(short.slotRight, 0);
    });

    test("on its way and landed, the end slot is at one right edge", async () => {
      const pending = await drawn("pending-short");
      const landed = await drawn("landed-short");
      expect(landed.noteLeft).toBeUndefined();
      expect(pending.slotRight).toBeCloseTo(landed.slotRight, 0);
      expect((await drawn("landed-long")).slotRight).toBeCloseTo(landed.slotRight, 0);
    });

    test("the delivery note sits before the end slot, never under its buttons", async () => {
      for (const id of ["pending-short", "pending-long"]) {
        const row = await drawn(id);
        // The note is `meta`, drawn from the line's start; the end slot keeps the right edge, so the
        // two never overlap at any text length.
        expect(row.noteRight!).toBeLessThanOrEqual(row.slotLeft + 0.5);
      }
    });
  });
});
