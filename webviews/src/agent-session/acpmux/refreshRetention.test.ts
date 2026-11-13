import { afterAll, afterEach, beforeAll, expect, jest, test } from "bun:test";
import { JSDOM } from "jsdom";
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
afterEach(() => jest.useRealTimers());
afterAll(async () => {
  await settleReact();
  if (saved.window) scope.window = saved.values.window;
  else delete scope.window;
  if (saved.document) scope.document = saved.values.document;
  else delete scope.document;
  dom.window.close();
});

const settle = async (done: () => boolean) => {
  for (let tries = 0; tries < 500 && !done(); tries += 1) await Promise.resolve();
  expect(done()).toBe(true);
};

test("same-chat refresh keeps the visible reply when the refresh hold expires before attach", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  let target = "";
  let targetAttachCount = 0;
  let release: (() => void) | undefined;
  const gate = new Promise<void>((resolve) => (release = resolve));
  class GatedAttach extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const hooks = this as unknown as {
        answer: (method: string, params: Record<string, unknown>) => Promise<unknown>;
      };
      const answer = hooks.answer.bind(this);
      hooks.answer = async (method, params) => {
        const result = await answer(method, params);
        if (method === "_acpmux/attach" && params.sessionId === target && ++targetAttachCount > 1) {
          await gate;
          return result;
        }
        return result;
      };
    }
  }

  const snapshots: { rows: { kind: string; text?: string }[]; canLoadOlder?: boolean }[] = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => snapshots.push(snapshot as unknown as (typeof snapshots)[number]),
    undefined,
    () => new GatedAttach() as unknown as WebSocket,
  );
  const sessionId = MockAcpmuxSocket.live!.seedLoadSession(150);
  target = sessionId;
  let reopening: Promise<unknown> | undefined;
  try {
    await client.select(sessionId);
    for (let page = 0; page < 200 && snapshots.at(-1)?.canLoadOlder; page += 1) await client.loadOlder();
    const before = snapshots.at(-1)!;
    const reply = before.rows.find((row) => row.kind === "assistant" && row.text?.startsWith("Turn 0:"));
    expect(reply).toBeDefined();
    const beforeCount = before.rows.length;
    const stillVisible = (snapshot: (typeof snapshots)[number]) =>
      snapshot.rows.length >= beforeCount &&
      snapshot.rows.some((row) => row.kind === "assistant" && row.text === reply!.text);

    jest.useFakeTimers();
    const beforeRefresh = snapshots.length;
    reopening = client.select(sessionId);
    await settle(() => targetAttachCount > 1);
    const beforeExpiry = snapshots.length;
    jest.advanceTimersByTime(1_501);
    jest.runOnlyPendingTimers();
    for (let turn = 0; turn < 10; turn += 1) await Promise.resolve();

    expect(snapshots.length).toBeGreaterThan(beforeExpiry);
    const duringFrames = snapshots.slice(beforeExpiry);
    expect(duringFrames.length).toBeGreaterThan(0);
    for (const frame of duringFrames) expect(stillVisible(frame)).toBe(true);

    release!();
    await reopening;
    for (const frame of snapshots.slice(beforeRefresh)) expect(stillVisible(frame)).toBe(true);
  } finally {
    release?.();
    await reopening?.catch(() => undefined);
    client.close();
  }
});
