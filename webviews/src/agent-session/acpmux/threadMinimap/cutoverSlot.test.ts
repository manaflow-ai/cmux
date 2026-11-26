import { expect, test } from "bun:test";
import { cutoverSlot } from "./cutoverSlot";
import { tickRanges } from "./tickWindow";

test("pending and indexed history precede the held entries, including in a filtered rail", () => {
  const rail = { heldStart: 5, items: [2, 10, 40].map((index) => ({ index })) };
  const all = [[0, 10]] as const;
  expect(cutoverSlot(rail, 0, all)).toBe(5);
  expect(cutoverSlot(rail, 8, all)).toBe(6);
  expect(cutoverSlot(rail, 35, all)).toBe(7);
  expect(cutoverSlot(rail, 45, all)).toBe(8);
  expect(cutoverSlot({ heldStart: 5, items: [] }, 3, all)).toBe(5);
});

test("only the drawn window and its neighbors are read in a million-prompt rail", () => {
  const count = 1_000_000;
  const ranges = tickRanges(count, 5_000_000, 400, [17]);
  let probes = 0;
  const items = new Proxy(Array<{ index: number }>(count), {
    get(array, key) {
      if (key === "length") return array.length;
      const at = Number(key);
      expect(ranges.some(([from, to]) => at >= from - 1 && at <= to)).toBe(true);
      probes++;
      return { index: at * 4 };
    },
  });
  const rail = { heldStart: 0, items };
  expect(cutoverSlot(rail, 2_000_001, ranges)).toBe(500_001);
  expect(probes).toBeLessThan(14);
  expect(cutoverSlot(rail, 201, ranges)).toBeUndefined();
});
