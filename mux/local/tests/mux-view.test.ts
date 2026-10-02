import { expect, test } from "bun:test";
import { MuxView, type AcpmuxEvent } from "../src/mux-view.ts";

let seq = 0;
const ev = (dir: string, kind: string, msg: Record<string, unknown> = {}): AcpmuxEvent => ({
  seq: ++seq,
  at: 1_790_000_000_000 + seq,
  dir,
  kind,
  msg,
});
const chunk = (text: string) =>
  ev("in", "agent_message_chunk", {
    params: { update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
  });

test("a turn folds into the user's bubble, typing, and one mux bubble with the whole reply", () => {
  const view = new MuxView({ id: "me", displayName: "lawrence" });
  expect(
    view.apply(ev("mux", "user_message", { promptId: "p1", text: "hi" })).messages[0],
  ).toMatchObject({ id: "p1", senderId: "me" });
  expect(view.apply(ev("mux", "turn_started"))).toEqual({ messages: [], typing: true });
  view.apply(chunk("Hel"));
  view.apply(chunk("lo."));
  view.apply(ev("in", "usage_update"));
  const end = view.apply(ev("mux", "turn_end", { stopReason: "end_turn" }));
  expect(end.typing).toBe(false);
  expect(end.messages[0]).toMatchObject({
    senderId: "mux",
    parts: [{ type: "text", text: "Hello." }],
  });
  expect(view.conversation().messages.map((m) => m.senderId)).toEqual(["me", "mux"]);
});

test("supervisor events show as Agents bubbles without the instructions meant for the mux", () => {
  const view = new MuxView({ id: "me", displayName: "lawrence" });
  const text =
    "[mux-event] Agent fixer (claude-sr, /repo) finished a turn.\nIts reply:\nAll tests pass.\n\nTell the user what matters, briefly.";
  const [message] = view.apply(ev("mux", "user_message", { promptId: "p2", text })).messages;
  expect(message.senderId).toBe("agents");
  expect(message.parts).toEqual([
    { type: "text", text: "Agent fixer (claude-sr, /repo) finished a turn.\nAll tests pass." },
  ]);
});

test("replaying history and then live events never duplicates a message", () => {
  const view = new MuxView({ id: "me", displayName: "lawrence" });
  const user = ev("mux", "user_message", { promptId: "p3", text: "again" });
  view.apply(user);
  expect(view.apply(user).messages).toEqual([]);
  expect(view.conversation().messages).toHaveLength(1);
});

test("live agent text (ACP session/update) folds like history does", () => {
  const view = new MuxView({ id: "me", displayName: "lawrence" });
  view.apply(ev("mux", "turn_started"));
  // The server turns a live update into this shape (see fromUpdate in main.ts).
  view.apply({
    seq: 200,
    at: 1,
    dir: "in",
    kind: "agent_message_chunk",
    msg: {
      params: {
        update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Ok" } },
      },
    },
  });
  expect(view.apply(ev("mux", "turn_end")).messages[0].parts).toEqual([
    { type: "text", text: "Ok" },
  ]);
});
