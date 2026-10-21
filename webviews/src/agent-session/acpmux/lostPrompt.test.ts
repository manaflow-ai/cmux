// A prompt whose connection went before acpmux took it is not "Not sent: read its saved state
// before retrying" (Leo, 2026-10-20: the coordinator chat lost a prompt to a reset socket and asked
// for a Refresh). The host sends it again on the next connection; the sender waits for it there.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { clientWaiter, isLostConnection, lostPrompt, lostPromptSlot, waitForResend } from "./lostPrompt";

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

const settle = async (done: () => boolean) => {
  for (let tries = 0; tries < 50 && !done(); tries += 1) await new Promise((resolve) => setTimeout(resolve, 5));
};

type Hooks = { answer: (method: string, params: any) => Promise<unknown> };
type Row = { kind: string; text?: string };

test("a lost prompt names its chat and prompt id; other errors name none", () => {
  const error = Object.assign(new Error("gone"), {
    interrupted: true,
    lostPrompt: { sessionId: "s-1", promptId: "p-1" },
  });
  expect(isLostConnection(error)).toBe(true);
  expect(lostPrompt(error)).toEqual({ sessionId: "s-1", promptId: "p-1" });
  expect(isLostConnection(new Error("refused"))).toBe(false);
  expect(lostPrompt(new Error("refused"))).toBeUndefined();
  expect(lostPrompt(undefined)).toBeUndefined();
});

test("the next connected client is the one after the client that lost the prompt", async () => {
  const clients = clientWaiter<string>();
  clients.connected("first");
  const next = clients.next("first", 1_000);
  clients.connected("second");
  expect(await next).toBe("second");
  // Connected already, before the sender asked.
  expect(await clients.next("first", 1_000)).toBe("second");
  // None comes.
  expect(await clients.next("second", 10)).toBeUndefined();
});

test("only the prompt Not sent named goes again under its id; another prompt gets its own", () => {
  const slot = lostPromptSlot();
  slot.keep("s-1", "p-lost", "fix it", ["img-1"]);
  // Another prompt: acpmux would answer the lost id as a duplicate and never run it.
  expect(slot.take("s-1", "something else", ["img-1"])).toBeUndefined();
  // Only the next send: a later identical prompt is a new one.
  expect(slot.take("s-1", "fix it", ["img-1"])).toBeUndefined();
  // The same prompt sent again: acpmux runs the id at most once, with the host's resend.
  slot.keep("s-1", "p-lost", "fix it", ["img-1"]);
  expect(slot.take("s-1", "fix it", [])).toBeUndefined();
  slot.keep("s-1", "p-lost", "fix it", ["img-1"]);
  expect(slot.take("s-1", "fix it", ["img-1"])).toBe("p-lost");
  expect(slot.take("s-1", "fix it", ["img-1"])).toBeUndefined();
});

test("a lost prompt goes again under its id only in its own chat, and each of two lost prompts can", () => {
  const slot = lostPromptSlot();
  slot.keep("s-1", "p-a", "fix it", []);
  // In another chat it is a new prompt: acpmux keeps prompt ids per chat.
  expect(slot.take("s-2", "fix it", [])).toBeUndefined();
  slot.keep("s-1", "p-a", "fix it", []);
  slot.keep("s-1", "p-b", "and test it", []);
  expect(slot.take("s-1", "and test it", [])).toBe("p-b");
  // A prompt the host sent again after all is not kept.
  slot.keep("s-1", "p-c", "ship it", []);
  slot.forget("p-c");
  expect(slot.take("s-1", "ship it", [])).toBeUndefined();
});

type Waiting = { name: string; isClosed: boolean; awaitResent: (s: string, p: string, ms: number) => Promise<boolean> };

test("a connection that drops while the prompt waits for its resend waits on the next one", async () => {
  const clients = clientWaiter<Waiting>();
  const lost: Waiting = { name: "lost", isClosed: true, awaitResent: async () => false };
  // The next connection drops before the host's resend shows on it.
  const dropped: Waiting = {
    name: "dropped",
    isClosed: false,
    awaitResent: async () => {
      dropped.isClosed = true;
      return false;
    },
  };
  const third: Waiting = { name: "third", isClosed: false, awaitResent: async () => true };
  const waited = waitForResend(clients, lost, { sessionId: "s-1", promptId: "p-1" }, 1_000, 1_000);
  clients.connected(dropped);
  await new Promise((resolve) => setTimeout(resolve, 5));
  clients.connected(third);
  expect((await waited)?.name).toBe("third");
  // A connection that stays and never shows it: not sent.
  const quiet: Waiting = { name: "quiet", isClosed: false, awaitResent: async () => false };
  clients.connected(quiet);
  expect(await waitForResend(clients, third, { sessionId: "s-1", promptId: "p-2" }, 50, 10)).toBeUndefined();
});

test("a prompt lost with its connection says so to its sender, with no Not sent line", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  // acpmux never answers the prompt: the connection goes first.
  class SilentHost extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const hooks = this as unknown as Hooks;
      const answer = hooks.answer.bind(this);
      hooks.answer = (method, params) =>
        method === "session/prompt" ? new Promise<unknown>(() => undefined) : answer(method, params);
    }
  }
  let socket: SilentHost | undefined;
  let rows: Row[] = [];
  let lost = false;
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (next) => (rows = [...((next as { rows?: Row[] }).rows ?? [])]),
    () => (lost = true),
    () => (socket = new SilentHost()) as unknown as WebSocket,
  );
  let accepted = false;
  const sent = client.send("keep this", [], "p-lost", () => (accepted = true)).catch((error: unknown) => error);
  await settle(() => rows.some((row) => row.kind === "user" && row.text === "keep this"));
  const sessionId = client.selectedSession;
  (socket as unknown as { onclose: (event: { code: number }) => void }).onclose({ code: 1006 });
  const error = await sent;
  expect(lost).toBe(true);
  expect(accepted).toBe(false);
  expect(lostPrompt(error)).toEqual({ sessionId: sessionId!, promptId: "p-lost" });
  expect(rows.some((row) => row.kind === "notice")).toBe(false);
});

test("the next connection's chat shows the prompt the host sent again", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    () => undefined,
    undefined,
    () => new MockAcpmuxSocket(() => Promise.resolve()) as unknown as WebSocket,
  );
  try {
    // The host's resend lands as this chat's prompt record (here: sent on this connection).
    await client.send("again", [], "p-resent");
    const sessionId = client.selectedSession!;
    expect(await client.awaitResent(sessionId, "p-resent", 1_000)).toBe(true);
    // A prompt the host never sent again does not show: the sender says "Not sent" then.
    expect(await client.awaitResent(sessionId, "p-never", 20)).toBe(false);
    // Another chat is not where the prompt went.
    expect(await client.awaitResent("another-chat", "p-resent", 20)).toBe(false);
  } finally {
    client.close();
  }
});

test("a connection waiting for a resend says no as soon as it closes", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    () => undefined,
    undefined,
    () => new MockAcpmuxSocket(() => Promise.resolve()) as unknown as WebSocket,
  );
  await client.send("hello", [], "p-hello");
  const waiting = client.awaitResent(client.selectedSession!, "p-never", 10_000);
  client.close();
  expect(client.isClosed).toBe(true);
  const late = new Promise<string>((resolve) => setTimeout(() => resolve("still waiting"), 200));
  expect(await Promise.race([waiting, late])).toBe(false);
});
