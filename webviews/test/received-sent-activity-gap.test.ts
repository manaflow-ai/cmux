// l10n-allow-file: test fixtures.
// ST-02. Leo, 2026-11-22 08:29Z (screenshot 1159, an opened "Worked for 7s" over another agent's message and
// "Sent to"): "this one seems to have an unnecessary gap due to being a recieved message. these aren't categorized
// properly under our tool call formatting." Earlier, 05:14Z: "sometimes you get these way-too-big gaps. i think it's
// the message recieving not properly getting treated like the tool call ish thing it should be".
//
// A received message and a "Sent to" line inside a turn's work are activity rows: under each row they stand exactly
// the gap a tool row stands there (transcriptGrid.ts transcriptGap, the one owner of spacing). The message that
// opened a turn, folded into that turn's opened "Worked for" as its first entry, stood the head gap (16) under the
// fold's rule, as if it opened a new turn. Under a closed "Worked for" it still opens the next turn: the head gap.
// The sim scenario `received-sent-as-activity` (test/chat-sim.test.ts) checks the same at every step of a chat.
import { expect, test } from "bun:test";
import { gridMark, type AcpmuxRow } from "../src/agent-session/acpmux/model";
import { ROW_GAP_LOOKS, transcriptGap } from "../src/agent-session/acpmux/transcriptGrid";

const row = (id: string, fields: Partial<AcpmuxRow>): AcpmuxRow => ({ id, version: 1, at: 0, ...fields }) as AcpmuxRow;
const received = row("user-12", {
  kind: "user",
  text: "chat-scenarios: no lane of mine holds it",
  incoming: {
    kind: "message",
    message: { fromName: "claude-sr2-coord", from: "fromAgent", text: "chat-scenarios: no lane of mine holds it" },
  } as never,
});
const sendItem = {
  kind: "tool",
  tool: {
    id: "call-2",
    title: "acpmux send map-edge-cases 'carry on'",
    kind: "execute",
    status: "completed",
    rawInput: { command: "acpmux send map-edge-cases 'carry on'" },
  },
};
const sent = row("activity-15", { kind: "activity", items: [sendItem] as never });
const tool = row("activity-16", {
  kind: "activity",
  items: [
    { ...sendItem, tool: { ...sendItem.tool, id: "call-3", title: "rg -n x", rawInput: { command: "rg -n x" } } },
  ] as never,
});
const worked = (open: boolean) => row("worked-user-12", { kind: "worked", foldOpen: open, status: "completed" });

/** The gap over `below` under `above` (with `over` above that), as the layout picks it. */
const gap = (over: AcpmuxRow | undefined, above: AcpmuxRow, below: AcpmuxRow) =>
  transcriptGap(gridMark(above, over), gridMark(below, above));

test("ST-02: under an opened Worked for, the message it folds stands a tool row's gap (flush), not the head gap", () => {
  const open = worked(true);
  expect(gap(undefined, open, received)).toBe(gap(undefined, open, tool));
  expect(gap(undefined, open, received)).toBe(0);
});

test("ST-02: received and Sent to rows sit on the tool rows' pitch with each other and with tool rows", () => {
  const open = worked(true);
  expect(gap(open, received, sent)).toBe(gap(open, tool, sent));
  expect(gap(open, received, sent)).toBe(0);
  expect(gap(received, sent, received)).toBe(gap(received, sent, tool));
  expect(gap(sent, tool, received)).toBe(gap(sent, tool, tool));
});

test("under a closed Worked for, another agent's line opens the next turn: the head gap stays", () => {
  expect(gap(undefined, worked(false), received)).toBe(ROW_GAP_LOOKS.shipped.workedAfterLine);
  expect(ROW_GAP_LOOKS.shipped.workedAfterLine).toBeGreaterThan(0);
});
