// cmux-web-test-timeout: 600
// l10n-allow-file: fixture listings, not shipped UI.
// The App Store's windowed grid across a column change, in a production build of
// test/browser/apps-catalog-visible-only.html (the real page over 1,000 stand-in listings), in
// Chromium and WebKit. Narrowing or widening the page mid-list across a column breakpoint moves every
// listing to another row, and a row's height follows its cards' width (a description wraps to more
// or fewer lines). The first listing in view stays where it was on every frame, the catalog is as
// tall as its rows, and a scroll moves by what it asks (no row lands at a stale estimate).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { gotoBenchPage, requireProductionReact, serveBenchPage, type BenchPage } from "../../bench/support/benchPage";
import { installPaintedFrames } from "../support/paintedFrames";
import { requireBrowserLane } from "../support/requireBrowserLane";

await requireBrowserLane("apps-catalog-columns.test.ts", async () => {
  setDefaultTimeout(300_000);
  const engines = { chromium, webkit } as const;
  const browsers: Partial<Record<keyof typeof engines, Browser>> = {};
  let served: BenchPage;
  beforeAll(async () => {
    // bun test runs with NODE_ENV=test, under which Vite's build compiles JSX for React's
    // development runtime; the page is built as it ships.
    const mode = process.env.NODE_ENV;
    process.env.NODE_ENV = "production";
    try {
      served = await serveBenchPage("/test/browser/apps-catalog-visible-only.html", { dev: false });
    } finally {
      process.env.NODE_ENV = mode;
    }
    for (const name of Object.keys(engines) as (keyof typeof engines)[])
      browsers[name] = await engines[name].launch({ headless: true });
  }, 300_000);
  afterAll(async () => {
    for (const browser of Object.values(browsers)) await browser?.close();
    await served?.close();
  });

  async function open(engine: keyof typeof engines): Promise<Page> {
    const page = await browsers[engine]!.newPage({ viewport: { width: 1200, height: 800 } });
    await installPaintedFrames(page);
    await gotoBenchPage(page, { ...served, url: `${served.url}#n=1000&layout=grid` });
    await requireProductionReact(page, { dev: served.dev });
    await page.waitForFunction(
      () => window.benchReady === true && !!document.querySelector(".apps-catalog-space .apps-card"),
    );
    await page.evaluate(() => window.cmuxPaintFrame());
    return page;
  }

  /** The page's width from `from` to `to` px, 30,000 px down the catalog: the first listing in
   *  view and where it is on each of 6 frames after, the columns before and after, how far the
   *  catalog's height is from its rows', and how far each of 10 one-viewport scrolls up moved from
   *  what it asked. */
  const columnChange = (page: Page, from: number, to: number, partial = false) =>
    page.evaluate(
      async ({ from, to, partial }) => {
        const root = document.getElementById("root")!;
        const scroller = document.querySelector<HTMLElement>(".apps-scroll")!;
        const cards = () => [...document.querySelectorAll<HTMLElement>(".apps-catalog-space .apps-card")];
        const columns = () => new Set(cards().map((card) => Math.round(card.getBoundingClientRect().left))).size;
        root.style.width = `${from}px`;
        await window.cmuxPaintFrame();
        await window.cmuxPaintFrame(() => (scroller.scrollTop = 30_000));
        await window.cmuxPaintFrame();
        const top = scroller.getBoundingClientRect().top;
        const at = (card: Element | null) => (card ? card.getBoundingClientRect().top - top : null);
        if (partial) {
          // The first row in view cut by half its height: its top half above the view.
          const first = cards()
            .filter((card) => at(card)! + card.offsetHeight > 0)
            .sort((a, b) => at(a)! - at(b)!)[0]!;
          const shift = at(first)! + first.offsetHeight / 2;
          await window.cmuxPaintFrame(() => (scroller.scrollTop += shift));
          await window.cmuxPaintFrame();
        }
        // The first listing in view: the leftmost card of the first row that reaches into the view
        // (its top may be above it).
        const anchor = cards()
          .filter((card) => at(card)! + card.offsetHeight > 0)
          .sort((a, b) => at(a)! - at(b)! || a.getBoundingClientRect().left - b.getBoundingClientRect().left)[0]!;
        const id = anchor.dataset.app!;
        const before = at(anchor)!;
        const columnsBefore = columns();
        const after: (number | null)[] = [];
        await window.cmuxPaintFrame(() => (root.style.width = `${to}px`));
        after.push(at(document.querySelector(`.apps-catalog-space [data-app="${id}"]`)));
        for (let frame = 1; frame < 6; frame++) {
          await window.cmuxPaintFrame();
          after.push(at(document.querySelector(`.apps-catalog-space [data-app="${id}"]`)));
        }
        const rows = Math.ceil(1000 / columns());
        // A card is stretched to its row's height.
        const rowHeight = document.querySelector<HTMLElement>(".apps-catalog-space > .apps-card")!.offsetHeight;
        const space = document.querySelector<HTMLElement>(".apps-catalog-space")!;
        const heightError = space.offsetHeight - (rows * rowHeight + (rows - 1) * 14);
        const jumps: number[] = [];
        for (let step = 0; step < 10; step++) {
          const start = scroller.scrollTop;
          await window.cmuxPaintFrame(() => (scroller.scrollTop -= 400));
          await window.cmuxPaintFrame();
          jumps.push(scroller.scrollTop - (start - 400));
        }
        return { id, before, after, columnsBefore, columnsAfter: columns(), heightError, jumps };
      },
      { from, to, partial },
    );

  /** The page's width from `from` to `to` px and back, 30,000 px down the catalog, with a listing in
   *  view focused: per change, the listings mounted before and after whose card is another element,
   *  how many cards mounted, and whether the focused button still holds focus. */
  const cardsKept = (page: Page, from: number, to: number) =>
    page.evaluate(
      async ({ from, to }) => {
        const root = document.getElementById("root")!;
        const scroller = document.querySelector<HTMLElement>(".apps-scroll")!;
        const cards = () => [...document.querySelectorAll<HTMLElement>(".apps-catalog-space .apps-card")];
        root.style.width = `${from}px`;
        await window.cmuxPaintFrame();
        await window.cmuxPaintFrame(() => (scroller.scrollTop = 30_000));
        await window.cmuxPaintFrame();
        const top = scroller.getBoundingClientRect().top;
        const button = cards()
          .find((card) => card.getBoundingClientRect().top >= top)!
          .querySelector<HTMLButtonElement>(".apps-card-open")!;
        button.focus({ preventScroll: true });
        await window.cmuxPaintFrame();
        const changes: { replaced: string[]; kept: number; mounted: number; focused: boolean }[] = [];
        for (const width of [to, from]) {
          const before = new Map(cards().map((card) => [card.dataset.app!, card]));
          await window.cmuxPaintFrame(() => (root.style.width = `${width}px`));
          const after = cards();
          const kept = after.filter((card) => before.has(card.dataset.app!));
          changes.push({
            replaced: kept.filter((card) => before.get(card.dataset.app!) !== card).map((card) => card.dataset.app!),
            kept: kept.length,
            mounted: after.length - kept.length,
            focused: document.activeElement === button,
          });
          await window.cmuxPaintFrame();
        }
        return changes;
      },
      { from, to },
    );

  // 760 px: two columns; 1000: three; 1200: four. 1000 and 1200 also re-wrap the banner and
  // chips above the catalog, which moves where the catalog starts.
  const changes = [
    [1000, 760],
    [760, 1000],
    [1200, 1000],
    [1000, 1200],
  ] as const;
  for (const engine of Object.keys(engines) as (keyof typeof engines)[])
    for (const [from, to] of changes)
      test(`${engine}: ${from} to ${to} px mid-list keeps the first listing in view in place, and the rows at their height`, async () => {
        const page = await open(engine);
        try {
          const change = await columnChange(page, from, to);
          expect(change.columnsAfter).not.toBe(change.columnsBefore);
          for (const y of change.after) {
            expect(y).not.toBeNull();
            expect(Math.abs(y! - change.before)).toBeLessThanOrEqual(1);
          }
          expect(Math.abs(change.heightError)).toBeLessThanOrEqual(1);
          for (const jump of change.jumps) expect(Math.abs(jump)).toBeLessThanOrEqual(1);
        } finally {
          await page.close();
        }
      });
  // The first row in view half above the top: its first listing, partly in view, stays at the same
  // (negative) offset from the top on every frame. Before, the page held the first row starting
  // below the top, and the partly visible listing moved.
  for (const engine of Object.keys(engines) as (keyof typeof engines)[])
    for (const [from, to] of changes)
      test(`${engine}: ${from} to ${to} px mid-list keeps a partly visible first listing in place`, async () => {
        const page = await open(engine);
        try {
          const change = await columnChange(page, from, to, true);
          expect(change.columnsAfter).not.toBe(change.columnsBefore);
          expect(change.before).toBeLessThan(0);
          for (const y of change.after) {
            expect(y).not.toBeNull();
            expect(Math.abs(y! - change.before)).toBeLessThanOrEqual(1);
          }
        } finally {
          await page.close();
        }
      });
  for (const engine of Object.keys(engines) as (keyof typeof engines)[])
    test(`${engine}: a column change keeps each mounted listing's card element, and focus`, async () => {
      const page = await open(engine);
      try {
        for (const change of await cardsKept(page, 1000, 760)) {
          expect(change.replaced).toEqual([]);
          expect(change.kept).toBeGreaterThan(change.mounted);
          expect(change.focused).toBe(true);
        }
      } finally {
        await page.close();
      }
    });
});
