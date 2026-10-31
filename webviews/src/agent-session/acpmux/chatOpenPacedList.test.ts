// A chat opens on its attach, not on the session list (Leo, 2026-10-30: "WHY DID IT TAKE 30 FUCKING
// SECONDS TO LOAD YOUR CHAT"). A busy acpmux paces its full session list (hub/list_guard.rs: one
// build per window, up to 15 s, and every streaming agent makes the last build stale): on
// cosmic-gray a first page of the list took 0.3 to 18 s while the chat's attach answered in 0.6 s,
// and the pane said "Waiting for the agent service" until the list came. These tests hold every
// list reply and answer the rest at once.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

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

const turns = () => new Promise<void>((resolve) => setTimeout(resolve, 0));
const LISTS = new Set(["_acpmux/watch", "_acpmux/sessions"]);

type Snapshot = { rows?: unknown[]; sessions?: { sessionId: string }[]; listedSessions?: boolean };

/// Connects `host` to a mock daemon whose session list replies wait until `release()`.
async function openWithHeldList(host?: Record<string, unknown>) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  // The mock opened before the page asked: the page is told so once it listens.
  await turns();
  const daemon = socket as unknown as {
    send: (raw: string) => void;
    onopen: (() => void) | null;
  };
  const answer = daemon.send.bind(socket);
  const held: string[] = [];
  let holding = true;
  daemon.send = (raw) => {
    const request = JSON.parse(raw) as { id?: number; method: string };
    if (holding && request.id !== undefined && LISTS.has(request.method)) held.push(raw);
    else answer(raw);
  };
  let last: Snapshot = {};
  let painted = false;
  let connected = false;
  const connecting = AcpmuxDirectClient.connect(
    { ...mockHost, ...host },
    (snapshot) => {
      last = snapshot as Snapshot;
      if (Array.isArray(last.rows) && last.rows.length > 0) painted = true;
    },
    undefined,
    () => {
      queueMicrotask(() => daemon.onopen?.());
      return socket as unknown as WebSocket;
    },
  );
  void connecting.then(
    () => (connected = true),
    () => undefined,
  );
  return {
    connecting,
    state: () => ({ painted, connected, last, held: held.length }),
    release: () => {
      holding = false;
      for (const raw of held.splice(0)) answer(raw);
    },
  };
}

async function settle(until: () => boolean, rounds = 200) {
  for (let i = 0; i < rounds && !until(); i += 1) await turns();
}

test("a chat opens on its attach while acpmux paces the session list", async () => {
  const open = await openWithHeldList();
  await settle(() => open.state().connected);
  try {
    const now = open.state();
    // The list was asked and is still held, yet the chat is open and drawn.
    expect(now.held).toBeGreaterThan(0);
    expect(now.connected).toBe(true);
    expect(now.painted).toBe(true);
    // Until the list comes the pane does not claim to have listed the chats.
    expect(now.last.listedSessions).not.toBe(true);
    open.release();
    await settle(() => open.state().last.listedSessions === true);
    const after = open.state().last;
    // The list then settles behind the open: every chat, the open one still selected.
    expect(after.listedSessions).toBe(true);
    expect((after.sessions ?? []).length).toBeGreaterThan(1);
  } finally {
    open.release();
    (await open.connecting).close();
  }
});

test("a chat its attach cannot find still waits for the list to say it is missing", async () => {
  const open = await openWithHeldList({ sessionId: "no-such-chat", sessionMustExist: true });
  await settle(() => open.state().held > 0);
  for (let i = 0; i < 100; i += 1) await turns();
  try {
    // The attach failed: the open decides with the list, so it waits for it as before.
    expect(open.state().connected).toBe(false);
    open.release();
    await settle(() => open.state().connected);
    expect(open.state().connected).toBe(true);
    expect(open.state().painted).toBe(false);
  } finally {
    open.release();
    (await open.connecting).close();
  }
});

test("an attach reply names the open's row only for that chat on this machine", async () => {
  const { attachedLocalRow } = await import("./direct");
  expect(attachedLocalRow({ session: { sessionId: "a" } }, "a")).toEqual({ sessionId: "a" });
  expect(attachedLocalRow({ session: { sessionId: "a", peer: "big-red" } }, "a")).toBeUndefined();
  // A reply forwarded from a peer names it at the top level; its session detail has no `peer`.
  expect(attachedLocalRow({ peer: "big-red", session: { sessionId: "a" } }, "a")).toBeUndefined();
  expect(attachedLocalRow({ session: { sessionId: "b" } }, "a")).toBeUndefined();
  expect(attachedLocalRow({}, "a")).toBeUndefined();
  expect(attachedLocalRow(undefined, "a")).toBeUndefined();
});

test("with a list that takes 3 s, the chat opens on its attach (the bench's number)", async () => {
  const open = await openWithHeldList();
  const started = performance.now();
  const timer = setTimeout(() => open.release(), 3000);
  const client = await open.connecting;
  const ms = Math.round(performance.now() - started);
  clearTimeout(timer);
  open.release();
  // The same harness before the fix: about 3000 ms (the open waited for the list).
  console.log(`chat open with a 3000 ms session list: connected after ${ms} ms`);
  try {
    expect(ms).toBeLessThan(1000);
  } finally {
    client.close();
  }
});
