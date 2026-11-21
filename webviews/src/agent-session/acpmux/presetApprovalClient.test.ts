// l10n-allow-file: test fixtures.
// A no-prompt preset's approval card through the client (direct.ts): a `preset_approval_request`
// record draws one card, its `preset_approval_decision` closes it, and Approve or Not now go to the
// daemon as `_acpmux/presets {name, approveMode, approveDigest, sessionId}` (the mock's, mock.ts).
// A refused answer keeps the card open with the daemon's message.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { PresetApproval } from "./conversation/presetApproval";
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
  delete scope.cmuxAcpmuxMockPresetError;
});

type Daemon = { record: (target: string, step: unknown, at?: number) => unknown };
type Row = { id: string; kind: string; text?: string; presetApproval?: PresetApproval };

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
  let last: { canLoadOlder?: boolean } | undefined;
  const wakes: Array<() => void> = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      rows = snapshot.rows as Row[];
      last = snapshot as { canLoadOlder?: boolean };
      for (const wake of wakes.splice(0)) wake();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  const cards = () => rows.filter((row) => row.kind === "presetApproval");
  const until = async (ready: () => boolean) => {
    while (!ready()) await new Promise<void>((resolve) => wakes.push(resolve));
  };
  return { client, cards, until, snapshot: () => last, rows: () => rows };
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

test("a card older than the open's page comes with the older page that holds it", async () => {
  const turns = Array.from({ length: 300 }, (_, turn) => [
    { mux: "user_message", msg: { text: `Turn ${turn}` } },
    { mux: "turn_started", msg: {} },
    { mux: "turn_result", msg: { status: "completed" } },
  ]).flat();
  const { client, cards, until, snapshot } = await open(turns);
  try {
    await until(() => snapshot()?.canLoadOlder === true);
    expect(cards()).toHaveLength(0);
    for (let pages = 0; snapshot()?.canLoadOlder && pages < 20; pages += 1) await client.loadOlder();
    expect(cards()).toHaveLength(1);
    expect(cards()[0].presetApproval?.ask.digest).toBe("d1");
  } finally {
    client.close();
  }
});

const TURNS = Array.from({ length: 300 }, (_, turn) => [
  { mux: "user_message", msg: { text: `Turn ${turn}` } },
  { mux: "turn_started", msg: {} },
  { mux: "turn_result", msg: { status: "completed" } },
]).flat();

test("a card an older request merges away stays gone, so one Approve closes the only card", async () => {
  // The first request is far older than the open's page; the agent's retry is in it.
  const { client, cards, until, snapshot } = await open([...TURNS, { mux: "preset_approval_request", msg: ASK }]);
  try {
    await until(() => cards().length === 1 && snapshot()?.canLoadOlder === true);
    const retry = cards()[0].id;
    for (let pages = 0; snapshot()?.canLoadOlder && pages < 20; pages += 1) await client.loadOlder();
    // The retry joined the first request's card, which the page drew; the retry's row did not come back.
    expect(cards()).toHaveLength(1);
    expect(cards()[0].id).not.toBe(retry);
    await client.answerPresetApproval(cards()[0].id, true);
    await until(() => cards()[0]?.presetApproval?.outcome === "approved");
    expect(cards()).toHaveLength(1);
  } finally {
    client.close();
  }
});

test("a card a late decision splits off sorts at its own request", async () => {
  // A request and its decline in one older turn (so one page folds both); the retry after the
  // decline is in the open's page, below the prompt before it. The page's request joins the retry's
  // card first, then its decline splits them again.
  const { client, cards, until, snapshot, rows } = await open([
    { mux: "user_message", msg: { text: "Try again" } },
    { mux: "turn_started", msg: {} },
    { mux: "preset_approval_request", msg: ASK },
    { mux: "preset_approval_decision", msg: { preset: "lane", digest: "d1", outcome: "declined" } },
    { mux: "turn_result", msg: { status: "completed" } },
    ...TURNS,
    { mux: "user_message", msg: { text: "Before the retry" } },
    { mux: "turn_started", msg: {} },
    { mux: "preset_approval_request", msg: ASK },
    { mux: "turn_result", msg: { status: "completed" } },
  ]);
  try {
    await until(() => cards().length === 1 && snapshot()?.canLoadOlder === true);
    for (let pages = 0; snapshot()?.canLoadOlder && pages < 20; pages += 1) await client.loadOlder();
    expect(cards().map((row) => row.presetApproval?.outcome)).toEqual(["declined", undefined]);
    const order = rows().map((row) => row.id);
    const prompt = rows().find((row) => row.kind === "user" && row.text === "Before the retry")!;
    expect(order.indexOf(cards()[1].id)).toBeGreaterThan(order.indexOf(prompt.id));
    expect(order.indexOf(cards()[0].id)).toBeLessThan(order.indexOf(prompt.id));
  } finally {
    client.close();
  }
});
