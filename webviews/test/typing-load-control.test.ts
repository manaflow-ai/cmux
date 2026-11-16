import { afterAll, expect, spyOn, test } from "bun:test";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const saved = globalThis.window;
(globalThis as any).window = dom.window;
afterAll(() => {
  (globalThis as any).window = saved;
  dom.window.close();
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
