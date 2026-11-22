// Leo, 2026-11-21: "the thinking timer is overstaying its welome after you just replied!" Every way a
// turn ends takes the live line (and its Thinking clock) away: the pane's `isWorking` goes false and
// the drawn rows hold no live line, whatever the session summary still lists for a moment.
// cmux#42088 covered the reply still being written before the turn's end; this file covers the end
// itself, one test per path acpmux ends a turn by (hub/turns.rs, hub/cancel.rs).
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
  /// Waits until the pane drew everything sent so far: a title change sent last is in the snapshot.
  const settled = async () => {
    const title = `mark-${(marks += 1)}`;
    daemon.touch(id, { title });
    await until(() => view.shown.summary?.title === title);
  };
  /// A running turn with a reply streamed into it, as acpmux sends one (hub/turns.rs).
  const running = async (turnId: string) => {
    daemon.touch(id, { status: "running", turn: { turnId } });
    daemon.emit(id, { mux: "user_message", msg: { text: "Fix the retry", promptId: `p-${turnId}` } });
    daemon.emit(id, { mux: "turn_started", msg: { turnId, promptId: `p-${turnId}` } });
    daemon.emit(id, {
      update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Done: the PR merged." } },
    });
    await until(() => view.shown.isWorking);
    expect(liveLine(view.shown)).toBe(true);
  };
  return { daemon, view, until, id, settled, running, close: () => client.close?.() };
}

/// Whether the drawn transcript holds the live line ("Thinking 7s", "Writing 3s").
const liveLine = (shown: Shown) =>
  turnView(shown.rows ?? [], new Set(), { working: shown.isWorking }).some((row) => row.kind === THINKING);

const ended = (shown: Shown) => {
  expect(shown.isWorking).toBe(false);
  expect(liveLine(shown)).toBe(false);
};

// acpmux clears the summary's `turn` before it logs the end and sets the chat's status after it
// (hub/turns.rs `write_turn_result`): between the two the summary still says "running".
const clearTurn = (daemon: Daemon, id: string) => daemon.touch(id, { status: "running", turn: null });

test("a reply: the turn's end takes the live line away while the summary still says running", async () => {
  const { daemon, view, id, settled, running, close } = await pane();
  try {
    await running("t-reply");
    clearTurn(daemon, id);
    daemon.emit(id, { mux: "turn_end", msg: { stopReason: "end_turn", turnId: "t-reply" } });
    daemon.emit(id, { mux: "turn_result", msg: { status: "completed", turnId: "t-reply", promptId: "p-t-reply" } });
    await settled();
    ended(view.shown);
    daemon.touch(id, { status: "ready" });
    await settled();
    ended(view.shown);
  } finally {
    close();
  }
});

test("an error: a failed turn takes the live line away", async () => {
  const { daemon, view, id, settled, running, close } = await pane();
  try {
    await running("t-error");
    clearTurn(daemon, id);
    daemon.emit(id, { mux: "turn_error", msg: { error: "stream disconnected", turnId: "t-error" } });
    daemon.emit(id, {
      mux: "turn_result",
      msg: { status: "failed", error: "stream disconnected", errorText: "stream disconnected", turnId: "t-error" },
    });
    await settled();
    ended(view.shown);
  } finally {
    close();
  }
});

test("a cancel: a Stop the agent answered takes the live line away", async () => {
  const { daemon, view, id, settled, running, close } = await pane();
  try {
    await running("t-cancel");
    clearTurn(daemon, id);
    daemon.emit(id, { mux: "turn_end", msg: { stopReason: "cancelled", turnId: "t-cancel" } });
    daemon.emit(id, { mux: "turn_result", msg: { status: "cancelled", stopReason: "cancelled", turnId: "t-cancel" } });
    await settled();
    ended(view.shown);
  } finally {
    close();
  }
});

test("an interrupt: a Stop acpmux forced (the agent never answered) takes the live line away", async () => {
  const { daemon, view, id, settled, running, close } = await pane();
  try {
    await running("t-forced");
    clearTurn(daemon, id);
    daemon.emit(id, { mux: "turn_result", msg: { status: "cancelled", cancelForced: true, turnId: "t-forced" } });
    await settled();
    ended(view.shown);
  } finally {
    close();
  }
});

test("a process exit: the agent exiting mid-turn takes the live line away", async () => {
  const { daemon, view, id, settled, running, close } = await pane();
  try {
    await running("t-exit");
    clearTurn(daemon, id);
    daemon.emit(id, { mux: "turn_error", msg: { error: "agent exited", code: -32000, turnId: "t-exit" } });
    daemon.emit(id, { mux: "turn_result", msg: { status: "failed", error: "agent exited", turnId: "t-exit" } });
    await settled();
    ended(view.shown);
    daemon.touch(id, { status: "disconnected" });
    await settled();
    ended(view.shown);
  } finally {
    close();
  }
});

test("a lost end: a summary saying no turn runs takes the live line away when the end never came", async () => {
  // What a reconnect brings when the turn ended while the socket was down (hostTurnState.ts).
  const { daemon, view, id, settled, running, close } = await pane();
  try {
    await running("t-lost");
    daemon.touch(id, { status: "ready", turn: null });
    await settled();
    ended(view.shown);
  } finally {
    close();
  }
});

for (const stopReason of ["max_tokens", "refusal", "max_turn_requests"])
  test(`a turn_end with stop reason ${stopReason} takes the live line away before its result`, async () => {
    const { daemon, view, id, settled, running, close } = await pane();
    try {
      await running(`t-${stopReason}`);
      clearTurn(daemon, id);
      daemon.emit(id, { mux: "turn_end", msg: { stopReason, turnId: `t-${stopReason}` } });
      await settled();
      ended(view.shown);
    } finally {
      close();
    }
  });

test("an older acpmux: a summary with no `turn` still listing the ended turn running takes no live line", async () => {
  const { daemon, view, id, settled, close } = await pane();
  try {
    daemon.touch(id, { status: "running" });
    daemon.emit(id, { mux: "user_message", msg: { text: "Fix the retry", promptId: "p-old" } });
    daemon.emit(id, { mux: "turn_started", msg: { turnId: "t-old", promptId: "p-old" } });
    await settled();
    expect(view.shown.isWorking).toBe(true);
    daemon.emit(id, { mux: "turn_result", msg: { status: "completed", turnId: "t-old" } });
    await settled();
    ended(view.shown);
  } finally {
    close();
  }
});
