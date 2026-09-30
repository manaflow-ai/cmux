import { expect, test } from "vite-plus/test";
import { fixtureSource } from "./fixture.ts";

test("summaries preview each conversation's latest text", async () => {
  const [summary] = await fixtureSource.listConversations();
  const conversation = await fixtureSource.getConversation(summary.id);
  const last = conversation.messages.at(-1)?.parts[0];
  expect(last?.type === "text" && last.text).toBe(summary.preview);
});

test("unknown conversations reject", async () => {
  await expect(fixtureSource.getConversation("missing")).rejects.toThrow("missing");
});
