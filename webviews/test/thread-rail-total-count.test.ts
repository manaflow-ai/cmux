// l10n-allow-file: test fixture prompts, not shipped UI.
// The prompt rail takes its length from the chat's prompt count, not from the prompts loaded so far.
// Leo, 2026-11-03: "as for the left side scroll rail thing, can it be bigger even without having all
// the prompts loaded? like it can read the count metadata right? with the scroll thing and whatever to
// be able to go way up?", then "mostly i just don't like it when the thing shifts and whatnot trying to
// center itself".
//
// The snapshot's `promptCount` (the summary's turnCount, while the prompt index has not answered or on a
// daemon without one) gives every prompt its tick on the first frame. Loading older history, page by
// page or from the index, only fills those ticks in: no tick moves. In a real engine, since where a tick
// draws is the rail's centered box, its list and the CSS together.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { installPaintedFrames } from "./support/paintedFrames";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("thread-rail-total-count.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("thread-rail-total-count: skipping (run `bunx playwright install chromium`)");
    describe.skip("thread rail total count", () => test("chromium", () => {}));
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
  const TOTAL = 45;
  /// Prompt n's turn (1-based): its prompt is `user-<n>`, so its seq is n.
  const turn = (n: number) => [
    row(`user-${n}`, "user", `Question number ${n} about the rail.`),
    row(`answer-${n}`, "assistant", `Answer ${n}.\n\nA second paragraph so the turn has some height.`),
    row(`summary-${n}`, "turnSummary", undefined, { status: "completed", durationMs: 1_000 }),
  ];
  /// The rows of the last `held` prompts, as the open page holds them.
  const heldRows = (held: number) => Array.from({ length: held }, (_, index) => turn(TOTAL - held + 1 + index)).flat();
  /// The prompt index's rows for the prompts before the last `held` ones.
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
    return page;
  }
  const show = (page: Page, rows: Row[], extra: { earlier?: Row[]; promptCount?: number }) =>
    page.evaluate(
      ([shown, more]) =>
        (window as unknown as { __showRows(rows: unknown, extra: unknown): void }).__showRows(shown, more),
      [rows, extra] as const,
    );
  /// Two painted frames, so the rail's layout effects and the list's scroll have run.
  const settle = (page: Page) =>
    page.evaluate(() => new Promise<void>((done) => requestAnimationFrame(() => requestAnimationFrame(() => done()))));
  /// Every drawn tick's place: its row and its top in the page, with the rail's box.
  const ticks = (page: Page) =>
    page.evaluate(() => {
      const rail = document.querySelector<HTMLElement>("nav.acpmux-minimap__rail")!.getBoundingClientRect();
      const all = Array.from(document.querySelectorAll<HTMLElement>("[data-tick]")).map((tick) => ({
        index: Number(tick.dataset.tick),
        setSize: Number(tick.closest("li")?.getAttribute("aria-setsize")),
        top: Math.round(tick.getBoundingClientRect().top * 10) / 10,
      }));
      return { rail: { top: Math.round(rail.top), height: Math.round(rail.height) }, all };
    });
  /// Prompt n's tick (1-based), counted from the latest prompt, which is always the last tick.
  const topOf = (shown: Awaited<ReturnType<typeof ticks>>, n: number) => {
    const count = shown.all[0]?.setSize ?? 0;
    return shown.all.find((tick) => tick.index === count - (TOTAL - n) - 1)?.top;
  };

  test("10,000 count-only prompts first paint benchmark", async () => {
    const samples: number[] = [];
    const rows = Array.from({ length: 12 }, (_, index) => turn(9989 + index)).flat();
    for (let repeat = 0; repeat < 5; repeat++) {
      const page = await open();
      try {
        const elapsed = await page.evaluate((shown) => {
          const start = performance.now();
          (window as unknown as { __showRows(rows: unknown, extra: unknown): void }).__showRows(shown, {
            promptCount: 10000,
          });
          return new Promise<number>((resolve, reject) => {
            const deadline = setTimeout(() => {
              stop();
              reject(new Error("10,000-turn rail did not reach its final frame"));
            }, 10000);
            const stop = window.cmuxAfterPaint(() => {
              const list = document.querySelector<HTMLElement>(".acpmux-minimap__list");
              const last = list?.querySelector<HTMLElement>('[data-tick="9999"]');
              const rect = last?.getBoundingClientRect();
              const box = list?.getBoundingClientRect();
              if (
                list?.scrollHeight === 100000 &&
                rect &&
                box &&
                rect.top >= box.top &&
                rect.bottom <= box.bottom + 1
              ) {
                clearTimeout(deadline);
                resolve(performance.now() - start);
                return false;
              }
            });
          });
        }, rows);
        samples.push(elapsed);
        expect((await ticks(page)).all.at(-1)?.index).toBe(9999);
      } finally {
        await page.close();
      }
    }
    const sorted = [...samples].sort((a, b) => a - b);
    console.log(
      `rail-first-paint ${JSON.stringify({ turns: 10000, held: 12, samples_ms: samples, median_ms: sorted[2] })}`,
    );
  });

  test("10,000 count-only prompts keep the same rail through paging and indexing", async () => {
    const page = await open();
    const count = 10000;
    const held = (n: number) => Array.from({ length: n }, (_, index) => turn(count - n + index + 1)).flat();
    try {
      await show(page, held(12), { promptCount: count });
      await page.waitForSelector('[aria-setsize="10000"]');
      await settle(page);
      const first = await ticks(page);
      expect(first.all.length).toBeLessThan(150);
      expect(first.all.at(-1)?.index).toBe(count - 1);
      const extent = () => page.evaluate(() => document.querySelector(".acpmux-minimap__list")!.scrollHeight);
      const initialExtent = await extent();
      expect(initialExtent).toBe(count * 20);
      await show(page, held(24), { promptCount: count });
      await settle(page);
      const paged = await ticks(page);
      expect(paged).toEqual(first);
      const earlier = Array.from({ length: count - 24 }, (_, index) => turn(index + 1)[0]!);
      await show(page, held(24), { earlier });
      await settle(page);
      expect(await ticks(page)).toEqual(first);
      expect(await extent()).toBe(initialExtent);
      // Browsing the count-only prefix still draws real ticks at their absolute row numbers.
      await show(page, held(24), { promptCount: count });
      await page.locator(".acpmux-minimap__list").evaluate((list) => {
        list.scrollTop = 0;
        list.dispatchEvent(new Event("scroll"));
      });
      await settle(page);
      expect(await page.locator('[data-tick="0"]').count()).toBe(1);
    } finally {
      await page.close();
    }
  });

  test("the first frame draws a tick for every prompt the count names, held or not", async () => {
    const page = await open();
    await show(page, heldRows(12), { promptCount: TOTAL });
    await page.waitForSelector("[data-tick]");
    await settle(page);
    const shown = await ticks(page);
    expect(shown.all[0]!.setSize).toBe(TOTAL);
    // The fixed box stays 480 px while the list scrolls all 45 prompts.
    expect(shown.rail.height).toBe(480);
    await page.close();
  });

  test("no tick moves while older history loads, page by page and then from the prompt index", async () => {
    const page = await open();
    await show(page, heldRows(12), { promptCount: TOTAL });
    await page.waitForSelector("[data-tick]");
    await settle(page);
    const first = await ticks(page);
    const watched = [34, 38, 41, 45];
    const before = watched.map((n) => topOf(first, n));
    expect(before.every((top) => top !== undefined)).toBe(true);
    // An older page lands: twenty-four prompts held, the index still out.
    await show(page, heldRows(24), { promptCount: TOTAL });
    await settle(page);
    const paged = await ticks(page);
    expect(watched.map((n) => topOf(paged, n))).toEqual(before);
    expect(paged.rail).toEqual(first.rail);
    // The index answers: every prompt older than the held ones, and no count.
    await show(page, heldRows(24), { earlier: indexRows(24) });
    await settle(page);
    const indexed = await ticks(page);
    expect(watched.map((n) => topOf(indexed, n))).toEqual(before);
    expect(indexed.rail).toEqual(first.rail);
    await page.close();
  });

  test("a click on a tick for a prompt not loaded yet pages in until it is held, then lands on it", async () => {
    const page = await open();
    await page.evaluate(
      ({ all, total }) => {
        const state = window as unknown as {
          __loads: number[];
          __held: number;
          __showRows(rows: unknown, extra: unknown): void;
          __setLoadThrough(load: (seq: number) => Promise<boolean>): void;
        };
        state.__loads = [];
        state.__held = 12;
        // Each read holds twelve more prompts and answers true, as the pane's client does once the
        // prompt at `seq` is held. The rows reach the transcript in a later task, as a snapshot does.
        state.__setLoadThrough((seq) => {
          state.__loads.push(seq);
          state.__held = Math.min(total, state.__held + 12);
          const held = state.__held;
          return new Promise<boolean>((done) =>
            setTimeout(() => {
              state.__showRows(all.slice((total - held) * 3), held < total ? { promptCount: total } : {});
              done(true);
            }, 0),
          );
        });
      },
      { all: heldRows(TOTAL), total: TOTAL },
    );
    await show(page, heldRows(12), { promptCount: TOTAL });
    await page.waitForSelector("[data-tick]");
    await settle(page);
    const at = await page.evaluate(() => {
      const rect = document.querySelector<HTMLElement>('[data-tick="4"]')!.getBoundingClientRect();
      return { x: rect.left + 8, y: rect.top + rect.height / 2 };
    });
    await page.mouse.click(at.x, at.y);
    await page.waitForSelector('.acpmux-row[data-row-id="user-5"]');
    // One read per page: before prompt 34, then 22, then 10. None asked twice.
    expect(await page.evaluate(() => (window as unknown as { __loads: number[] }).__loads)).toEqual([33, 21, 9]);
    // It landed on prompt 5: its row is near the top of the view.
    const landed = await page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!.getBoundingClientRect();
      const row = document.querySelector<HTMLElement>('.acpmux-row[data-row-id="user-5"]')!.getBoundingClientRect();
      return row.top - scroller.top;
    });
    expect(landed).toBeGreaterThanOrEqual(0);
    expect(landed).toBeLessThan(200);
    await page.close();
  });

  test("a tick for a prompt not loaded yet pages history in when clicked, and its card fills in once it arrives", async () => {
    const page = await open();
    await page.evaluate(() => {
      const calls: number[] = [];
      (window as unknown as { __loads: number[] }).__loads = calls;
      (window as unknown as { __setLoadThrough(load: (seq: number) => Promise<boolean>): void }).__setLoadThrough(
        (seq) => {
          calls.push(seq);
          return new Promise<boolean>(() => {});
        },
      );
    });
    await show(page, heldRows(12), { promptCount: TOTAL });
    await page.waitForSelector("[data-tick]");
    await settle(page);
    // Prompt 5's tick: nothing about it is loaded yet.
    const at = await page.evaluate(() => {
      const rect = document.querySelector<HTMLElement>('[data-tick="4"]')!.getBoundingClientRect();
      return { x: rect.left + 8, y: rect.top + rect.height / 2 };
    });
    await page.mouse.move(at.x, at.y);
    await page.waitForSelector('[data-tick="4"][data-tone="active"]');
    await page.waitForSelector(".acpmux-minimap__card[data-pending]");
    await page.mouse.click(at.x, at.y);
    // The click asks for the page before the held ones: the oldest held prompt is 34.
    await page.waitForFunction(() => ((window as unknown as { __loads: number[] }).__loads.length ?? 0) > 0);
    expect(await page.evaluate(() => (window as unknown as { __loads: number[] }).__loads[0])).toBe(33);
    // The index answers while the card is open: its prompt fills in at the same place.
    await show(page, heldRows(12), { earlier: indexRows(12) });
    await page.waitForFunction(() =>
      document
        .querySelector(".acpmux-minimap__card .acpmux-minimap__prompt")
        ?.textContent?.includes("Question number 5 "),
    );
    expect(
      await page.evaluate(() => document.querySelector(".acpmux-minimap__card")!.hasAttribute("data-pending")),
    ).toBe(false);
    await page.close();
  });
});
