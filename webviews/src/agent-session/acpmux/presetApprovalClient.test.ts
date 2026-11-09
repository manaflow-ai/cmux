// l10n-allow-file: test fixtures.
// A no-prompt preset's approval card through the client (direct.ts): a `preset_approval_request`
// record draws one card, its `preset_approval_decision` closes it, and Approve or Not now go to the
// daemon as `_acpmux/presets {name, approveMode, approveDigest, sessionId}` (the mock's, mock.ts).
// A refused answer keeps the card open with the daemon's message.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { PresetApproval } from "./conversation/presetApproval";

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
afterAll(() => {
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});
afterEach(() => {
  delete scope.cmuxAcpmuxMockPresetError;
});

type Daemon = { record: (target: string, step: unknown, at?: number) => unknown };
type Row = { id: string; kind: string; presetApproval?: PresetApproval };

const ASK = { preset: "lane", digest: "d1", harness: "claude", model: "opus", policy: "approve-all", host: "linux-3" };

async function open(extra: unknown[] = []) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as Daemon;
  const steps = [
    { mux: "user_message", msg: { text: "Hand the compile check to linux-3." } },
    { mux: "turn_started", msg: {} },
    { mux: "preset_approval_request", msg: ASK },
    { mux: "turn_result", msg: { status: "completed" } },
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
  const cards = () => rows.filter((row) => row.kind === "presetApproval");
  const until = async (ready: () => boolean) => {
    while (!ready()) await new Promise<void>((resolve) => wakes.push(resolve));
  };
  return { client, cards, until };
}

test("a request draws one card; a retry joins it and a decision closes it", async () => {
  const { client, cards, until } = await open([
    { mux: "preset_approval_request", msg: ASK },
    { mux: "preset_approval_request", msg: { ...ASK, digest: "d2" } },
    { mux: "preset_approval_decision", msg: { preset: "lane", digest: "d1", outcome: "declined" } },
  ]);
  try {
    await until(() => cards().length === 2);
    expect(cards().map((row) => row.presetApproval?.outcome)).toEqual(["declined", undefined]);
    expect(cards()[1].presetApproval?.ask.digest).toBe("d2");
  } finally {
    client.close();
  }
});

test("Approve sends the card's preset and digest for this chat and closes it", async () => {
  const { client, cards, until } = await open();
  try {
    await until(() => cards().length === 1);
    await client.answerPresetApproval(cards()[0].id, true);
    await until(() => cards()[0].presetApproval?.outcome === "approved");
    expect(cards()).toHaveLength(1);
  } finally {
    client.close();
  }
});

test("a refused answer keeps the card open with the daemon's message", async () => {
  scope.cmuxAcpmuxMockPresetError = "approving a preset's mode needs the person";
  const { client, cards, until } = await open();
  try {
    await until(() => cards().length === 1);
    await client.answerPresetApproval(cards()[0].id, false);
    await until(() => cards()[0].presetApproval?.error !== undefined);
    const card = cards()[0].presetApproval!;
    expect(card.error).toBe("approving a preset's mode needs the person");
    expect(card.outcome).toBeUndefined();
    expect(card.busy).toBeUndefined();
  } finally {
    client.close();
  }
});
