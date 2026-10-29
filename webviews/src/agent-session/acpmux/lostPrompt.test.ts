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
  // The same prompt sent again: acpmux runs the id at most once (the host marks it a resend).
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
  slot.keep("s-2", "p-d", "deploy it", []);
  expect(slot.take("s-1", "and test it", [])).toBe("p-b");
  // The chat's other lost prompt still goes again under its own id, and another chat's stays.
  expect(slot.take("s-1", "fix it", [])).toBe("p-a");
  expect(slot.take("s-2", "deploy it", [])).toBe("p-d");
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
  let asked!: () => void;
  const droppedAsked = new Promise<void>((resolve) => (asked = resolve));
  const dropped: Waiting = {
    name: "dropped",
    isClosed: false,
    awaitResent: async () => {
      dropped.isClosed = true;
      asked();
      return false;
    },
  };
  const third: Waiting = { name: "third", isClosed: false, awaitResent: async () => true };
  const waited = waitForResend(clients, lost, { sessionId: "s-1", promptId: "p-1" }, 1_000, 1_000);
  clients.connected(dropped);
  await droppedAsked;
  clients.connected(third);
  expect((await waited)?.name).toBe("third");
  // A connection that stays and never shows it: not sent.
  const quiet: Waiting = { name: "quiet", isClosed: false, awaitResent: async () => false };
  clients.connected(quiet);
  expect(await waitForResend(clients, third, { sessionId: "s-1", promptId: "p-2" }, 50, 10)).toBeUndefined();
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
  // Far past the test's own timeout: only the close can settle it.
  const waiting = client.awaitResent(client.selectedSession!, "p-never", 600_000);
  client.close();
  expect(client.isClosed).toBe(true);
  expect(await waiting).toBe(false);
});

test("a connection waiting for a resend says no once the pane shows another chat", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    () => undefined,
    undefined,
    () => new MockAcpmuxSocket(() => Promise.resolve()) as unknown as WebSocket,
  );
  try {
    await client.send("hello", [], "p-hello");
    // Far past the test's own timeout: only the selection change can settle it.
    const waiting = client.awaitResent(client.selectedSession!, "p-never", 600_000);
    client.leave();
    expect(await waiting).toBe(false);
  } finally {
    client.close();
  }
});

test("a lost prompt the host sent again after the wait gave up is done: the next identical prompt is new", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const slot = lostPromptSlot();
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    () => undefined,
    undefined,
    () => new MockAcpmuxSocket(() => Promise.resolve()) as unknown as WebSocket,
  );
  try {
    const sessionId = client.selectedSession!;
    // The wait gave up: "continue" is kept under its id for the person's resend.
    slot.keep(sessionId, "p-late", "continue", []);
    client.promptShown = (promptId) => slot.forget(promptId);
    // The host's journal sends it again later, and acpmux runs it (here: sent on this connection).
    await client.send("continue", [], "p-late");
    // The sender's own catch keeps it again after it landed: the id stays retired.
    slot.keep(sessionId, "p-late", "continue", []);
    // The next "continue" is a new instruction, not that prompt's duplicate.
    expect(slot.take(sessionId, "continue", [])).toBeUndefined();
  } finally {
    client.close();
  }
});

test("a connection whose history already shows a kept lost prompt retires its id", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    () => undefined,
    undefined,
    () => new MockAcpmuxSocket(() => Promise.resolve()) as unknown as WebSocket,
  );
  try {
    await client.send("continue", [], "p-read");
    const sessionId = client.selectedSession!;
    const slot = lostPromptSlot();
    slot.keep(sessionId, "p-read", "continue", []);
    slot.keep(sessionId, "p-other", "and test it", []);
    slot.forgetShown((chat, promptId) => client.showsPrompt(chat, promptId));
    expect(slot.take(sessionId, "continue", [])).toBeUndefined();
    slot.keep(sessionId, "p-other", "and test it", []);
    expect(slot.take(sessionId, "and test it", [])).toBe("p-other");
  } finally {
    client.close();
  }
});

test("a late resend names the kept prompts a connection's history shows, and retires them", () => {
  const slot = lostPromptSlot();
  slot.keep("s-1", "p-read", "continue", []);
  slot.keep("s-1", "p-other", "and test it", []);
  expect(slot.forgetShown((_chat, promptId) => promptId === "p-read")).toEqual(["p-read"]);
  // Retired: the sender's later keep does not bring it back.
  slot.keep("s-1", "p-read", "continue", []);
  expect(slot.take("s-1", "and test it", [])).toBe("p-other");
  expect(slot.take("s-1", "continue", [])).toBeUndefined();
});

test("a claimed lost prompt keeps its slot until its send has left", () => {
  const slot = lostPromptSlot();
  slot.keep("s-1", "p-lost", "continue", []);
  slot.keep("s-1", "p-other", "and test it", []);
  // An edited draft matches none: nothing changes until it has gone.
  const edited = slot.claim("s-1", "continue\n\nand test it", []);
  expect(edited.promptId).toBeUndefined();
  // It failed before acpmux took it: the lost prompt still goes under its id.
  const again = slot.claim("s-1", "continue", []);
  expect(again.promptId).toBe("p-lost");
  again.commit();
  again.commit();
  // Sent: each lost prompt goes again once.
  expect(slot.claim("s-1", "continue", []).promptId).toBeUndefined();
  expect(slot.claim("s-1", "and test it", []).promptId).toBe("p-other");
  // A send that is none of them, once it has gone, ends the chat's others.
  slot.claim("s-1", "something else", []).commit();
  expect(slot.claim("s-1", "and test it", []).promptId).toBeUndefined();
});
