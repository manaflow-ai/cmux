// l10n-allow-file: test fixture prompts, not shipped UI.
// The prompt rail stays hoverable when its chat column gets narrow (Leo, 2026-11-03: "when the scroll
// rail resizes i can no longer hover on it :(" then "*when the pane gets real small horizontally").
// The rail's inset follows the pane (`.acpmux-shell`), never the chat column (#30436), so a column
// narrower than its pane (Session Info beside it) leaves the resting rail over the text's edge: it is
// drawn there, dimmed (#30190), and its own box takes no pointer so the text keeps its clicks. Its hover
// strip stopped at the text edge, short of the ticks it draws, so hovering them did nothing. The strip
// now reaches over the drawn resting ticks. Real Chromium on the transcript harness, the pointer moved
// in from the text as a person moves it.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("thread-rail-narrow-hover.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("thread-rail-narrow-hover: skipping (run `bunx playwright install chromium`)");
    describe.skip("thread rail narrow hover", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const out = process.env.FAST_CHECKS_OUT;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/thread-minimap.html");
    browser = await chromium.launch({ headless: true });
    if (out) await mkdir(out, { recursive: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const row = (id: string, kind: string, text?: string, extra: Record<string, unknown> = {}) => ({
    id,
    kind,
    text,
    version: 1,
    at: 1,
    ...extra,
  });
  const rows = Array.from({ length: 18 }, (_, index) => [
    row(`user-${index + 1}`, "user", `Reply with only the word ok and the number ${index + 1}.`),
    row(`answer-${index + 1}`, "assistant", `ok ${index + 1}\n\nA second paragraph so the turn has some height.`),
    row(`summary-${index + 1}`, "turnSummary", undefined, { status: "completed", durationMs: 1_000 }),
  ]).flat();

  /// A pane `pane` px wide whose chat column is `column` px: the rest stands in for a side column, as
  /// Session Info's beside the chat (the transcript reads the pane's width from `.acpmux-shell`).
  async function open(pane: number, column: number, motion: "reduce" | "no-preference"): Promise<Page> {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: pane, height: 820 } });
    await page.emulateMedia({ reducedMotion: motion });
    await page.goto(`http://127.0.0.1:${port}/test/browser/thread-minimap.html`);
    await page.waitForFunction(() => "__showRows" in window);
    await page.evaluate(
      ({ shown, side }) => {
        // The shell's padding stands in for the side column: the shell's clientWidth is the pane's,
        // the transcript's the column's.
        const root = document.getElementById("root")!;
        root.classList.add("acpmux-shell");
        Object.assign(root.style, { flexDirection: "column", boxSizing: "border-box", paddingRight: `${side}px` });
        (window as unknown as { __showRows(rows: unknown): void }).__showRows(shown);
      },
      { shown: rows, side: pane - column },
    );
    await page.waitForSelector('[data-tick="3"]');
    await page.waitForFunction(
      (width) => Math.round(document.querySelector(".acpmux-scroll")!.getBoundingClientRect().width) === width,
      column,
    );
    // Two frames: the rail places itself from the measured pane after the resize lands.
    await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
    return page;
  }

  /// Moves the pointer in from the text onto tick 3's drawn bar, as a person reaches for the rail.
  async function hoverDrawnTick(page: Page) {
    const at = await page.evaluate(() => {
      const bar = document.querySelector<HTMLElement>('[data-tick="3"] .acpmux-minimap__bar')!.getBoundingClientRect();
      const text = document.querySelector<HTMLElement>(".acpmux-scroll")!.getBoundingClientRect();
      return {
        x: bar.left + Math.min(2, bar.width / 2),
        y: bar.top + bar.height / 2,
        from: text.left + text.width / 2,
      };
    });
    await page.mouse.move(at.from, at.y);
    await page.mouse.move(at.x, at.y, { steps: 12 });
    return at;
  }

  const shown = (page: Page) =>
    page.evaluate(() => ({
      hovering: document.querySelector(".acpmux-minimap__rail")?.hasAttribute("data-hovering") ?? false,
      active: document.querySelectorAll('[data-tick][data-tone="active"]').length,
      card: document.querySelector(".acpmux-minimap__card") !== null,
    }));

  // Pane and chat column widths: a plain narrow pane, and columns narrower than their pane by a side
  // column, down to a column at the pane's smallest.
  const CASES = [
    { pane: 160, column: 160 },
    { pane: 900, column: 300 },
    { pane: 1000, column: 200 },
    { pane: 1280, column: 760 },
  ];
  for (const motion of ["no-preference", "reduce"] as const)
    for (const { pane, column } of CASES)
      test(`a ${column} px chat column in a ${pane} px pane: hovering the drawn rail opens its preview (${motion})`, async () => {
        const page = await open(pane, column, motion);
        try {
          const rest = await page.evaluate(
            () => document.querySelector(".acpmux-minimap__rail")!.getBoundingClientRect().left,
          );
          await hoverDrawnTick(page);
          await page
            .waitForFunction(() => document.querySelector(".acpmux-minimap__card") !== null, undefined, {
              timeout: 3_000,
            })
            .catch(() => {});
          const after = await shown(page);
          if (out && !after.card)
            await page.screenshot({ path: path.join(out, `narrow-hover-${pane}-${column}-${motion}.png`) });
          expect(after).toEqual({ hovering: true, active: 1, card: true });
          // The rail is where it rested: the pane's edge places it, never the chat column (#30436).
          const hovered = await page.evaluate(
            () => document.querySelector(".acpmux-minimap__rail")!.getBoundingClientRect().left,
          );
          expect(hovered).toBe(rest);
        } finally {
          await page.close();
        }
      });
});
