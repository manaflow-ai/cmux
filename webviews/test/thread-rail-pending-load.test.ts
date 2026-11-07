// l10n-allow-file: test fixture prompts, not shipped UI.
// The prompt rail's count-only ("pending") ticks load what they stand for: a hover shows the prompt's
// words, and a click lands on the prompt however far back it is. Leo, 2026-11-03: "the hover previews
// ... aren't loading past the first bits", and "just showing all these doesn't mean anything if i
// can't jump to them... i need to be able to jump to them/the stuff should load after".
//
// A long chat opens with only its recent prompts held and the summary's count naming the rest. The
// prompt index (`loadPromptIndex`, the pane client's one read of every prompt's seq and words) names
// the pending ticks; the rail asks for it when a pending tick is hovered or clicked, at most once in
// flight however many ticks the pointer crosses, and a click then reads history straight through to
// the prompt instead of one page per older prompt.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { installPaintedFrames } from "./support/paintedFrames";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("thread-rail-pending-load.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("thread-rail-pending-load: skipping (run `bunx playwright install chromium`)");
    describe.skip("thread rail pending load", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
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
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Row = { id: string; kind: string; text?: string; version: number; at: number; [key: string]: unknown };
  const row = (id: string, kind: string, text?: string, extra: Record<string, unknown> = {}): Row => ({
    id,
    kind,
    text,
    version: 1,
    at: 1,
    ...extra,
  });
  const TOTAL = 60;
  const HELD = 12;
  /// Prompt n's turn (1-based): its prompt is `user-<n>`, so its seq is n.
  const turn = (n: number) => [
    row(`user-${n}`, "user", `Question number ${n} about the rail.`),
    row(`answer-${n}`, "assistant", `Answer ${n}.\n\nA second paragraph so the turn has some height.`),
    row(`summary-${n}`, "turnSummary", undefined, { status: "completed", durationMs: 1_000 }),
  ];
  const heldRows = (held: number) => Array.from({ length: held }, (_, index) => turn(TOTAL - held + 1 + index)).flat();
  const indexRows = (held: number) =>
    Array.from({ length: TOTAL - held }, (_, index) =>
      row(`user-${index + 1}`, "user", `Question number ${index + 1} about the rail.`),
    );

  async function open(): Promise<Page> {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 1280, height: 820 } });
    await page.emulateMedia({ reducedMotion: "reduce" });
    await installPaintedFrames(page);
    await page.goto(`http://127.0.0.1:${port}/test/browser/thread-minimap.html`);
    await page.waitForFunction(() => "__showRows" in window);
    // The pane client, as direct.ts answers the rail: the prompt index names every prompt older than
    // the held ones after a short read (counted in `__indexReads`), and a read through a seq holds
    // every prompt from it on (counted in `__loads`). Both answers reach the transcript in a later
    // task, as a snapshot does.
    await page.evaluate(
      ({ all, index, total, held }) => {
        const state = window as unknown as {
          __indexReads: number;
          __loads: number[];
          __extra: Record<string, unknown>;
          __rows: unknown[];
          __showRows(rows: unknown, extra: unknown): void;
          __setLoadThrough(load: (seq: number) => Promise<boolean>): void;
          __setPromptIndex(read: () => Promise<boolean>): void;
        };
        state.__indexReads = 0;
        state.__loads = [];
        state.__rows = all.slice((total - held) * 3);
        state.__extra = { promptCount: total };
        state.__setPromptIndex(() => {
          state.__indexReads += 1;
          return new Promise<boolean>((done) =>
            // fixed-wait: the fake client's index read takes a moment, as acpmux's does, so the card opens pending first.
            setTimeout(() => {
              state.__extra = { earlier: index };
              state.__showRows(state.__rows, state.__extra);
              done(true);
            }, 60),
          );
        });
        state.__setLoadThrough((seq) => {
          state.__loads.push(seq);
          return new Promise<boolean>((done) =>
            // fixed-wait: the read's rows reach the transcript in a later task, as a snapshot does.
            setTimeout(() => {
              state.__rows = all.slice((seq - 1) * 3);
              state.__extra = seq > 1 ? { earlier: index.slice(0, seq - 1) } : {};
              state.__showRows(state.__rows, state.__extra);
              done(true);
            }, 0),
          );
        });
        state.__showRows(state.__rows, state.__extra);
      },
      { all: heldRows(TOTAL), index: indexRows(HELD), total: TOTAL, held: HELD },
    );
    await page.waitForSelector("[data-tick]");
    await settle(page);
    return page;
  }
  const settle = (page: Page) =>
    page.evaluate(() => new Promise<void>((done) => requestAnimationFrame(() => requestAnimationFrame(() => done()))));
  const tickAt = (page: Page, index: number) =>
    page.evaluate((at) => {
      const rect = document.querySelector<HTMLElement>(`[data-tick="${at}"]`)!.getBoundingClientRect();
      return { x: rect.left + 8, y: rect.top + rect.height / 2 };
    }, index);
  const tops = (page: Page) =>
    page.evaluate(() =>
      Array.from(document.querySelectorAll<HTMLElement>("[data-tick]")).map(
        (tick) => `${tick.dataset.tick}@${Math.round(tick.getBoundingClientRect().top * 10) / 10}`,
      ),
    );
  const cardText = (page: Page) =>
    page.evaluate(() => document.querySelector(".acpmux-minimap__card .acpmux-minimap__prompt")?.textContent ?? "");

  test("hovering a far pending tick shows that prompt's words", async () => {
    const page = await open();
    try {
      // Prompt 3's tick: the chat holds prompts 49 to 60, and the count names the rest.
      const at = await tickAt(page, 2);
      await page.mouse.move(at.x, at.y);
      await page.waitForSelector(".acpmux-minimap__card");
      await page.waitForFunction(
        () =>
          document
            .querySelector(".acpmux-minimap__card .acpmux-minimap__prompt")
            ?.textContent?.includes("Question number 3 ") === true,
        undefined,
        { timeout: 3_000 },
      );
      expect(await cardText(page)).toContain("Question number 3 ");
      expect(
        await page.evaluate(() => document.querySelector(".acpmux-minimap__card")!.hasAttribute("data-pending")),
      ).toBe(false);
    } finally {
      await page.close();
    }
  });

  test("clicking a far pending tick lands on its prompt in one read, and no tick moves", async () => {
    const page = await open();
    try {
      const before = await tops(page);
      const at = await tickAt(page, 4);
      await page.mouse.click(at.x, at.y);
      const state = () =>
        page.evaluate(() => {
          const w = window as unknown as { __indexReads: number; __loads: number[] };
          return JSON.stringify({
            indexReads: w.__indexReads,
            loads: w.__loads,
            rows: Array.from(document.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id^='user-']"))
              .map((row) => row.dataset.rowId)
              .slice(0, 3),
            ticks: document.querySelectorAll("[data-tick]").length,
          });
        });
      await page
        .waitForSelector('.acpmux-row[data-row-id="user-5"]', { timeout: 5_000 })
        .catch(async (error: unknown) => {
          throw new Error(`${String(error)}; state ${await state()}`);
        });
      await page.waitForFunction(() => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!.getBoundingClientRect();
        const row = document.querySelector<HTMLElement>('.acpmux-row[data-row-id="user-5"]')?.getBoundingClientRect();
        return row !== undefined && row.top - scroller.top >= 0 && row.top - scroller.top < 200;
      });
      // One index read and one read straight through prompt 5: no page per older prompt.
      expect(await page.evaluate(() => (window as unknown as { __indexReads: number }).__indexReads)).toBe(1);
      expect(await page.evaluate(() => (window as unknown as { __loads: number[] }).__loads)).toEqual([5]);
      // The rail drew every prompt's tick from the first frame: none moved while it all loaded. The
      // rail's own list scrolls to keep the lit tick in view, so compare by row.
      const after = await tops(page);
      const placed = (list: string[]) => new Map(list.map((entry) => entry.split("@") as [string, string]));
      const was = placed(before);
      const now = placed(after);
      const shared = [...was.keys()].filter((key) => now.has(key));
      expect(shared.length).toBeGreaterThan(0);
      const offsets = new Set(shared.map((key) => Math.round(Number(now.get(key)) - Number(was.get(key)))));
      expect(offsets.size).toBe(1);
    } finally {
      await page.close();
    }
  });

  test("a sweep across many pending ticks reads the index at most once", async () => {
    const page = await open();
    try {
      const first = await tickAt(page, 0);
      const last = await tickAt(page, 40);
      await page.mouse.move(first.x, first.y);
      await page.mouse.move(last.x, last.y, { steps: 40 });
      await page.waitForFunction(
        () =>
          document.querySelector(".acpmux-minimap__card .acpmux-minimap__prompt")?.textContent?.includes("Question") ===
          true,
        undefined,
        { timeout: 3_000 },
      );
      await page.mouse.move(first.x, first.y, { steps: 40 });
      await settle(page);
      expect(await page.evaluate(() => (window as unknown as { __indexReads: number }).__indexReads)).toBe(1);
      expect(await page.evaluate(() => (window as unknown as { __loads: number[] }).__loads)).toEqual([]);
    } finally {
      await page.close();
    }
  });
});
