// l10n-allow-file: test fixture prompts and messages, not shipped UI.
// Received messages that fold into one card (conversation/waitingMessages.ts groupAgentMessages)
// each keep their minimap turn, as they did before they folded (#26980), and their ticks land on the
// card. A reply streaming after the fold reads the fold again whole: no turn is lost or doubled.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { groupAgentMessages } from "../src/agent-session/acpmux/conversation/waitingMessages";
import { minimapTurns } from "../src/agent-session/acpmux/threadMinimap/model";

const prompt = (id: string): AcpmuxRow => ({ id, version: 1, at: 1, kind: "user", text: id });
const message = (id: string): AcpmuxRow => ({
  id,
  version: 1,
  at: 1,
  kind: "user",
  text: id,
  incoming: { kind: "message", message: { name: "claude-sr2", sessionId: "claude-sr2", text: id, raw: id } },
  untyped: true,
});
const answer = (id: string, text = "done"): AcpmuxRow => ({ id, version: 1, at: 2, kind: "assistant", text });

test("each folded received message is a turn on the card's row", () => {
  const rows = groupAgentMessages([prompt("p1"), answer("a1"), message("m1"), message("m2"), message("m3")]);
  expect(rows.map((row) => row.id)).toEqual(["p1", "a1", "messages-m1"]);
  const { turns, ticks } = minimapTurns(rows, "s");
  expect(turns.map((turn) => [turn.id, turn.index, turn.rowId])).toEqual([
    ["p1", 0, undefined],
    ["m1", 2, "messages-m1"],
    ["m2", 2, "messages-m1"],
    ["m3", 2, "messages-m1"],
  ]);
  expect(ticks.map((tick) => tick.id)).toEqual(["p1", "m1", "m2", "m3"]);
});

test("a reply streaming after a fold keeps every turn once", () => {
  const head = groupAgentMessages([prompt("p1"), answer("a1"), message("m1"), message("m2"), message("m3")]);
  let rows: readonly AcpmuxRow[] = [...head, answer("live", "t0")];
  let read = minimapTurns(rows, "s");
  const ticks = read.ticks;
  for (let token = 1; token <= 5; token += 1) {
    const next = [...head, answer("live", `t${token}`)];
    read = minimapTurns(next, "s", read, { base: rows, rows: next, from: head.length });
    rows = next;
    expect(read.turns.map((turn) => turn.id)).toEqual(["p1", "m1", "m2", "m3"]);
    expect(read.turns.at(-1)?.reply.length).toBeGreaterThan(0);
    expect(read.ticks).toBe(ticks);
  }
  // A fourth message joins the fold: the fold row changes, and its turns are read again whole.
  const grown = groupAgentMessages([prompt("p1"), answer("a1"), message("m1"), message("m2"), message("m3"), message("m4")]);
  read = minimapTurns(grown, "s", read, { base: rows, rows: grown, from: 2 });
  expect(read.turns.map((turn) => turn.id)).toEqual(["p1", "m1", "m2", "m3", "m4"]);
});

test("a change after a fold that starts inside it reads the fold again whole", () => {
  const head = groupAgentMessages([message("m1"), message("m2"), answer("a"), prompt("p2"), answer("b")]);
  const first = minimapTurns(head, "s");
  expect(first.turns.map((turn) => turn.id)).toEqual(["m1", "m2", "p2"]);
  // The change lands in the fold's turn (its reply), so the read restarts at the fold's row.
  const next = [head[0]!, answer("a", "edited"), ...head.slice(2)];
  const read = minimapTurns(next, "s", first, { base: head, rows: next, from: 1 });
  expect(read.turns.map((turn) => turn.id)).toEqual(["m1", "m2", "p2"]);
});
