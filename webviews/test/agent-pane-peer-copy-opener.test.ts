// l10n-allow-file: synthetic peer transcript prompts, not shipped UI.
import { expect, test } from "bun:test";
import { peerCopyTail } from "../src/agent-session/acpmux/peerCopy";

const prompt = {
  sessionId: "chat",
  seq: 2,
  at: 2000,
  dir: "mux",
  kind: "user_message",
  msg: { text: "Explain the completed investigation" },
};
const events = [
  {
    sessionId: "chat",
    seq: 100,
    at: 100000,
    dir: "in",
    kind: "agent_message_chunk",
    msg: {
      method: "session/update",
      params: {
        update: {
          sessionUpdate: "agent_message_chunk",
          content: { type: "text", text: "Investigation complete." },
        },
      },
    },
  },
  {
    sessionId: "chat",
    seq: 101,
    at: 101000,
    dir: "mux",
    kind: "turn_result",
    msg: { stopReason: "end_turn" },
  },
];
const snapshot = {
  peer: "peer",
  sessionId: "chat",
  generation: 42,
  capturedAt: 101000,
  stale: true,
  hasMore: true,
  lastSeq: 101,
  events,
};

test("a cold capped peer tail carries its completed turn's prompt before any handshake", () => {
  const got = peerCopyTail({ ...snapshot, turnOpener: prompt }, "peer/chat")!;
  expect(got.tail.turnOpener).toEqual(prompt);
  expect(got.tail.events).toEqual(events);
  expect(got.tail.historyExhausted).toBe(false);
  expect(got.tail.usageFromSeq).toBe(100);
  expect(got.copy).toEqual({
    sessionId: "peer/chat",
    peer: "peer",
    generation: 42,
    capturedAt: 101000,
    lastSeq: 101,
    offline: false,
  });
});

test("older snapshots without an opener keep their tail", () => {
  for (const turnOpener of [undefined, null]) {
    const got = peerCopyTail({ ...snapshot, turnOpener }, "peer/chat")!;
    expect(got.tail.turnOpener).toBeUndefined();
    expect(got.tail.events).toEqual(events);
  }
});

test("an opener without a session id uses the page's wire session id", () => {
  const got = peerCopyTail({ ...snapshot, turnOpener: { ...prompt, sessionId: undefined } }, "peer/chat")!;
  expect(got.tail.turnOpener).toEqual(prompt);
});

test("a snapshot never forwards a malformed, foreign, or non-opening prompt", () => {
  const invalid = [
    "prompt",
    {},
    { ...prompt, seq: 100 },
    { ...prompt, seq: 102 },
    { ...prompt, seq: NaN },
    { ...prompt, seq: -1 },
    { ...prompt, seq: 1.5 },
    { ...prompt, sessionId: "another-chat" },
    { ...prompt, kind: "agent_message_chunk" },
    { ...prompt, dir: "in" },
    { ...prompt, msg: null },
    { ...prompt, msg: [] },
    { ...prompt, msg: { text: "A steer", steer: true } },
  ];
  for (const turnOpener of invalid) {
    const got = peerCopyTail({ ...snapshot, turnOpener }, "peer/chat")!;
    expect(got.tail.turnOpener).toBeUndefined();
    expect(got.tail.events).toEqual(events);
  }
});

test("a whole page or one starting a new turn needs no preceding prompt", () => {
  expect(
    peerCopyTail({ ...snapshot, hasMore: false, turnOpener: prompt }, "peer/chat")!.tail.turnOpener,
  ).toBeUndefined();
  const nextPrompt = { ...prompt, seq: 100, msg: { text: "Next turn" } };
  expect(
    peerCopyTail({ ...snapshot, events: [nextPrompt], turnOpener: prompt }, "peer/chat")!.tail.turnOpener,
  ).toBeUndefined();
});
