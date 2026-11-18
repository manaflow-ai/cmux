// cmux-web-test-timeout: 300
// ui/Listbox windows itself past 50 rows, and places the rows it mounts from their measured heights:
// rows of different heights (the steer queue's), a scaled interface (fractional heights: the mention
// menu and the recent files at 110 and 125 percent) and a row that grows after it mounted (a steer
// row gaining its step line) leave no blank area in view and keep the highlighted row in view over
// 200 arrow-key steps. The steer queue (60 chats, both looks, a row gaining its `said` line after it
// mounted), the mention menu and the recent list run as themselves at interface scales 1, 1.1 and
// 1.25. Measured on a production build in Chromium (test/support/visibleLists.ts).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import type { Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { startVisibleLists, type VisibleListsServer } from "./support/visibleLists";

await requireBrowserLane("visible-lists-listbox-measure.browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  let server: VisibleListsServer;
  beforeAll(async () => {
    server = await startVisibleLists();
  });
  afterAll(async () => {
    await server?.stop();
  });

  /** Points every 4 px down the scroller's view that no row covers (a blank area), and the rows
   * that overlap the next one. The list's own padding, at the top and bottom of its content, is not
   * a blank. */
  const coverage = (page: Page) =>
    page.evaluate(() => {
      const scroller = (
        window as unknown as { __visibleListControls: { scroller(): HTMLElement } }
      ).__visibleListControls.scroller();
      const view = scroller.getBoundingClientRect();
      const style = getComputedStyle(scroller);
      const top = view.top + Number.parseFloat(style.borderTopWidth);
      const bottom = top + scroller.clientHeight;
      const contentTop = top + Number.parseFloat(style.paddingTop) - scroller.scrollTop;
      const contentBottom = top + scroller.scrollHeight - Number.parseFloat(style.paddingBottom) - scroller.scrollTop;
      const rows = [...scroller.querySelectorAll<HTMLElement>("[role='option']")].map((row) =>
        row.getBoundingClientRect(),
      );
      const blanks: number[] = [];
      for (let y = Math.ceil(top) + 1; y < bottom - 1; y += 4) {
        if (y < contentTop + 0.5 || y > contentBottom - 0.5) continue;
        if (!rows.some((rect) => rect.top - 0.5 <= y && y <= rect.bottom + 0.5)) blanks.push(Math.round(y - top));
      }
      const sorted = [...rows].sort((a, b) => a.top - b.top);
      const overlaps = sorted.filter((rect, index) => index > 0 && rect.top < sorted[index - 1]!.bottom - 0.5).length;
      return { blanks, overlaps, scrollTop: scroller.scrollTop };
    });

  const activeInView = (page: Page) =>
    page.evaluate(() => {
      const scroller = (
        window as unknown as { __visibleListControls: { scroller(): HTMLElement } }
      ).__visibleListControls.scroller();
      const id = scroller.getAttribute("aria-activedescendant");
      const row = id ? document.getElementById(id) : null;
      const view = scroller.getBoundingClientRect();
      const box = row?.getBoundingClientRect();
      return {
        mounted: !!row,
        inView: !!box && box.top >= view.top - 1 && box.bottom <= view.bottom + 1,
        posinset: row?.getAttribute("aria-posinset") ?? null,
      };
    });

  const nextFrames = (page: Page) =>
    page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));

  /** `steps` presses of `key` from the row at `start` (1-based) in a list of `count`: every 10, the
   * highlighted row is mounted, in view and the one the steps lead to, and the view has no blank. */
  async function walk(page: Page, steps: number, key: "ArrowDown" | "ArrowUp", start: number, count: number) {
    for (let step = 1; step <= steps; step++) {
      await page.keyboard.press(key);
      if (step % 10 === 0 || step === steps) {
        // What a frame paints: the scroll the key caused is handled before it.
        await nextFrames(page);
        const at = key === "ArrowDown" ? Math.min(count, start + step) : Math.max(1, start - step);
        expect({ step, ...(await activeInView(page)) }).toEqual({
          step,
          mounted: true,
          inView: true,
          posinset: String(at),
        });
        const cover = await coverage(page);
        expect({ step, blanks: cover.blanks, overlaps: cover.overlaps }).toEqual({ step, blanks: [], overlaps: 0 });
      }
    }
  }

  /** Focus where the list's keys go: the list, or the field that keeps focus for it. */
  const focusKeys = (page: Page) =>
    page.evaluate(() => {
      const controls = (
        window as unknown as { __visibleListControls: { scroller(): HTMLElement; keyTarget?(): HTMLElement } }
      ).__visibleListControls;
      (controls.keyTarget?.() ?? controls.scroller()).focus();
    });

  const scrollToTop = async (page: Page) => {
    await page.evaluate(() =>
      (window as unknown as { __visibleListControls: { scroller(): HTMLElement } }).__visibleListControls
        .scroller()
        .scrollTo(0, 0),
    );
    await nextFrames(page);
  };

  /** Scrolled through, 200 steps down and back up, then End: no blank and the active row in view. */
  async function scrollAndWalk(page: Page, count: number) {
    await scrollThrough(page);
    await scrollToTop(page);
    await focusKeys(page);
    const steps = Math.min(200, count - 1);
    await walk(page, steps, "ArrowDown", 1, count);
    await walk(page, steps, "ArrowUp", 1 + steps, count);
  }

  async function scrollThrough(page: Page) {
    for (const fraction of [0.1, 0.37, 0.5, 0.83, 1, 0.21]) {
      await page.evaluate((fraction) => {
        const scroller = (
          window as unknown as { __visibleListControls: { scroller(): HTMLElement } }
        ).__visibleListControls.scroller();
        scroller.scrollTop = (scroller.scrollHeight - scroller.clientHeight) * fraction;
      }, fraction);
      await nextFrames(page);
      const cover = await coverage(page);
      expect(cover.blanks).toEqual([]);
      expect(cover.overlaps).toBe(0);
    }
  }

  describe("rows of different heights", () => {
    for (const zoom of ["1", "1.1", "1.25"]) {
      test(`at ${Math.round(Number(zoom) * 100)}% zoom: no blank area while scrolling or over 200 arrow steps, the active row in view`, async () => {
        const open = await server.open(`listbox-variable&zoom=${zoom}`, 2000);
        await scrollAndWalk(open.page, 2000);
        await open.page.keyboard.press("End");
        await nextFrames(open.page);
        expect(await activeInView(open.page)).toEqual({ mounted: true, inView: true, posinset: "2000" });
        expect((await coverage(open.page)).blanks).toEqual([]);
        await open.close();
      });
    }

    test("a row that grows after it mounted pushes the rows below it, leaving no gap or overlap", async () => {
      const open = await server.open("listbox-variable", 2000);
      await open.page.evaluate(() => {
        const scroller = (
          window as unknown as { __visibleListControls: { scroller(): HTMLElement } }
        ).__visibleListControls.scroller();
        scroller.scrollTop = 30 * 26;
      });
      await open.page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
      const mounted = await open.page.evaluate(() =>
        [...document.querySelectorAll("[role='option']")].map((row) => Number(row.getAttribute("aria-posinset")) - 1),
      );
      // Rows in view, above it and out of it grow.
      for (const index of [mounted[2]!, mounted[Math.floor(mounted.length / 2)]!, 5, 1900])
        await open.page.evaluate(
          (index) => (window as unknown as { __growRow(index: number): void }).__growRow(index),
          index,
        );
      await open.page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
      const cover = await coverage(open.page);
      expect(cover.blanks).toEqual([]);
      expect(cover.overlaps).toBe(0);
      await scrollThrough(open.page);
      await open.close();
    });
  });

  /** Scrolls through the whole list, 150 px a step: each row's height as drawn (rows in order sit
   * edge to edge), their sum, and the list's scroll length without its padding. */
  async function rowsThrough(page: Page) {
    const heights = new Map<number, number>();
    for (let top = 0; ; top += 150) {
      const atEnd = await page.evaluate((top) => {
        const scroller = (
          window as unknown as { __visibleListControls: { scroller(): HTMLElement } }
        ).__visibleListControls.scroller();
        scroller.scrollTop = top;
        return scroller.scrollTop + scroller.clientHeight >= scroller.scrollHeight - 1;
      }, top);
      await nextFrames(page);
      const rows = await page.evaluate(() => {
        const scroller = (
          window as unknown as { __visibleListControls: { scroller(): HTMLElement } }
        ).__visibleListControls.scroller();
        return [...scroller.querySelectorAll<HTMLElement>("[role='option']")]
          .map((row) => ({ place: Number(row.getAttribute("aria-posinset")), rect: row.getBoundingClientRect() }))
          .map(({ place, rect }) => ({ place, top: rect.top, bottom: rect.bottom }))
          .sort((a, b) => a.place - b.place);
      });
      for (const [index, row] of rows.entries()) {
        heights.set(row.place, row.bottom - row.top);
        const before = rows[index - 1];
        if (before && before.place === row.place - 1)
          expect({ place: row.place, gap: Math.abs(row.top - before.bottom) <= 0.5 }).toEqual({
            place: row.place,
            gap: true,
          });
      }
      if (atEnd) break;
    }
    const sum = [...heights.values()].reduce((total, height) => total + height, 0);
    const length = await page.evaluate(() => {
      const scroller = (
        window as unknown as { __visibleListControls: { scroller(): HTMLElement } }
      ).__visibleListControls.scroller();
      const style = getComputedStyle(scroller);
      return scroller.scrollHeight - Number.parseFloat(style.paddingTop) - Number.parseFloat(style.paddingBottom);
    });
    return { heights, sum, length };
  }

  test("200 rows of one and three lines: rows edge to edge, the scroll length their sum, a key reveals its row", async () => {
    const open = await server.open("listbox-variable", 200);
    const { page } = open;
    // Every third row has two lines; growing it gives three. The rest have one.
    await page.evaluate(() => {
      for (let index = 0; index < 200; index += 3)
        (window as unknown as { __growRow(index: number): void }).__growRow(index);
    });
    await nextFrames(page);
    const { heights, sum, length } = await rowsThrough(page);
    expect(new Set([...heights.values()].map(Math.round)).size).toBe(2);
    expect(heights.size).toBe(200);
    expect(Math.abs(length - sum)).toBeLessThanOrEqual(1);
    await scrollToTop(page);
    await focusKeys(page);
    const outside = () =>
      page.evaluate(() => {
        const scroller = (
          window as unknown as { __visibleListControls: { scroller(): HTMLElement } }
        ).__visibleListControls.scroller();
        const row = document.getElementById(scroller.getAttribute("aria-activedescendant") ?? "");
        if (!row) return Number.POSITIVE_INFINITY;
        const view = scroller.getBoundingClientRect();
        const box = row.getBoundingClientRect();
        return Math.max(0, view.top - box.top, box.bottom - view.bottom);
      });
    for (const key of [...Array<string>(199).fill("ArrowDown"), "Home", "End"]) {
      await page.keyboard.press(key);
      await nextFrames(page);
      const off = await outside();
      expect({ key, off: off <= 1 }).toEqual({ key, off: true });
    }
    await open.close();
  });

  // The callers: their own rows, styles and keys.
  describe("SteerQueue, 60 chats", () => {
    for (const look of ["rows", "compact"]) {
      for (const scale of ["1", "1.1", "1.25"]) {
        test(`${look} look at interface scale ${scale}: a row gaining its said line after it mounted leaves no blank, the active row in view`, async () => {
          const open = await server.open(`steer-queue&look=${look}&scale=${scale}`, 60);
          await scrollAndWalk(open.page, 60);
          // A step into the chat at row 31: its row gains its said line ("Sending"), which takes the
          // step line's place in the rows look and is hidden in the compact one.
          await walk(open.page, 30, "ArrowDown", 1, 60);
          await open.page.keyboard.type("go on");
          await open.page.keyboard.press("Enter");
          await nextFrames(open.page);
          const said = await open.page.evaluate(
            () => document.querySelector("[role='option'][aria-posinset='31'] .acpmux-steer-said") !== null,
          );
          expect(said).toBe(true);
          const cover = await coverage(open.page);
          expect(cover.blanks).toEqual([]);
          expect(cover.overlaps).toBe(0);
          expect(await activeInView(open.page)).toEqual({ mounted: true, inView: true, posinset: "31" });
          await scrollThrough(open.page);
          await open.close();
        });
      }
    }
  });

  for (const [name, title] of [
    ["mention-menu-scaled", "MentionMenu"],
    ["recent-list", "RecentList"],
  ] as const) {
    describe(`${title}, 2000 rows`, () => {
      for (const scale of ["1", "1.1", "1.25"]) {
        test(`at interface scale ${scale}: no blank area and no drift of the active row over 200 arrow steps`, async () => {
          const open = await server.open(`${name}&scale=${scale}`, 2000);
          await scrollAndWalk(open.page, 2000);
          await open.close();
        });
      }
    });
  }

  // While the list is open: the interface scale (Text Size) changes, or the steer queue's look.
  const setScale = (page: Page, scale: string) =>
    page.evaluate((scale) => (window as unknown as { __setScale(scale: string): void }).__setScale(scale), scale);

  for (const [name, title] of [
    ["mention-menu-scaled", "MentionMenu"],
    ["recent-list", "RecentList"],
  ] as const) {
    test(`${title}: the interface scale changes while it is open, scrolled through once: no blank, the scroll length the rows' sum`, async () => {
      const open = await server.open(name, 300);
      const { page } = open;
      // Every row measured at the first scale, then the view left mid-list.
      await rowsThrough(page);
      await page.evaluate(() => {
        const scroller = (
          window as unknown as { __visibleListControls: { scroller(): HTMLElement } }
        ).__visibleListControls.scroller();
        scroller.scrollTop = (scroller.scrollHeight - scroller.clientHeight) * 0.4;
      });
      await nextFrames(page);
      for (const scale of ["1.25", "1.1"]) {
        await setScale(page, scale);
        await nextFrames(page);
        await nextFrames(page);
        const cover = await coverage(page);
        expect({ scale, blanks: cover.blanks, overlaps: cover.overlaps }).toEqual({ scale, blanks: [], overlaps: 0 });
        const { sum, length } = await rowsThrough(page);
        expect({ scale, length: Math.round(length), sum: Math.round(sum) }).toEqual({
          scale,
          length: Math.round(sum),
          sum: Math.round(sum),
        });
      }
      await scrollToTop(page);
      await focusKeys(page);
      await walk(page, 60, "ArrowDown", 1, 300);
      await open.close();
    });
  }

  test("SteerQueue: the look switches while it is open, the active row deep in the list: no blank, the active row in view", async () => {
    const open = await server.open("steer-queue&look=rows", 60);
    const { page } = open;
    await focusKeys(page);
    await walk(page, 40, "ArrowDown", 1, 60);
    for (const look of ["compact", "rows", "compact"]) {
      await page.evaluate((look) => (window as unknown as { __setLook(look: string): void }).__setLook(look), look);
      await nextFrames(page);
      await nextFrames(page);
      const cover = await coverage(page);
      expect({ look, blanks: cover.blanks, overlaps: cover.overlaps }).toEqual({ look, blanks: [], overlaps: 0 });
      // The next key brings the active row into view at the new heights.
      await page.keyboard.press("ArrowUp");
      await page.keyboard.press("ArrowDown");
      await nextFrames(page);
      expect({ look, ...(await activeInView(page)) }).toEqual({ look, mounted: true, inView: true, posinset: "41" });
      const { sum, length } = await rowsThrough(page);
      expect({ look, off: Math.abs(length - sum) <= 1 }).toEqual({ look, off: true });
    }
    await open.close();
  });
});
