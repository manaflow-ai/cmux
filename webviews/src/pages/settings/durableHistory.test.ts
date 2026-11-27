import { describe, expect, test } from "bun:test";
import type { HistoryEntry } from "./appearanceHistory";
import { APPEARANCE_CATEGORIES, appearanceAreas } from "./appearanceUndo";
import {
  areaResetGroup,
  type DurableEntry,
  nextDurableUndo,
  parseDurableHistory,
  planUndo,
  rowGroupId,
  rowsInGroup,
} from "./durableHistory";
import { rowsByKey, schema } from "./schema";

const entry = (revision: number, undoes: number | null = null, origin = "app"): DurableEntry => ({
  revision,
  at: revision * 10,
  origin,
  keys: ["appearance.background"],
  undoes,
});

/** Newest first, as settings.history answers. */
const newestFirst = (...entries: DurableEntry[]) => [...entries].reverse();

describe("the durable settings history (settings.history)", () => {
  test("reads the daemon's decimal strings, newest first, and skips what does not parse", () => {
    const parsed = parseDurableHistory({
      entries: [
        { revision: "9", at: "90", origin: "app", keys: ["a.b"], undoes: "7" },
        { revision: "7", at: "70", origin: "mcp", keys: ["a.b"] },
        { revision: "x", at: "1", origin: "cli", keys: [] },
      ],
    });
    expect(parsed).toEqual([
      { revision: 9, at: 90, origin: "app", keys: ["a.b"], undoes: 7 },
      { revision: 7, at: 70, origin: "mcp", keys: ["a.b"], undoes: null },
    ]);
    expect(parseDurableHistory(null)).toEqual([]);
  });

  // The same walk as cmux-config history::undo_pick (its tests use these cases).
  test("the next undo walks back one change at a time, skipping undos and what they undid", () => {
    const entries = [entry(1), entry(2), entry(3)];
    expect(nextDurableUndo(newestFirst(...entries))?.revision).toBe(3);
    entries.push(entry(4, 3));
    expect(nextDurableUndo(newestFirst(...entries))?.revision).toBe(2);
    entries.push(entry(5, 2), entry(6, 1));
    expect(nextDurableUndo(newestFirst(...entries))).toBeNull();
  });

  test("a change after an undo is undone first", () => {
    const entries = newestFirst(entry(1), entry(2), entry(3, 2), entry(4));
    expect(nextDurableUndo(entries)?.revision).toBe(4);
  });
});

describe("which undo the bar runs", () => {
  const step = (revisions: number[], head: number): HistoryEntry => ({
    label: "Background → Shuffle Paintings",
    changes: [],
    revisions,
    head,
  });

  test("the page's own step is undone through the durable history", () => {
    expect(planUndo(step([3], 3), newestFirst(entry(1), entry(2), entry(3)))).toEqual({ kind: "step" });
  });

  test("a newer change by another writer (an agent, the CLI, a hand edit) is undone first", () => {
    const foreign = entry(4, null, "mcp");
    expect(planUndo(step([3], 3), newestFirst(entry(3), foreign))).toEqual({ kind: "foreign", pick: foreign });
    expect(planUndo(null, newestFirst(foreign))).toEqual({ kind: "foreign", pick: foreign });
  });

  test("a step the file does not hold (a workspace background) stays on the page's own stack", () => {
    expect(planUndo(step([], 3), newestFirst(entry(3)))).toEqual({ kind: "memory" });
  });

  test("a host without the durable history keeps the page's own stack", () => {
    expect(planUndo(step([3], 3), null)).toEqual({ kind: "memory" });
    expect(planUndo(null, null)).toBeNull();
    expect(planUndo(null, [])).toBeNull();
  });
});

describe("Reset <card> and settings.reset_group", () => {
  test("a row's group id is its section and its group key's last part (cmux-config Row::group_id)", () => {
    const row = schema.rows.find((item) => item.group.key)!;
    expect(rowGroupId(row)).toBe(`${row.section}.${row.group.key!.split(".").at(-1)}`);
    expect(rowsInGroup(rowGroupId(row)).map((item) => item.key)).toContain(row.key);
    expect(rowsInGroup(row.section).length).toBeGreaterThanOrEqual(rowsInGroup(rowGroupId(row)).length);
    expect(rowsInGroup("no.such.group")).toEqual([]);
  });

  test("a card resets as its group only when the group is exactly the card's keys", () => {
    let grouped = 0;
    for (const category of APPEARANCE_CATEGORIES) {
      for (const area of appearanceAreas(category)) {
        const group = areaResetGroup(area);
        if (group === null) continue;
        grouped += 1;
        const groupKeys = rowsInGroup(group).map((row) => row.key);
        expect(new Set(groupKeys)).toEqual(new Set(area.keys));
      }
    }
    // Not every card is one group (Personalization draws other pages' groups), but some are.
    expect(grouped).toBeGreaterThan(0);
  });

  test("a card with keys outside its group (a moved or extra key) is not a group reset", () => {
    const row = [...rowsByKey.values()].find((item) => item.group.key)!;
    const others = rowsInGroup(rowGroupId(row)).map((item) => item.key);
    expect(areaResetGroup({ keys: [...others, "no.such.key"] })).toBeNull();
    if (others.length > 1) expect(areaResetGroup({ keys: others.slice(1) })).toBeNull();
  });
});
