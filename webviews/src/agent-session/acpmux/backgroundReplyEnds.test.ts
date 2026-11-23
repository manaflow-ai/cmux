// l10n-allow-file: test fixture text, not shipped UI.
// A reply from a turn the agent ran on its own (acpmux brackets it with `background_turn` records) gets
// its action row in the frame its ended record comes in, with its final icons. Before, the reply
// carried acpmux's segment stamp and kept streaming past the end, so the row (Copy, Fork, Timeline,
// Read aloud, More) waited for the next record. In the log Leo sent, that was 5.8 s later (Leo,
// 2026-11-22: "this wrap-up had a very delayed set of icons appearing").
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { settleReact } from "../../../test/support/domTeardown";
import type { AcpmuxRow, AcpmuxSnapshot } from "./model";

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

type Step =
  | { update: Record<string, unknown>; meta?: Record<string, unknown> }
  | { mux: string; msg?: Record<string, unknown> };
type Daemon = {
  record: (target: string, step: Step, at?: number) => unknown;
  emit: (target: string, step: Step, at?: number) => void;
};

const REPLY = "Still running; nothing new.";
const chunk = (text: string, segment: string, messageId: string): Step => ({
  update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text }, messageId },
  meta: { acpmux: { segment } },
});
const tool = (id: string): Step[] => [
  {
    update: {
      sessionUpdate: "tool_call",
      toolCallId: id,
      title: "git status",
      kind: "execute",
      status: "in_progress",
      rawInput: { command: "git status" },
      _meta: { claude: { tool: "Bash" } },
    },
  },
  { update: { sessionUpdate: "tool_call_update", toolCallId: id, status: "completed" } },
];

/// The action row under the reply, as the footer the transcript draws it from: what decides each icon.
const footerOf = (rows: readonly AcpmuxRow[]) => {
  const footer = rows.find((row) => row.kind === "turnSummary" && row.text === REPLY);
  return (
    footer && {
      id: footer.id,
      // Fork goes through it, Timeline opens its work, Copy, Read aloud and More read its reply.
      seq: footer.seq,
      timeline: Boolean(footer.turnWork?.length),
      copy: Boolean(footer.turnCopy?.length),
      answerId: footer.answerId,
    }
  );
};

test("a background turn's reply gets its action row with the ended record, and keeps it", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const { turnView } = await import("./conversation/turns");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as Daemon;
  const target = mockHost.sessionId!;
  const start = Date.now();
  // The prompt's turn ended; then the agent woke on its own, ran a call and answered.
  const history: Step[] = [
    { mux: "user_message", msg: { text: "Watch the build and tell me when it changes" } },
    { mux: "turn_started", msg: {} },
    chunk("Watching it.", "-.a.1", "m1"),
    { mux: "turn_result", msg: { status: "completed" } },
    { mux: "background_turn", msg: { id: "bg-1", state: "started", trigger: "system" } },
    ...tool("check"),
    chunk("Still running; ", "-.a.2", "m2"),
    chunk("nothing new.", "-.a.2", "m2"),
  ];
  for (const [index, step] of history.entries()) daemon.record(target, step, start + index * 1_000);
  let snapshot: AcpmuxSnapshot | undefined;
  const wakes: Array<() => void> = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (next) => {
      snapshot = next;
      for (const wake of wakes.splice(0)) wake();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  const view = () =>
    turnView(snapshot?.rows ?? [], new Set(), { now: start + 60_000, working: false, agentFamily: "claude" });
  // Waits for the snapshot `ready` accepts (each record is delivered on its own microtask).
  const until = async (ready: () => boolean) => {
    for (let tries = 0; tries < 200 && !ready(); tries += 1)
      await new Promise<void>((resolve) => {
        wakes.push(resolve);
      });
    expect(ready()).toBe(true);
  };
  try {
    await until(() => Boolean(snapshot?.rows.some((row) => row.kind === "assistant" && row.text === REPLY)));
    // While it runs, the reply streams and has no row yet.
    expect(footerOf(view())).toBeUndefined();
    const reply = () => snapshot!.rows.find((row) => row.kind === "assistant" && row.text === REPLY)!;
    expect(reply().streaming).toBe(true);
    daemon.emit(
      target,
      {
        mux: "background_turn",
        msg: { id: "bg-1", state: "ended", trigger: "system", quiet: false, reason: "result" },
      },
      start + 20_000,
    );
    await until(() => snapshot!.rows.some((row) => row.background?.id === "bg-1" && row.background.running === false));
    // The frame the turn ends in: the reply stopped, and its row is there with every icon it keeps.
    expect(reply().streaming).toBe(false);
    const first = footerOf(view());
    expect(first).toMatchObject({ id: "backgroundEnd-bg-1", timeline: true, copy: true, answerId: reply().id });
    expect(first!.seq).toBeNumber();
    // Later records (the next turn the agent starts on its own) change none of its icons.
    daemon.emit(
      target,
      { mux: "background_turn", msg: { id: "bg-2", state: "started", trigger: "system" } },
      start + 30_000,
    );
    daemon.emit(target, chunk("Next check.", "-.a.3", "m3"), start + 30_001);
    await until(() => Boolean(snapshot?.rows.some((row) => row.kind === "assistant" && row.text === "Next check.")));
    expect(footerOf(view())).toEqual(first);
    expect(reply().text).toBe(REPLY);
  } finally {
    client.close?.();
  }
});

test("a late chunk of the reply after its turn ended goes on in the same row", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as Daemon;
  const target = mockHost.sessionId!;
  const steps: Step[] = [
    { mux: "user_message", msg: { text: "Watch it" } },
    { mux: "turn_started", msg: {} },
    { mux: "turn_result", msg: { status: "completed" } },
    { mux: "background_turn", msg: { id: "bg-1", state: "started", trigger: "system" } },
    chunk("Still running; ", "-.b.1", "m1"),
    { mux: "background_turn", msg: { id: "bg-1", state: "ended", trigger: "system", quiet: false, reason: "result" } },
    chunk("nothing new.", "-.b.1", "m1"),
  ];
  for (const step of steps) daemon.record(target, step);
  let rows: readonly AcpmuxRow[] = [];
  const wakes: Array<() => void> = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (next) => {
      rows = next.rows;
      for (const wake of wakes.splice(0)) wake();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  try {
    for (
      let tries = 0;
      tries < 200 && !rows.some((row) => row.kind === "assistant" && row.text?.includes("nothing"));
      tries += 1
    )
      await new Promise<void>((resolve) => {
        wakes.push(resolve);
      });
    // The mock's own scripted chat comes first; the background turn's rows are this one reply.
    expect(
      rows.filter((row) => row.kind === "assistant" && row.inBackground === "bg-1").map((row) => row.text),
    ).toEqual([REPLY]);
  } finally {
    client.close?.();
  }
});
