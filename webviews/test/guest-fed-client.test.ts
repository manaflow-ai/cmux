// l10n-allow-file: test fixtures.
// A client fed one chat's records from elsewhere (AcpmuxDirectClient.fed, the guest page's room):
// a snapshot draws the chat, live records past the newest held fold once, and an older page joins
// in front of what is held.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient, type EventRecord } from "../src/agent-session/acpmux/direct";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { chatRowsHostCount } from "../src/agent-session/acpmux/rows/receiver";
import type { KeptTail } from "../src/agent-session/acpmux/tailCache";

const say = (seq: number, text: string): EventRecord => ({
  sessionId: "owner-session",
  seq,
  at: 1_000 + seq,
  dir: "in",
  kind: "agent_message_chunk",
  msg: {
    method: "session/update",
    params: { update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
  },
});
const prompt = (seq: number, text: string): EventRecord => ({
  seq,
  at: 1_000 + seq,
  dir: "mux",
  kind: "user_message",
  msg: { text },
});

test("a fed client folds a snapshot, live records once, and an older page in front", () => {
  let shown: AcpmuxSnapshot | undefined;
  const client = AcpmuxDirectClient.fed("guest-chat", (snapshot) => (shown = snapshot));
  const words = () => (shown?.rows ?? []).map((row) => row.text ?? "").join("|");
  client.feed([prompt(3, "Second ask"), say(4, "Working on it. ")], "snapshot");
  expect(words()).toContain("Second ask");
  expect(words()).toContain("Working on it.");
  // A copy of a held record, and the next one: only the new words fold.
  client.feed([say(4, "Working on it. "), say(5, "Done.")], "live");
  expect(words().match(/Working on it\./g)?.length).toBe(1);
  expect(words()).toContain("Done.");
  client.feed([prompt(1, "First ask"), say(2, "Sure.")], "older");
  const text = words();
  expect(text.indexOf("First ask")).toBeLessThan(text.indexOf("Second ask"));
  expect(text).toContain("Done.");
});

test("dispose removes the page listeners and a frame already asked for draws nothing", () => {
  const scope = globalThis as Record<string, unknown>;
  // The listeners on the page, as the DOM keeps them: a second remove of one is a no-op.
  const listening = new Set<string>();
  const handlers = new Map<unknown, number>();
  const id = (handler: unknown) => handlers.get(handler) ?? handlers.set(handler, handlers.size).get(handler)!;
  const target = (kind: string) => ({
    addEventListener: (type: string, handler: unknown) => listening.add(`${kind}:${type}:${id(handler)}`),
    removeEventListener: (type: string, handler: unknown) => listening.delete(`${kind}:${type}:${id(handler)}`),
    visibilityState: "visible",
  });
  const saved = { document: scope.document, window: scope.window };
  scope.document = target("document");
  scope.window = target("window");
  const frames: (() => void)[] = [];
  const schedule = AcpmuxDirectClient.scheduleFrame;
  AcpmuxDirectClient.scheduleFrame = (run) => void frames.push(run);
  try {
    let draws = 0;
    const client = AcpmuxDirectClient.fed("guest-chat", () => (draws += 1));
    // Not a page chat: nothing left listening from the moment it is made.
    expect([...listening]).toEqual([]);
    client.feed([prompt(1, "Ask")], "snapshot");
    expect(draws).toBe(1);
    client.feed([say(2, "Working")], "live");
    expect(frames.length).toBe(1);
    client.dispose();
    for (const run of frames) run();
    client.feed([say(3, "More")], "live");
    client.feed([prompt(1, "Again")], "snapshot");
    expect(draws).toBe(1);
    expect([...listening]).toEqual([]);
  } finally {
    AcpmuxDirectClient.scheduleFrame = schedule;
    scope.document = saved.document;
    scope.window = saved.window;
  }
});

test("a fed client has no socket, yet every feed reaches its listener", () => {
  // A client with no socket counts as closed, and a closed one draws nothing (emitNow): a fed
  // client is the exception until it is disposed, or the guest's transcript stays blank.
  const shown: AcpmuxSnapshot[] = [];
  const client = AcpmuxDirectClient.fed("guest-chat", (snapshot) => void shown.push(snapshot));
  client.feed([prompt(1, "Ask")], "snapshot");
  client.feed([say(2, "Working")], "live");
  client.feed([prompt(0, "skipped"), say(-1, "skipped")], "older");
  expect(shown.length).toBe(3);
  expect(
    shown
      .at(-1)
      ?.rows.map((row) => row.text ?? "")
      .join("|"),
  ).toContain("Working");
});

/// The page's document, counting the listeners on it, for the length of `run`.
function withCountedDocument(run: (listening: () => number) => void): void {
  const scope = globalThis as Record<string, unknown>;
  const listening = new Set<unknown>();
  const target = {
    addEventListener: (_type: string, handler: unknown) => listening.add(handler),
    removeEventListener: (_type: string, handler: unknown) => listening.delete(handler),
    visibilityState: "visible",
  };
  const saved = { document: scope.document, window: scope.window };
  scope.document = target;
  scope.window = target;
  try {
    run(() => listening.size);
  } finally {
    scope.document = saved.document;
    scope.window = saved.window;
  }
}

test("a fed client leaves no host in the document's receiver once made", () => {
  withCountedDocument(() => {
    const hosts = chatRowsHostCount();
    const client = AcpmuxDirectClient.fed("guest-chat", () => {});
    expect(chatRowsHostCount()).toBe(hosts);
    client.dispose();
    expect(chatRowsHostCount()).toBe(hosts);
  });
});

test("a restored tab's retained draws leave no page listener and no receiver host, however many", () => {
  const tail: KeptTail = {
    events: [prompt(1, "Ask"), prompt(2, "Again")],
    summary: undefined,
    turnOpener: undefined,
    historyExhausted: true,
    queue: [],
    configSeq: 0,
    usageFromSeq: 0,
  };
  for (const draws of [1, 50])
    withCountedDocument((listening) => {
      const before = { listeners: listening(), hosts: chatRowsHostCount() };
      for (let draw = 0; draw < draws; draw += 1) AcpmuxDirectClient.retainedSnapshot("guest-chat", tail);
      expect({ listeners: listening(), hosts: chatRowsHostCount() }).toEqual(before);
    });
});
