import { expect, test } from "bun:test";
import { isNewChat } from "./EmptyState";
import type { AcpmuxSnapshot } from "./model";

const blank = (patch: Partial<AcpmuxSnapshot> = {}): AcpmuxSnapshot => ({
  type: "snapshot",
  protocolVersion: 1,
  rows: [],
  sessions: [],
  connection: "connected",
  isWorking: false,
  queue: [],
  catalog: [],
  canLoadOlder: false,
  ...patch,
});

test("a host-created blank chat offers terminal conversion and projects before its agent starts", () => {
  for (const connection of ["connected", "connecting", "failed: no agent installed"])
    expect(isNewChat(blank({ connection }), true)).toBe(true);
});

test("an unavailable resumed chat never becomes a blank chat", () => {
  expect(isNewChat(blank())).toBe(false);
  expect(isNewChat(blank({ sessionId: "old" }), true)).toBe(false);
  expect(isNewChat(blank({ canLoadOlder: true }), true)).toBe(false);
});

test("a host-created chat stops offering blank-chat actions once work starts", () => {
  expect(isNewChat(blank({ isWorking: true }), true)).toBe(false);
  expect(isNewChat(blank({ rows: [{ id: "prompt", version: 1, at: 1, kind: "user", text: "hello" }] }), true)).toBe(
    false,
  );
});
