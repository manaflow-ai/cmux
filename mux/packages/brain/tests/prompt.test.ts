import type { Conversation } from "@mux/protocol";
import { expect, test } from "vite-plus/test";
import { conversationInput, instructions } from "../src/index.ts";

const conversation: Conversation = {
  id: "c",
  title: "plans",
  participants: [
    { kind: "human", id: "u1", displayName: "Lawrence" },
    { kind: "human", id: "u2", displayName: "Austin" },
    { kind: "mux", id: "m1", displayName: "mux" },
  ],
  messages: [
    { id: "1", senderId: "u1", sentAt: "t", parts: [{ type: "text", text: "hi" }], reactions: [] },
    { id: "2", senderId: "m1", sentAt: "t", parts: [{ type: "text", text: "hey" }], reactions: [] },
    { id: "3", senderId: "u2", sentAt: "t", parts: [], retractedAt: "t", reactions: [] },
    { id: "4", senderId: "u2", sentAt: "t", parts: [{ type: "text", text: "yo" }], reactions: [] },
  ],
};

test("my messages are assistant turns and other people's are named user turns", () => {
  expect(conversationInput({ muxId: "m1", conversation })).toEqual([
    { role: "user", content: "Lawrence: hi" },
    { role: "assistant", content: "hey" },
    { role: "user", content: "Austin: yo" },
  ]);
});

test("instructions name the other participants and include memory", () => {
  const text = instructions({
    muxId: "m1",
    conversation,
    memory: "#0-1 Lawrence likes short replies",
  });
  expect(text).toContain("Lawrence (human), Austin (human)");
  expect(text).toContain("Lawrence likes short replies");
});
