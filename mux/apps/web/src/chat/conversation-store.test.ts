import type { Conversation, Message } from "@mux/protocol";
import { expect, test } from "vite-plus/test";
import { applyFrame, EMPTY } from "./conversation-store.ts";

const conversation: Conversation = {
  id: "c",
  title: "mux",
  participants: [
    { kind: "human", id: "u", displayName: "me" },
    { kind: "mux", id: "m", displayName: "mux" },
  ],
  messages: [],
};
const message = (id: string, senderId: string): Message => ({
  id,
  senderId,
  sentAt: "t",
  parts: [{ type: "text", text: id }],
  reactions: [],
});

test("an echoed send replaces its pending copy exactly once", () => {
  let state = applyFrame(EMPTY, { type: "snapshot", conversation });
  state = { ...state, pending: [{ clientId: "c1", message: message("pending-c1", "u") }] };
  state = applyFrame(state, { type: "message", message: message("m1", "u"), clientId: "c1" });
  state = applyFrame(state, { type: "message", message: message("m1", "u"), clientId: "c1" });
  expect(state.pending).toEqual([]);
  expect(state.conversation?.messages.map((m) => m.id)).toEqual(["m1"]);
});

test("a reply clears its sender's typing indicator", () => {
  let state = applyFrame(EMPTY, { type: "snapshot", conversation });
  state = applyFrame(state, { type: "typing", participantId: "m", on: true });
  expect(state.typing).toEqual(["m"]);
  state = applyFrame(state, { type: "message", message: message("r", "m") });
  expect(state.typing).toEqual([]);
});
