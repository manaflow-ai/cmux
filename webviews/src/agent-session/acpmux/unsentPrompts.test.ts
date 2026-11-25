// Leo, 2026-11-11: "when restarting ALL MY ... UNSENT ... GOT DELETED". A refused or unanswered
// prompt lived only in the page as its Not sent row; a relaunch dropped every one. The app host now
// keeps each prompt no agent took (unsentPrompts.ts, AgentPaneUnsentPrompts.swift), and a cold
// start draws every one again at once as a Not sent row with Retry, Edit and Remove.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { resetKeptTailsForTests } from "./tailCache";
import { unanswered, type UnsentPromptRecord, type UnsentPromptStore } from "./unsentPrompts";
import { deliveryTiming } from "./direct/queue";
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

type Row = {
  id: string;
  kind: string;
  text?: string;
  failed?: boolean;
  error?: string;
  pending?: boolean;
  delivery?: { state?: string };
};

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
async function pane(
  store: UnsentPromptStore,
  answer: (text: string) => Error | "hang" | undefined = () => undefined,
  asked: string[] = [],
) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  class Relay extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const self = this as unknown as { answer: (method: string, params: Record<string, any>) => Promise<unknown> };
      const through = self.answer.bind(this);
      self.answer = (method, params) => {
        if (method !== "session/prompt") return through(method, params);
        asked.push(String(params._meta?.acpmux?.promptId ?? ""));
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
  /// A frame from acpmux on this connection (its record of a prompt the host sent again).
  const deliver = (frame: unknown) => (socket as unknown as { deliver: (frame: unknown) => void }).deliver(frame);
  return { client, rows: () => rows, drop, deliver };
}

