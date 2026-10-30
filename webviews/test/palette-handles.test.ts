import { describe, expect, test } from "bun:test";
import { type PaletteRankEntry, rankPalette } from "../src/palette/ranker";

// A row's handles: the short ids a person types to find it (a Chief subagent's `a612`).
// Same cases as cmux-tui/crates/cmux-palette-ranker/tests/handles.rs: both rankers agree.
const entries: PaletteRankEntry[] = [
  { title: "a212 · Chief agents", keywords: ["workspace", "Chief agents"], handles: ["a212"] },
  { title: "a162 · Cmd-T tabs self-close", keywords: ["workspace"], handles: ["a162"] },
  { title: "a112 · cmux WireGuard mesh", keywords: ["workspace"], handles: ["a112"] },
  { title: "github.com/manaflow-ai/cmux/compare/a612b0c...a612d00", keywords: ["workspace"] },
  { title: "about:blank", keywords: ["tab", "acp:01a16c0a-6120-7f80-8aee-aeac17612612"], rankBias: 40 },
  { title: "Markdown pane omnibar back", subtitle: "cmux-next app", keywords: ["workspace"], handles: ["a612"] },
];

function order(query: string, rows: PaletteRankEntry[] = entries): number[] {
  return rankPalette({ entries: rows, query, now: 1_000_000 }).flatMap((section) =>
    section.rows.map((row) => row.index),
  );
}

describe("palette handles", () => {
  test("the handle or its digits rank its row first", () => {
    for (const query of ["a612", "A612", " a612 ", "612"]) expect(order(query)[0]).toBe(5);
    expect(order("a212")[0]).toBe(0);
    expect(order("162")[0]).toBe(1);
  });

  test("a part of a handle is no handle match", () => {
    for (const query of ["61", "a61", "6"]) expect(order(query)[0]).not.toBe(5);
  });

  test("rows without handles rank as before", () => {
    const plain = [{ title: "Mark all read" }, { title: "Markdown pane omnibar back" }];
    expect(order("omnibar", plain)).toEqual([1]);
    expect(order("612", plain)).toEqual([]);
  });
});
