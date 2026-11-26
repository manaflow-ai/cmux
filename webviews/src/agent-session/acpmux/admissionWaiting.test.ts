// An Auto start that acpmux holds for a machine being added shows "Auto is adding a machine" while
// it waits, not only once `session/new` answers up to its bound later. acpmux tells the creating
// connection when the wait begins (`_acpmux/admission_waiting`, hub/admission.rs); the pane's client
// publishes it as the snapshot's `startupAdmission` (App.tsx draws the line from it) and drops it
// when the start answers or fails. A start that is not Auto's never shows it.
import { afterAll, beforeAll, expect, test } from "bun:test";
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
afterAll(async () => {
  await settleReact();
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});

const settle = async (done: () => boolean) => {
  for (let tries = 0; tries < 500 && !done(); tries += 1) await new Promise((resolve) => setTimeout(resolve, 0));
};

type Hooks = {
  answer: (method: string, params: any) => Promise<unknown>;
  deliver: (message: unknown) => void;
};
type Snapshot = { startupAdmission?: { sessionId?: string; scalingUp: true } };

/// A daemon whose `session/new` first says it waits for a machine being added, then answers only
/// once `release` runs, with `fail` making that answer a refusal.
async function waitingStart(auto: boolean, fail = false) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const asked: { method: string; params: any }[] = [];
  let release = () => {};
  const held = new Promise<void>((resolve) => (release = resolve));
  class Scaling extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const hooks = this as unknown as Hooks;
      const answer = hooks.answer.bind(this);
      hooks.answer = async (method, params) => {
        asked.push({ method, params });
        if (method !== "session/new") return answer(method, params);
        hooks.deliver({
          jsonrpc: "2.0",
          method: "_acpmux/admission_waiting",
          params: { warning: "a machine is being added", live: 9, maxLanes: 8, scalingUp: true, waitSecs: 250 },
        });
        await held;
        if (fail) throw new Error("no room");
        return answer(method, params);
      };
    }
  }
  let snapshot: Snapshot = {};
  const client = (await AcpmuxDirectClient.connect(
    mockHost,
    (next) => (snapshot = next as Snapshot),
    undefined,
    () => new Scaling() as unknown as WebSocket,
  )) as any;
  await settle(() => asked.some((ask) => ask.method === "_acpmux/attach"));
  if (auto) client.holdAutoPlace(true);
  const starting: Promise<string | undefined> = client.startSession("claude");
  await settle(() => asked.some((ask) => ask.method === "session/new"));
  // The notification and any snapshot it makes arrive in later tasks.
  for (let tick = 0; tick < 20; tick += 1) await new Promise((resolve) => setTimeout(resolve, 0));
  return { client, starting, release, asked, now: () => snapshot };
}

test("an Auto start acpmux holds for a machine shows the adding line until session/new answers", async () => {
  const { client, starting, release, asked, now } = await waitingStart(true);
  try {
    const sent = asked.find((ask) => ask.method === "session/new");
    expect(sent?.params?._meta?.acpmux?.autoPlace).toBe(true);
    await settle(() => now().startupAdmission !== undefined);
    expect(now().startupAdmission).toEqual({ scalingUp: true });
    release();
    expect(await starting).toBeTruthy();
    // The mock's answer carries no admission of its own: the waiting line goes with the wait.
    await settle(() => now().startupAdmission === undefined);
    expect(now().startupAdmission).toBeUndefined();
  } finally {
    release();
    client.close?.();
  }
});

test("a failed Auto start drops the adding line", async () => {
  const { client, starting, release, now } = await waitingStart(true, true);
  try {
    await settle(() => now().startupAdmission !== undefined);
    expect(now().startupAdmission).toEqual({ scalingUp: true });
    release();
    await starting.catch(() => undefined);
    await settle(() => now().startupAdmission === undefined);
    expect(now().startupAdmission).toBeUndefined();
  } finally {
    release();
    client.close?.();
  }
});

test("a start that is not Auto's never shows the adding line", async () => {
  const { client, starting, release, now } = await waitingStart(false);
  try {
    expect(now().startupAdmission).toBeUndefined();
    release();
    await starting;
    expect(now().startupAdmission).toBeUndefined();
  } finally {
    release();
    client.close?.();
  }
});
