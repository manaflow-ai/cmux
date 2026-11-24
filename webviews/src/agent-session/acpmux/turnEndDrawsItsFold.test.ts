// Leo: "and we also need shit to be loading faster and not unloading themselves." Under load the
// pane drew a turn's end in two steps: acpmux's `turn_end` took the live line away and left the
// turn's work drawn as it came, and only its `turn_result` (logged after the turn's git stats are
// read, hub/turns.rs) folded that work under "Worked for", a frame or more later, after the turn's
// end fold had played. The reply jumped up by the fold's height. The end alone draws what the
// result draws, so the turn ends in one change.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { settleReact } from "../../../test/support/domTeardown";
import { turnView, WORKED } from "./conversation/turns";
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
  return { daemon, view, until, id, settled, close: () => client.close?.() };
}

/// What the transcript draws for the turn `prompt` opened (the mock's own history comes before it):
/// each row's id and kind, in order.
const drawn = (shown: Shown, prompt: string) => {
  const rows = turnView(shown.rows ?? [], new Set(), { working: shown.isWorking, agentFamily: "codex" });
  const opened = rows.findIndex((row) => row.kind === "user" && row.text === prompt);
  expect(opened).toBeGreaterThanOrEqual(0);
  return rows.slice(opened).map((row) => `${row.id}@${row.kind}`);
};

/// The summary rows of the turn `prompt` opened.
const summariesOf = (shown: Shown, prompt: string) => {
  const rows = shown.rows ?? [];
  const opened = rows.findIndex((row) => row.kind === "user" && row.text === prompt);
  return rows.slice(opened).filter((row) => row.kind === "turnSummary");
};

test("a turn's end alone draws the fold its result draws", async () => {
  const { daemon, view, until, id, settled, close } = await pane();
  try {
    const turnId = "t-fold";
    // Stamped six seconds apart: a turn under a second never folds (turns.ts `worthFolding`).
    const t0 = Date.now() - 60_000;
    daemon.touch(id, { status: "running", turn: { turnId } });
    daemon.emit(id, { mux: "user_message", msg: { text: "Fold the retry work", promptId: `p-${turnId}` } }, t0);
    daemon.emit(id, { mux: "turn_started", msg: { turnId, promptId: `p-${turnId}` } }, t0);
    // Three calls: a turn with less to hide draws flat, with no fold (turns.ts `worthFolding`).
    for (const [index, toolCallId] of ["c1", "c2", "c3"].entries()) {
      daemon.emit(
        id,
        {
          update: {
            sessionUpdate: "tool_call",
            toolCallId,
            kind: "execute",
            title: "run tests",
            status: "completed",
          },
        },
        t0 + (index + 1) * 1_000,
      );
    }
    daemon.emit(
      id,
      {
        update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Done: the tests pass." } },
      },
      t0 + 5_000,
    );
    await until(() => view.shown.isWorking);
    await settled();
    daemon.touch(id, { status: "running", turn: null });
    daemon.emit(id, { mux: "turn_end", msg: { stopReason: "end_turn", turnId } }, t0 + 6_000);
    await settled();
    const atEnd = drawn(view.shown, "Fold the retry work");
    expect(atEnd.some((row) => row.endsWith(`@${WORKED}`))).toBe(true);
    expect(atEnd.some((row) => row.endsWith("@activity"))).toBe(false);
    daemon.emit(id, { mux: "turn_result", msg: { status: "completed", turnId, promptId: `p-${turnId}` } }, t0 + 6_000);
    daemon.touch(id, { status: "ready" });
    await settled();
    expect(drawn(view.shown, "Fold the retry work")).toEqual(atEnd);
    // The result fills in the summary the end drew: one summary row, newer than the end's.
    expect(summariesOf(view.shown, "Fold the retry work").map((row) => [row.id, row.version])).toEqual([
      [`summary-${turnId}`, 2],
    ]);
  } finally {
    close();
  }
});

test("an end with no turn named still waits for its result to fold", async () => {
  const { daemon, view, id, settled, close } = await pane();
  try {
    daemon.touch(id, { status: "running" });
    daemon.emit(id, { mux: "user_message", msg: { text: "Look", promptId: "p-legacy" } });
    daemon.emit(id, {
      update: { sessionUpdate: "tool_call", toolCallId: "c2", kind: "execute", title: "ls", status: "completed" },
    });
    daemon.emit(id, { mux: "turn_end", msg: { stopReason: "end_turn" } });
    await settled();
    expect(drawn(view.shown, "Look").length).toBeGreaterThan(1);
    expect(summariesOf(view.shown, "Look")).toEqual([]);
  } finally {
    close();
  }
});
