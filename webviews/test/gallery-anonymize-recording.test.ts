import { expect, test } from "bun:test";
import { anonymize, neutralText } from "../scripts/gallery/anonymize-recording";

test("a text keeps its length, line breaks and punctuation, and none of its words or numbers", () => {
  const text = "Fix #26504 at bc7b3f86:\n  run `bun test` in /Users/leo/src";
  const out = neutralText(text);
  expect(out.length).toBe(text.length);
  expect(out.split("\n").map((line) => line.length)).toEqual(text.split("\n").map((line) => line.length));
  for (const word of ["Fix", "26504", "bc7b3f86", "bun", "test", "Users", "leo", "src"])
    expect(out).not.toContain(word);
  expect(out).toMatch(/^[A-Z][a-z-]* #\d{5} /);
});

test("protocol words stay, ids and names do not, and events renumber from one", () => {
  const out = anonymize(
    [
      { seq: 90, at: 5000, kind: "codex.turn/diff/updated", msg: {} },
      {
        seq: 91,
        at: 6000,
        sessionId: "real-session",
        kind: "user_message",
        msg: {
          _meta: { provenance: { from: "fromAgent", fromName: "claude-sr2", kind: "agent_message" } },
          text: "secret plan",
        },
      },
      {
        seq: 92,
        at: 7000,
        kind: "tool_call",
        msg: {
          params: {
            update: {
              sessionUpdate: "tool_call",
              toolCallId: "exec-1",
              kind: "execute",
              status: "completed",
              title: "rg secret",
            },
          },
        },
      },
    ],
    { sessionId: "fixture" },
  );
  expect(out.map((event) => [event.seq, event.kind, event.sessionId])).toEqual([
    [1, "user_message", "fixture"],
    [2, "tool_call", "fixture"],
  ]);
  const text = JSON.stringify(out);
  for (const word of ["secret", "claude-sr2", "exec-1", "real-session"]) expect(text).not.toContain(word);
  for (const word of ["fromAgent", "agent_message", "tool_call", "execute", "completed"]) expect(text).toContain(word);
});
