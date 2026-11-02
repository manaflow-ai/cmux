import { expect, test } from "bun:test";
import { askBtwQuestion } from "./btwCapability";

function client() {
  return {
    capabilities: undefined,
    selectedSession: "chat-1",
    selectionToken: 1,
    btw: async () => "side-1",
  };
}

test("purges a legacy side session when selection changes before it opens", async () => {
  const c = client();
  const discarded: string[] = [];
  const pending = askBtwQuestion(c, "question", "chat-1", {
    inline: async () => "unused",
    openSide: async () => undefined,
    discardSide: (id) => discarded.push(id),
    openedMessage: () => "opened",
    staleMessage: () => "stale",
  });
  c.selectedSession = "chat-2";
  await expect(pending).rejects.toThrow("stale");
  expect(discarded).toEqual(["side-1"]);
});

test("purges a legacy side session when opening it fails", async () => {
  const c = client();
  const discarded: string[] = [];
  await expect(
    askBtwQuestion(c, "question", "chat-1", {
      inline: async () => "unused",
      openSide: async () => {
        throw new Error("open failed");
      },
      discardSide: (id) => discarded.push(id),
      openedMessage: () => "opened",
      staleMessage: () => "stale",
    }),
  ).rejects.toThrow("open failed");
  expect(discarded).toEqual(["side-1"]);
});
