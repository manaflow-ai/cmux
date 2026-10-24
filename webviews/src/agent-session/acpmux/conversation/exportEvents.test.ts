// l10n-allow-file: synthetic recorded conversation fixtures, not shipped UI.
import { describe, expect, test } from "bun:test";
import type { EventRecord } from "../direct";
import { recordedConversationEvents, type ConversationExportSource } from "./exportEvents";

const event = (seq: number, sessionId = "chat-1"): EventRecord => ({
  sessionId,
  seq,
  at: 1792800000000,
  dir: "mux",
  kind: "user_message",
  msg: { text: `Prompt ${seq}` },
});

describe("recorded conversation export", () => {
  test("reads every page up to the initial sequence while the live chat keeps growing", async () => {
    const requests: Parameters<ConversationExportSource["page"]>[0][] = [];
    const source: ConversationExportSource = {
      detail: async () => ({ lastSeq: 6 }),
      page: async (params) => {
        requests.push(params);
        const events = [1, 2, 3, 4, 5, 6, 7, 8]
          .filter((seq) => seq > params.afterSeq && seq < params.beforeSeq)
          .slice(-2)
          .map((seq) => event(seq));
        return { events, hasMore: (events[0]?.seq ?? 1) > 1 };
      },
    };
    const events = await recordedConversationEvents("chat-1", source, () => true);
    expect(events.map((record) => record.seq)).toEqual([1, 2, 3, 4, 5, 6]);
    expect(requests.map((request) => request.beforeSeq)).toEqual([7, 5, 3]);
    expect(requests.every((request) => request.afterSeq === 0 && request.sessionId === "chat-1")).toBe(true);
  });

  test("refuses a late page after the selected chat changes", async () => {
    let current = true;
    const source: ConversationExportSource = {
      detail: async () => ({ lastSeq: 2 }),
      page: async () => {
        current = false;
        return { events: [event(1), event(2)], hasMore: false };
      },
    };
    await expect(recordedConversationEvents("chat-1", source, () => current)).rejects.toThrow();
  });

  test("refuses an incomplete page instead of exporting a silently truncated chat", async () => {
    const source: ConversationExportSource = {
      detail: async () => ({ lastSeq: 3 }),
      page: async () => ({ events: [], hasMore: true }),
    };
    await expect(recordedConversationEvents("chat-1", source, () => true)).rejects.toThrow();
  });

  test("refuses records belonging to another session", async () => {
    const source: ConversationExportSource = {
      detail: async () => ({ lastSeq: 1 }),
      page: async () => ({ events: [event(1, "other-chat")], hasMore: false }),
    };
    await expect(recordedConversationEvents("chat-1", source, () => true)).rejects.toThrow();
  });
});
