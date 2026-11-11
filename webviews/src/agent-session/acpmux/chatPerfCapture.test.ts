import { describe, expect, test } from "bun:test";
import {
  ChatPerfCapture,
  type CaptureEnv,
  arrivalSummary,
  captureKind,
  frameSummary,
  layoutShiftSummary,
  longTaskSummary,
  scriptSource,
  unmeasuredReason,
  visibilitySummary,
} from "./chatPerfCapture";

describe("chat perf capture: pure parts", () => {
  test("record kinds group into tool_call, tool_call_update, agent_message_chunk and other", () => {
    expect(captureKind("tool_call")).toBe("tool_call");
    expect(captureKind("tool_call_update")).toBe("tool_call_update");
    expect(captureKind("agent_message_chunk")).toBe("agent_message_chunk");
    expect(captureKind("plan")).toBe("other");
    expect(captureKind(undefined)).toBe("other");
  });

  test("arrival-to-paint splits by kind and keeps every kind under all", () => {
    const report = arrivalSummary([
      { kind: "tool_call", apply: 1, paint: 10 },
      { kind: "tool_call", apply: 3, paint: 30 },
      { kind: "agent_message_chunk", apply: 0.5, paint: 8 },
    ]);
    expect(report.all.count).toBe(3);
    expect(report.tool_call.count).toBe(2);
    expect(report.tool_call.to_paint.max_ms).toBe(30);
    expect(report.tool_call.apply.max_ms).toBe(3);
    expect(report.agent_message_chunk.to_paint.p50_ms).toBe(8);
    expect(report.tool_call_update.count).toBe(0);
    expect(report.other.to_paint.max_ms).toBe(0);
  });

  test("frames count intervals past 33 and 50 ms", () => {
    const report = frameSummary([0, 16, 32, 72, 132, 148]);
    expect(report.count).toBe(6);
    expect(report.over_33_ms).toBe(2);
    expect(report.over_50_ms).toBe(1);
    expect(report.interval_max_ms).toBe(60);
    expect(report.interval_p50_ms).toBe(16);
  });

  test("long tasks name their top scripts without query strings", () => {
    const report = longTaskSummary(
      [
        {
          duration: 120,
          blockingDuration: 70,
          scripts: [
            { invoker: "MessagePort.onmessage", sourceURL: "cmux-page://agent/app.js?token=x", duration: 90 },
            { invoker: "FrameRequestCallback", sourceURL: "cmux-page://agent/app.js", duration: 20 },
          ],
        },
        {
          duration: 60,
          blockingDuration: 10,
          scripts: [{ invoker: "MessagePort.onmessage", sourceURL: "cmux-page://agent/app.js#x", duration: 40 }],
        },
      ],
      "long-animation-frame",
    );
    expect(report.count).toBe(2);
    expect(report.longest_ms).toBe(120);
    expect(report.blocking_ms).toBe(80);
    expect(report.top_scripts[0]).toEqual({
      invoker: "MessagePort.onmessage",
      source_url: "cmux-page://agent/app.js",
      function: "",
      count: 2,
      total_ms: 130,
      max_ms: 90,
    });
    expect(report.top_scripts).toHaveLength(2);
    expect(scriptSource(undefined)).toBe("");
  });

  test("layout shift sums only shifts without recent input", () => {
    expect(
      layoutShiftSummary([{ value: 0.1 }, { value: 0.05, hadRecentInput: true }, { value: 0.02, hadRecentInput: false }]),
    ).toEqual({ count: 2, sum: 0.12 });
  });

  test("a hidden or undrawn page says it measured nothing", () => {
    const hidden = visibilitySummary(
      [
        { at: 0, state: "visible" },
        { at: 1000, state: "hidden" },
      ],
      5000,
    );
    expect(hidden).toEqual({ start: "visible", end: "hidden", changes: 1, hidden_ms: 4000 });
    expect(unmeasuredReason(5, 60, hidden)).toBe("page_hidden");
    expect(unmeasuredReason(5, 1, { hidden_ms: 0 })).toBe("no_frames");
    expect(unmeasuredReason(5, 300, { hidden_ms: 0 })).toBe(null);
  });
});

