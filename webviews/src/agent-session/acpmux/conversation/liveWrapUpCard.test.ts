// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The agent's wrap-up card draws the moment its call returns (Leo, 2026-11-19, on the Needs your
// input cards: "plus it's not instant yet"). Before, it drew only once the turn ended, which takes
// one more model request after the call (6 s in the record that showed it), and the call's own row
// stood in its place until then.
import { describe, expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { NEXT_STEP, turnView } from "./turns";

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow =>
  ({ id, version: 1, at: (at += 1000), kind, ...extra }) as AcpmuxRow;
const wrapUp = (status: string) =>
  row("w1", "activity", {
    items: [
      {
        id: "w1-call",
        tool: {
          id: "w1-call",
          title: "mcp__acpmux__wrap_up",
          kind: "other",
          status,
          inputSummary: JSON.stringify({
            recap: "Merged #1.",
            ask: "Trust ~/fun/cmux for the new sub-session?",
            actions: ["Trust it", "Not now"],
          }),
        },
      },
    ],
  } as unknown as Partial<AcpmuxRow>);

const asked = [row("p1", "user", { text: "Start the lane." }), row("a1", "assistant", { text: "Started." })];
const cards = (rows: readonly AcpmuxRow[]) => rows.filter((shown) => shown.kind === NEXT_STEP);
const hasCall = (rows: readonly AcpmuxRow[]) =>
  rows.some((shown) => shown.items?.some((item) => item.tool?.id === "w1-call"));

describe("a wrap-up call in a running turn", () => {
  test("draws as its card as soon as it returns, in place of its row", () => {
    const shown = turnView([...asked, wrapUp("completed")], new Set(), { working: true });
    const [card] = cards(shown);
    expect(card?.nextStep?.ask.question).toBe("Trust ~/fun/cmux for the new sub-session?");
    expect(card?.nextStep?.ask.options.map((option) => option.label)).toEqual(["Trust it", "Not now"]);
    expect(hasCall(shown)).toBe(false);
  });

  test("keeps its row while it runs", () => {
    const shown = turnView([...asked, wrapUp("in_progress")], new Set(), { working: true });
    expect(cards(shown)).toEqual([]);
  });

  test("keeps the same row id once the turn ends", () => {
    const rows = [...asked, wrapUp("completed")];
    const [live] = cards(turnView(rows, new Set(), { working: true }));
    const [ended] = cards(turnView([...rows, row("s1", "turnSummary", { status: "completed" })], new Set()));
    expect(live?.id).toBeDefined();
    expect(ended?.id).toBe(live!.id);
  });
});

const otherWrapUp = (id: string, question: string): AcpmuxRow =>
  row(id, "activity", {
    items: [
      {
        id: `${id}-call`,
        tool: {
          id: `${id}-call`,
          title: "mcp__acpmux__wrap_up",
          kind: "other",
          status: "completed",
          inputSummary: JSON.stringify({ ask: question, actions: ["Yes"] }),
        },
      },
    ],
  } as unknown as Partial<AcpmuxRow>);

describe("a running turn's later wrap-up", () => {
  // Review on #47702: every live card had version 1, and the row's memo compares id and version,
  // so a second wrap-up kept the first card's question on screen.
  test("is a new version of the card", () => {
    const first = [...asked, wrapUp("completed")];
    const [before] = cards(turnView(first, new Set(), { working: true }));
    const [after] = cards(
      turnView([...first, row("a2", "assistant", { text: "One more." }), otherWrapUp("w2", "Merge it?")], new Set(), {
        working: true,
      }),
    );
    expect(after?.id).toBe(before!.id);
    expect(after?.nextStep?.ask.question).toBe("Merge it?");
    expect(after?.version).not.toBe(before!.version);
  });
});

describe("a running turn's card", () => {
  // Review on #47702: the live card dropped its call with `withoutWrapUp`, which reads every
  // earlier call of the turn again on each record.
  test("reads no earlier call to drop its own", () => {
    let reads = 0;
    // An MCP call (no command), whose title a wrap-up check reads.
    const counted = (id: string): AcpmuxRow => {
      const tool = { id, kind: "other", status: "completed" };
      Object.defineProperty(tool, "title", { get: () => ((reads += 1), "mcp__docs__read"), enumerable: true });
      return row(id, "activity", { items: [{ id, kind: "tool", text: "", tool }] } as unknown as Partial<AcpmuxRow>);
    };
    // The reads the card adds: the same turn with and without its wrap-up call, whose card draws
    // the rows the turn without it draws. Fresh rows each time: the view caches by row.
    const turn = (calls: number, tag: string) => [
      ...asked,
      ...Array.from({ length: calls }, (_, index) => counted(`${tag}${calls}-${index}`)),
      row(`${tag}s${calls}`, "assistant", { text: "Done." }),
    ];
    const extra = (calls: number) => {
      reads = 0;
      turnView(turn(calls, "a"), new Set(), { working: true });
      const without = reads;
      reads = 0;
      turnView([...turn(calls, "b"), otherWrapUp(`e${calls}`, "Ship it?")], new Set(), { working: true });
      return reads - without;
    };
    expect(extra(200)).toBe(extra(10));
  });
});
