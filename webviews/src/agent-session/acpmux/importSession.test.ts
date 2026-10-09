import { describe, expect, test } from "bun:test";
import { importedPrompt, parseImportedSession } from "./importSession";

describe("outside session import", () => {
  test("reads Claude user and assistant text while dropping sidechains and metadata", () => {
    const session = parseImportedSession(
      [
        JSON.stringify({ type: "custom-title", "custom-title": "ignored", cwd: "/repo" }),
        JSON.stringify({ type: "user", cwd: "/repo", message: { content: "<user_query>fix tests</user_query>" } }),
        JSON.stringify({
          type: "assistant",
          message: { content: [{ type: "text", text: "I found the failing test." }] },
        }),
        JSON.stringify({ type: "assistant", isSidechain: true, message: { content: "drop me" } }),
      ].join("\n"),
      "claude-session.jsonl",
    );
    expect(session.source).toBe("claude");
    expect(session.cwd).toBe("/repo");
    expect(session.messages).toEqual([
      { role: "user", text: "fix tests" },
      { role: "assistant", text: "I found the failing test." },
    ]);
    expect(importedPrompt(session)).toContain("Claude Code (claude-session.jsonl)");
    expect(importedPrompt(session)).toContain("Working directory: /repo");
  });

  test("reads Codex response_item messages and ignores tool records", () => {
    const session = parseImportedSession(
      [
        JSON.stringify({ type: "event_msg", payload: { type: "user_message", message: "start here" } }),
        JSON.stringify({
          cwd: "/work",
          type: "response_item",
          payload: { type: "message", role: "user", content: [{ type: "input_text", text: "review this" }] },
        }),
        JSON.stringify({ type: "response_item", payload: { type: "function_call", name: "shell", arguments: "{}" } }),
        JSON.stringify({
          type: "response_item",
          payload: {
            type: "message",
            role: "assistant",
            content: [{ type: "output_text", text: "The change is safe." }],
          },
        }),
      ].join("\n"),
      "rollout.jsonl",
    );
    expect(session.source).toBe("codex");
    expect(session.messages.map((message) => message.text)).toEqual([
      "start here",
      "review this",
      "The change is safe.",
    ]);
  });

  test("bounds imported transcript text", () => {
    const session = parseImportedSession(JSON.stringify({ type: "user", message: { content: "x".repeat(20_000) } }));
    expect(session.messages[0]?.text.length).toBe(12_000);
    expect(importedPrompt(session).length).toBeLessThanOrEqual(64 * 1024);
  });
});
