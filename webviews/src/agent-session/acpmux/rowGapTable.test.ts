// l10n-allow-file: transcript geometry fixtures.
// The gap between every adjacent pair of row kinds, laid out through layoutConversation (the one owner of
// placement), printed as a table and asserted (Leo, 2026-11-21: "the spacing is just insanely shit here. way too
// close. no way. we can measure all of these. we can deterministically see when these come in").
import { expect, test } from "bun:test";
import { BACKGROUND_TURN } from "./conversation/backgroundTurns";
import { WORKED } from "./conversation/turns";
import { layoutConversation, MESSAGE_RUN, type AcpmuxRow } from "./model";
import { type RowGapLook } from "./transcriptGrid";

const row = (id: string, kind: string, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: 0,
  ...fields,
});
const tool = (id: string, text: string, kind = "execute") => ({
  kind: "tool" as const,
  text,
  tool: { id, title: text, kind, status: "completed" },
});

/// One row of each kind a Leo screenshot shows, built fresh per slot so a pair never shares an id.
export const KINDS: Record<string, (id: string) => AcpmuxRow> = {
  prompt: (id) => row(id, "user", { text: "Go" }),
  reply: (id) => row(id, "assistant", { text: "Done." }),
  footer: (id) => row(id, "turnSummary", { text: "Done.", durationMs: 1000, status: "completed" }),
  worked: (id) => row(id, WORKED, { durationMs: 13_000 }),
  run: (id) => row(id, "activity", { items: [tool(`${id}-t`, "ls")] }),
  peer: (id) =>
    row(id, "user", { incoming: { kind: "message", message: { name: "peer", text: "Report", raw: "Report" } } }),
  bgTask: (id) => row(id, "backgroundTask", { text: "Background task finished" }),
  group: (id) => row(id, MESSAGE_RUN, { foldOpen: true } as Partial<AcpmuxRow>),
  bgRun: (id) => row(id, "activity", { inBackground: "bg-x", items: [tool(`${id}-t`, "ls")] }),
  bgReply: (id) => row(id, "assistant", { text: "Done.", inBackground: "bg-x" }),
  bgLine: (id) => row(id, BACKGROUND_TURN, { background: { id, trigger: "scheduled", running: false, quiet: true } }),
};

export type GapTable = Record<string, Record<string, number>>;
/// gap[a][b]: the px from a's bottom to b's top when b follows a, every row's own height taken as 22.
export function gapTable(): GapTable {
  const table: GapTable = {};
  for (const a of Object.keys(KINDS)) {
    table[a] = {};
    for (const b of Object.keys(KINDS)) {
      const layout = layoutConversation([KINDS[a]!("a"), KINDS[b]!("b")], 720);
      table[a]![b] = layout.tops[1]! - (layout.tops[0]! + layout.heights[0]!);
    }
  }
  return table;
}

/// The table drawn under one look (`<html data-row-gap>`).
function under<T>(look: RowGapLook, body: () => T): T {
  const g = globalThis as { document?: unknown };
  const before = g.document;
  g.document = { documentElement: { dataset: { rowGap: look } } };
  try {
    return body();
  } finally {
    if (before === undefined) delete g.document;
    else g.document = before;
  }
}
const draw = (table: GapTable): string => {
  const names = Object.keys(KINDS);
  const lines = ["from \\ to".padEnd(10) + names.map((n) => n.padStart(8)).join("")];
  for (const a of names) lines.push(a.padEnd(10) + names.map((b) => String(table[a]![b]).padStart(8)).join(""));
  return lines.join("\n");
};

const SHIPPED = `
from \\ to   prompt   reply  footer  worked     run    peer  bgTask   group   bgRun bgReply  bgLine
prompt          32      32      32      32      32      32      32      32      32      32      32
reply           32      24       8      16      16      16      16      16      32      32      16
footer          32      24      24      24      24      24       8      24      24      32       8
worked          32       0       0       0       0      16       0       0       0       0       0
run             32      16       8      16       0       0       0       0       0      32       0
peer            32      16       8      16       0       0       0       0       0      32       0
bgTask          32      16       8      16       0       0       0       0       0      32       0
group           32      16       8      16       0       0       0       0       0      32       0
bgRun           32      16       8      16       0       0       0       0       0      16       0
bgReply         32      24       8      16      16      16      16      16      16      24      16
bgLine          32      16       8      16       0       0       0       0       0      32       0`.trim();

// Leo's captures: "Sent to", another agent's line and "Worked for" ran together (run/peer -> worked was 0), and a
// blank band stood between a closed or opened group and the background turn's rows under it (any line -> bgRun was
// 32). The rule: one-line rows of a run sit flush on the 22 pitch, whichever turn made them; "Worked for", a turn's
// header, stands the run gap over a run; the turn and block gaps stay around prose, prompts and footers.
test("the shipped gap table: every adjacent kind pair", () => {
  expect(draw(under("shipped", gapTable))).toBe(SHIPPED);
});

test("the replaced look had a flush header and a blank band under every line", () => {
  const before = under("before", gapTable);
  for (const line of ["run", "peer", "bgTask", "group", "bgLine"]) {
    expect(before[line]!.worked).toBe(0);
    expect(before[line]!.bgRun).toBe(32);
  }
  const shipped = under("shipped", gapTable);
  for (const line of ["run", "peer", "bgTask", "group", "bgLine", "bgRun"]) {
    expect(shipped[line]!.worked).toBe(16);
    expect(shipped[line]!.bgRun).toBe(0);
    // A line stands over a line, an opened group's child included, on the 22 pitch.
    expect(shipped[line]!.peer).toBe(0);
    expect(shipped[line]!.group).toBe(0);
  }
});
