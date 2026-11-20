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
