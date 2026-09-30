import type { Conversation } from "@mux/protocol";
import type { ChatSource } from "./source.ts";

const viewerId = "human-lawrence";

const conversations: Conversation[] = [
  {
    id: "mux",
    title: "mux",
    participants: [
      { kind: "human", id: viewerId, displayName: "Lawrence" },
      { kind: "mux", id: "mux-main", displayName: "mux" },
    ],
    messages: [
      {
        id: "m1",
        senderId: viewerId,
        sentAt: "2026-09-30T12:00:00-07:00",
        parts: [{ type: "text", text: "Spin up a sandbox for the cmux-next themes branch." }],
        reactions: [],
      },
      {
        id: "m2",
        senderId: "mux-main",
        sentAt: "2026-09-30T12:00:04-07:00",
        parts: [{ type: "text", text: "Not connected yet. This is fixture data." }],
        reactions: [],
      },
    ],
  },
];

export const fixtureSource: ChatSource = {
  viewerId,
  async listConversations() {
    return conversations.map((c) => {
      const last = c.messages.at(-1);
      const part = last?.parts[0];
      return {
        id: c.id,
        title: c.title,
        preview: part?.type === "text" ? part.text : "",
        lastAt: last?.sentAt ?? "",
      };
    });
  },
  async getConversation(id) {
    const found = conversations.find((c) => c.id === id);
    if (!found) throw new Error(`no conversation ${id}`);
    return found;
  },
};