/** A page whose frames, timers, messages and observers the test drives by hand. */
function fakeEnv() {
  let clock = 0;
  const frames = new Map<number, (time: number) => void>();
  let nextFrame = 1;
  const timers = new Map<number, () => void>();
  let nextTimer = 1;
  const messages: (() => void)[] = [];
  const observers = new Map<string, (entries: unknown[]) => void>();
  let channelOpen = false;
  let visibilityListeners = 0;
  const env: CaptureEnv = {
    now: () => clock,
    requestFrame(callback) {
      frames.set(nextFrame, callback);
      return nextFrame++;
    },
    cancelFrame: (handle) => void frames.delete(handle),
    setTimer(callback) {
      timers.set(nextTimer, callback);
      return nextTimer++;
    },
    clearTimer: (handle) => void timers.delete(handle as number),
    channel(onMessage) {
      channelOpen = true;
      return { post: () => messages.push(onMessage), close: () => void (channelOpen = false) };
    },
    visibility: () => "visible",
    onVisibilityChange() {
      visibilityListeners += 1;
      return () => void (visibilityListeners -= 1);
    },
    observe(type, onEntries) {
      observers.set(type, onEntries);
      return { disconnect: () => void observers.delete(type) };
    },
    supportedEntryTypes: () => ["long-animation-frame", "layout-shift"],
  };
  return {
    env,
    advance: (ms: number) => void (clock += ms),
    /** Runs the pending frame callbacks at the current time. */
    frame() {
      const due = [...frames.values()];
      frames.clear();
      for (const callback of due) callback(clock);
    },
    /** Delivers the posted messages (the task after the frame painted). */
    paint() {
      for (const run of messages.splice(0)) run();
    },
    finish() {
      for (const run of [...timers.values()]) run();
    },
    observers,
    live: () => ({ frames: frames.size, timers: timers.size, observers: observers.size, channelOpen, visibilityListeners }),
  };
}

describe("chat perf capture: the window", () => {
  test("times each arriving record to the first painted frame and removes everything after", async () => {
    const page = fakeEnv();
    const recorder = new ChatPerfCapture();
    recorder.arrived("tool_call", 0, 0);
    expect(recorder.active).toBe(false);
    const running = recorder.capture({ seconds: 1 }, page.env);
    expect(recorder.active).toBe(true);
    expect(page.live()).toEqual({ frames: 1, timers: 1, observers: 2, channelOpen: true, visibilityListeners: 1 });
    for (let index = 0; index < 4; index += 1) {
      page.advance(16);
      page.frame();
      page.paint();
    }
    // A tool call arrives, takes 4 ms to apply, and the frame after it paints 16 ms after it arrived.
    recorder.arrived("tool_call", 70, 74);
    page.advance(20);
    page.frame();
    page.advance(2);
    page.paint();
    page.observers.get("long-animation-frame")?.([{ duration: 80, scripts: [] }]);
    page.observers.get("layout-shift")?.([{ value: 0.2 }]);
    page.finish();
    const report = (await running) as Record<string, any>;
    expect(recorder.active).toBe(false);
    expect(page.live()).toEqual({ frames: 0, timers: 0, observers: 0, channelOpen: false, visibilityListeners: 0 });
    expect(report.records.tool_call.count).toBe(1);
    expect(report.records.tool_call.to_paint.max_ms).toBe(16);
    expect(report.records.tool_call.apply.max_ms).toBe(4);
    expect(report.frames.count).toBe(5);
    expect(report.long_tasks.count).toBe(1);
    expect(report.long_tasks.source).toBe("long-animation-frame");
    expect(report.layout_shift).toEqual({ count: 1, sum: 0.2 });
    expect(report.measured).toBe(true);
    // After the window, records cost one check and are not kept.
    recorder.arrived("tool_call", 0, 0);
    expect(page.live().frames).toBe(0);
  });

  test("a second capture while one runs is refused, and a page with no frames says so", async () => {
    const page = fakeEnv();
    const recorder = new ChatPerfCapture();
    const running = recorder.capture({ seconds: 2 }, page.env);
    expect(await recorder.capture({ seconds: 1 }, page.env)).toEqual({ error: "capture_running" });
    page.finish();
    const report = (await running) as Record<string, any>;
    expect(report.measured).toBe(false);
    expect(report.unmeasured_reason).toBe("no_frames");
    expect(page.live().observers).toBe(0);
  });
});
