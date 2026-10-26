// l10n-allow-file: test fixture prompts, not shipped UI.
// The rail's turns lead with the chat's prompts older than the transcript (earlierPrompts.ts), with
// no row; when the transcript loads their turns they become those turns, keeping their keys, and a
// streamed token leaves the ticks as they are.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { minimapTurns } from "../src/agent-session/acpmux/threadMinimap/model";

const prompt = (seq: number, text = `Question ${seq}`): AcpmuxRow => ({
  id: `user-${seq}`,
  version: 1,
  at: seq,
  kind: "user",
  text,
});
const reply = (seq: number): AcpmuxRow => ({
  id: `a-${seq}`,
  version: 1,
  at: seq,
  kind: "assistant",
  text: `Answer ${seq}`,
});
/// Turns `from` to `to`, a prompt (seq 2n) and a reply each.
const transcript = (from: number, to: number) => {
  const rows: AcpmuxRow[] = [];
  for (let n = from; n <= to; n++) rows.push(prompt(2 * n), reply(2 * n + 1));
  return rows;
};

test("earlier prompts lead the turns with no row, and keep their keys once their turns load", () => {
  const earlier = Array.from({ length: 450 }, (_, n) => prompt(2 * (n + 1)));
  const rows = transcript(451, 500);
  const read = minimapTurns(rows, "s", undefined, undefined, earlier);
  expect(read.turns).toHaveLength(500);
  expect(read.ticks).toHaveLength(500);
  expect(read.turns[0]!.index).toBe(-1);
  expect(read.turns[449]!.index).toBe(-1);
  expect(read.turns[450]!.index).toBe(0);
  expect(read.turns[450]!.prompt).toBe("Question 902");
  const keys = read.turns.map((turn) => turn.key);

  // A streamed token: the same turns and ticks.
  const streamed = [...rows.slice(0, -1), { ...rows.at(-1)!, text: "Answer 1001 and more", version: 2 }];
  const next = minimapTurns(streamed, "s", read, { base: rows, rows: streamed, from: streamed.length - 1 }, earlier);
  expect(next.ticks).toBe(read.ticks);

  // The transcript loads 30 older turns: those leave `earlier` and become loaded turns, same keys.
  const older = [...transcript(421, 450), ...rows];
  const fewer = earlier.slice(0, 420);
  const loaded = minimapTurns(older, "s", next, undefined, fewer);
  expect(loaded.turns).toHaveLength(500);
  expect(loaded.turns.map((turn) => turn.key)).toEqual(keys);
  expect(loaded.turns[420]!.index).toBe(0);
  expect(loaded.turns[419]!.index).toBe(-1);
});
