// cmux-web-test-timeout: 600
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Scrolling up a long chat mounts each older page's rows a few viewports above the reader, before
// they show (Leo, 2026-11-16: "how about speeding up the scrolling up of chats?", "as in i scroll up
// and it loads the stuff"). Every element those rows held was styled and laid out in the commit that
// mounted them, 1,000 to 2,400 a fling commit, by whatever read came first after the insert.
//
// A row mounted that far from the view now has its contents skipped until it comes near
// (conversation/offscreenRows.ts). The run wheels up through older pages and counts, among the
// mounted rows more than FAR_VIEWPORTS above the view, those whose contents the page laid out. It
// fails when any is, and when a row that came into view since misdraws: one whose rendered height is
// not the height the transcript placed it at (the row under it then overlaps it or leaves a gap), or
// whose gap under it no longer takes a click (the clip content-visibility brings along).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser } from "playwright";
import { godLog } from "../bench/godFixture";
import { papercutPane, type PapercutStep } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { traceUpwardAnchors } from "./support/upwardAnchorTrace";

await requireBrowserLane("transcript-offscreen-rows-skipped.test.ts", async () => {
  setDefaultTimeout(420_000);
  let launches = true;
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    launches = false;
  }
  if (!launches) {
    describe.skip("transcript offscreen rows skipped", () => test("no chromium", () => {}));
    return;
  }

  const TURNS = 1200;
  /// Rows this many viewports or more above the view must not be laid out.
  const FAR_VIEWPORTS = 1.5;

  const log = godLog("small", { turns: TURNS, imageEvery: 25, chainEvery: 150 });
  const lead: PapercutStep[] = log.events.map((event) => [
    event.dir,
    event.kind,
    event.msg as Record<string, unknown>,
    event.at,
  ]);
  const prompts = log.events.filter((event) => event.kind === "user_message").length + 1;

  let browser: Browser;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser.close();
  });

  test("chromium: rows an older page mounts far above the view are not laid out until they come near", async () => {
    const pane = await papercutPane(() => browser, {
      turns: 1,
      running: false,
      lead,
      attachPage: 160,
      session: { turnCount: prompts },
      daemonIndexes: true,
    });
    try {
      const page = await pane.open({ width: 1100, height: 800 });
      const view = (await page.locator(".acpmux-scroll").boundingBox())!;
      await page.mouse.move(view.x + view.width / 2, view.y + view.height / 2);
      await page.waitForFunction(() => document.querySelectorAll(".acpmux-row").length > 10, null, {
        timeout: 60_000,
      });
      const pagesBefore = pane.methods.filter((method) => method === "_acpmux/events").length;
      for (let round = 0; round < 4; round++)
        await page.evaluate(traceUpwardAnchors, {
          steps: Array.from({ length: 60 }, (_, frame) => -2 * [40.25, 95.5, 61.75, 128.125][frame % 4]!),
          restFrames: 12,
        });
      const pages = pane.methods.filter((method) => method === "_acpmux/events").length - pagesBefore;
      const census = await page.evaluate((far) => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const box = scroller.getBoundingClientRect();
        const laidOut = (row: HTMLElement) =>
          [...row.children].some(
            (child) =>
              !child.classList.contains("acpmux-row__gap") &&
              (child as HTMLElement).checkVisibility({ contentVisibilityAuto: true }),
          );
        const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")];
        // Placed offsets from the thread's top, which is read once: no layout read of a row itself.
        const thread = scroller.querySelector<HTMLElement>(".acpmux-thread")!;
        const threadTop = thread.getBoundingClientRect().top - box.top;
        const farAbove = rows.filter((row) => {
          const top = Number.parseFloat(row.style.top) + Number.parseFloat(row.style.marginTop || "0");
          const height = Number.parseFloat(row.style.containIntrinsicHeight.replace("auto", "")) || 0;
          return threadTop + top + height < -box.height * far;
        });
        const laid = farAbove.filter(laidOut);
        // Rows on screen: each placed where it draws (the next row's top is its bottom and gap), and
        // its gap under it hit by a click there.
        const shown = rows
          .filter((row) => {
            const rect = row.getBoundingClientRect();
            return rect.bottom > box.top && rect.top < box.bottom;
          })
          .sort((a, b) => a.getBoundingClientRect().top - b.getBoundingClientRect().top);
        const overlaps: string[] = [];
        for (let at = 1; at < shown.length; at += 1) {
          const above = shown[at - 1]!.getBoundingClientRect();
          const below = shown[at]!.getBoundingClientRect();
          if (below.top < above.bottom - 0.5)
            overlaps.push(`${shown[at - 1]!.dataset.rowId}>${shown[at]!.dataset.rowId}`);
        }
        const gapMisses: string[] = [];
        let gapsChecked = 0;
        for (const row of shown) {
          const gap = row.querySelector<HTMLElement>(":scope > .acpmux-row__gap");
          const rect = gap?.getBoundingClientRect();
          if (!gap || !rect || rect.height < 4 || rect.top < box.top || rect.bottom > box.bottom) continue;
          const rowRect = row.getBoundingClientRect();
          if (rect.top < rowRect.bottom) continue;
          gapsChecked += 1;
          const hit = document.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2);
          if (!hit || !row.contains(hit)) gapMisses.push(row.dataset.rowId ?? "?");
        }
        return {
          mounted: rows.length,
          offscreenClass: rows.filter((row) => row.classList.contains("acpmux-row--offscreen")).length,
          farAbove: farAbove.length,
          laidOutFarAbove: laid.length,
          shown: shown.length,
          shownSkippable: shown.filter((row) => row.classList.contains("acpmux-row--offscreen")).length,
          overlaps,
          gapsChecked,
          gapMisses,
        };
      }, FAR_VIEWPORTS);
      console.log(`transcript-offscreen-rows-skipped: ${JSON.stringify({ pages, ...census })}`);
      expect(pages).toBeGreaterThanOrEqual(1);
      expect(census.farAbove).toBeGreaterThanOrEqual(10);
      expect(census.laidOutFarAbove).toBe(0);
      expect(census.overlaps).toEqual([]);
      expect(census.gapMisses).toEqual([]);
    } finally {
      await pane.close();
    }
  });
});
