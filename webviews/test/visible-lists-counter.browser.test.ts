// cmux-web-test-timeout: 300
// The visible-lists counter counts rows by the case's row selector, not by component name: a row
// drawn by inline JSX has no name, and a name count read 0 renders for it however many rows re-ran.
// - A list of inline rows (no row component) re-runs every mounted row on a hover: the count is
//   the mounted rows, where the name count reads 0.
// - A case whose rowSelector is missing or matches no row fails at `open`, so no case counts 0 for
//   rows it never named.
// - On the named cases the selector count is the name count, but where the names miss a row that
//   re-rendered (the combobox's Base UI items, on a hover).
// Measured on a production build in Chromium (test/support/visibleLists.ts).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { startVisibleLists, type VisibleListsServer, type VisibleStep } from "./support/visibleLists";

await requireBrowserLane("visible-lists-counter.browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  let server: VisibleListsServer;
  beforeAll(async () => {
    server = await startVisibleLists();
  });
  afterAll(async () => {
    await server?.stop();
  });

  test("inline rows: a hover counts every mounted row the map re-ran, not 0", async () => {
    const open = await server.open("inline-rows", 1000);
    const { rows } = await open.counts();
    expect(rows).toBe(1000);
    const hover = await open.measure("hover", 5);
    expect({ max: hover.rowRendersMax, mean: hover.rowRendersMean }).toEqual({ max: rows, mean: rows });
    expect(hover.byNameMax).toBe(0);
    // A scroll step re-renders nothing: the rows are all mounted and nothing reads the offset.
    const scroll = await open.measure("scroll", 5);
    expect(scroll.rowRendersMax).toBe(0);
    await open.close();
  });

  describe("a case that names no row fails", () => {
    test("rowSelector matches no row in the list", async () => {
      await expect(server.open("unnamed-rows", 100)).rejects.toThrow(
        'visible-lists case "unnamed-rows" (n=100) rowSelector "[role=\\"option\\"]" matches no row in its list after mount',
      );
    });
    test("no rowSelector", async () => {
      await expect(server.open("unnamed-rows&missing=1", 100)).rejects.toThrow("has no rowSelector after mount");
    });
  });

  const named: { name: string; steps: VisibleStep[]; namesMiss?: Partial<Record<VisibleStep, number>> }[] = [
    { name: "listbox", steps: ["scroll", "hover", "changeOne", "resize"] },
    { name: "virtual-list", steps: ["scroll", "hover", "changeOne", "resize"] },
    // A hover moves Base UI's highlight between two items: the items re-render, the case's named
    // row content does not.
    { name: "combobox", steps: ["type", "scroll", "hover", "changeOne", "resize"], namesMiss: { hover: 2 } },
  ];
  for (const { name, steps, namesMiss } of named) {
    test(`${name}: the selector count is the name count, but for rows the names miss`, async () => {
      const seen: Record<string, { rows: number; byName: number }> = {};
      const wanted: Record<string, { rows: number; byName: number }> = {};
      for (const step of steps) {
        // A fresh page per step, as the bench takes one.
        const open = await server.open(name, 1000);
        const numbers = await open.measure(step, 8);
        await open.close();
        seen[step] = { rows: numbers.rowRendersMax, byName: numbers.byNameMax };
        wanted[step] =
          namesMiss?.[step] !== undefined
            ? { rows: namesMiss[step]!, byName: 0 }
            : {
                rows: numbers.byNameMax,
                byName: numbers.byNameMax,
              };
      }
      console.log(`${name} at 1000: ${JSON.stringify(seen)}`);
      expect(seen).toEqual(wanted);
    });
  }
});
