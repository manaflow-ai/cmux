// A message the person sent as a steer into a turn that ended without reading it is carried into
// the next turn (acpmux `turn_started.carried.promptIds`). It draws where that turn starts, never
// above the ended turn's reply, which answered something else (Leo, 2026-11-12, on a "No change."
// to a background notice drawn under his "hm? what happened here").
// l10n-allow-file: synthetic prompts and replies used by a behavioral regression.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = (["window", "document"] as const).map((key) => [key, key in scope, scope[key]] as const);
beforeAll(() => {
  Object.assign(scope, { window: dom.window, document: dom.window.document });
});
afterAll(() => {
  for (const [key, had, value] of saved)
    if (had) scope[key] = value;
    else delete scope[key];
});

type Daemon = { record: (target: string, step: unknown, at?: number) => unknown };
type Row = { id: string; kind: string; text?: string; steer?: string; turnId?: string };

test("a steer the turn never read draws after that turn's reply, opening the turn it was carried to", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const { forgetTail } = await import("./tailCache");
  forgetTail(mockHost.sessionId!);
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as Daemon;
  const steps = [
    // A background notice opens a turn of its own.
    { mux: "user_message", msg: { text: "[notice from acpmux] Background command finished", promptId: "p-notice" } },
    { mux: "turn_started", msg: { promptId: "p-notice", turnId: "t-notice" } },
    // The person writes while it runs: a steer into that turn.
    {
      mux: "user_message",
      msg: { text: "hm? what happened here", promptId: "p-person", steer: true, turnId: "t-notice" },
    },
    // The notice turn's reply, which never read the steer.
    {
      update: {
        sessionUpdate: "agent_message_chunk",
        messageId: "m-1",
        content: { type: "text", text: "No change." },
      },
    },
    { mux: "turn_end", msg: { stopReason: "end_turn", turnId: "t-notice" } },
    { mux: "turn_result", msg: { status: "completed", turnId: "t-notice" } },
    // acpmux carries the unread steer into the next turn.
    {
      mux: "turn_started",
      msg: { promptId: "p-person", turnId: "t-person", carried: { fromTurnId: "t-notice", promptIds: ["p-person"] } },
    },
    {
      update: {
        sessionUpdate: "agent_message_chunk",
        messageId: "m-2",
        content: { type: "text", text: "Here is what happened." },
      },
    },
    { mux: "turn_result", msg: { status: "completed", turnId: "t-person" } },
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
  try {
    const drawn = () => rows.filter((row) => row.kind === "user" || row.kind === "assistant");
    while (!drawn().some((row) => row.text?.includes("Here is what happened")))
      await new Promise<void>((resolve) => wakes.push(resolve));
    const order = drawn().map((row) => row.text ?? "");
    const person = order.findIndex((text) => text === "hm? what happened here");
    const noChange = order.findIndex((text) => text === "No change.");
    const answer = order.findIndex((text) => text === "Here is what happened.");
    expect(person).toBeGreaterThan(-1);
    expect(noChange).toBeGreaterThan(-1);
    // The ended turn's reply comes first; the carried message opens the turn that answers it.
    expect(noChange).toBeLessThan(person);
    expect(person).toBeLessThan(answer);
    const row = drawn()[person]!;
    expect(row.steer).toBeUndefined();
    expect(row.turnId).toBe("t-person");
  } finally {
    client.close?.();
  }
});

test("a steer the turn read stays where it was sent", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const { forgetTail } = await import("./tailCache");
  forgetTail(mockHost.sessionId!);
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as Daemon;
  const steps = [
    { mux: "user_message", msg: { text: "Fix the build", promptId: "p-1" } },
    { mux: "turn_started", msg: { promptId: "p-1", turnId: "t-1" } },
    { mux: "user_message", msg: { text: "Use the cache too", promptId: "p-2", steer: true, turnId: "t-1" } },
    { mux: "steer_read", msg: { promptId: "p-2" } },
    {
      update: {
        sessionUpdate: "agent_message_chunk",
        messageId: "m-1",
        content: { type: "text", text: "Done, cached." },
      },
    },
    { mux: "turn_result", msg: { status: "completed", turnId: "t-1" } },
    { mux: "turn_started", msg: { promptId: "p-3", turnId: "t-2" } },
    { mux: "turn_result", msg: { status: "completed", turnId: "t-2" } },
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
  try {
    const drawn = () => rows.filter((row) => row.kind === "user" || row.kind === "assistant");
    while (!drawn().some((row) => row.text === "Done, cached."))
      await new Promise<void>((resolve) => wakes.push(resolve));
    const order = drawn().map((row) => row.text ?? "");
    expect(order.indexOf("Use the cache too")).toBeLessThan(order.indexOf("Done, cached."));
    expect(drawn().find((row) => row.text === "Use the cache too")?.turnId).toBe("t-1");
  } finally {
    client.close?.();
  }
});
