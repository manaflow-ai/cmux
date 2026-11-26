// cmux-web-test-timeout: 600
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Scrolling up a long chat mounts each older page's rows a few viewports above the reader, before
// they show (Leo, 2026-11-16: "how about speeding up the scrolling up of chats?", "as in i scroll up
// and it loads the stuff"). Every element those rows held was styled and laid out in the commit that
// mounted them, 1,000 to 2,400 a fling commit, by whatever read came first after the insert.
//
// A row mounted that far from the view now has its contents skipped until it comes near
// (conversation/offscreenRows.ts). The run wheels up through older pages and counts, among the
// mounted rows more than FAR_VIEWPORTS window heights above the window, those whose contents the
// page laid out. It
// fails when any is, and when a row that came into view since misdraws: one whose rendered height is
// not the height the transcript placed it at (the row under it then overlaps it or leaves a gap), or
// whose gap under it no longer takes a click (the clip content-visibility brings along).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
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
  /// Rows this many window heights or more above the window must not be laid out: past the margin in
  /// which Chromium renders a content-visibility: auto element ahead of the view. Measured here: rows
  /// up to 2.45 window heights above were drawn, none past 2.5.
  const FAR_VIEWPORTS = 2.6;

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
        // How many window heights above the window's top a row's placed bottom is (negative: below it).
        // Chromium renders a content-visibility: auto row within a margin of the window (FAR_VIEWPORTS).
        const above = (row: HTMLElement) => {
          const top = Number.parseFloat(row.style.top) + Number.parseFloat(row.style.marginTop || "0");
          const height = Number.parseFloat(row.style.containIntrinsicHeight.replace("auto", "")) || 0;
          return -(box.top + threadTop + top + height) / window.innerHeight;
        };
        const farAbove = rows.filter((row) => above(row) > far);
        const laid = farAbove.filter(laidOut);
        const laidAt = laid.map((row) => Math.round(above(row) * 10) / 10);
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
          // A clipped gap lets the click through to the thread under the rows.
          const hit = document.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2);
          if (!hit || (scroller.contains(hit) && !hit.closest(".acpmux-row")))
            gapMisses.push(`${row.dataset.rowId ?? "?"}:${hit?.className ?? "none"}`);
        }
        return {
          mounted: rows.length,
          offscreenClass: rows.filter((row) => row.classList.contains("acpmux-row--offscreen")).length,
          farAbove: farAbove.length,
          laidOutFarAbove: laid.length,
          laidAt,
          skippedNearest:
            Math.round(Math.min(...rows.filter((row) => !laidOut(row) && above(row) > 0).map(above)) * 10) / 10,
          laidAbove: rows.filter((row) => laidOut(row) && above(row) > 0).length,
          skippedAbove: rows.filter((row) => !laidOut(row) && above(row) > 0).length,
          shown: shown.length,
          shownSkippable: shown.filter((row) => row.classList.contains("acpmux-row--offscreen")).length,
          overlaps,
          gapsChecked,
          gapMisses,
        };
      }, FAR_VIEWPORTS);
      // Pixels: the rows in view that mounted skipped draw exactly as they do without the class. A row
      // drops it once rendered (`shownSkippable` 0); kept, its paint containment set text a pixel off.
      const scroller = page.locator(".acpmux-scroll");
      const painted = () =>
        page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
      await painted();
      const settled = await scroller.screenshot({ animations: "disabled" });
      await painted();
      const withClass = await scroller.screenshot({ animations: "disabled" });
      // Two shots of nothing changed: what the page changes on its own between shots.
      const steady = settled.equals(withClass);
      const unmarked = await page.evaluate(() => {
        const box = document.querySelector<HTMLElement>(".acpmux-scroll")!.getBoundingClientRect();
        const shown = [...document.querySelectorAll<HTMLElement>(".acpmux-scroll .acpmux-row--offscreen")].filter(
          (row) => {
            const rect = row.getBoundingClientRect();
            return rect.bottom > box.top && rect.top < box.bottom;
          },
        );
        for (const row of shown) row.classList.remove("acpmux-row--offscreen");
        return shown.length;
      });
      await painted();
      const withoutClass = await scroller.screenshot({ animations: "disabled" });
      const samePixels = withClass.equals(withoutClass);
      if (process.env.SHOTS_DIR) {
        fs.mkdirSync(process.env.SHOTS_DIR, { recursive: true });
        fs.writeFileSync(path.join(process.env.SHOTS_DIR, "settled.png"), settled);
        fs.writeFileSync(path.join(process.env.SHOTS_DIR, "with-class.png"), withClass);
        fs.writeFileSync(path.join(process.env.SHOTS_DIR, "without-class.png"), withoutClass);
      }
      // Find in Chat finds text in a row whose contents the page skips: it reads the rows' text, not
      // their layout.
      const target = await page.evaluate(() => {
        const skipped = [...document.querySelectorAll<HTMLElement>(".acpmux-scroll .acpmux-row--offscreen")].find(
          (row) =>
            ![...row.children].some(
              (child) =>
                !child.classList.contains("acpmux-row__gap") &&
                (child as HTMLElement).checkVisibility({ contentVisibilityAuto: true }),
            ) && /[A-Za-z]{6,}/.test(row.textContent ?? ""),
        );
        return skipped ? { id: skipped.dataset.rowId!, word: /[A-Za-z]{6,}/.exec(skipped.textContent!)![0] } : null;
      });
      // Every mounted row that holds the word gets a highlight, skipped or laid out.
      let find: { skippedHolding: number; skippedMissed: string[]; laidHolding: number; laidMissed: string[] } | null =
        null;
      if (target) {
        await page.evaluate((text) => window.cmuxAcpmuxActions?.["chat.find"]?.({ text }), target.word);
        await page.waitForSelector(".acpmux-find .find-pill__field");
        find = await page.evaluate(async (word) => {
          const highlighted = () => {
            const registry = (globalThis.CSS as unknown as { highlights?: Map<string, Set<Range>> }).highlights;
            const ids = new Set<string>();
            for (const name of ["acpmux-find", "acpmux-find-active"])
              for (const range of registry?.get(name) ?? []) {
                const id = range.startContainer.parentElement?.closest(".acpmux-row")?.getAttribute("data-row-id");
                if (id) ids.add(id);
              }
            return ids;
          };
          for (let frame = 0; frame < 60 && highlighted().size === 0; frame += 1)
            await new Promise((done) => requestAnimationFrame(() => done(undefined)));
          // Two frames more: the reveal may move the view and mount other rows first.
          for (let frame = 0; frame < 2; frame += 1)
            await new Promise((done) => requestAnimationFrame(() => done(undefined)));
          const ids = highlighted();
          const needle = word.toLowerCase();
          const result = {
            skippedHolding: 0,
            skippedMissed: [] as string[],
            laidHolding: 0,
            laidMissed: [] as string[],
          };
          for (const row of document.querySelectorAll<HTMLElement>(".acpmux-scroll .acpmux-row")) {
            if (!(row.textContent ?? "").toLowerCase().includes(needle)) continue;
            const skipped = ![...row.children].some(
              (child) =>
                !child.classList.contains("acpmux-row__gap") &&
                (child as HTMLElement).checkVisibility({ contentVisibilityAuto: true }),
            );
            const id = row.dataset.rowId ?? "?";
            if (skipped) {
              result.skippedHolding += 1;
              if (!ids.has(id)) result.skippedMissed.push(id);
            } else {
              result.laidHolding += 1;
              if (!ids.has(id)) result.laidMissed.push(id);
            }
          }
          return result;
        }, target.word);
      }
      console.log(
        `transcript-offscreen-rows-skipped: ${JSON.stringify({ pages, ...census, unmarked, steady, samePixels, findTarget: target, find })}`,
      );
      expect(pages).toBeGreaterThanOrEqual(1);
      expect(census.farAbove).toBeGreaterThanOrEqual(10);
      expect(census.laidOutFarAbove).toBe(0);
      expect(census.overlaps).toEqual([]);
      expect(census.gapMisses).toEqual([]);
      expect(census.shownSkippable).toBe(0);
      if (steady) expect(samePixels).toBe(true);
      // A row the find leaves out for its own reasons (a hidden copy, a fold) is left out laid out too.
      if (find)
        expect(find.skippedMissed.length <= find.laidMissed.length || find.skippedMissed.length === 0).toBe(true);
    } finally {
      await pane.close();
    }
  });
});
