// l10n-allow-file: synthetic relay fixtures, not shipped UI.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = new Map(["window", "document"].map((key) => [key, { had: key in scope, value: scope[key] }]));
beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(() => {
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

// "i shuold be able to cancel a fork probably" (Leo, 2026-11-06): Cancel hides the line at once,
// the fork's answer opens nothing, and the fork acpmux made is taken back whole.
test("Cancel on a pending fork opens nothing and takes the fork back", async () => {
  const { client, shown, answers, sent } = await forkingClient();
  try {
    const forked = client.fork("live", undefined, true);
    await Promise.resolve();
    client.cancelFork();
    expect(shown.forkPending).toBeUndefined();
    answers[0]!.resolve({ sessionId: "fork-1" });
    expect(await forked).toBeUndefined();
    const kill = sent.find((call) => call.method === "_acpmux/kill");
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
