// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A settled turn stays settled when the person sends (Leo, 2026-11-22: "when i sent that message it was as
// if briefliy the worked for disappeared and then reappeared and we just had this crazy flicker where it
// forgot it just folded and settled and then it acted as if the turn was still going"). Right after the
// send the live pane holds the person's prompt as its own row, not written yet (`pending`), in the turn
// that just ended; acpmux then lists the chat running, or opens the turn (`turn_started`, the typing
// placeholder), before the prompt's record comes. Through all of it the ended turn keeps its closed
// "Worked for" in its place and never draws "Working for" again; the prompt on its way draws the
// Thinking line under it, as it does before the chat reads running.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { LIVE_THINKING, turnView, settledTail } from "../src/agent-session/acpmux/conversation/turns";

const START = Date.UTC(2026, 10, 22, 21, 40, 0);
const at = (second: number) => START + second * 1000;
const row = (id: string, kind: string, second: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: at(second),
  ...extra,
});
type Item = NonNullable<AcpmuxRow["items"]>[number];
const call = (id: string, title: string, startedAt: number, endedAt: number): Item => ({
  kind: "tool",
  text: title,
  tool: { id, title, kind: "execute", status: "completed", startedAt: at(startedAt), endedAt: at(endedAt) },
});

// The turn Leo's screenshot shows settled: "Worked for 1m 3s", folded.
const ended: AcpmuxRow[] = [
  row("u-1", "user", 0, { text: "Fix the flaky retry test." }),
  row("act-1", "activity", 2, { items: [call("c-1", "Run tests", 2, 20), call("c-2", "Read client.ts", 21, 30)] }),
  row("a-1", "assistant", 40, { text: "The loop allowed one attempt too many." }),
  row("act-2", "activity", 41, { items: [call("c-3", "Run tests again", 41, 60)] }),
  row("a-2", "assistant", 62, { text: "Fixed: the loop now makes exactly `attempts` calls." }),
  row("s-1", "turnSummary", 63, { status: "completed", durationMs: 63_000, toolCount: 3 }),
];
const delivery = { state: "sending", promptId: "p-2", sessionId: "s", sentAt: at(70) } as const;
const sending = row("u-2", "user", 70, { text: "Now check the other callers.", pending: true, delivery });
const typing = row("typing", "typing", 71);

for (const family of ["claude", "codex"]) {
  const view = (rows: AcpmuxRow[], working: boolean) =>
    turnView(rows, new Set(), {
      working,
      agentFamily: family,
      now: at(72),
      turnStartedAtMs: working ? at(71) : undefined,
    });
  const settled = view(ended, false);
  const head = settled.findIndex((each) => each.id === "worked-u-1");
  const settledIds = settled.slice(0, head + 1).map((each) => each.id);

  test(`${family}: the settled turn draws its closed Worked for`, () => {
    expect(head).toBeGreaterThan(0);
    expect(settled[head]!.foldOpen).toBeFalsy();
  });

  const orderings: [string, AcpmuxRow[]][] = [
    ["the prompt on its way, the chat not running yet", [...ended, sending]],
    ["the prompt on its way, the chat listed running", [...ended, sending]],
    ["the prompt on its way, its turn started (typing)", [...ended, sending, typing]],
    ["no prompt row yet, its turn started (another client sent it)", [...ended, typing]],
  ];
  orderings.forEach(([name, rows], index) => {
    test(`${family}: ${name}: the settled turn stays settled`, () => {
      const drawn = view(rows, index > 0);
      const ids = drawn.map((each) => each.id);
      // The settled turn keeps its rows up to its closed "Worked for", in place, and never reads running.
      expect(ids.slice(0, head + 1)).toEqual(settledIds);
      expect(drawn[head]!.foldOpen).toBeFalsy();
      expect(ids).not.toContain("working-u-1");
      expect(ids).not.toContain("act-1");
      // The prompt on its way draws its own heading and the Thinking line under it from the send on,
      // running or not: the heading's slot is held before the turn opens.
      if (rows.includes(sending)) expect(ids.slice(ids.indexOf("u-2"))).toEqual(["u-2", "working-u-2", LIVE_THINKING]);
    });
  });

  test(`${family}: once the prompt's record comes it opens its own turn, under the settled one`, () => {
    const written = { ...sending, pending: undefined, delivery: undefined, version: 2 };
    const drawn = view(
      [...ended, written, row("act-3", "activity", 72, { items: [call("c-4", "rg -n withRetry", 72, 73)] })],
      true,
    );
    const ids = drawn.map((each) => each.id);
    expect(ids.slice(0, head + 1)).toEqual(settledIds);
    expect(ids).not.toContain("working-u-1");
    expect(ids.indexOf("u-2")).toBeGreaterThan(head);
  });
}

test("settledTail: an ended turn's summary under prompts on their way and the typing placeholder", () => {
  const tail = (rows: AcpmuxRow[]) => settledTail(rows, 0, rows.length);
  // A bare summary with the chat running is the turn going on after it, not settled (ContinueAfterStop).
  expect(tail(ended)).toBe(false);
  expect(tail([...ended, sending, typing])).toBe(true);
  expect(tail([...ended, { ...sending, pending: undefined, failed: true }])).toBe(true);
  // Work after the summary (the agent went on by itself) runs again; a turn with no summary runs.
  expect(tail([...ended, row("act-9", "activity", 80, { items: [call("c-9", "Run", 80, 81)] })])).toBe(false);
  expect(tail(ended.slice(0, -1))).toBe(false);
  // A stop the person's prompt made goes on under that prompt.
  expect(tail([...ended.slice(0, -1), { ...ended.at(-1)!, status: "cancelled", continued: true }, sending])).toBe(
    false,
  );
});
