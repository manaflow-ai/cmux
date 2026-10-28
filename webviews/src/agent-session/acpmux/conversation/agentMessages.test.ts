// l10n-allow-file: test fixtures.
// Tool calls that message another agent draw as message cards (agentMessages.ts): Claude Code's
// SendMessage, and the cmux-sessions MCP server's send_to_session (#21858) under the names a
// harness gives MCP tools, and the acpmux MCP server's acpmux_send (acpmux_mcp.rs).
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
    expect(agentMessage(call(title, { to: "build-box/lane-a", text: "Rebase on main." }))).toEqual({
      channel: "agent",
      to: "build-box/lane-a",
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

test("a subagent's agentId resolves to its description; an unknown id reads short", async () => {
  const { agentIdIn } = await import("../subagents/subagentFold");
  const { recipientName, shortId } = await import("./agentNames");
  // Claude Code's Agent call answers in prose, with the id in the middle of it.
  const answer = [
    "Async agent launched successfully. (This tool result is internal metadata.)",
    "agentId: a5b7309ddf7afa44d (internal ID - do not mention to user. Use SendMessage with to: 'a5b7309ddf7afa44d')",
    "The agent is working in the background.",
  ].join("\n");
  expect(agentIdIn(answer)).toBe("a5b7309ddf7afa44d");
  const names = new Map([["a5b7309ddf7afa44d", "Time-cap the pre-push check"]]);
  const message = agentMessage(
    call("SendMessage", { to: "a5b7309ddf7afa44d", recipient: "a5b7309ddf7afa44d", message: "Resume." }),
  )!;
  expect(recipientName(message.to, names)).toBe("Time-cap the pre-push check");
  expect(recipientName("a997582716e0ae335", names)).toBeUndefined();
  expect(shortId("a997582716e0ae335")).toBe("a9975827");
  expect(shortId(" 01a0ebd5-0efe-721d-9edc-cf1a6ba78d98 ")).toBe("01a0ebd5");
  expect(shortId("grid")).toBe("grid");
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

test("why a send was not delivered, read from its result", async () => {
  const { notDeliveredReason } = await import("./agentMessages");
  const reason = (output: string) => notDeliveredReason({ output });
  expect(
    reason(JSON.stringify({ success: false, message: "Agent x was stopped by the user and won't be resumed." })),
  ).toBe("stopped");
  expect(reason(JSON.stringify({ success: false, error: "No agent named grid-fix" }))).toBe("noAgent");
  expect(reason(JSON.stringify({ success: false, error: "Recipient grid-fix not found" }))).toBe("noAgent");
  expect(reason("error: no_session: grid\n")).toBe("noAgent");
  expect(reason("error: session grid has exited\n")).toBe("stopped");
  expect(reason(JSON.stringify({ success: false }))).toBe("other");
  expect(reason("")).toBe("other");
});

test("a result that says it was not delivered never reads as delivered", async () => {
  const { messageDelivery } = await import("./agentMessages");
  const done = (output: string) => messageDelivery({ status: "completed", output });
  expect(done("Message could not be delivered: the session is gone")).toBe("failed");
  expect(done("warning: not delivered")).toBe("failed");
  expect(done('{"success":true,"message":"Failed to deliver to grid-fix"}')).toBe("failed");
  // An empty error field is no error.
  expect(done('{"success":true,"error":"","message":"Message delivered to grid-fix"}')).toBe("delivered");
});

test("a send's own words are never read as its receipt", async () => {
  const { messageDelivery } = await import("./agentMessages");
  const done = (output: string) => ({ status: "completed", output });
  expect(messageDelivery(done("Message wasn't delivered\n"))).toBe("failed");
  expect(messageDelivery(done("It hasn't been sent"))).toBe("failed");
  // A mailbox write echoes what it wrote.
  const note = "The earlier message was not delivered; resending.";
  expect(messageDelivery(done(`${note}\n`), { channel: "mailbox", text: note })).toBe("sent");
  // A send that echoes its message before its receipt reads the receipt.
  expect(
    messageDelivery(done(`${note}\ndelivered to leoli-24 (id 9defc4d0ed87)\n`), { channel: "coordinator", text: note }),
  ).toBe("delivered");
});

test("a message's words never erase a JSON receipt's failure flag", async () => {
  const { messageDelivery } = await import("./agentMessages");
  const done = (output: string) => ({ status: "completed", output });
  const say = (text: string) => ({ channel: "agent" as const, text });
  expect(messageDelivery(done('{"success":false,"error":"Agent stopped"}'), say("success"))).toBe("failed");
  expect(messageDelivery(done('{"ok":false}'), say("ok"))).toBe("failed");
});

test("a recipient's name is not a failure word", async () => {
  const { messageDelivery } = await import("./agentMessages");
  const done = (output: string) => ({ status: "completed", output });
  expect(
    messageDelivery(done('{"success":true,"message":"Message queued for delivery to undelivered-reviewer"}')),
  ).toBe("queued");
  expect(messageDelivery(done("queued for not-delivered-lane"))).toBe("queued");
  expect(messageDelivery(done("Message undeliverable"))).toBe("failed");
});

test("a short message never erases its receipt's words, and a recipient named like a failure is not one", async () => {
  const { messageDelivery } = await import("./agentMessages");
  const done = (output: string) => ({ status: "completed", output });
  const say = (text: string, to?: string) => ({ channel: "agent" as const, text, to });
  expect(messageDelivery(done('{"message":"Message not delivered: recipient is gone"}'), say("not"))).toBe("failed");
  expect(messageDelivery(done("not delivered"), say("not"))).toBe("failed");
  expect(messageDelivery(done("not delivered"), say("not delivered"))).toBe("sent");
  expect(
    messageDelivery(
      done('{"success":true,"message":"Message queued for delivery to undelivered"}'),
      say("hi", "undelivered"),
    ),
  ).toBe("queued");
  expect(messageDelivery(done("Message not delivered to not"), say("hi", "not"))).toBe("failed");
});
