// One prompt in a chat whose Claude Code conversation was lost drew four identical "Claude Code quit
// before it finished this turn." cards (Aziz, 2026-11-03, a8 "iOS composer shortcuts"): the failed
// turn, then each automatic continuation (`P~resume-n`, provenance auto_resume) and each Retry failed
// the same way, and each attempt's failure drew its own card. Attempts of one prompt draw one card,
// the last attempt's.
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
  dom.window.close();
});

type Daemon = { emit: (target: string, step: unknown, at?: number) => void };
type Row = { id: string; kind: string; status?: string; error?: string; text?: string; incoming?: { kind: string } };

async function pane() {
  const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
  const { MockAcpmuxSocket, mockHost } = await import("../src/agent-session/acpmux/mock");
  const { forgetTail } = await import("../src/agent-session/acpmux/tailCache");
  forgetTail(mockHost.sessionId!);
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as Daemon;
  const view: { rows: Row[]; ready: boolean } = { rows: [], ready: false };
  const wakes: Array<() => void> = [];
  // Each snapshot wakes the check; nothing waits on a clock.
  const shown = async (check: () => boolean) => {
    while (!check()) await new Promise<void>((resolve) => wakes.push(resolve));
  };
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      const s = snapshot as unknown as { rows?: Row[]; summary?: unknown };
      view.rows = s.rows ?? [];
      view.ready = s.summary !== undefined;
      for (const wake of wakes.splice(0)) wake();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  await shown(() => view.ready);
  return { daemon, view, shown, id: mockHost.sessionId!, close: () => client.close?.() };
}

const attempt = (n: number, manual = false) => ({
  mux: "user_message",
  msg: {
    promptId: `p-1~resume-${n}`,
    turnId: `t-${n + 1}`,
    text: "Continue from where you stopped.",
    _meta: {
      provenance: { kind: "auto_resume", promptId: "p-1", attempt: n, turnId: `t-${n}`, ...(manual ? { manual } : {}) },
    },
  },
});
const failed = (turn: number) => ({
  mux: "turn_result",
  msg: { status: "failed", errorText: "agent process closed", turnId: `t-${turn}` },
});

test("a prompt whose automatic continuation and Retries fail the same way draws one error card", async () => {
  const { turnView } = await import("../src/agent-session/acpmux/conversation/turns");
  const { daemon, view, shown, id, close } = await pane();
  try {
    daemon.emit(id, { mux: "user_message", msg: { promptId: "p-1", turnId: "t-1", text: "has this been pushed yet" } });
    daemon.emit(id, { mux: "turn_started", msg: { turnId: "t-1" } });
    daemon.emit(id, failed(1));
    for (const [n, manual] of [
      [1, false],
      [2, true],
      [3, true],
    ] as const) {
      daemon.emit(id, attempt(n, manual));
      daemon.emit(id, { mux: "turn_started", msg: { turnId: `t-${n + 1}` } });
      daemon.emit(id, failed(n + 1));
    }
    await shown(() => view.rows.some((row) => row.id === "summary-t-4"));
    const drawn = turnView(view.rows as never, new Set() as never, { now: Date.now() }) as unknown as Row[];
    const cards = drawn.filter((row) => row.kind === "turnSummary" && row.status === "failed");
    expect(cards.length).toBe(1);
    // The prompt draws once; the continuations' own words never do.
    expect(drawn.filter((row) => row.kind === "user").map((row) => row.text)).toEqual(["has this been pushed yet"]);
  } finally {
    close();
  }
});

test("a later prompt's failure still draws its own card", async () => {
  const { turnView } = await import("../src/agent-session/acpmux/conversation/turns");
  const { daemon, view, shown, id, close } = await pane();
  try {
    daemon.emit(id, { mux: "user_message", msg: { promptId: "p-1", turnId: "t-1", text: "first" } });
    daemon.emit(id, { mux: "turn_started", msg: { turnId: "t-1" } });
    daemon.emit(id, failed(1));
    daemon.emit(id, { mux: "user_message", msg: { promptId: "p-2", turnId: "t-2", text: "second" } });
    daemon.emit(id, { mux: "turn_started", msg: { turnId: "t-2" } });
    daemon.emit(id, failed(2));
    await shown(() => view.rows.some((row) => row.id === "summary-t-2"));
    const drawn = turnView(view.rows as never, new Set() as never, { now: Date.now() }) as unknown as Row[];
    expect(drawn.filter((row) => row.kind === "turnSummary" && row.status === "failed").length).toBe(2);
  } finally {
    close();
  }
});
