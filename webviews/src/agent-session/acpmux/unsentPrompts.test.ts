// Leo, 2026-11-11: "when restarting ALL MY ... UNSENT ... GOT DELETED". A refused or unanswered
// prompt lived only in the page as its Not sent row; a relaunch dropped every one. The app host now
// keeps each prompt no agent took (unsentPrompts.ts, AgentPaneUnsentPrompts.swift), and a cold
// start draws every one again at once as a Not sent row with Retry, Edit and Remove.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { resetKeptTailsForTests } from "./tailCache";
import type { UnsentPromptRecord, UnsentPromptStore } from "./unsentPrompts";
import { translate } from "./i18n";
import { teardownDom } from "../../../test/support/domTeardown";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = (["window", "document"] as const).map((key) => [key, key in scope, scope[key]] as const);

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
// React finishes its queued work before the DOM globals go (test/support/domTeardown.ts); the kept
// tails are cleared after that work, as failedPromptRetry.test.ts does.
afterAll(async () => {
  await teardownDom(saved, { scope });
  resetKeptTailsForTests();
});

type Row = { id: string; kind: string; text?: string; failed?: boolean; error?: string; pending?: boolean };

/// The app host's store, in memory: it outlives the panes as the file outlives the page.
function hostStore() {
  const chats = new Map<string, Map<string, UnsentPromptRecord>>();
  const store: UnsentPromptStore = {
    read: async (sessionId) => [...(chats.get(sessionId)?.values() ?? [])],
    put: async (sessionId, record) => {
      const chat = chats.get(sessionId) ?? new Map();
      chat.set(record.promptId, record);
      chats.set(sessionId, chat);
    },
    remove: async (sessionId, promptId) => {
      chats.get(sessionId)?.delete(promptId);
    },
  };
  const all = () => [...chats.values()].flatMap((chat) => [...chat.values()]);
  return { store, all };
}

/// A pane on the mock daemon. `answer` decides each session/prompt: an Error refuses it, "hang"
/// never answers it (the app quits while it is on its way), undefined lets it through.
async function pane(store: UnsentPromptStore, answer: (text: string) => Error | "hang" | undefined = () => undefined) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  class Relay extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const self = this as unknown as { answer: (method: string, params: Record<string, any>) => Promise<unknown> };
      const through = self.answer.bind(this);
      self.answer = (method, params) => {
        if (method !== "session/prompt") return through(method, params);
        const verdict = answer(String(params.prompt?.[0]?.text ?? ""));
        if (verdict === "hang") return new Promise(() => undefined);
        return verdict ? Promise.reject(verdict) : through(method, params);
      };
    }
  }
  let rows: Row[] = [];
  let socket: Relay | undefined;
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => (rows = snapshot.rows as Row[]),
    undefined,
    () => (socket = new Relay()) as unknown as WebSocket,
  );
  client.setUnsentPromptStore(store);
  /// The connection goes while a request waits (`rejectPending`), as an acpmux restart drops it.
  const drop = () => {
    socket!.close();
    (socket as unknown as { onclose: (() => void) | null }).onclose?.();
  };
  return { client, rows: () => rows, drop };
}

/// Lets the pane's queued work run: the host store answers at once, so the restore and the store
/// writes are a few promise hops and one queued microtask, done after the macrotask queue drains.
const settle = async () => {
  for (let hop = 0; hop < 5; hop += 1) await new Promise<void>((resolve) => setImmediate(resolve));
};
const refusal = () =>
  Object.assign(
    new Error(
      "This chat runs with your Mac's Claude permissions. Start a new chat from this device to control it remotely.",
    ),
    { code: "remote.local_claude_session", reason: "remote.local_claude_session" },
  );

test("a cold restart with refused and pending sends draws every one again as Not sent, at once", async () => {
  const host = hostStore();
  const N = 3;
  const refused = Array.from({ length: N }, (_, i) => `refused ${i}`);
  const pending = Array.from({ length: N }, (_, i) => `pending ${i}`);
  const before = await pane(host.store, (text) => (text.startsWith("refused") ? refusal() : "hang"));
  for (const text of refused) await before.client.send(text).catch(() => undefined);
  for (const text of pending) void before.client.send(text).catch(() => undefined);
  await settle();
  expect(
    before
      .rows()
      .filter((row) => row.failed)
      .map((row) => row.text),
  ).toEqual(refused);
  // The app quits: the page and everything it held go. Only the host's store stays.
  before.client.close?.();
  expect(
    host
      .all()
      .map((record) => record.input)
      .sort(),
  ).toEqual([...refused, ...pending].sort());

  const after = await pane(host.store);
  try {
    await settle();
    const shown = after.rows().filter((row) => row.kind === "user" && row.failed);
    expect(new Set(shown.map((row) => row.text))).toEqual(new Set([...refused, ...pending]));
    expect(shown).toHaveLength(refused.length + pending.length);
    // A refused one keeps its reason; each has a Retry (it is the pane's failed prompt).
    expect(shown.find((row) => row.text === "refused 0")?.error).toContain("Mac's Claude permissions");
    for (const row of shown) expect(after.client.failedPromptCopies([row.id])).toHaveLength(1);
  } finally {
    after.client.close?.();
  }
});

