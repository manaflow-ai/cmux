// l10n-allow-file: recorded chat fixtures, not shipped UI.
import { expect, test } from "bun:test";
import type { EventRecord } from "../direct";
import { recordedConversationEvents } from "./exportEvents";
import { recordedConversationMarkdown } from "./exportMarkdown";

test("exports older turns and tools from paginated history using the real transcript reducer", async () => {
  const event = (seq: number, kind: string, dir: "mux" | "in", msg: EventRecord["msg"]): EventRecord => ({
    seq,
    kind,
    dir,
    msg,
    sessionId: "chat-1",
    at: 1792800000000,
  });
  const update = (seq: number, kind: string, data: Record<string, unknown>) =>
    event(seq, kind, "in", {
      method: "session/update",
      params: { update: { sessionUpdate: kind, ...data } },
    });
  const history = [
    event(1, "user_message", "mux", { text: "An older prompt" }),
    update(2, "agent_message_chunk", { content: { type: "text", text: "An older answer" } }),
    event(3, "turn_result", "mux", { status: "completed" }),
    event(4, "user_message", "mux", { text: "The latest prompt" }),
    update(5, "tool_call", {
      toolCallId: "read-1",
      title: "Read settings.json",
      kind: "read",
      status: "completed",
      rawInput: { secret: "not copied" },
      content: [{ type: "content", content: { type: "text", text: "private output" } }],
    }),
    update(6, "agent_message_chunk", { content: { type: "text", text: "The latest answer" } }),
  ];
  const events = await recordedConversationEvents(
    "chat-1",
    {
      detail: async () => ({ lastSeq: 6 }),
      page: async ({ afterSeq, beforeSeq }) => {
        const events = history.filter((event) => event.seq > afterSeq && event.seq < beforeSeq).slice(-3);
        return { events, hasMore: (events[0]?.seq ?? 1) > 1 };
      },
    },
    () => true,
  );
  const markdown = recordedConversationMarkdown("chat-1", events);
  expect(markdown).toContain("**User:**\nAn older prompt");
  expect(markdown).toContain("**Assistant:**\nAn older answer");
  expect(markdown).toContain("The latest prompt");
  expect(markdown).toContain("The latest answer");
  expect(markdown).toContain("- Tool: Read settings.json");
  expect(markdown).not.toContain("not copied");
  expect(markdown).not.toContain("private output");
});
