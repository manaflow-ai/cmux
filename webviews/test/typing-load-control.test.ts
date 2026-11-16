import { afterAll, expect, spyOn, test } from "bun:test";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = { window: scope.window, document: scope.document };
const had = { window: "window" in scope, document: "document" in scope };
scope.window = dom.window;
scope.document = dom.window.document;
afterAll(async () => {
  for (const key of ["window", "document"] as const) {
    if (had[key]) scope[key] = saved[key];
    else delete scope[key];
  }
  dom.window.close();
});

test("light fixture includes the summary in the model row count used by the 100k typing mode", async () => {
  const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
  const { MockAcpmuxSocket, mockHost } = await import("../src/agent-session/acpmux/mock");
  let rows: readonly { kind: string }[] = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (next) => {
      rows = next.rows;
    },
    undefined,
    () => new MockAcpmuxSocket(() => Promise.resolve()) as unknown as WebSocket,
  );
  try {
    await client.select(MockAcpmuxSocket.live!.seedLoadSession(4, true));
    expect(rows).toHaveLength(12);
    expect(rows.filter((row) => row.kind === "turnSummary")).toHaveLength(4);
  } finally {
    client.close();
  }
});

test("typing load emits the requested tool lines, exposes progress and stops without another delta", async () => {
  const { MockAcpmuxSocket } = await import("../src/agent-session/acpmux/mock");
  const { typingLoad } = await import("../src/agent-session/acpmux/typingLoadDebug");
  let now = 1000;
  const clock = spyOn(performance, "now").mockImplementation(() => now);
  let tick: (() => void) | undefined;
  const socket = new MockAcpmuxSocket(
    (ms) =>
      new Promise((resolve) => {
        tick = () => {
          now += ms;
          resolve();
        };
      }),
  );
  try {
    const session = socket.seedLoadSession(1, true);
    const started = await typingLoad(session, { chunks_per_second: 20, tool_lines_per_second: 2000, seconds: 10 });
    expect(started.running).toBe(true);
    tick!();
    await Promise.resolve();
    const receipt = await typingLoad(session);
    expect(receipt.deltas).toBe(1);
    expect(receipt.toolLines).toBe(100);
    expect(receipt.elapsedMs).toBe(50);
    const stopping = typingLoad(session, { stop: true });
    tick!();
    const stopped = await stopping;
    expect(stopped.running).toBe(false);
    expect(stopped.deltas).toBe(1);
    expect(stopped.finished_epoch_ms).not.toBeNull();
  } finally {
    socket.close();
    clock.mockRestore();
  }
});