test("only an agent taking it, Remove or Edit takes a prompt off the host", async () => {
  const host = hostStore();
  const first = await pane(host.store, () => refusal());
  await first.client.send("keep me").catch(() => undefined);
  await first.client.send("remove me").catch(() => undefined);
  await first.client.send("edit me").catch(() => undefined);
  await settle();
  // A refusal never takes one off.
  expect(host.all()).toHaveLength(3);
  const id = (text: string) => first.rows().find((row) => row.text === text)!.id;
  first.client.removeFailedPrompt(id("remove me"));
  expect(first.client.takeFailedPrompt(id("edit me"))?.input).toBe("edit me");
  await settle();
  expect(host.all().map((record) => record.input)).toEqual(["keep me"]);
  first.client.close?.();

  // Retry on a later pane goes through: acpmux took it, so the host lets it go and no failed copy stays.
  const second = await pane(host.store);
  try {
    await settle();
    const row = second.rows().find((candidate) => candidate.text === "keep me" && candidate.failed);
    expect(row).toBeDefined();
    await second.client.retryPrompt(row!.id);
    await settle();
    expect(host.all()).toHaveLength(0);
    expect(second.rows().some((candidate) => candidate.text === "keep me" && candidate.failed)).toBe(false);
  } finally {
    second.client.close?.();
  }
});

test("a prompt that went through is never kept", async () => {
  const host = hostStore();
  const sent = await pane(host.store);
  try {
    await sent.client.send("ship it");
    await settle();
    expect(host.all()).toHaveLength(0);
  } finally {
    sent.client.close?.();
  }
});

test("a prompt lost with its connection stays kept for a relaunch, and comes back as a quiet Not sent row", async () => {
  const host = hostStore();
  const lost = await pane(host.store, () => "hang");
  const sending = lost.client.send("lost one").then(
    () => undefined,
    (e: unknown) => e,
  );
  await settle();
  lost.drop();
  const error = await sending;
  expect((error as { lostPrompt?: unknown }).lostPrompt).toBeDefined();
  // Its sender waits for the next connection (lostPrompt.ts keepLostPrompt), as #41513 made it:
  // no failed row to keep in the chat from here, and the host's copy stays meanwhile.
  expect((error as { failedRow?: unknown }).failedRow).toBeUndefined();
  expect(host.all().map((record) => record.input)).toEqual(["lost one"]);
  lost.client.close?.();
  // The app went before any connection showed it: the relaunch draws it, saying only "Not sent".
  const next = await pane(host.store);
  try {
    await settle();
    const row = next.rows().find((candidate) => candidate.text === "lost one");
    expect(row?.failed).toBe(true);
    expect(row?.error).toBe(translate("prompt.failure.hostAway"));
    expect(row?.error).not.toContain("taking longer");
    expect(next.client.failedPromptCopies([row!.id])).toHaveLength(1);
    // The lost prompt's sender draws it on its way over the restored row: one row, sending again.
    const promptId = host.all()[0]!.promptId;
    expect(next.client.drawLostPrompt(next.client.selectedSession ?? "", promptId, "lost one", [])).toBe(true);
    const rows = next.rows().filter((candidate) => candidate.text === "lost one");
    expect(rows).toHaveLength(1);
    expect(rows[0]?.failed).toBeFalsy();
    expect(rows[0]?.pending).toBe(true);
    // Once it showed (or went back to the composer), its sender lets the host's copy go.
    next.client.forgetUnsentPrompt(promptId);
    await settle();
    expect(host.all()).toHaveLength(0);
  } finally {
    next.client.close?.();
  }
});

test("a prompt given back to the composer is not kept as a row too", async () => {
  const host = hostStore();
  // A remote chat's connection: no journal resends it, so it goes back to the composer at once.
  const lost = await pane(host.store, () => Object.assign(new Error("closed"), { code: "native.timed_out" }));
  const error = await lost.client.send("back to the composer").then(
    () => undefined,
    (e: unknown) => e,
  );
  expect((error as { failedRow?: unknown }).failedRow).toBeUndefined();
  await settle();
  expect(host.all()).toHaveLength(0);
  lost.client.close?.();
});
