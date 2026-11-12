// l10n-allow-file: synthetic relay fixtures, not shipped UI.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { settleReact } from "../../../../test/support/domTeardown";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = new Map(["window", "document"].map((key) => [key, { had: key in scope, value: scope[key] }]));
beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(async () => {
  await settleReact();
  for (const [key, previous] of saved) {
    if (previous.had) scope[key] = previous.value;
    else delete scope[key];
  }
  dom.window.close();
});

type Row = { id: string; kind: string; text?: string };
type Shown = { rows: Row[]; forkPending?: { since: number } };

/// A client whose fork waits for `answer`, and every request it sent besides.
async function forkingClient() {
  const { AcpmuxDirectClient } = await import("../direct");
  const { MockAcpmuxSocket, mockHost } = await import("../mock");
  const { FORK_OP } = await import("../operations");
  const shown: Shown = { rows: [] };
  const relay = new MockAcpmuxSocket(() => Promise.resolve());
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      if ((snapshot as { type?: string }).type !== "snapshot") return;
      const next = snapshot as unknown as Shown;
      shown.rows = next.rows;
      shown.forkPending = next.forkPending;
    },
    undefined,
    () => relay as unknown as WebSocket,
  );
  const answers: { resolve(value: unknown): void; reject(error: Error): void }[] = [];
  const sent: { method: string; params: any }[] = [];
  const internals = client as unknown as {
    canFork: boolean;
    selectedSessionId?: string;
    request(method: string, params: unknown): Promise<unknown>;
  };
  internals.canFork = true;
  internals.selectedSessionId = "chat-1";
  internals.request = (method, params) => {
    sent.push({ method, params });
    return method === FORK_OP
      ? new Promise((resolve, reject) => answers.push({ resolve, reject }))
      : Promise.resolve(undefined);
  };
  return { client, shown, answers, sent };
}

// Fork Conversation (to a new workspace, a split, a tab): the pane shows its pending line from the
// click until acpmux answers, so a slow fork never looks like nothing happened (NIGHTLY
// 2026-10-29), and the line is gone once the fork opens. The transcript gets no row for it (Leo,
// 2026-11-06: "forking text is weird").
test("a Fork Conversation shows the pending line, not a transcript row, until the fork answers", async () => {
  const { client, shown, answers } = await forkingClient();
  try {
    const forked = client.fork("live", undefined, true);
    await Promise.resolve();
    expect(shown.forkPending?.since).toBeNumber();
    expect(shown.rows.some((row) => row.kind === "notice")).toBe(false);
    answers[0]!.resolve({ sessionId: "fork-1" });
    expect(await forked).toBe("fork-1");
    expect(shown.forkPending).toBeUndefined();
  } finally {
    client.close();
  }
});

// The line and its Cancel belong to the chat being forked: another chat opened meanwhile shows
// neither, and going back shows them again (review of #36979).
test("a pending fork's line shows only in the chat it forks", async () => {
  const { client, shown, answers } = await forkingClient();
  const internals = client as unknown as { selectedSessionId?: string; emit(): void };
  try {
    const forked = client.fork("live", undefined, true);
    await Promise.resolve();
    expect(shown.forkPending).toBeDefined();
    internals.selectedSessionId = "chat-2";
    internals.emit();
    expect(shown.forkPending).toBeUndefined();
    internals.selectedSessionId = "chat-1";
    internals.emit();
    expect(shown.forkPending).toBeDefined();
    answers[0]!.resolve({ sessionId: "fork-1" });
    await forked;
  } finally {
    client.close();
  }
});

// "i shuold be able to cancel a fork probably" (Leo, 2026-11-06): Cancel hides the line at once,
// the fork's answer opens nothing, and the fork acpmux made is taken back whole.
test("Cancel on a pending fork opens nothing and takes the fork back", async () => {
  const { client, shown, answers, sent } = await forkingClient();
  try {
    const forked = client.fork("live", undefined, true);
    await Promise.resolve();
    const token = sent[0]!.params.cancelToken;
    expect(token).toBeString();
    client.cancelFork();
    expect(shown.forkPending).toBeUndefined();
    // Sent at once, while acpmux still makes the fork: it stops there (review of #36979).
    const stop = sent.filter((call) => call.method === "_acpmux/kill");
    expect(stop.map((call) => call.params)).toEqual([{ sessionId: "chat-1", cancelFork: true, cancelToken: token }]);
    answers[0]!.resolve({ sessionId: "fork-1" });
    expect(await forked).toBeUndefined();
    // A fork it answered with all the same is taken back.
    const kill = sent.filter((call) => call.method === "_acpmux/kill").at(-1);
    expect(kill?.params).toEqual({ sessionId: "fork-1", purge: true, cancelFork: true });
    // The next fork is a fork again.
    const again = client.fork("live", undefined, true);
    await Promise.resolve();
    expect(shown.forkPending).toBeDefined();
    answers[1]!.resolve({ sessionId: "fork-2" });
    expect(await again).toBe("fork-2");
  } finally {
    client.close();
  }
});

