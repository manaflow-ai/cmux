// A far rail jump's held window and the indexed prompts between it and the held tail
// (direct.ts `mergeIndexedPage`) are published as one list (`withPlaceholders`). Most held rows
// carry no `seq` (a reply, a call): a sort on `seq` put every one of them after every footer and
// placeholder, so hundreds of footers sat in one run, each with no height, and the transcript
// mounted all of them in one view (bench/chat-fast-scroll.bench.ts rail_click_paint).
import { describe, expect, test } from "bun:test";
import { withPlaceholders } from "./direct";
import type { AcpmuxRow } from "./model";

const row = (id: string, kind: AcpmuxRow["kind"], seq?: number): AcpmuxRow =>
  ({ id, version: 1, at: 1_000, kind, ...(seq !== undefined ? { seq } : {}) }) as AcpmuxRow;

describe("withPlaceholders", () => {
  test("keeps held rows in their order and puts each placeholder at its sequence", () => {
    // Held: turns at 10..13 and 40..43, as OrderedRows orders them (by the record that made each).
    const order = new Map<string, number>([
      ["user-10", 10],
      ["assistant-11", 11],
      ["summary-13", 13],
      ["user-40", 40],
      ["assistant-41", 41],
      ["summary-43", 43],
    ]);
    const held = [
      row("user-10", "user"),
      row("assistant-11", "assistant"),
      row("summary-13", "turnSummary", 13),
      row("user-40", "user"),
      row("assistant-41", "assistant"),
      row("summary-43", "turnSummary", 43),
    ];
    const placeholders = [row("user-30", "user", 30), row("user-20", "user", 20), row("user-50", "user", 50)];
    const out = withPlaceholders(held, placeholders, (each) => order.get(each.id) ?? Infinity);
    expect(out.map((each) => each.id)).toEqual([
      "user-10",
      "assistant-11",
      "summary-13",
      "user-20",
      "user-30",
      "user-40",
      "assistant-41",
      "summary-43",
      "user-50",
    ]);
    // No two footers in a row: each stays under its own turn.
    for (let at = 1; at < out.length; at += 1)
      expect(out[at - 1]!.kind === "turnSummary" && out[at]!.kind === "turnSummary").toBe(false);
  });
});
