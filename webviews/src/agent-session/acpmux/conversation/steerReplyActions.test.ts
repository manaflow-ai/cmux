// The reply before a message the person sent into the running turn (a steer) ends that part of the
// turn for the reader, so it keeps its own Copy row, as Claude Code's reply does when the person comes
// in (Leo, 2026-11-03: "a lot of these should've been counted as 'ended'-ish turns that allow me to
// copy/paste your stuff / cuz look claude code lets that happen if the user comes in").
import { expect, test } from "bun:test";
import { type AcpmuxRow, hasReplyActions, keepsReplyRoom } from "../model";

const reply = { id: "r", version: 1, at: 1, kind: "assistant", text: "Starting on the rail now." } as AcpmuxRow;
const steer = { id: "s", version: 1, at: 2, kind: "user", text: "also check the footer", steer: "landed" } as AcpmuxRow;

test("a finished reply before the person's steer draws its own action row", () => {
  expect(hasReplyActions(reply, steer)).toBe(true);
  // One continuing a stopped turn counts the same.
  const { steer: _, ...prompt } = steer;
  expect(hasReplyActions(reply, { ...prompt, continues: true } as AcpmuxRow)).toBe(true);
  // Inside an opened "Worked for", the reply to the person keeps it too.
  expect(hasReplyActions({ ...reply, settled: true, foldedReply: true }, steer)).toBe(true);
  // It draws in the room the reply already keeps, so showing it moves nothing.
  expect(keepsReplyRoom(reply, steer)).toBe(true);
});

test("other replies keep the turn's one footer", () => {
  // Still streaming, empty, or a short note folded in an opened "Worked for".
  expect(hasReplyActions({ ...reply, streaming: true }, steer)).toBe(false);
  expect(hasReplyActions({ ...reply, text: "  " }, steer)).toBe(false);
  expect(hasReplyActions({ ...reply, settled: true }, steer)).toBe(false);
  // A new prompt opens the next turn: the ended turn's footer serves the reply.
  const { steer: _, ...prompt } = steer;
  expect(hasReplyActions(reply, prompt as AcpmuxRow)).toBe(false);
  // A steer not yet sent, or refused, did not come in.
  expect(hasReplyActions(reply, { ...steer, pending: true })).toBe(false);
  expect(hasReplyActions(reply, { ...steer, failed: true })).toBe(false);
  // Another agent's message, a tool run or the turn's footer.
  expect(hasReplyActions(reply, { ...steer, incoming: { kind: "message" } } as AcpmuxRow)).toBe(false);
  expect(hasReplyActions(reply, { id: "a", version: 1, at: 2, kind: "activity", items: [] } as AcpmuxRow)).toBe(false);
  expect(hasReplyActions(reply, { id: "t", version: 1, at: 2, kind: "turnSummary" } as AcpmuxRow)).toBe(false);
  expect(hasReplyActions(reply, undefined)).toBe(false);
});
