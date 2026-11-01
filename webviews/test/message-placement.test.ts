// l10n-allow-file: synthetic transcript placement fixtures.
import { expect, test } from "bun:test";
import { layoutConversation, type AcpmuxRow, type ConversationLayout } from "../src/agent-session/acpmux/model";
import { latestMessageRow, MessagePlacement } from "../src/agent-session/acpmux/conversation/messagePlacement";

const row = (id: string, text = "", kind = "assistant"): AcpmuxRow => ({ id, text, kind, at: 0, version: 1 });
const emptyLayout = (): ConversationLayout => ({
  tops: new Float64Array(),
  heights: new Float64Array(),
  totalHeight: 0,
});

test("streaming a held tail does not rescan history or trailing tools for a message host", () => {
  for (const hasEarlierMessage of [false, true]) {
    let rows = [
      row("earlier", hasEarlierMessage ? "Done" : ""),
      { ...row("active", "["), streaming: true },
      ...Array.from({ length: 2_000 }, (_, index) => row(`tool-${index}`, "", "activity")),
    ];
    let layout = emptyLayout();
    const initial = new MessagePlacement(rows);
    rows.forEach((value, index) => initial.visit(value, index));
    initial.finish(rows, layout);
    for (let token = 0; token < 20; token++) {
      const previous = rows;
      rows = rows.slice();
      rows[1] = { ...rows[1]!, text: `[unfinished ${token}`, version: token + 2 };
      let reads = 0;
      const observed = new Proxy(rows, {
        get(target, property, receiver) {
          if (typeof property === "string" && /^\d+$/.test(property)) reads++;
          return Reflect.get(target, property, receiver);
        },
      });
      const next = new MessagePlacement(observed, layout);
      next.visit(rows[1]!, 1, previous[1]);
      layout = emptyLayout();
      next.finish(observed, layout);
      expect(latestMessageRow(observed, layout)).toBe("active");
      expect(reads).toBeLessThanOrEqual(1);
    }
  }
});

test("layout carries placement through visibility changes, folding, deletion, reorder and replacement", () => {
  let previous: { rows: readonly AcpmuxRow[]; layout: ConversationLayout } | undefined;
  const check = (rows: AcpmuxRow[], expected?: string) => {
    const layout = layoutConversation(rows, 720, undefined, () => 1, undefined, previous);
    expect(latestMessageRow(rows, layout)).toBe(expected);
    previous = { rows, layout };
  };
  const earlier = row("earlier", "Done");
  const tools = row("tools", "", "activity");
  const held = { ...row("active", "[unfinished"), streaming: true };
  check([tools, held], "active");
  check([earlier, tools, held], "active");
  const visible = { ...held, text: "[ready](https://example.com)", version: 2 };
  check([earlier, tools, visible], "active");
  check([earlier, tools, { ...visible, text: "", version: 3 }], "earlier");
  const footer = row("footer", "Finished", "turnSummary");
  check([earlier, tools, footer], "footer");
  check([earlier, tools], "earlier");
  check([footer, tools, earlier], "earlier");
  check([earlier, tools, footer], "footer");
  check([tools]);
  check([]);
  const incoming: AcpmuxRow = {
    ...row("incoming", "", "user"),
    incoming: { kind: "message", message: { name: "Helper", text: "Hello", raw: "Hello" } },
  };
  check([incoming], "incoming");
});
