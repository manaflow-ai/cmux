// The quiet watch (direct.ts `armQuietWatch`) looks for a stream that stopped while the chat works. A chat attached
// at rest has nothing to watch: its timer woke the pane about 6.5 s after a switch only to find the chat not working
// (CMUX-571, idle wakeups: bench/chat-switch.bench.ts, the 10 s left-alone window). A working chat is still watched.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { settleReact } from "../../../test/support/domTeardown";

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
  record: (target: string, step: unknown, at?: number) => unknown;
  touch: (target: string, fields: Record<string, unknown>) => void;
};
type Row = { kind: string; text?: string };

/// Connects to a chat holding one turn, ended or still running, and reads whether its quiet timer is armed once
/// the attach drew the reply.
async function attached(ended: boolean): Promise<boolean> {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const { forgetTail } = await import("./tailCache");
  const target = mockHost.sessionId!;
  forgetTail(target);
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as Daemon;
  daemon.record(target, { mux: "user_message", msg: { text: "Look at the logs" } });
  daemon.record(target, { mux: "turn_started", msg: {} });
  daemon.record(target, {
    update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "The reply." } },
  });
  if (ended) daemon.record(target, { mux: "turn_result", msg: { status: "completed" } });
  daemon.touch(target, { status: ended ? "idle" : "running" });
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
    const internals = client as unknown as {
      quietTimer?: unknown;
      attachedGeneration?: number;
      selectionGeneration?: number;
    };
    while (
      !rows.some((row) => row.kind === "assistant" && row.text?.includes("The reply.")) ||
      internals.attachedGeneration !== internals.selectionGeneration
    )
      await new Promise<void>((resolve) => wakes.push(resolve));
    await settleReact();
    return internals.quietTimer !== undefined;
  } finally {
    client.close?.();
  }
}

test("a chat attached at rest arms no quiet timer", async () => {
  expect(await attached(true)).toBe(false);
});

test("a chat attached while its turn runs is still watched", async () => {
  expect(await attached(false)).toBe(true);
});
