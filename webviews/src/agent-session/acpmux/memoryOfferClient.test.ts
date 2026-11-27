// l10n-allow-file: test fixtures.
// The memory inbox through the client (direct.ts): a `memory_offer` record draws one row under its
// turn, `memory_resolved` records settle its facts, and Accept or Dismiss go to the daemon as
// `_acpmux/memory_resolve` (the mock's, mock.ts). A failed write leaves the facts actionable with
// the daemon's message; a daemon without the `memory-inbox-v1` feature draws no card.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { MemoryOffer } from "./conversation/memoryInbox";
import { settleReact } from "../../../test/support/domTeardown";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = {
  window: "window" in scope,
  document: "document" in scope,
  values: { window: scope.window, document: scope.document },
};

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(async () => {
  await settleReact();
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});
afterEach(() => {
  delete scope.cmuxAcpmuxMockMemoryError;
});

type Daemon = { record: (target: string, step: unknown, at?: number) => unknown };
type Row = { id: string; kind: string; memory?: MemoryOffer };

const FACTS = ["Use bun, never npm.", "Run webview tests from webviews/."];
const OFFER = { offerId: "o1", file: "CLAUDE.md", facts: FACTS, heading: "## Learned in chats", created: false };

async function open(extra: unknown[] = []) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as Daemon;
  const steps = [
    { mux: "user_message", msg: { text: "No, use bun." } },
    { mux: "turn_started", msg: {} },
    { mux: "turn_result", msg: { status: "completed" } },
    { mux: "memory_offer", msg: OFFER },
    ...extra,
  ];
  for (const step of steps) daemon.record(mockHost.sessionId!, step);
  let rows: Row[] = [];
  const wakes: Array<() => void> = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      rows = snapshot.rows as Row[];
      for (const wake of wakes.splice(0)) wake();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  const memory = () => rows.find((row) => row.kind === "memoryOffer")?.memory;
  const until = async (ready: () => boolean) => {
    while (!ready()) await new Promise<void>((resolve) => wakes.push(resolve));
  };
  return { client, memory, until, rows: () => rows };
}

test("an offer record draws one card; a resolution record settles the facts it names", async () => {
  const { client, memory, until, rows } = await open([
    { mux: "memory_resolved", msg: { offerId: "o1", file: "CLAUDE.md", accepted: [FACTS[0]], dismissed: [] } },
  ]);
  try {
    await until(() => memory()?.accepted.length === 1);
    expect(rows().filter((row) => row.kind === "memoryOffer")).toHaveLength(1);
    expect(memory()).toMatchObject({ offerId: "o1", file: "CLAUDE.md", accepted: [FACTS[0]], dismissed: [] });
  } finally {
    client.close?.();
  }
});

test("Accept and Dismiss go to the daemon, and its answer settles the card", async () => {
  const { client, memory, until } = await open();
  try {
    await until(() => memory() !== undefined);
    await client.resolveMemory("o1", [FACTS[0]], []);
    expect(memory()?.accepted).toEqual([FACTS[0]]);
    expect(memory()?.busy).toBeUndefined();
    await client.resolveMemory("o1", [], [FACTS[1]]);
    expect(memory()).toMatchObject({ accepted: [FACTS[0]], dismissed: [FACTS[1]] });
    // The daemon's own `memory_resolved` records land too, and settle nothing twice.
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(memory()).toMatchObject({ accepted: [FACTS[0]], dismissed: [FACTS[1]] });
  } finally {
    client.close?.();
  }
});

test("a failed write shows the daemon's message and leaves the facts actionable", async () => {
  const { client, memory, until } = await open();
  try {
    await until(() => memory() !== undefined);
    scope.cmuxAcpmuxMockMemoryError = "EACCES: permission denied, open 'CLAUDE.md'";
    await client.resolveMemory("o1", FACTS, []);
    expect(memory()?.error).toBe("EACCES: permission denied, open 'CLAUDE.md'");
    expect(memory()?.accepted).toEqual([]);
    expect(memory()?.busy).toBeUndefined();
    delete scope.cmuxAcpmuxMockMemoryError;
    await client.resolveMemory("o1", FACTS, []);
    expect(memory()).toMatchObject({ accepted: FACTS, error: undefined });
  } finally {
    client.close?.();
  }
});
