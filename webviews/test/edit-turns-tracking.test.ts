// The editable prompts are tracked across streamed snapshots (trackEditableTurns), reading only the
// rows after the first one that changed. It must answer exactly what a full read (editableTurns)
// does, and keep the same Map while the editable prompts do not change.
import { expect, test } from "bun:test";
import {
  editableTurns,
  trackEditableTurns,
  type EditableTurns,
} from "../src/agent-session/acpmux/conversation/editPrompt";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const row = (fields: Record<string, unknown>) => ({ text: "", ...fields }) as unknown as AcpmuxRow;
const user = (n: number, fields: Record<string, unknown> = {}) =>
  row({ kind: "user", id: `user-${n}`, text: `prompt ${n}`, ...fields });
const summary = (n: number) => row({ kind: "turnSummary", id: `sum-${n}`, seq: n });
const reply = (n: number, text: string) => row({ kind: "assistant", id: `reply-${n}`, text });

const chat = (turns: number) => {
  const rows: AcpmuxRow[] = [];
  for (let n = 0; n < turns; n += 1) rows.push(user(n), reply(n, "answer"), summary(n));
  return rows;
};

test("a tracked read equals a full read as a chat streams, finishes a turn and takes a new prompt", () => {
  let tracked: EditableTurns | undefined;
  let rows = chat(6);
  const step = (next: AcpmuxRow[], family = "claude") => {
    rows = next;
    tracked = trackEditableTurns(rows, family, tracked);
    expect([...tracked.seqs]).toEqual([...editableTurns(rows, family)]);
  };
  step(rows);
  step([...rows, user(6, { pending: true })]);
  step([...rows.slice(0, -1), user(6)]);
  for (const text of ["a", "ab", "abc"]) step([...rows, reply(6, text)]);
  step([...rows.slice(0, -1), reply(6, "abc"), summary(6)]);
  step([...rows, user(7, { steer: "waiting" })]);
  step([...rows.slice(0, -1), user(7)]);
  step(rows.slice(0, 8));
  step(chat(3), "gemini");
  step(chat(3), "codex");
});

test("the prompts' Map is the same object until an editable prompt changes", () => {
  const rows = chat(4);
  const first = trackEditableTurns(rows, "claude");
  const streamed = [...rows, user(4), reply(4, "t")];
  const second = trackEditableTurns(streamed, "claude", first);
  const third = trackEditableTurns([...streamed.slice(0, -1), reply(4, "tok")], "claude", second);
  expect(third.seqs).toBe(second.seqs);
  expect(trackEditableTurns(rows, "claude", first)).toBe(first);
  expect(trackEditableTurns([...rows], "claude", first).seqs).toBe(first.seqs);
  const finished = trackEditableTurns([...streamed.slice(0, -1), reply(4, "tok"), summary(4)], "claude", third);
  expect(finished.seqs).toBe(third.seqs);
  const next = trackEditableTurns([...finished.rows, user(5)], "claude", finished);
  expect(next.seqs).not.toBe(finished.seqs);
  expect(next.seqs.get("user-5")).toBe(4);
});
