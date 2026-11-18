// cmux-web-test-timeout: 300
// ui/Listbox compares what a row draws, not the identity of the callbacks that drew it. A controlled
// caller whose renderItem and itemAttributes are inline arrows passes new ones on every render, and
// re-renders whenever the highlight moves: that must re-render the two rows the highlight moved
// between, not every mounted row. A change to data the caller's renderItem reads from its closure
// (not the item) must still re-render the rows it draws differently, so no row goes stale. Measured
// on a production build in Chromium (test/support/visibleLists.ts), at 1,000 and 10,000 items.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import type { Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { startVisibleLists, type VisibleListsServer } from "./support/visibleLists";

const ROWS = ["ListboxRow", "ListboxInlineRow"];

await requireBrowserLane("visible-lists-listbox-callbacks.browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  let server: VisibleListsServer;
  beforeAll(async () => {
    server = await startVisibleLists();
  });
  afterAll(async () => {
    await server?.stop();
  });

  /** Row renders of each named component across `run`, after its frames. */
  async function rendersAcross(page: Page, run: () => Promise<unknown>) {
    await page.evaluate(() =>
      (window as unknown as { __visibleList: { renderCounts: { start(): void } } }).__visibleList.renderCounts.start(),
    );
    await run();
    await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
    return page.evaluate((names) => {
      const counts = (
        window as unknown as {
          __visibleList: { renderCounts: { stop(): void; read(names: readonly string[]): { renders: number } } };
        }
      ).__visibleList.renderCounts;
      counts.stop();
      return Object.fromEntries(names.map((name) => [name, counts.read([name]).renders]));
    }, ROWS);
  }

  /** The list keeps no Tab stop when controlled: its keys arrive as a field would forward them. */
  const press = (page: Page, key: string) =>
    page.evaluate((key) => {
      const list = (
        window as unknown as { __visibleListControls: { list(): HTMLElement } }
      ).__visibleListControls.list();
      list.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
    }, key);

  const rowText = (page: Page, id: string) =>
    page.evaluate((id) => document.querySelector(`[data-item="${id}"]`)?.textContent ?? null, id);

  const setSuffix = (page: Page, id: string, suffix: string) =>
    page.evaluate(
      ({ id, suffix }) =>
        (window as unknown as { __setSuffix(id: string, suffix: string): void }).__setSuffix(id, suffix),
      { id, suffix },
    );

  for (const n of [1000, 10000]) {
    describe(`a controlled list with inline callbacks, ${n} items`, () => {
      test("a highlight move re-renders at most the two rows it moved between", async () => {
        const open = await server.open("listbox-inline", n);
        const { rows } = await open.counts();
        expect(rows).toBeGreaterThan(4);
        // From the first row, in view: no step scrolls a row in.
        for (let step = 0; step < 5; step++) {
          const counts = await rendersAcross(open.page, () => press(open.page, "ArrowDown"));
          expect({ step, counts }).toEqual({ step, counts: { ListboxRow: 2, ListboxInlineRow: 0 } });
        }
        const hover = await open.measure("hover");
        expect(hover.rowRendersMax).toBeLessThanOrEqual(2);
        console.log(`listbox-inline at ${n}: rows ${rows}, hover ${hover.rowRendersMax} rows ${hover.taskMsP95} ms`);
        await open.close();
      });

      test("one changed item re-renders its row", async () => {
        const open = await server.open("listbox-inline", n);
        const change = await open.measure("changeOne");
        expect(change.rowRendersMax).toBe(1);
        await open.close();
      });

      test("a change to data renderItem reads from its closure re-renders that row, and it shows", async () => {
        const open = await server.open("listbox-inline", n);
        expect(await rowText(open.page, "id-3")).toBe("item 00003 delta");
        const one = await rendersAcross(open.page, () => setSuffix(open.page, "id-3", " (edited)"));
        expect(one).toEqual({ ListboxRow: 1, ListboxInlineRow: 1 });
        expect(await rowText(open.page, "id-3")).toBe("item 00003 delta (edited)");
        expect(await rowText(open.page, "id-4")).toBe("item 00004 echo");
        // Two mounted rows at once, then a row not mounted: only the mounted rows it touches.
        const two = await rendersAcross(open.page, async () => {
          await setSuffix(open.page, "id-5", " *");
          await setSuffix(open.page, "id-6", " *");
        });
        expect(two).toEqual({ ListboxRow: 2, ListboxInlineRow: 2 });
        expect(await rowText(open.page, "id-6")).toBe("item 00006 golf *");
        const none = await rendersAcross(open.page, () => setSuffix(open.page, `id-${n - 1}`, " *"));
        expect(none).toEqual({ ListboxRow: 0, ListboxInlineRow: 0 });
        await open.close();
      });
    });
  }
  test("stable callbacks whose rows draw a new style object each call: a highlight move re-renders two rows", async () => {
    const open = await server.open("listbox-inline&stable=1", 1000);
    for (let step = 0; step < 5; step++) {
      const counts = await rendersAcross(open.page, () => press(open.page, "ArrowDown"));
      expect({ step, counts }).toEqual({ step, counts: { ListboxRow: 2, ListboxInlineRow: 0 } });
    }
    await open.close();
  });
});
