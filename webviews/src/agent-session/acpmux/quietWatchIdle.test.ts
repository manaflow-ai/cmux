// The quiet watch (direct.ts `armQuietWatch`) looks for a stream that stopped while the chat works. A chat attached
// at rest has nothing to watch: its timer woke the pane about 6.5 s after a switch only to find the chat not working
// (CMUX-571, idle wakeups: bench/chat-switch.bench.ts, the 10 s left-alone window). A working chat is still watched, until its turn ends.
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
  emit: (target: string, step: unknown, at?: number) => void;
  touch: (target: string, fields: Record<string, unknown>, moved?: boolean) => void;
};
type Row = { kind: string; text?: string };
type Internals = {
  quietTimer?: unknown;
  attachedGeneration?: number;
  selectionGeneration?: number;
  workingNow: () => boolean;
};

/// Connects to a chat holding one turn, ended or still running, and reads whether its quiet timer is armed once
/// the attach drew the reply. `endLive` then ends the running turn live and reads the timer again once it drew.
async function attached(ended: boolean, endLive = false): Promise<boolean[]> {
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
  const until = async (done: () => boolean) => {
    while (!done()) await new Promise<void>((resolve) => wakes.push(resolve));
    await settleReact();
  };
  try {
    const internals = client as unknown as Internals;
    await until(
      () =>
        rows.some((row) => row.kind === "assistant" && row.text?.includes("The reply.")) &&
        internals.attachedGeneration === internals.selectionGeneration,
    );
    const armed = [internals.quietTimer !== undefined];
    if (endLive) {
      daemon.emit(target, { mux: "turn_result", msg: { status: "completed" } });
      daemon.touch(target, { status: "idle" });
      await until(() => !internals.workingNow());
      armed.push(internals.quietTimer !== undefined);
    }
    return armed;
  } finally {
    client.close?.();
  }
}

test("a chat attached at rest arms no quiet timer", async () => {
  expect(await attached(true)).toEqual([false]);
});

test("a chat attached while its turn runs is still watched", async () => {
  expect(await attached(false)).toEqual([true]);
});

test("a watched turn that ends stops its quiet timer", async () => {
  expect(await attached(false, true)).toEqual([true, false]);
});
