// l10n-allow-file: test fixture prompts and senders, not shipped UI.
// The prompt rail ticks only the prompts the person typed: a notice, another agent's message or a
// task's result gets no tick, held or read from the prompt index (Leo, 2026-11-27: "honestly non-user
// messages shouldnt appear in the scroll rail anymore. we've basically categorized all of them now so
// just... anything we've tagged as a tool call (or whatever ordering of logic we wanna do) we gotta
// just... have those not show up in the scroll rail. simple"). Before: the rail drew a tick for each,
// and a notice's card read "[notice from glaeda-land on … · WARN] glaeda land: https://gith…".
import { expect, test } from "bun:test";
import { incomingPrompt } from "../src/agent-session/acpmux/conversation/incomingMessage";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { PromptHeads } from "../src/agent-session/acpmux/promptHeads";
import { minimapTurns, railEntries, railShowsOffered } from "../src/agent-session/acpmux/threadMinimap/model";

const CHAT = "0190a000-0000-7000-8000-0000000c0de3";
const prompt = (n: number, text: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id: `user-${n}`,
  version: 1,
  at: n,
  kind: "user",
  text,
  promptId: `p-${n}`,
  ...extra,
});
const reply = (n: number): AcpmuxRow => ({
  id: `a-${n}`,
  version: 1,
  at: n + 0.5,
  kind: "assistant",
  text: `Answer ${n}`,
});

const NOTICE = "[notice from glaeda-land · WARN] glaeda land: https://github.com/example/pull/1";
const notice = (n: number): AcpmuxRow =>
  prompt(n, NOTICE, { incoming: { kind: "notice", text: NOTICE }, untyped: true });
function agentMessage(n: number): AcpmuxRow {
  const body = "HQ mirror stash cleared on the helper's branch.";
  const incoming = incomingPrompt(body, {
    _meta: { provenance: { kind: "session_message", from: "hq-mirror-id", fromName: "hq-mirror", to: "me" } },
  });
  if (incoming?.kind !== "message") throw new Error(`not a message: ${JSON.stringify(incoming)}`);
  return prompt(n, incoming.message.text, { incoming, resend: body, untyped: true });
}

const rows = [
  prompt(1, "Fix the sidebar"),
  reply(1),
  notice(2),
  reply(2),
  agentMessage(3),
  reply(3),
  prompt(4, "Thanks"),
  reply(4),
];

test("a notice and another agent's message get no tick; the person's typed prompts keep theirs", () => {
  const read = minimapTurns(rows, CHAT);
  // The model still reads every turn (the full-height map, Find and the cards use them).
  expect(read.turns.map((turn) => turn.id)).toEqual(["user-1", "user-2", "user-3", "user-4"]);
  expect(read.ticks.map((tick) => tick.others ?? false)).toEqual([false, true, true, false]);
  const kept = railEntries(read.turns, read.ticks, 0, "prompts");
  expect(kept.ticks.map((tick) => tick.prompt)).toEqual(["Fix the sidebar", "Thanks"]);
  expect(kept.turns.map((turn) => turn.id)).toEqual(["user-1", "user-4"]);
  // My prompts keeps the same; prompts and replies drops the others' prompt tick but keeps its reply.
  expect(railEntries(read.turns, read.ticks, 0, "mine").ticks.map((tick) => tick.id)).toEqual(["user-1", "user-4"]);
  expect(railEntries(read.turns, read.ticks, 0, "everything").ticks.map((tick) => tick.id)).toEqual([
    "user-1",
    "a-1",
    "a-2",
    "a-3",
    "user-4",
    "a-4",
  ]);
  // Only the explicit "received" choice ticks them.
  expect(railEntries(read.turns, read.ticks, 0, "received").ticks.map((tick) => tick.id)).toEqual(["user-2", "user-3"]);
  expect(railShowsOffered(read.turns, read.ticks).has("received")).toBe(true);
});

test("a chat of only the person's prompts keeps its lists as they are", () => {
  const own = [prompt(1, "One"), reply(1), prompt(2, "Two"), reply(2)];
  const read = minimapTurns(own, CHAT);
  const kept = railEntries(read.turns, read.ticks, 0, "prompts");
  expect(kept.ticks).toBe(read.ticks);
  expect(kept.turns).toBe(read.turns);
  expect(read.ticks.some((tick) => tick.others)).toBe(false);
});

test("the prompt index's prompts acpmux marks others get no tick either", () => {
  const heads = PromptHeads.of([
    { seq: 1, at: 1, text: "Fix the sidebar", promptId: "p-1" },
    { seq: 3, at: 3, text: NOTICE, others: true },
    { seq: 5, at: 5, text: "Thanks", promptId: "p-5" },
  ]);
  const persons = PromptHeads.persons(heads);
  expect(persons.length).toBe(2);
  expect([0, 1].map((at) => PromptHeads.text(persons, at))).toEqual(["Fix the sidebar", "Thanks"]);
  expect(PromptHeads.persons(heads)).toBe(persons);
  // A row read back as a placeholder stays someone else's, and an index of the person's alone is itself.
  expect(PromptHeads.row(heads, 1).untyped).toBe(true);
  const mine = PromptHeads.of([{ seq: 1, at: 1, text: "One" }]);
  expect(PromptHeads.persons(mine)).toBe(mine);
  // A view cut before the notice holds none of it.
  expect(PromptHeads.persons(PromptHeads.before(heads, 3)).length).toBe(1);
});
