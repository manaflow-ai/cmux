// A host push of hundreds of stream frames is never one task in front of a key (cmuxterm-hq
// docs/design/chat-instant-under-load.md, "Ingest is a queue, not a task"): `receive` stores the
// frames and returns; the frame lane folds them in slices, coalescing a reply's chunks before the
// reducer, and draws once. On the base every frame was parsed and reduced in the receiving task.
// l10n-allow-file: synthetic replies used by a behavioral regression.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { teardownDom } from "../../../test/support/domTeardown";
import { createLanes, type LanesEnv } from "./schedule";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = (["window", "document"] as const).map((key) => [key, key in scope, scope[key]] as const);
beforeAll(() => {
  Object.assign(scope, { window: dom.window, document: dom.window.document });
});
afterAll(async () => {
  await teardownDom(saved, { window: dom.window });
});

type Row = { id: string; kind: string; text?: string };
type Daemon = { record: (target: string, step: unknown, at?: number) => unknown };

/// Lanes on a manual clock: frames and tasks run when the test says.
function manualLanes() {
  let time = 0;
  let frames: (() => void)[] = [];
  const tasks: (() => void)[] = [];
  const env: LanesEnv = {
    now: () => time,
    requestFrame: (cb) => frames.push(cb),
    postTask: (cb) => tasks.push(cb),
    setTimer: () => () => {},
    hidden: () => false,
    listen: () => () => {},
    reportError: (error) => {
      throw error;
    },
  };
  return {
    lanes: createLanes(env),
    advance: (ms: number) => (time += ms),
    pendingFrames: () => frames.length,
    async frame() {
      const run = frames;
      frames = [];
      for (const cb of run) cb();
      while (tasks.length) tasks.shift()!();
      await new Promise((resolve) => setTimeout(resolve, 0));
    },
  };
}

async function openChat() {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const { forgetTail } = await import("./tailCache");
  forgetTail(mockHost.sessionId!);
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  (socket as unknown as Daemon).record(mockHost.sessionId!, {
    update: { sessionUpdate: "agent_message_chunk", messageId: "m-0", content: { type: "text", text: "Hello." } },
  });
  let rows: Row[] = [];
  let snapshots = 0;
  const wakes: Array<() => void> = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      rows = snapshot.rows as Row[];
      snapshots += 1;
      for (const wake of wakes.splice(0)) wake();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  while (!rows.some((row) => row.text === "Hello.")) await new Promise<void>((resolve) => wakes.push(resolve));
  const pane = client as unknown as {
    lastSeq: number;
    events: { seq: number }[];
    selectedSessionId: string;
    reduce: (event: unknown) => void;
  };
  let reduces = 0;
  const reduce = pane.reduce.bind(pane);
  pane.reduce = (event) => {
    reduces += 1;
    reduce(event);
  };
  const push = (frames: unknown[]) => {
    const target = socket as unknown as { onmessage?: (message: { data: string }) => void };
    for (const frame of frames) target.onmessage?.({ data: JSON.stringify(frame) });
  };
  const chunk = (seq: number, text: string, messageId = "m-1") => ({
    jsonrpc: "2.0",
    method: "session/update",
    params: {
      sessionId: pane.selectedSessionId,
      update: { sessionUpdate: "agent_message_chunk", messageId, content: { type: "text", text } },
      _meta: { acpmux: { seq, at: 1_700_000_000_000 + seq } },
    },
  });
  return {
    client,
    pane,
    push,
    chunk,
    rows: () => rows,
    snapshots: () => snapshots,
    reduces: () => reduces,
  };
}

test("a push of 300 reply chunks is stored, not reduced, in the task that got it; the frame lane folds it in a few reduces", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const manual = manualLanes();
  const frames: (() => void)[] = [];
  AcpmuxDirectClient.scheduleFrame = (run) => void frames.push(run);
  AcpmuxDirectClient.ingestLanes = manual.lanes;
  const chat = await openChat();
  try {
    const from = chat.pane.lastSeq;
    const words: string[] = [];
    const push: unknown[] = [];
    for (let index = 1; index <= 300; index += 1) {
      words.push(`w${index} `);
      push.push(chat.chunk(from + index, `w${index} `));
    }
    const before = chat.snapshots();
    chat.push(push);
    // The receiving task folded nothing.
    expect(chat.reduces()).toBe(0);
    expect(chat.pane.lastSeq).toBe(from);
    expect(manual.pendingFrames()).toBe(1);
    await manual.frame();
    // One frame: the reply's first chunk alone, the other 299 as one, one snapshot.
    expect(chat.reduces()).toBe(2);
    expect(chat.snapshots() - before).toBe(1);
    // Every record is held, by its own seq.
    expect(chat.pane.lastSeq).toBe(from + 300);
    expect(chat.pane.events.slice(-300).map((event) => event.seq)).toEqual(
      Array.from({ length: 300 }, (_, index) => from + 1 + index),
    );
    // The reply reads as if each chunk had been folded alone.
    const reply = chat.rows().find((row) => row.kind === "assistant" && row.text?.startsWith("w1 "));
    expect(reply?.text).toBe(words.join(""));
  } finally {
    chat.client.close?.();
    AcpmuxDirectClient.scheduleFrame = undefined;
    AcpmuxDirectClient.ingestLanes = undefined;
    manual.lanes.dispose();
  }
});

