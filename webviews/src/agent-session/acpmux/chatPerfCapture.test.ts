import { describe, expect, test } from "bun:test";
import {
  ChatPerfCapture,
  type CaptureEnv,
  arrivalSummary,
  captureKind,
  frameSummary,
  layoutShiftSummary,
  keydownSummary,
  longTaskSummary,
  scriptSource,
  unmeasuredReason,
  visibilitySummary,
} from "./chatPerfCapture";
import { startFrameOwners } from "./frameOwners";

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
          duration: 120, // motion-allow: a long-task entry's length, not motion
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
    // A longtask entry (no LoAF) has no blockingDuration: its blocking time is its duration past 50 ms.
    const fallback = longTaskSummary([{ duration: 120 }, { duration: 40 }, { duration: 51 }], "longtask"); // motion-allow: a long-task entry's length, not motion
    expect(fallback.blocking_ms).toBe(71);
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

  test("script time sums every script in long animation frames, not only the top list", () => {
    const scripts = Array.from({ length: 8 }, () => ({ invoker: "i", sourceURL: "u", duration: 10 }));
    const report = longTaskSummary([{ duration: 120, scripts }], "long-animation-frame");
    expect(report.script_ms).toBe(80);
    expect(report.top_scripts).toHaveLength(1);
    // A longtask entry carries no script attribution: no number, not zero.
    expect(longTaskSummary([{ duration: 120 }], "longtask").script_ms).toBeNull();
  });

  test("keydown-to-frame is the p95 of keydown entries, null when nobody typed", () => {
    const entries = [
      ...Array.from({ length: 20 }, (_, index) => ({ name: "keydown", duration: 16 + index * 8 })),
      { name: "pointerdown", duration: 400 },
    ];
    const typed = keydownSummary(entries);
    expect(typed.count).toBe(20);
    expect(typed.p95_ms).toBe(160);
    expect(typed.max_ms).toBe(168);
    expect(keydownSummary([{ name: "click", duration: 50 }])).toEqual({
      count: 0,
      threshold_ms: 16,
      p95_ms: null,
      max_ms: null,
    });
  });

  test("layout shift sums only shifts without recent input", () => {
    expect(
      layoutShiftSummary([
        { value: 0.1 },
        { value: 0.05, hadRecentInput: true },
        { value: 0.02, hadRecentInput: false },
      ]),
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
    // The end sample the capture always takes is no change, nor is an event that left the state as it was.
    const unchanged = [
      { at: 0, state: "visible" },
      { at: 2000, state: "visible" },
      { at: 5000, state: "visible" },
    ];
    expect(visibilitySummary(unchanged, 5000)).toEqual({ start: "visible", end: "visible", changes: 0, hidden_ms: 0 });
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
    supportedEntryTypes: () => ["long-animation-frame", "layout-shift", "event"],
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
      for (const run of timers.values()) run();
    },
    observers,
    live: () => ({
      frames: frames.size,
      timers: timers.size,
      observers: observers.size,
      channelOpen,
      visibilityListeners,
    }),
  };
}

describe("chat perf capture: a record's own paint", () => {
  // Leo, 2026-11-16: "it shuold be instant even under load". The capture counted the first frame after a
  // record arrived, drawn or not; the pane drew it a frame later, and the report read on time.
  test("a record drawn in a task after its frame counts the next frame's paint; one drawn in its frame, that frame's", async () => {
    const page = fakeEnv();
    let onDraw: () => void = () => {};
    page.env.watchDraws = (draw) => {
      onDraw = draw;
      return { disconnect: () => {} };
    };
    const recorder = new ChatPerfCapture();
    const running = recorder.capture({ seconds: 1 }, page.env);
    page.advance(16);
    page.frame();
    page.paint();
    // Drawn a frame late: arrives at 16, the frame at 266 paints without it, React draws it in a task after.
    recorder.arrived("tool_call", 16, 17);
    page.advance(250);
    page.frame();
    page.advance(10);
    page.paint();
    onDraw();
    page.advance(250);
    page.frame();
    page.advance(10);
    page.paint();
    // Drawn in its frame: arrives, then the frame's callbacks change the transcript before it paints.
    recorder.arrived("agent_message_chunk", page.env.now(), page.env.now());
    page.advance(250);
    page.frame();
    onDraw();
    page.advance(10);
    page.paint();
    page.finish();
    const report = (await running) as Record<string, any>;
    expect(report.records.tool_call.to_paint.max_ms).toBe(520);
    expect(report.records.agent_message_chunk.to_paint.max_ms).toBe(260);
    expect(report.records.unpainted).toBe(0);
  });
});

