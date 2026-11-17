// l10n-allow-file: test fixtures.
// The prompt coach through the client (direct.ts): a `coach_offer` record draws nothing and, once its
// batch is folded, asks the daemon once for the rewrite (`_acpmux/prompt_coach`, the mock's, mock.ts);
// the `coach` record it logs draws one card. A history batch that already holds the `coach` record
// asks nothing. With the setting off, or for a chat whose card was dismissed on this device, nothing
// is asked and nothing draws.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { PromptCoach } from "./conversation/promptCoach";
import { settleReact } from "../../../test/support/domTeardown";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = {
  window: "window" in scope,
  document: "document" in scope,
  localStorage: "localStorage" in scope,
  values: { window: scope.window, document: scope.document, localStorage: scope.localStorage },
};

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
  scope.localStorage = dom.window.localStorage;
});
afterAll(async () => {
  await settleReact();
  for (const key of ["window", "document", "localStorage"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});
afterEach(async () => {
  dom.window.localStorage.clear();
  const { setChatDisplay } = await import("./chatDisplay");
  setChatDisplay({});
});

type Daemon = { record: (target: string, step: unknown, at?: number) => unknown };
type Row = { id: string; kind: string; coach?: PromptCoach };

const OFFER = { mux: "coach_offer", msg: { coachId: "k1", corrections: 3 } };
const COACH = {
  mux: "coach",
  msg: { coachId: "k1", firstPrompt: "Add a toggle.", rewrite: "Add a toggle in Settings.", corrections: 3 },
};

/// `answer: false` holds the daemon's answer to `_acpmux/prompt_coach`, as while its model call runs.
async function open(extra: unknown[], { answer = true } = {}) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as Daemon;
  const asked: unknown[] = [];
  const send = socket.send.bind(socket);
  socket.send = (raw: string) => {
    const request = JSON.parse(raw) as { method: string; params?: unknown };
    if (request.method === "_acpmux/prompt_coach") {
      asked.push(request.params);
      if (!answer) return;
    }
    send(raw);
  };
  const steps = [
    { mux: "user_message", msg: { text: "Add a toggle." } },
    { mux: "turn_started", msg: {} },
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
  const cards = () => rows.filter((row) => row.kind === "promptCoach");
  const until = async (ready: () => boolean) => {
    while (!ready()) await new Promise<void>((resolve) => wakes.push(resolve));
  };
  /// Runs the microtasks queued so far: the one that asks (queued while the batch was folded, before
  /// the snapshot that woke `until`) has run once this resolves.
  const settle = async () => {
    for (let step = 0; step < 4; step++) await Promise.resolve();
  };
  return { client, cards, until, settle, asked, sessionId: mockHost.sessionId!, rows: () => rows };
}

test("an offer alone draws nothing while the rewrite is being written", async () => {
  const { client, cards, until, settle, asked, sessionId, rows } = await open([OFFER], { answer: false });
  try {
    await until(() => rows().length > 0);
    await settle();
    expect(asked).toEqual([{ sessionId, coachId: "k1" }]);
    expect(cards()).toHaveLength(0);
  } finally {
    client.close?.();
  }
});

test("the page asks once, and the coach record it logs draws one card", async () => {
  const { client, cards, until, settle, asked, sessionId } = await open([OFFER]);
  try {
    await until(() => cards().length === 1);
    expect(asked).toEqual([{ sessionId, coachId: "k1" }]);
    expect(cards()[0]?.coach).toMatchObject({ coachId: "k1", sessionId, corrections: 3 });
    // A rebuild folds the offer again; the page has the coach record and never asks twice.
    await settle();
    expect(asked).toHaveLength(1);
  } finally {
    client.close?.();
  }
});

test("a history batch that holds the coach record after its offer asks nothing", async () => {
  const { client, cards, until, settle, asked } = await open([OFFER, COACH]);
  try {
    await until(() => cards().length === 1);
    await settle();
    expect(asked).toHaveLength(0);
    expect(cards()[0]?.coach?.rewrite).toBe("Add a toggle in Settings.");
  } finally {
    client.close?.();
  }
});

test("with the setting off, nothing is asked and no card draws", async () => {
  const { setChatDisplay, PROMPT_COACH_KEY } = await import("./chatDisplay");
  setChatDisplay({ [PROMPT_COACH_KEY]: false });
  const { client, cards, until, settle, asked, rows } = await open([
    OFFER,
    { ...COACH, msg: { ...COACH.msg, coachId: "k2" } },
  ]);
  try {
    await until(() => rows().length > 0);
    await settle();
    expect(asked).toHaveLength(0);
    expect(cards()).toHaveLength(0);
  } finally {
    client.close?.();
  }
});

test("a dismissed chat draws no card and asks nothing; × remembers the chat", async () => {
  const { mockHost } = await import("./mock");
  const { promptCoachDismissed, rememberPromptCoachDismissed } = await import("./conversation/promptCoachDismissed");
  rememberPromptCoachDismissed(mockHost.sessionId!);
  const first = await open([OFFER, { ...COACH, msg: { ...COACH.msg, coachId: "k0" } }]);
  try {
    await first.until(() => first.rows().length > 0);
    await first.settle();
    expect(first.asked).toHaveLength(0);
    expect(first.cards()).toHaveLength(0);
  } finally {
    first.client.close?.();
  }
  dom.window.localStorage.clear();
  const second = await open([OFFER, COACH]);
  try {
    await second.until(() => second.cards().length === 1);
    const card = second.cards()[0]!;
    second.client.dismissPromptCoach(card.id, card.coach!.sessionId);
    expect(second.cards()).toHaveLength(0);
    expect(promptCoachDismissed(card.coach!.sessionId)).toBe(true);
  } finally {
    second.client.close?.();
  }
});

test("a guest's fed page keeps no coach row, so no blank gap is reserved", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  let rows: Row[] = [];
  const client = AcpmuxDirectClient.fed("guest-chat", (snapshot) => {
    rows = snapshot.rows as Row[];
  });
  client.feed(
    [
      { seq: 1, at: 1, dir: "mux", kind: "user_message", msg: { text: "Add a toggle." } },
      { seq: 2, at: 2, dir: "mux", kind: "coach_offer", msg: OFFER.msg },
      { seq: 3, at: 3, dir: "mux", kind: "coach", msg: COACH.msg },
    ],
    "snapshot",
  );
  expect(rows.length).toBeGreaterThan(0);
  expect(rows.filter((row) => row.kind === "promptCoach")).toHaveLength(0);
});
