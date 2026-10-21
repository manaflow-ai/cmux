// l10n-allow-file: test fixtures.
// Tool calls that message another agent draw as message cards (agentMessages.ts): Claude Code's
// SendMessage, and the cmux-sessions MCP server's send_to_session (#21858) under the names a
// harness gives MCP tools, and acpmux_send (acpmux_mcp.rs) and `acpmux send --no-wait`.
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

test("acpmux_send, as harnesses name it behind the cmux server or on its own", () => {
  for (const title of ["mcp__cmux__acpmux_send", "mcp__acpmux__send", "acpmux_send", "cmux.acpmux_send"])
    expect(agentMessage(call(title, { to: "huge-blue/lane-a", text: "Rebase on main." }))).toEqual({
      channel: "agent",
      to: "huge-blue/lane-a",
      text: "Rebase on main.",
    });
  // Codex nests an MCP call's arguments under {server, tool, arguments}.
  expect(
    agentMessage(
      call("cmux", { server: "cmux", tool: "acpmux_send", arguments: { to: "lane-b", text: "Done.", steer: false } }),
    ),
  ).toEqual({ channel: "agent", to: "lane-b", text: "Done." });
  // Another server's send, or no recipient: an ordinary tool row.
  expect(agentMessage(call("mcp__gmail__send", { to: "x", text: "y" }))).toBeUndefined();
  expect(agentMessage(call("mcp__cmux__acpmux_send", { text: "y" }))).toBeUndefined();
});

test("acpmux send in a shell, fed by printf and under timeout", () => {
  const command = "printf 'first line\\nsecond line' | timeout 60 acpmux send --no-wait huge-blue/lane-a -";
  expect(agentMessage({ id: "t1", title: "Run", status: "completed", command })).toEqual({
    channel: "agent",
    to: "huge-blue/lane-a",
    text: "first line\nsecond line",
  });
  expect(
    agentMessage({ id: "t1", title: "Run", status: "completed", command: 'acpmux send --no-wait --steer lane-b "Stop and rebase."' }),
  ).toEqual({ channel: "agent", to: "lane-b", text: "Stop and rebase." });
  // A send that waits for the reply is a conversation, not a message: the command row keeps it.
  expect(
    agentMessage({ id: "t1", title: "Run", status: "completed", command: 'acpmux send lane-b "What is the status?"' }),
  ).toBeUndefined();
});
