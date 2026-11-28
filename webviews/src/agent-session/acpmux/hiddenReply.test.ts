import { afterEach, expect, test } from "bun:test";
import type { AcpmuxRow, AcpmuxSnapshot } from "./model";
import { drewHiddenRows, hiddenReply, hiddenReplyOnly } from "./hiddenReply";
import { BACKGROUND_TURN } from "./conversation/backgroundTurns";

const snapshot = (rows: AcpmuxRow[]): AcpmuxSnapshot => ({ rows, connection: "agent_message_chunk" }) as AcpmuxSnapshot;
const user: AcpmuxRow = {
  id: "u1",
  version: 1,
  at: 1,
  kind: "user",
  text: "go",
};
const line: AcpmuxRow = {
  id: `${BACKGROUND_TURN}-bg1`,
  version: 1,
  at: 2,
  kind: BACKGROUND_TURN,
  background: { id: "bg1", trigger: "task_notification", running: true },
};
const reply = (text: string, version: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id: "bg1-reply",
  version,
  at: 3,
  kind: "assistant",
  text,
  streaming: true,
  inBackground: "bg1",
  ...extra,
});

afterEach(() => hiddenReply.reset());

test("a hidden background reply's chunk keeps the pane's snapshot", () => {
  const drawn = snapshot([user, line, reply("Checking", 1)]);
  // The transcript drew the turn's line, not its reply (backgroundTurns.ts `hiddenInBackground`).
  drewHiddenRows([user, line]);
  const next = snapshot([user, line, reply("Checking the", 2)]);
  expect(hiddenReplyOnly(drawn, next)).toBe(2);
  // Chunks keep coming against the same drawn snapshot.
  expect(hiddenReplyOnly(drawn, snapshot([user, line, reply("Checking the logs", 3)]))).toBe(2);
});

test("a reply the transcript draws, an empty one, a prompt after it or another change redraws", () => {
  const drawn = snapshot([user, line, reply("Checking", 1)]);
  drewHiddenRows([user, line, reply("Checking", 1)]);
  expect(hiddenReplyOnly(drawn, snapshot([user, line, reply("Checking the", 2)]))).toBe(-1);

  drewHiddenRows([user, line]);
  // Its first words may be what make it draw (visibleMessage.ts).
  expect(hiddenReplyOnly(snapshot([user, line, reply("", 1)]), snapshot([user, line, reply("Ok", 2)]))).toBe(-1);
  expect(hiddenReplyOnly(snapshot([user, line, reply(".", 1)]), snapshot([user, line, reply(".x", 2)]))).toBe(-1);
  // Not a background turn's reply.
  expect(
    hiddenReplyOnly(
      snapshot([user, reply("Checking", 1, { inBackground: undefined })]),
      snapshot([user, reply("Checking the", 2, { inBackground: undefined })]),
    ),
  ).toBe(-1);
  // A field other than the text moved.
  expect(hiddenReplyOnly(drawn, snapshot([user, line, reply("Checking the", 2, { streaming: false })]))).toBe(-1);
  // Two rows moved.
  const ended = {
    ...line,
    background: {
      id: "bg1",
      trigger: "task_notification",
      running: false,
      quiet: false,
    },
  };
  expect(hiddenReplyOnly(drawn, snapshot([user, ended, reply("Checking the", 2)]))).toBe(-1);
  // The pane's other fields moved.
  expect(
    hiddenReplyOnly(drawn, {
      ...snapshot([user, line, reply("Checking the", 2)]),
      connection: "connected",
    } as AcpmuxSnapshot),
  ).toBe(-1);
});

test("a pass that draws the reply from the pane's older rows draws the newest at once", () => {
  const drawn = snapshot([user, line, reply("Checking", 1)]);
  drewHiddenRows([user, line]);
  const next = snapshot([user, line, reply("Checking the", 2)]);
  const at = hiddenReplyOnly(drawn, next);
  hiddenReply.set(next, at);
  let flushed = 0;
  const off = hiddenReply.onFlush(() => (flushed += 1));
  // A pass that still hides it draws nothing stale.
  drewHiddenRows([user, line]);
  expect(flushed).toBe(0);
  // The line opened: the transcript drew the reply as the pane holds it ("Checking").
  drewHiddenRows([user, line, drawn.rows[2]!]);
  expect(flushed).toBe(1);
  expect(hiddenReply.pending()).toBe(0);
  off();
});

test("the pane's draw of the newest text clears the entry; an older one keeps it", () => {
  const drawn = snapshot([user, line, reply("Checking", 1)]);
  drewHiddenRows([user, line]);
  const next = snapshot([user, line, reply("Checking the", 2)]);
  hiddenReply.set(next, hiddenReplyOnly(drawn, next));
  hiddenReply.redraw(drawn);
  expect(hiddenReply.pending()).toBe(1);
  hiddenReply.redraw(next);
  expect(hiddenReply.pending()).toBe(0);
});
