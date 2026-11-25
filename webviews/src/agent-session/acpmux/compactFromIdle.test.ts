// Leo, 2026-11-25: "the compaction starting from idle should not go from thinking to idle
// potentially. just the compacting conversation to start with so it skips the unnecesssary
// animation". A /compact sent to a hibernated chat: acpmux wakes its agent (`starting`), and the
// summaries of that wake hold no turn, so the pane read them as the turn's end and drew the chat
// idle until turn_started; and the line read "Thinking" until the harness's compaction row came.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { settleReact } from "../../../test/support/domTeardown";
import { THINKING, turnView } from "./conversation/turns";
import type { AcpmuxRow } from "./model";

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

type Daemon = {
  emit: (target: string, step: unknown, at?: number) => void;
  touch: (target: string, fields: Record<string, unknown>, moved?: boolean) => void;
};

type Shown = { isWorking: boolean; rows?: AcpmuxRow[]; summary?: { title?: string } };

async function pane() {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as Daemon;
  const view = { shown: { isWorking: false } as Shown };
  const snapshots: Array<() => void> = [];
  const until = async (check: () => boolean) => {
    while (!check()) await new Promise<void>((resolve) => snapshots.push(resolve));
  };
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      view.shown = snapshot as unknown as Shown;
      for (const wake of snapshots.splice(0)) wake();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  await until(() => view.shown.summary !== undefined);
  const id = mockHost.sessionId!;
  let marks = 0;
  const settled = async () => {
    const title = `mark-${(marks += 1)}`;
    daemon.touch(id, { title });
    await until(() => view.shown.summary?.title === title);
  };
  return { daemon, view, until, id, settled, close: () => client.close?.() };
}

const line = (shown: Shown) =>
  turnView(shown.rows ?? [], new Set(), { working: shown.isWorking }).find((row) => row.kind === THINKING);

const compacting = (shown: Shown) => {
  expect(shown.isWorking).toBe(true);
  expect(line(shown)?.liveState).toBe("compacting");
};

const compaction = (state: string) => ({ update: { sessionUpdate: "compaction", state } });

test("a /compact to a hibernated chat reads Compacting from its send, through the wake, to its end", async () => {
  const { daemon, view, id, settled, close } = await pane();
  try {
    daemon.touch(id, { status: "idle", turn: null });
    await settled();
    expect(view.shown.isWorking).toBe(false);
    daemon.emit(id, { mux: "user_message", msg: { text: "/compact", promptId: "p-compact" } });
    await settled();
    compacting(view.shown);
    // The wake: acpmux starts the agent, then lists it ready, all before the turn starts.
    daemon.touch(id, { status: "idle", turn: null, starting: true });
    await settled();
    compacting(view.shown);
    daemon.emit(id, { mux: "host_started", msg: { hostPid: 1 } });
    daemon.emit(id, { mux: "resumed", msg: { level: "exact", wake: true } });
    daemon.touch(id, { status: "ready", turn: null, starting: false });
    await settled();
    compacting(view.shown);
    daemon.touch(id, { status: "running", turn: { turnId: "t-compact" } });
    daemon.emit(id, { mux: "turn_started", msg: { turnId: "t-compact", promptId: "p-compact" } });
    await settled();
    compacting(view.shown);
    daemon.emit(id, compaction("running"));
    await settled();
    compacting(view.shown);
  } finally {
    close();
  }
});

test("a prompt that never starts lets the chat go idle once the wake is over", async () => {
  const { daemon, view, id, settled, until, close } = await pane();
  try {
    daemon.touch(id, { status: "idle", turn: null });
    await settled();
    daemon.emit(id, { mux: "user_message", msg: { text: "/compact", promptId: "p-lost" } });
    daemon.touch(id, { status: "ready", turn: null, starting: false });
    await settled();
    expect(view.shown.isWorking).toBe(true);
    await until(() => !view.shown.isWorking);
    expect(line(view.shown)).toBeUndefined();
  } finally {
    close();
  }
}, 10_000);

test("a plain prompt still reads Thinking before its first step", async () => {
  const { daemon, view, id, settled, close } = await pane();
  try {
    daemon.touch(id, { status: "idle", turn: null });
    await settled();
    daemon.emit(id, { mux: "user_message", msg: { text: "fix the retry", promptId: "p-plain" } });
    await settled();
    expect(view.shown.isWorking).toBe(true);
    expect(line(view.shown)?.liveState).toBeUndefined();
  } finally {
    close();
  }
});