test("the frame lane stops at its budget and goes on next frame; nothing is lost or reordered", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const manual = manualLanes();
  AcpmuxDirectClient.scheduleFrame = () => undefined;
  AcpmuxDirectClient.ingestLanes = manual.lanes;
  const chat = await openChat();
  try {
    const from = chat.pane.lastSeq;
    // Each reply its own message: nothing coalesces, so each chunk is a reduce that costs 1 ms here.
    const pane = chat.pane as unknown as { reduce: (event: unknown) => void };
    const reduce = pane.reduce;
    pane.reduce = (event) => {
      manual.advance(1);
      reduce(event);
    };
    const push: unknown[] = [];
    for (let index = 1; index <= 40; index += 1) push.push(chat.chunk(from + index, `m${index}`, `msg-${index}`));
    chat.push(push);
    await manual.frame();
    const firstFrame = chat.reduces();
    // A 6 ms frame budget at 1 ms a reduce: a handful, never the whole push.
    expect(firstFrame).toBeGreaterThan(0);
    expect(firstFrame).toBeLessThan(40);
    expect(manual.pendingFrames()).toBe(1);
    for (let guard = 0; guard < 40 && manual.pendingFrames() > 0; guard += 1) await manual.frame();
    expect(chat.reduces()).toBe(40);
    const texts = chat
      .rows()
      .filter((row) => row.kind === "assistant" && /^m\d+$/.test(row.text ?? ""))
      .map((row) => row.text);
    expect(texts).toEqual(Array.from({ length: 40 }, (_, index) => `m${index + 1}`));
  } finally {
    chat.client.close?.();
    AcpmuxDirectClient.scheduleFrame = undefined;
    AcpmuxDirectClient.ingestLanes = undefined;
    manual.lanes.dispose();
  }
});

test("a notification that is not a stream record applies after the records sent before it", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const manual = manualLanes();
  AcpmuxDirectClient.scheduleFrame = () => undefined;
  AcpmuxDirectClient.ingestLanes = manual.lanes;
  const chat = await openChat();
  try {
    const from = chat.pane.lastSeq;
    chat.push([chat.chunk(from + 1, "a "), chat.chunk(from + 2, "b ")]);
    expect(chat.reduces()).toBe(0);
    // `_acpmux/lagged` reads on from the chat's newest seq: the queue is folded first.
    chat.push([{ jsonrpc: "2.0", method: "_acpmux/lagged", params: { sessionIds: [], dropped: 0 } }]);
    expect(chat.pane.lastSeq).toBe(from + 2);
  } finally {
    chat.client.close?.();
    AcpmuxDirectClient.scheduleFrame = undefined;
    AcpmuxDirectClient.ingestLanes = undefined;
    manual.lanes.dispose();
  }
});

test("a duplicate record in a push is dropped as before, never folded ahead of the records before it", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const manual = manualLanes();
  AcpmuxDirectClient.scheduleFrame = () => undefined;
  AcpmuxDirectClient.ingestLanes = manual.lanes;
  const chat = await openChat();
  try {
    const from = chat.pane.lastSeq;
    // A replaced socket's or a reconnect's replay sends a record twice.
    chat.push([
      chat.chunk(from + 1, "a "),
      chat.chunk(from + 2, "b "),
      chat.chunk(from + 3, "c "),
      chat.chunk(from + 4, "d "),
      chat.chunk(from + 3, "c "),
    ]);
    await manual.frame();
    const reply = chat.rows().find((row) => row.kind === "assistant" && row.text?.startsWith("a "));
    expect(reply?.text).toBe("a b c d ");
    expect(chat.pane.events.slice(-4).map((event) => event.seq)).toEqual([from + 1, from + 2, from + 3, from + 4]);
  } finally {
    chat.client.close?.();
    AcpmuxDirectClient.scheduleFrame = undefined;
    AcpmuxDirectClient.ingestLanes = undefined;
    manual.lanes.dispose();
  }
});

test("a page that hides folds what it received at once", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const manual = manualLanes();
  AcpmuxDirectClient.scheduleFrame = () => undefined;
  AcpmuxDirectClient.ingestLanes = manual.lanes;
  const chat = await openChat();
  const doc = dom.window.document;
  try {
    const from = chat.pane.lastSeq;
    chat.push([chat.chunk(from + 1, "x "), chat.chunk(from + 2, "y ")]);
    expect(chat.pane.lastSeq).toBe(from);
    Object.defineProperty(doc, "visibilityState", { configurable: true, get: () => "hidden" });
    doc.dispatchEvent(new dom.window.Event("visibilitychange"));
    expect(chat.pane.lastSeq).toBe(from + 2);
  } finally {
    Object.defineProperty(doc, "visibilityState", { configurable: true, get: () => "visible" });
    chat.client.close?.();
    AcpmuxDirectClient.scheduleFrame = undefined;
    AcpmuxDirectClient.ingestLanes = undefined;
    manual.lanes.dispose();
  }
});