/// Waits for `ready` on the pane's own work, never a fixed time.
const until = async (ready: () => boolean) => {
  for (let turns = 0; !ready(); turns += 1) {
    if (turns > 20_000) throw new Error(`never settled: ${ready.toString()}`);
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
};
/// The wait for the host's resend to show, shortened for a test and put back after.
async function withResendShowMs<T>(ms: number, body: () => Promise<T>): Promise<T> {
  const before = deliveryTiming.resendShowMs;
  deliveryTiming.resendShowMs = ms; // motion-allow: a delivery wait, not motion
  try {
    return await body();
  } finally {
    deliveryTiming.resendShowMs = before; // motion-allow: a delivery wait, not motion
  }
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

test("a cold restart with refused and pending sends draws every one again, and each unanswered one is Not sent with Retry", async () => {
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

  // No record of the pending ones comes on the next connection (this host sent none again): each
  // says Not sent again once its wait for the host's resend ends, and a refused one says it at once.
  await withResendShowMs(30, async () => {
    const after = await pane(host.store);
    try {
      await settle();
      const atOnce = after.rows().filter((row) => row.kind === "user" && row.failed);
      expect(new Set(atOnce.map((row) => row.text))).toEqual(new Set(refused));
      await until(() => after.rows().filter((row) => row.kind === "user" && row.failed).length === 2 * N);
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
  await withResendShowMs(30, async () => {
    const next = await pane(host.store);
    try {
      await until(() => next.rows().find((candidate) => candidate.text === "lost one")?.failed === true);
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

// Leo, 2026-11-24: after an app update restarted acpmux, GUI chats said "Not sent: no answer from
// cmux" on prompts sent around the restart, and each wanted a Retry by hand. The host's journal
// sends such a prompt again on the pane's next connection under its promptId (acpmux runs a
// promptId at most once); the row stayed "Not sent" all the same until someone pressed Retry.
test("a prompt that got no answer goes again by itself on the next connection: its Not sent clears, with no Retry and no second send", async () => {
  const host = hostStore();
  const before = { ...deliveryTiming };
  Object.assign(deliveryTiming, { slowMs: 10, failMs: 30, localFailMs: 30 }); // motion-allow: delivery timeouts, not motion
  const sentBefore: string[] = [];
  const first = await pane(host.store, () => "hang", sentBefore);
  try {
    void first.client.send("after the update").catch(() => undefined);
    // acpmux says nothing (it is restarting): the row fails as the person saw it.
    await until(() => first.rows().find((row) => row.text === "after the update")?.failed === true);
    expect(first.rows().find((row) => row.text === "after the update")?.error).toBe(
      translate("prompt.delivery.noAnswer"),
    );
    await settle();
  } finally {
    Object.assign(deliveryTiming, before); // motion-allow: delivery timeouts, not motion
  }
  const promptId = sentBefore[0]!;
  expect(host.all().map((record) => record.promptId)).toEqual([promptId]);
  // The connection goes with the old acpmux.
  first.drop();
  first.client.close?.();

  // acpmux is back: the pane's next connection.
  const sentAfter: string[] = [];
  const next = await pane(host.store, () => undefined, sentAfter);
  try {
    const mine = () => next.rows().filter((row) => row.kind === "user" && row.text === "after the update");
    // On its way again by itself: one row, no "Not sent", nobody pressed Retry.
    await until(() => mine().length === 1 && mine()[0]!.failed !== true);
    expect(mine()[0]!.pending).toBe(true);
    expect(mine()[0]!.error).toBeUndefined();
    expect(mine()[0]!.delivery?.state).toBe("sending");
    const sessionId = next.client.selectedSession!;
    // The host's journal sent it again, and acpmux's record of it lands here.
    next.deliver({
      jsonrpc: "2.0",
      method: "_acpmux/event",
      params: {
        seq: Number((next.client as unknown as { lastSeq: number }).lastSeq) + 1,
        sessionId,
        at: Date.now(),
        dir: "mux",
        kind: "user_message",
        msg: { text: "after the update", promptId, turnId: "t-resent", client: "cmux-react-agent-pane#x" },
      },
    });
    await until(() => mine().length === 1 && !mine()[0]!.pending && !mine()[0]!.failed);
    expect(mine()[0]!.delivery?.state ?? "settled").not.toBe("sending");
    expect(next.client.failedPromptCopies(mine().map((row) => row.id))).toHaveLength(0);
    // The page sent nothing itself: the one resend is the host's, under the same promptId.
    expect(sentAfter).toEqual([]);
    await settle();
    expect(host.all()).toHaveLength(0);
  } finally {
    next.client.close?.();
  }
});

test("a prompt refused for a real reason keeps its Not sent and its Retry on the next connection", async () => {
  const host = hostStore();
  const gesture = () =>
    Object.assign(new Error("transport.gesture_required: a click is needed"), { code: "transport.gesture_required" });
  const first = await pane(host.store, () => gesture());
  await first.client.send("needs a click").catch(() => undefined);
  await settle();
  const words = first.rows().find((row) => row.text === "needs a click")?.error;
  expect(words).toBeDefined();
  first.client.close?.();
  const next = await pane(host.store);
  try {
    await settle();
    const row = next.rows().find((candidate) => candidate.text === "needs a click");
    expect(row?.failed).toBe(true);
    expect(row?.pending).toBeFalsy();
    expect(row?.error).toBe(words);
    expect(next.client.failedPromptCopies([row!.id])).toHaveLength(1);
  } finally {
    next.client.close?.();
  }
});

test("only a prompt nobody refused counts as unanswered", () => {
  const record = (failure?: UnsentPromptRecord["failure"]): UnsentPromptRecord => ({
    promptId: "p",
    input: "x",
    attachments: [],
    at: 1,
    ...(failure ? { failure } : {}),
  });
  // On its way when the app went; the page's deadline; a connection that went.
  expect(unanswered(record())).toBe(true);
  expect(unanswered(record({ hop: "acpmux", code: "timeout" }))).toBe(true);
  expect(unanswered(record({ hop: "connection", code: "native.timed_out", reason: "interrupted" }))).toBe(true);
  expect(unanswered(record({ hop: "connection", code: "native.not_connected" }))).toBe(true);
  // Refused: by the app, by acpmux, by the agent.
  expect(unanswered(record({ hop: "connection", code: "transport.gesture_required" }))).toBe(false);
  expect(unanswered(record({ hop: "acpmux", code: "-32000", reason: "trust.pending" }))).toBe(false);
  expect(unanswered(record({ hop: "acpmux", reason: "message.too_large" }))).toBe(false);
  expect(unanswered(record({ hop: "agent", code: "timeout" }))).toBe(false);
});
