// l10n-allow-file: test fixtures.
// Tool calls that message another agent draw as message cards (agentMessages.ts): Claude Code's
// SendMessage, and the cmux-sessions MCP server's send_to_session (#21858) under the names a
// harness gives MCP tools.
import { expect, test } from "bun:test";
import { agentMessage } from "./agentMessages";

const call = (title: string, input: Record<string, unknown>) => ({
  id: "t1",
  title,
  status: "completed",
  inputSummary: JSON.stringify(input),
});

test("Claude Code's SendMessage", () => {
  expect(agentMessage(call("SendMessage", { to: "leoli-fb", message: "Done." }))).toEqual({
    channel: "agent",
    to: "leoli-fb",
    text: "Done.",
  });
});

test("send_to_session, as Claude Code and other harnesses name MCP tools", () => {
  for (const title of ["mcp__cmux-sessions__send_to_session", "cmux-sessions.send_to_session", "send_to_session"])
    expect(agentMessage(call(title, { session: "child-3", text: "Rebase on main." }))).toEqual({
      channel: "agent",
      to: "child-3",
      text: "Rebase on main.",
    });
  // Another server's tool of a similar name is not this one.
  expect(agentMessage(call("mcp__gmail__send_to_session_log", { session: "x", text: "y" }))).toBeUndefined();
  // No recipient: an ordinary tool row.
  expect(agentMessage(call("mcp__cmux-sessions__send_to_session", { text: "y" }))).toBeUndefined();
});
