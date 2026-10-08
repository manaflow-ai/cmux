import { expect, test } from "bun:test";
import { heldPrompts } from "./heldPrompt";

// The send's gesture is kept for the held prompt at the refusal, and goes with its next send once.
test("a held prompt reserves its send's gesture for its promptId and gives it out once", async () => {
  const intents: Record<string, unknown>[] = [];
  const held = heldPrompts(async (intent) => {
    intents.push(intent);
    return "ticket-1";
  });
  await held.hold("p1");
  expect(intents).toEqual([{ method: "session/prompt", params: { promptId: "p1" } }]);
  expect(held.take()).toEqual({ promptId: "p1", ticket: "ticket-1" });
  expect(held.take()).toBeUndefined();
});

test("a host without a gesture to keep still holds the promptId, without a ticket", async () => {
  const held = heldPrompts(async () => {
    throw new Error("transport.gesture_required");
  });
  await held.hold("p2");
  expect(held.take()).toEqual({ promptId: "p2" });
});
