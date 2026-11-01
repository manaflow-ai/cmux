// l10n-allow-file: test fixture tool titles and replies, not shipped UI.
// An assistant message with nothing to read (empty, whitespace, or only zero-width characters)
// draws nothing and adds no spacing: it takes zero height, and the rows around it sit as if it
// were not there. Before, such a message kept a message block and its gap, a tall blank band
// between two groups of tool rows (Leo, 2026-11-01: "wtf are these spacesr").
import { expect, test } from "bun:test";
import { isBlankReply, isBlankText, layoutConversation, nextDrawnRow, previousDrawnRow } from "./model";
import { turnView } from "./conversation/turns";

const tools = (id: string, at: number) => ({
  id,
  version: 1,
  at,
  kind: "activity",
  items: [
    {
      kind: "tool",
      text: "",
      tool: { id: `${id}-1`, title: "ls", kind: "execute", status: "completed", command: "ls" },
    },
    {
      kind: "tool",
      text: "",
      tool: { id: `${id}-2`, title: "pwd", kind: "execute", status: "completed", command: "pwd" },
    },
  ],
});
const reply = (id: string, text: string, at = 2_000) => ({ id, version: 1, at, kind: "assistant", text });

test("text with only whitespace or zero-width characters is blank", () => {
  for (const text of [undefined, "", " ", "\n\n", "\u200b", " \u200b\n\u200c\u200d\u2060\ufeff "])
    expect(isBlankText(text)).toBe(true);
  for (const text of ["a", "\u200bok", " . "]) expect(isBlankText(text)).toBe(false);
});

test("a zero-width-only assistant message between two tool groups adds no gap", () => {
  const first = tools("t1", 1_000);
  const second = tools("t2", 3_000);
  const blank = reply("blank", "\u200b\u200b");
  const without = layoutConversation([first, second] as never, 720);
  const withBlank = layoutConversation([first, blank, second] as never, 720);
  expect(withBlank.heights[1]).toBe(0);
  // The second group sits exactly where it would with no message between them.
  expect(withBlank.tops[2]).toBe(without.tops[1]!);
  expect(withBlank.totalHeight).toBe(without.totalHeight);
  // Rows on either side see each other, not the blank message, for their edges and joins.
  const rows = [first, blank, second] as never[];
  expect(isBlankReply(blank as never)).toBe(true);
  expect(nextDrawnRow(rows, 0)).toBe(second as never);
  expect(previousDrawnRow(rows, 2)).toBe(first as never);
});

test("whitespace and empty assistant messages take no height either", () => {
  for (const text of ["", "  \n  ", "\ufeff"]) {
    const layout = layoutConversation([tools("t1", 1_000), reply("r", text), tools("t2", 3_000)] as never, 720);
    expect(layout.heights[1]).toBe(0);
  }
});

test("a finished turn ending on a blank message keeps its last-turn rhythm on the row that draws", () => {
  const source = [
    { id: "u", version: 1, at: 0, kind: "user", text: "Look around" },
    tools("t1", 1_000),
    reply("blank", " \u200b "),
  ];
  const rows = turnView(source as never, new Set(["u"]), { now: 5_000 });
  const marked = rows.filter((row) => row.lastTurn);
  expect(marked.every((row) => !isBlankReply(row))).toBe(true);
});
