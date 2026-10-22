// A prompt whose connection went before acpmux took it is not "Not sent: read its saved state
// before retrying" (Leo, 2026-10-20: the coordinator chat lost a prompt to a reset socket and asked
// for a Refresh). The host sends it again on the next connection; the sender waits for it there.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import {
  clientWaiter,
  isLostConnection,
  lostDrafts,
  lostPrompt,
  lostPromptSlot,
  waitForResend,
  withoutParts,
  withoutRestored,
} from "./lostPrompt";

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

/// Yields a macrotask at a time until `done`.
const settle = async (done: () => boolean) => {
  for (let tries = 0; tries < 500 && !done(); tries += 1) await new Promise((resolve) => setTimeout(resolve, 0));
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
  // Far past the test's own timeout: only the close can settle it.
  const waiting = client.awaitResent(client.selectedSession!, "p-never", 600_000);
  client.close();
  expect(client.isClosed).toBe(true);
  expect(await waiting).toBe(false);
});

test("a harness switch sends a lost prompt it held under its id, never marked a resend by the page", async () => {
  const { HarnessSwitch } = await import("./harnessSwitch");
  // The host refuses a page frame with `resend` (#22881): the page reuses the id, the host marks it.
  const sent: { promptId: string; args: number }[] = [];
  const store = new HarnessSwitch({ now: () => 0, schedule: () => () => undefined });
  store.connect({
    turnRunning: () => false,
    shown: () => undefined,
    create: async () => "s-new",
    leave: () => undefined,
    open: async (sessionId) => sessionId,
    send: async (...args) => {
      sent.push({ promptId: args[2], args: args.length });
    },
    setModel: async () => undefined,
    setMode: async () => undefined,
    setConfig: async () => undefined,
    discard: () => undefined,
    prewarm: () => undefined,
    prewarmSupported: () => false,
  });
  void store.switchTo("codex", "/tmp/project");
  const turn = store.send("fix it", [], undefined, "p-lost");
  expect(turn).toBeDefined();
  await turn;
  expect(sent).toEqual([{ promptId: "p-lost", args: 3 }]);
});

test("a lost prompt that comes back while another chat shows waits for its own chat", () => {
  const drafts = lostDrafts<{ promptId: string; text: string }>();
  drafts.hold("s-a", { promptId: "p-a", text: "chat A's task" });
  // Chat B shows: nothing of chat A goes into its composer.
  expect(drafts.take("s-b")).toEqual([]);
  expect(drafts.take(undefined)).toEqual([]);
  // Chat A shows again: its draft comes back, once.
  expect(drafts.take("s-a")).toEqual([{ promptId: "p-a", text: "chat A's task" }]);
  expect(drafts.take("s-a")).toEqual([]);
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

test("a lost prompt the host sent again after all never comes back into its chat's composer", () => {
  const drafts = lostDrafts<{ promptId: string; text: string }>();
  drafts.hold("s-a", { promptId: "p-1", text: "continue" });
  drafts.hold("s-a", { promptId: "p-2", text: "and test it" });
  drafts.hold("s-b", { promptId: "p-3", text: "ship it" });
  drafts.drop("p-1");
  drafts.drop("p-3");
  expect(drafts.take("s-a")).toEqual([{ promptId: "p-2", text: "and test it" }]);
  expect(drafts.take("s-b")).toEqual([]);
});

test("a send leaves out every lost prompt that ran after all, as it came back, and keeps the rest", () => {
  const first = { text: "continue", attachmentIds: [] };
  const image = { text: "", attachmentIds: ["img-1"] };
  const last = { text: "and test it", attachmentIds: [] };
  // Restored first, then the image, then the last: the composer holds the newest first.
  const draft = { text: "and test it\n\n\n\ncontinue\n\nmy note", attachmentIds: ["img-1"] };
  expect(withoutParts(draft, [first, image, last], new Set([0, 1]))).toEqual({
    text: "and test it\n\nmy note",
    attachmentIds: [],
  });
  // An attachment-only prompt that ran goes too.
  expect(withoutParts({ text: "", attachmentIds: ["img-1"] }, [image], new Set([0]))).toEqual({
    text: "",
    attachmentIds: [],
  });
  // Edited: the person's draft, sent as typed.
  expect(withoutParts({ text: "continue now", attachmentIds: [] }, [first], new Set([0]))).toBeUndefined();
});

test("a lost prompt the host sent after all leaves the composer; the person's own text and edits stay", () => {
  const go = { text: "continue", attachmentIds: ["img-1"] };
  expect(withoutRestored({ text: "continue", attachmentIds: ["img-1"] }, [go], 0)).toEqual({ text: "", attachmentIds: [] });
  // Two prompts lost together come back as one draft, the newer first: each goes on its own.
  const test2 = { text: "and test it", attachmentIds: ["img-2"] };
  const both = { text: "and test it\n\ncontinue", attachmentIds: ["img-2", "img-1"] };
  expect(withoutRestored(both, [go, test2], 0)).toEqual({ text: "and test it", attachmentIds: ["img-2"] });
  expect(withoutRestored(both, [go, test2], 1)).toEqual({ text: "continue", attachmentIds: ["img-1"] });
  // A part that is also a paragraph of another: the part that went goes, never the paragraph.
  const plain = { text: "continue", attachmentIds: [] };
  const longer = { text: "continue\n\nand test it", attachmentIds: [] };
  const overlap = { text: "continue\n\nand test it\n\ncontinue", attachmentIds: [] };
  expect(withoutRestored(overlap, [plain, longer], 0)).toEqual({ text: "continue\n\nand test it", attachmentIds: [] });
  expect(withoutRestored(overlap, [plain, longer], 1)).toEqual({ text: "continue", attachmentIds: [] });
  // What the person typed before it came back stays, after it.
  expect(withoutRestored({ text: "continue\n\nmy note", attachmentIds: ["img-1", "img-3"] }, [go], 0)).toEqual({
    text: "my note",
    attachmentIds: ["img-3"],
  });
  // Edited, or a chip of it removed: the person's draft now, so it stays.
  expect(withoutRestored({ text: "continue please", attachmentIds: ["img-1"] }, [go], 0)).toBeUndefined();
  expect(withoutRestored({ text: "please continue", attachmentIds: ["img-1"] }, [go], 0)).toBeUndefined();
  expect(withoutRestored({ text: "continue", attachmentIds: [] }, [go], 0)).toBeUndefined();
  expect(withoutRestored({ text: "and test it, continue", attachmentIds: [] }, [plain, longer], 0)).toBeUndefined();
  // Sent already: the composer is empty, nothing to take out.
  expect(withoutRestored({ text: "", attachmentIds: [] }, [go], 0)).toBeUndefined();
});
