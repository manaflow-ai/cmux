// Turn rules taken from the reference prototype port (#16759): N previous messages, one
// edited-files card per turn, and the fold label without a tool-call count.
import { describe, expect, test } from "bun:test";
import { translatorFor } from "../i18n";
import type { AcpmuxRow } from "../model";
import { turnView, workedLabel } from "./turns";

const english = translatorFor("en");

const row = (id: string, kind: string, at: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  version: 1,
  at,
  kind,
  ...extra,
});
const tool = (id: string, kind: string, path?: string) => ({
  kind: "tool",
  text: `${kind} ${path ?? id}`,
  tool: {
    id,
    title: `${kind} ${path ?? id}`,
    kind,
    status: "completed",
    ...(path ? { diffs: [{ path, oldText: "a\n", newText: "b\n" }] } : {}),
  },
});
const ids = (rows: AcpmuxRow[]) => rows.map((entry) => entry.id);

describe("turn rules", () => {
  test("an earlier turn without a summary folds under N previous messages", () => {
    const rows = [
      row("u1", "user", 0, { text: "old" }),
      row("t1", "activity", 1, { items: [tool("r", "read"), tool("x", "execute")] }),
      row("c1", "assistant", 2, { text: "note" }),
      row("t2", "activity", 3, { items: [tool("r2", "read")] }),
      row("a1", "assistant", 4, { text: "answer" }),
      row("u2", "user", 10, { text: "new" }),
    ];
    const view = turnView(rows, new Set(), { now: 1_000 });
    expect(ids(view)).toEqual(["u1", "worked-u1", "a1", "u2"]);
    expect(workedLabel(english, view[1]!)).toBe("4 previous messages");
    expect(ids(turnView(rows, new Set(["worked-u1"]), { now: 1_000 }))).toEqual([
      "u1",
      "worked-u1",
      "t1",
      "c1",
      "t2",
      "a1",
      "u2",
    ]);
  });

  test("a turn's edits close it as one card that keeps the first edit's id", () => {
    const rows = [
      row("u", "user", 0, { text: "edit two files" }),
      row("e1", "activity", 1, { items: [tool("w1", "edit", "/r/a.ts")], toolCount: 1 }),
      row("e2", "activity", 2, { items: [tool("w2", "edit", "/r/b.ts")], toolCount: 1, version: 3 }),
      row("a", "assistant", 3, { text: "Done." }),
      row("s", "turnSummary", 4, { durationMs: 4, toolCount: 2, status: "completed" }),
    ];
    const view = turnView(rows, new Set(), { now: 1_000 });
    expect(ids(view)).toEqual(["u", "worked-u", "a", "e1", "s"]);
    const card = view[3]!;
    expect(card.items?.map((item) => item.tool?.id)).toEqual(["w1", "w2"]);
    // The edits' versions summed, odd so it differs from the live rows it replaces.
    expect(card.version).toBe((1 + 3) * 2 + 1);
  });

  test("the fold reads as a duration, without a tool-call count", () => {
    expect(workedLabel(english, row("w", "worked", 0, { durationMs: 76_000, toolCount: 3 }))).toBe("Worked for 1m 16s");
    expect(workedLabel(english, row("w", "worked", 0, { durationMs: 40_000, status: "cancelled" }))).toBe(
      "You stopped after 40s",
    );
    expect(workedLabel(english, row("w", "worked", 0, { previous: 1 }))).toBe("1 previous message");
  });
});
