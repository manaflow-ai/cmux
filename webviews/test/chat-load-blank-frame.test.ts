import { expect, test } from "bun:test";
import { MockAcpmuxSocket } from "../src/agent-session/acpmux/mock";
import { loadRun } from "../src/agent-session/acpmux/loadDebug";
import { acpmuxPerf } from "../src/agent-session/acpmux/perf";

test("loadRun counts a blank painted frame even if the transcript catches up before afterRender", async () => {
  const scope = globalThis as Record<string, unknown>;
  let frames = 0;
  let scrollTop = 0;
  const scroller = {
    get scrollTop() {
      return scrollTop;
    },
    set scrollTop(top: number) {
      scrollTop = Math.max(0, Math.min(400, top));
    },
    scrollHeight: 1000,
    clientHeight: 600,
  };
  const replacements = {
    document: { querySelector: () => scroller, addEventListener() {} },
    requestAnimationFrame: (callback: FrameRequestCallback) => {
      frames += 1;
      // Warmup finishes at 30; every later frame starts with missing rows.
      acpmuxPerf.mounted = [];
      acpmuxPerf.contentHeight = 1000;
      queueMicrotask(() => callback(frames * 16));
      return frames;
    },
    MessageChannel: class {
      port1 = { onmessage: undefined as (() => void) | undefined, close() {} };
      port2 = {
        postMessage: () =>
          queueMicrotask(() => {
            // Work between paint and the posted task must not erase the blank frame.
            acpmuxPerf.mounted = [[0, 1000]];
            acpmuxPerf.contentHeight = 300;
            acpmuxPerf.span("test.afterRender", 1);
            this.port1.onmessage?.();
          }),
      };
    },
  };
  const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
  const live = MockAcpmuxSocket.live;
  const enabled = acpmuxPerf.enabled;
  const mounted = acpmuxPerf.mounted;
  const contentHeight = acpmuxPerf.contentHeight;
  Object.assign(scope, replacements);
  MockAcpmuxSocket.live = { streamLoadTurn: async () => ({}) } as unknown as MockAcpmuxSocket;
  try {
    const result = await loadRun({ sessionId: () => "load-test", rowCount: () => 10 }, { scroll_speed: 0 });
    expect(result.frames).toBe(30);
    expect(result.blank_frames).toBe(result.frames);
    expect(acpmuxPerf.stats().blank_frames).toBe(29);
    const spans = acpmuxPerf.stats().spans as Record<string, { max_ms: number }>;
    expect(spans["test.afterRender"]?.max_ms).toBe(1);
  } finally {
    MockAcpmuxSocket.live = live;
    acpmuxPerf.enabled = enabled;
    acpmuxPerf.mounted = mounted;
    acpmuxPerf.contentHeight = contentHeight;
    acpmuxPerf.resetFrames();
    for (const [key, had, value] of saved) {
      if (had) scope[key] = value;
      else delete scope[key];
    }
  }
});
