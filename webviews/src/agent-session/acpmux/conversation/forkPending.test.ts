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

// Fork Conversation (to a new workspace, a split, a tab): the chat shows "Forking…" from the
// click until acpmux answers, so a slow fork never looks like nothing happened (NIGHTLY
// 2026-10-29), and the row is gone once the fork opens.
test("a Fork Conversation shows Forking… while acpmux forks, and removes it when the fork answers", async () => {
  const { AcpmuxDirectClient } = await import("../direct");
  const { MockAcpmuxSocket, mockHost } = await import("../mock");
  const { FORK_OP } = await import("../operations");
  let rows: Row[] = [];
  const relay = new MockAcpmuxSocket(() => Promise.resolve());
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      if ((snapshot as { type?: string }).type === "snapshot") rows = (snapshot as { rows: Row[] }).rows;
    },
    undefined,
    () => relay as unknown as WebSocket,
  );
  let answer: ((value: unknown) => void) | undefined;
  const internals = client as unknown as {
    canFork: boolean;
    selectedSessionId?: string;
    request(method: string, params: unknown): Promise<unknown>;
  };
  internals.canFork = true;
  internals.selectedSessionId = "chat-1";
  internals.request = (method) =>
    method === FORK_OP ? new Promise((resolve) => (answer = resolve)) : Promise.resolve(undefined);
  try {
    const forked = client.fork("live", undefined, true);
    await Promise.resolve();
    const pending = rows.filter((row) => row.kind === "notice" && row.text === "Forking…");
    expect(pending).toHaveLength(1);
    answer?.({ sessionId: "fork-1" });
    expect(await forked).toBe("fork-1");
    expect(rows.some((row) => row.text === "Forking…")).toBe(false);
  } finally {
    client.close();
  }
});