describe("chat perf capture: the window", () => {
  test("times each arriving record to the first painted frame and removes everything after", async () => {
    const page = fakeEnv();
    const recorder = new ChatPerfCapture();
    recorder.arrived("tool_call", 0, 0);
    expect(recorder.active).toBe(false);
    const running = recorder.capture({ seconds: 1 }, page.env);
    expect(recorder.active).toBe(true);
    expect(page.live()).toEqual({ frames: 1, timers: 1, observers: 3, channelOpen: true, visibilityListeners: 1 });
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
    page.observers.get("long-animation-frame")?.([{ duration: 80, scripts: [] }]); // motion-allow: a long-task entry's length, not motion
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
    expect(report.visibility.changes).toBe(0);
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

describe("chat perf capture: script, keydown and size", () => {
  test("the report carries script ms per second, keydown p95 and the shown chat's rows and events", async () => {
    const page = fakeEnv();
    const recorder = new ChatPerfCapture();
    const running = recorder.capture({ seconds: 2 }, page.env, () => ({ rows: 340, events: 5200 }));
    page.observers.get("long-animation-frame")?.([
      { duration: 120, scripts: [{ invoker: "a", sourceURL: "u", duration: 50 }] }, // motion-allow: a long-task entry's length, not motion
      { duration: 90, scripts: [{ invoker: "b", sourceURL: "u", duration: 30 }] }, // motion-allow: a long-task entry's length, not motion
    ]);
    page.observers.get("event")?.([
      { name: "keydown", duration: 24 },
      { name: "keydown", duration: 40 },
      { name: "pointerdown", duration: 300 },
    ]);
    page.finish();
    const report = (await running) as Record<string, any>;
    expect(report.long_tasks.script_ms).toBe(80);
    expect(report.script_ms_per_s).toBe(40);
    expect(report.keydown.count).toBe(2);
    expect(report.keydown.p95_ms).toBe(40);
    expect(report.transcript).toEqual({ rows: 340, events: 5200 });
    expect(page.live().observers).toBe(0);
  });

  test("nobody typing leaves keydown p95 null, and a page without the entry types leaves both null", async () => {
    const page = fakeEnv();
    const typed = new ChatPerfCapture().capture({ seconds: 1 }, page.env);
    page.finish();
    const report = (await typed) as Record<string, any>;
    expect(report.keydown.p95_ms).toBeNull();
    expect(report.transcript).toEqual({ rows: null, events: null });
    const bare = fakeEnv();
    bare.env.supportedEntryTypes = () => [];
    const none = new ChatPerfCapture().capture({ seconds: 1 }, bare.env);
    bare.finish();
    const bareReport = (await none) as Record<string, any>;
    expect(bareReport.script_ms_per_s).toBeNull();
    expect(bareReport.keydown).toBeNull();
  });
});

describe("chat perf capture: frame owners", () => {
  test("the report names the page code that asked for frames, apart from the capture's own loop", async () => {
    const page = fakeEnv();
    let pageRequests = 0;
    const host = {
      requestAnimationFrame: () => ++pageRequests,
      setTimeout: () => 0,
      setInterval: () => 0,
    };
    const original = host.requestAnimationFrame;
    page.env.startOwners = () => startFrameOwners({ host, animations: () => [], loadSites: async () => null });
    const recorder = new ChatPerfCapture();
    const running = recorder.capture({ seconds: 1 }, page.env);
    // Six capture frames; page code asks for one more frame in four of them, as a loop with no idle check does.
    for (let index = 0; index < 6; index += 1) {
      page.advance(16);
      page.frame();
      if (index < 4) host.requestAnimationFrame();
    }
    page.finish();
    const report = (await running) as Record<string, any>;
    expect(report.frames.count).toBe(6);
    expect(report.owners.page_frames).toBe(4);
    expect(report.owners.frames).toHaveLength(1);
    expect(report.owners.frames[0].count).toBe(4);
    expect(report.owners.frames[0].file).toContain("chatPerfCapture.test.ts");
    expect(pageRequests).toBe(4);
    // The page's own function is back once the window ends.
    expect(host.requestAnimationFrame).toBe(original);
  });

  test("a page at rest reports no owners while the capture still counts its own frames", async () => {
    const page = fakeEnv();
    const host = { requestAnimationFrame: () => 0, setTimeout: () => 0, setInterval: () => 0 };
    page.env.startOwners = () => startFrameOwners({ host, animations: () => [], loadSites: async () => null });
    const running = new ChatPerfCapture().capture({ seconds: 1 }, page.env);
    for (let index = 0; index < 3; index += 1) {
      page.advance(16);
      page.frame();
    }
    page.finish();
    const report = (await running) as Record<string, any>;
    expect(report.frames.count).toBe(3);
    expect(report.owners).toEqual({
      page_frames: 0,
      frames: [],
      timers: [],
      animate: [],
      animations: [],
      sites_resolved: false,
    });
  });
});