// A fork that fails after its Cancel says nothing: the person already took it back.
test("a cancelled fork that fails adds no failure notice", async () => {
  const { client, shown, answers } = await forkingClient();
  try {
    const forked = client.fork("live", undefined, true);
    await Promise.resolve();
    client.cancelFork();
    answers[0]!.reject(new Error("boom"));
    expect(await forked).toBeUndefined();
    expect(shown.rows.some((row) => row.kind === "notice")).toBe(false);
  } finally {
    client.close();
  }
});

// "where did the forked chat even go??? what does it even have???" (Leo, 2026-11-06): the fork's
// transcript says where the chat's history ends and its own begins, and which chat that was.
test("a fork's transcript names the chat its history above came from", async () => {
  const { client, shown } = await forkingClient();
  const internals = client as unknown as {
    sessions: Record<string, unknown>[];
    reduce(event: Record<string, unknown>): void;
    snapshot(): void;
  };
  try {
    internals.sessions = [{ sessionId: "chat-0", name: "release-fix", title: "Release asset step" }];
    const forked = (parentId: string, seq: number) => ({
      seq,
      at: seq,
      dir: "mux",
      kind: "forked",
      msg: { parentId, forkSeq: seq - 1 },
    });
    internals.reduce(forked("chat-0", 40));
    internals.reduce(forked("gone", 41));
    internals.snapshot();
    const lines = shown.rows.filter((row) => row.id.startsWith("forked-from-")).map((row) => row.text);
    expect(lines).toEqual([
      "Forked from release-fix. Everything above is from that chat.",
      "Forked from another chat. Everything above is from that chat.",
    ]);
  } finally {
    client.close();
  }
});

// A fork acpmux refuses is feedback on the click: a toast in the pane (toastSink), never a
// transcript row (review of #37629, F1).
test("a failed fork says so in a toast, not a transcript row", async () => {
  const { client, shown, answers } = await forkingClient();
  const toasts: string[] = [];
  client.toastSink = (text) => toasts.push(text);
  try {
    const forked = client.fork("live", undefined, true);
    await Promise.resolve();
    answers[0]!.reject(new Error("the chat has no finished turn"));
    expect(await forked).toBeUndefined();
    expect(shown.rows.some((row) => row.kind === "notice")).toBe(false);
    expect(toasts).toHaveLength(1);
    expect(toasts[0]).toContain("the chat has no finished turn");
  } finally {
    client.close();
  }
});

// A model switch in a started chat (Leo 2026-11-11: "if i switch to a different model in a chat, it
// should just be able to seamlesly within the same pane do stuff and stop asking so much
// bullshit"): the client forks the whole chat onto the picked harness and model, and opens the fork
// in this pane; a refusal rejects, so the composer keeps the message.
test("forkTo forks the chat live onto the picked harness and model and opens it here", async () => {
  const { client, answers, sent } = await forkingClient();
  const opened: string[] = [];
  (client as unknown as { select(id: string): Promise<string> }).select = async (id) => {
    opened.push(id);
    (client as unknown as { selectedSessionId: string }).selectedSessionId = id;
    return id;
  };
  try {
    const forked = client.forkTo({ harness: "codex", model: "gpt-6" });
    await Promise.resolve();
    expect(sent[0]).toEqual({
      method: "acp.session.fork",
      params: { sessionId: "chat-1", live: true, harness: "codex", model: "gpt-6" },
    });
    answers[0]!.resolve({ sessionId: "fork-1" });
    expect(await forked).toBe("fork-1");
    expect(opened).toEqual(["fork-1"]);
    const refused = client.forkTo({ harness: "claude" });
    await Promise.resolve();
    answers[1]!.reject(new Error("no ACP harness runs claude here"));
    await expect(refused).rejects.toThrow("no ACP harness runs claude here");
  } finally {
    client.close();
  }
});
