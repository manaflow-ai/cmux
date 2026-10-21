import { expect, test } from "bun:test";
import { inlineCompletion } from "../src/agent-session/acpmux/newtab/screenModel";

test("top-site open rows provide an inline completion", () => {
  expect(inlineCompletion("reddi", [{ type: "open", url: "https://reddit.com", text: "reddit.com" }])).toBe(
    "reddit.com",
  );
});

test("history URL rows provide an inline completion", () => {
  expect(inlineCompletion("reddi", [{ type: "history", url: "https://reddit.com/" }])).toBe("reddit.com");
});

test("prompt and search rows never become inline completions", () => {
  expect(
    inlineCompletion("reddi", [{ type: "ask", text: "reddi", harness: "claude", agent: "Claude Code" }]),
  ).toBeUndefined();
  expect(inlineCompletion("reddi", [{ type: "search", text: "reddi" }])).toBeUndefined();
});
