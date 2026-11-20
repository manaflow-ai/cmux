// l10n-allow-file: test fixtures.
// The held surge's row follows reads (direct.ts reducer, conversation/surgeHold.ts): an `inbox_read`
// or `inbox_removed` that clears what needed the chat carries the whole snapshot, so the count falls
// in an open pane and in a replay, whichever client read it; a bare read moves nothing.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient, type EventRecord } from "./direct";
import type { SurgeHold } from "./conversation/surgeHold";

const at = (seq: number) => 1_000 + seq;
const held = (seq: number, h: number, need: number): EventRecord => ({
  seq,
  at: at(seq),
  dir: "mux",
  kind: "inbox",
  msg: { surgeHeld: true, surge: { held: h, needYou: need }, threadId: "pr:48120", promptId: `p${seq}` },
});
const SURGE: EventRecord[] = [
  { seq: 1, at: at(1), dir: "mux", kind: "user_message", msg: { text: "Watch the queue." } },
  held(2, 11, 1),
  held(3, 12, 2),
  // A bare read (no snapshot) and one carrying only part of it move nothing.
  { seq: 4, at: at(4), dir: "mux", kind: "inbox_read", msg: { threadId: "pr:48120" } },
  { seq: 5, at: at(5), dir: "mux", kind: "inbox_read", msg: { surge: { held: 1 } } },
  // Read from another client (a phone, another window): the count falls here too.
  {
    seq: 6,
    at: at(6),
    dir: "mux",
    kind: "inbox_read",
    msg: { threadId: "pr:48120", client: "another-window", surge: { held: 10, needYou: 0 } },
  },
  {
    seq: 7,
    at: at(7),
    dir: "mux",
    kind: "inbox_removed",
    msg: { threadId: "topic:runner", surge: { held: 0, needYou: 0 } },
  },
];
const counts = (surge: SurgeHold | undefined) => surge && { held: surge.held, needYou: surge.needYou };

test("an open pane's count falls as reads and removals carry their snapshot; bare reads move nothing", () => {
  let surge: SurgeHold | undefined;
  const client = AcpmuxDirectClient.fed("surge-chat", (snapshot) => {
    surge = snapshot.surge;
  });
  client.feed(SURGE.slice(0, 3), "snapshot");
  expect(counts(surge)).toEqual({ held: 12, needYou: 2 });
  client.feed(SURGE.slice(3, 5), "live");
  expect(counts(surge)).toEqual({ held: 12, needYou: 2 });
  client.feed([SURGE[5]!], "live");
  expect(counts(surge)).toEqual({ held: 10, needYou: 0 });
  client.feed([SURGE[6]!], "live");
  expect(counts(surge)).toEqual({ held: 0, needYou: 0 });
});

test("a replay's count falls at the read that cleared it", () => {
  let surge: SurgeHold | undefined;
  const client = AcpmuxDirectClient.replay("surge-chat", [...SURGE], (snapshot) => {
    surge = snapshot.surge;
  });
  client.seekReplay(5);
  expect(counts(surge)).toEqual({ held: 12, needYou: 2 });
  client.seekReplay(6);
  expect(counts(surge)).toEqual({ held: 10, needYou: 0 });
  client.seekReplay(7);
  expect(counts(surge)).toEqual({ held: 0, needYou: 0 });
});
