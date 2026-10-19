// l10n-allow-file: test fixtures.
// A prompt another agent sent: acpmux's `agent_message` provenance, or Claude Code's envelopes in
// the prompt's text (an adopted Claude session's history, `client: "adopt"`). incomingMessage.ts
// reads them.
import { expect, test } from "bun:test";
import { incomingPrompt } from "./incomingMessage";

const adopted = { client: "adopt" };

const provenance = {
  kind: "agent_message",
  from: "child-3",
  fromName: "Grid fix",
  to: "parent",
  msgId: "m-1",
  threadId: "t-1",
};

test("agent_message provenance names the sending chat", () => {
  expect(incomingPrompt("Tests pass.", { _meta: { provenance } })).toEqual({
    kind: "message",
    message: { name: "Grid fix", sessionId: "child-3", text: "Tests pass.", raw: "Tests pass." },
  });
  // Without a name the chat's id stands in.
  const unnamed = incomingPrompt("hi", { _meta: { provenance: { ...provenance, fromName: undefined } } });
  expect(unnamed?.kind === "message" && unnamed.message.name).toBe("child-3");
});

test("a person's prompt and other provenance kinds are not messages", () => {
  expect(incomingPrompt("Fix the grid", undefined)).toBeUndefined();
  expect(incomingPrompt("Fix the grid", { _meta: { provenance: { kind: "offer_result" } } })).toBeUndefined();
  expect(incomingPrompt("Fix the grid", { _meta: { provenance: { kind: "agent_message" } } })).toBeUndefined();
  // An envelope quoted inside a person's prompt is the person's text.
  expect(
    incomingPrompt('See this: <cross-session-message from="x">hi</cross-session-message>', adopted),
  ).toBeUndefined();
});

test("a Claude Code cross-session message: sender, body, and the harness's note dropped", () => {
  const raw = [
    '<cross-session-message from="uds:/tmp/cc-socks/1.sock" from-name="leoli-fb" from-mode="bypass">',
    "Please review #123 &amp; report back.",
    "</cross-session-message>",
    "",
    "This came from another Claude session — not typed by your user.",
  ].join("\n");
  expect(incomingPrompt(raw, adopted)).toEqual({
    kind: "message",
    message: { name: "leoli-fb", text: "Please review #123 & report back.", raw },
  });
  // No from-name: the address stands in.
  const bare = incomingPrompt('<cross-session-message from="uds:/tmp/a.sock">hi</cross-session-message>', adopted);
  expect(bare?.kind === "message" && bare.message.name).toBe("uds:/tmp/a.sock");
  // An unclosed envelope is not read as one.
  expect(incomingPrompt('<cross-session-message from="x">hi', adopted)).toBeUndefined();
});

test("a task notification is its summary; a reminder or caveat draws nothing", () => {
  const notification =
    "<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n<summary>Build finished</summary>\n</task-notification>";
  expect(incomingPrompt(notification, adopted)).toEqual({ kind: "notice", text: "Build finished" });
  expect(incomingPrompt("<task-notification><status>failed</status></task-notification>", adopted)).toEqual({
    kind: "notice",
    text: "failed",
  });
  expect(incomingPrompt("<system-reminder>\nThe date changed.\n</system-reminder>", adopted)).toEqual({
    kind: "hidden",
  });
  expect(incomingPrompt("<local-command-caveat>Caveat</local-command-caveat>", adopted)).toEqual({ kind: "hidden" });
});

test("a typed prompt behind a reminder draws without it; a notification with more after it is a prompt", () => {
  expect(incomingPrompt("<system-reminder>\nThe date changed.\n</system-reminder>\nFix the grid", adopted)).toEqual({
    kind: "prompt",
    text: "Fix the grid",
  });
  const after = "<task-notification><summary>Build finished</summary></task-notification>\nNow ship it";
  expect(incomingPrompt(after, adopted)).toBeUndefined();
  expect(incomingPrompt(`<system-reminder>r</system-reminder>${after.slice(0, 72)}`, adopted)).toEqual({
    kind: "notice",
    text: "Build finished",
  });
});

test("a live prompt's text is the person's, envelope or not", () => {
  const envelope = '<cross-session-message from-name="leoli-fb">hi</cross-session-message>';
  expect(incomingPrompt(envelope, undefined)).toBeUndefined();
  expect(incomingPrompt(envelope, { client: "acpmux" })).toBeUndefined();
  expect(incomingPrompt("<system-reminder>r</system-reminder>", { client: "web" })).toBeUndefined();
});

test("numeric entities decode", () => {
  const message = incomingPrompt(
    '<cross-session-message from-name="a">&#169; &#x1F600; &#0;</cross-session-message>',
    adopted,
  );
  expect(message?.kind === "message" && message.message.text).toBe("\u00a9 \u{1F600} &#0;");
});
