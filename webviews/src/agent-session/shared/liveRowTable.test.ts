import { describe, expect, test } from "bun:test";
import { LiveRowTable } from "./liveRowTable";

describe("LiveRowTable", () => {
  test("keeps the same table until writes pass twice the live rows plus slack", () => {
    const table = new LiveRowTable<object, number>();
    const rows = [{}, {}];
    for (let at = 0; at < 4 + 8; at += 1) table.set(rows[at % 2]!, at);
    expect(table.compacted(rows.length, () => rows, 8)).toBe(table);
  });

  test("past the bound, keeps only the live rows' entries", () => {
    let table = new LiveRowTable<object, number>();
    const live = [{}, {}, {}];
    live.forEach((row, at) => table.set(row, at));
    const gone: object[] = [];
    for (let at = 0; at < 20; at += 1) {
      const row = {};
      gone.push(row);
      table.set(row, 100 + at);
    }
    table = table.compacted(live.length, () => live, 4);
    expect(live.map((row) => table.get(row))).toEqual([0, 1, 2]);
    expect(gone.some((row) => table.has(row))).toBe(false);
    // The new table counts from its kept entries: the next few writes keep it.
    table.set(live[0]!, 7);
    expect(table.compacted(live.length, () => live, 4)).toBe(table);
  });

  test("keeps an entry whose value is undefined", () => {
    const table = new LiveRowTable<object, number | undefined>();
    const row = {};
    table.set(row, undefined);
    const next = table.compacted(0, () => [row], 0);
    expect(next).not.toBe(table);
    expect(next.has(row)).toBe(true);
  });
});
