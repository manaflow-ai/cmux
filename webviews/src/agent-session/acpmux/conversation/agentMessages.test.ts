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

test("a send's delivery: sending, sent, queued, delivered or failed, from its state and result", async () => {
  const { messageDelivery } = await import("./agentMessages");
  const done = (output?: string) => ({ status: "completed", output });
  expect(messageDelivery({ status: "in_progress" })).toBe("sending");
  expect(messageDelivery({ status: "failed", output: "boom" })).toBe("failed");
  expect(messageDelivery({ status: "completed", exitCode: 1 })).toBe("failed");
  expect(messageDelivery(done())).toBe("sent");
  expect(
    messageDelivery(done('{"success":true,"message":"Message queued for delivery to a39e817af38ddf5e7","pin":{}}')),
  ).toBe("queued");
  expect(messageDelivery(done('{"success":true,"message":"Message delivered to grid-fix"}'))).toBe("delivered");
  expect(messageDelivery(done('{"success":true,"message":"Message sent to grid-fix"}'))).toBe("sent");
  expect(messageDelivery(done('{"success":false,"error":"no such agent"}'))).toBe("failed");
  // acpmux send --no-wait, plain and --json.
  expect(messageDelivery(done("queued\n"))).toBe("queued");
  expect(messageDelivery(done("steered\n"))).toBe("delivered");
  expect(messageDelivery(done('{"sessionId":"x","queued":true,"steered":false}'))).toBe("queued");
  expect(messageDelivery(done('{"sessionId":"x","queued":false,"steered":true}'))).toBe("delivered");
  // tell-coordinator's receipt.
  expect(messageDelivery(done("delivered to leoli-24 (id 9defc4d0ed87)\n"))).toBe("delivered");
  expect(messageDelivery(done("error: no session named grid\n"))).toBe("failed");
});

test("a recipient id nothing names is never shown", async () => {
  const { looksLikeId, recipientName } = await import("./agentNames");
  expect(looksLikeId("a39e817af38ddf5e7")).toBe(true);
  expect(looksLikeId("01a0ebd5-0efe-721d-9edc-cf1a6ba78d98")).toBe(true);
  for (const name of ["grid-fix", "coord-deputy", "release-rings-32", "coordinator", "decade"])
    expect(looksLikeId(name)).toBe(false);
  const names = new Map([["a39e817af38ddf5e7", "Fix grid jump"]]);
  expect(recipientName("a39e817af38ddf5e7", names)).toBe("Fix grid jump");
  expect(recipientName("a5f0c2b9e1d4a7c3b", names)).toBeUndefined();
  expect(recipientName("grid-fix", names)).toBe("grid-fix");
});
