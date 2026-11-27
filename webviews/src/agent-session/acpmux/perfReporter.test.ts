// The page's perf reporter (perfReporter.ts): nothing runs while the watch is off, a report holds
// what happened since the last one (renders reset, bytes summed by method), and the spans the page
// owns are assembled from their marks.
import { describe, expect, test } from "bun:test";
import { AcpmuxPerf } from "./perf";
import {
  bytesByMethod,
  keyPaintSpan,
  newChatSpan,
  pageLoadSpan,
  PerfReporter,
  renderDelta,
  workspaceSwitchSpan,
  type PerfReporterEnv,
  chatSwitchSpan,
  sendSpan,
} from "./perfReporter";
import { AcpWireLog } from "./wire";

function harness(extra: Partial<PerfReporterEnv> = {}) {
  const perf = new AcpmuxPerf();
  const wire = new AcpWireLog(
    () => 0,
    () => 0,
  );
  let clock = 1_000;
  const timers: (() => void)[] = [];
  const frames: ((time: number) => void)[] = [];
  const observed: string[] = [];
  const shiftObservers: ((entries: PerformanceEntry[]) => void)[] = [];
  const env: PerfReporterEnv = {
    perf,
    wire,
    now: () => clock,
    wall: () => clock,
    every: (run) => {
      timers.push(run);
      return timers.length;
    },
    stopEvery: (handle) => {
      if (typeof handle === "number") timers[handle - 1] = () => undefined;
    },
    frame: (run) => frames.push(run),
    cancelFrame: () => void frames.splice(0),
    observe: (type, onEntries) => {
      observed.push(type);
      if (type !== "layout-shift") return undefined;
      shiftObservers.push(onEntries);
      return () => void shiftObservers.splice(shiftObservers.indexOf(onEntries), 1);
    },
    ...extra,
  };
  const sent: Record<string, unknown>[] = [];
  let answer: unknown = { on: true };
  const send = async (params: Record<string, unknown>) => {
    sent.push(params);
    return answer;
  };
  const reporter = new PerfReporter(env);
  return {
    perf,
    wire,
    reporter,
    sent,
    send,
    timers,
    frames,
    observed,
    shiftObservers,
    now: () => clock,
    advance: (ms: number) => (clock += ms),
    answer: (next: unknown) => (answer = next),
  };
}

const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

describe("while off", () => {
  test("a status answer of off registers nothing and sends nothing more", async () => {
    const h = harness();
    h.answer({ on: false });
    h.reporter.attach(h.send);
    await flush();
    expect(h.sent).toEqual([{ op: "status" }]);
    expect(h.reporter.on).toBe(false);
    expect(h.timers.length).toBe(0);
    expect(h.observed).toEqual([]);
    expect(h.frames.length).toBe(0);
    expect(h.perf.enabled).toBe(false);
    expect(h.perf.markListener).toBeUndefined();
    h.perf.render("Row");
    h.reporter.tick();
    expect(h.sent.length).toBe(1);
  });

  test("the status read happens once per page", async () => {
    const h = harness();
    h.answer({ on: false });
    h.reporter.attach(h.send);
    h.reporter.attach(h.send);
    await flush();
    expect(h.sent.length).toBe(1);
  });

  test("turning off removes every timer, observer and listener and restores measuring", async () => {
    const h = harness();
    h.reporter.attach(h.send);
    await flush();
    expect(h.reporter.on).toBe(true);
    expect(h.perf.enabled).toBe(true);
    expect(h.timers.length).toBe(1);
    expect(h.observed).toEqual(["long-animation-frame", "longtask", "layout-shift"]);
    expect(h.shiftObservers.length).toBe(1);
    h.reporter.setOn(false);
    expect(h.perf.enabled).toBe(false);
    expect(h.perf.markListener).toBeUndefined();
    expect(h.frames.length).toBe(0);
    expect(h.shiftObservers.length).toBe(0);
    h.perf.render("Row");
    h.timers[0]!();
    expect(h.sent.length).toBe(1);
  });

  test("a report answered off stops the reporter", async () => {
    const h = harness();
    h.reporter.attach(h.send);
    await flush();
    h.perf.render("Row");
    h.answer({ on: false });
    h.timers[0]!();
    await flush();
    expect(h.sent.at(-1)?.op).toBe("report");
    expect(h.reporter.on).toBe(false);
  });

  test("a quiet page sends an empty report every few seconds and hears an off from another client", async () => {
    const h = harness();
    h.reporter.attach(h.send);
    await flush();
    h.timers[0]!();
    expect(h.sent.length).toBe(1);
    h.advance(5_000);
    h.answer({ on: false });
    h.timers[0]!();
    await flush();
    expect(h.sent.at(-1)).toMatchObject({ op: "report", spans: [], renders: {}, frames: [], bytes: [] });
    expect(h.reporter.on).toBe(false);
  });

  test("a page shown while off asks again, at most every 10 s, and turns on with the watch", async () => {
    const h = harness();
    h.answer({ on: false });
    h.reporter.attach(h.send);
    await flush();
    h.reporter.visibilityChanged(true);
    expect(h.sent.length).toBe(1);
    h.reporter.visibilityChanged(false);
    expect(h.sent.length).toBe(1);
    h.advance(10_000);
    h.answer({ on: true });
    h.reporter.visibilityChanged(true);
    await flush();
    expect(h.sent.at(-1)).toEqual({ op: "status" });
    expect(h.reporter.on).toBe(true);
  });

  test("a page measuring for a debug bench stays measuring when the watch goes off", () => {
    const h = harness();
    h.perf.enabled = true;
    h.reporter.setOn(true);
    h.reporter.setOn(false);
    expect(h.perf.enabled).toBe(true);
  });
});

describe("batching", () => {
  test("renders are counted since the last report, then reset", () => {
    const h = harness();
    h.reporter.setOn(true);
    h.perf.render("Transcript");
    h.perf.render("Transcript");
    h.perf.render("Composer");
    h.advance(1_000);
    const first = h.reporter.buildReport()!;
    expect(first.renders).toEqual({ Transcript: 2, Composer: 1 });
    expect(first.windowMs).toBe(1_000);
    h.perf.render("Transcript");
    h.advance(500);
    const second = h.reporter.buildReport()!;
    expect(second.renders).toEqual({ Transcript: 1 });
    expect(second.windowMs).toBe(500);
    expect(h.reporter.buildReport()).toBeUndefined();
  });

  test("renders before the watch turned on are not counted", () => {
    const h = harness();
    h.perf.enabled = true;
    h.perf.render("Transcript");
    h.reporter.setOn(true);
    h.perf.render("Transcript");
    expect(h.reporter.buildReport()!.renders).toEqual({ Transcript: 1 });
  });

  test("bytes are summed by method since the last report, the watch's own left out", () => {
    const h = harness();
    h.wire.sent("x".repeat(10), "session/list", 1);
    h.reporter.setOn(true);
    h.wire.sent("y".repeat(100), "_acpmux/events", 2);
    h.wire.received(JSON.stringify({ id: 2, result: { pad: "z".repeat(50) } }));
    h.wire.sent("w".repeat(40), "_acpmux/events", 3);
    h.wire.sent("p".repeat(999), "_acpmux/perf", 4);
    h.wire.received(JSON.stringify({ method: "session/update", params: {} }));
    const report = h.reporter.buildReport()!;
    const response = JSON.stringify({ id: 2, result: { pad: "z".repeat(50) } }).length;
    const update = JSON.stringify({ method: "session/update", params: {} }).length;
    expect(report.bytes).toEqual([
      { label: "_acpmux/events", bytes: 100 + response + 40 },
      { label: "session/update", bytes: update },
    ]);
    expect(h.reporter.buildReport()).toBeUndefined();
  });

  test("one report a tick, none while the last is out, none when nothing happened", async () => {
    const h = harness();
    h.reporter.attach(h.send);
    await flush();
    h.timers[0]!();
    expect(h.sent.length).toBe(1);
    h.perf.render("Row");
    h.timers[0]!();
    h.perf.render("Row");
    h.timers[0]!();
    expect(h.sent.length).toBe(2);
    await flush();
    h.timers[0]!();
    expect(h.sent.length).toBe(3);
    expect(h.sent[2]!.renders).toEqual({ Row: 1 });
  });

  test("layout shifts say whether they came after the first paint", () => {
    const h = harness();
    h.reporter.setOn(true);
    h.perf.markLaunch("painted", performance.timeOrigin + 500);
    h.shiftObservers[0]!([
      { value: 0.2, startTime: 600, hadRecentInput: false, sources: [] } as unknown as PerformanceEntry,
      { value: 0.1, startTime: 100, hadRecentInput: false } as unknown as PerformanceEntry,
      { value: 0.3, startTime: 700, hadRecentInput: true } as unknown as PerformanceEntry,
    ]);
    expect(h.reporter.buildReport()!.layoutShifts).toEqual([
      { score: 0.2, afterPaint: true, what: "" },
      { score: 0.1, afterPaint: false, what: "" },
    ]);
  });

  test("the flicker log's long frames count only when the engine reports none", () => {
    const h = harness();
    h.reporter.setOn(true);
    h.reporter.longFrame(120.4);
    expect(h.reporter.buildReport()!.frames).toEqual([120]);
  });
});

describe("spans", () => {
  test("a new chat: handshake, composer, first token; the person's typing is left out", () => {
    const span = newChatSpan({
      handshakeStart: 100,
      handshakeReady: 300,
      composerReady: 350,
      promptSent: 5_350,
      firstToken: 6_350,
    })!;
    expect(span).toEqual({
      name: "new chat",
      budget: "chat.first_token",
      ms: 1_250,
      parts: [
        { name: "handshake", startMs: 0, ms: 200 },
        { name: "composer ready", startMs: 200, ms: 50 },
        { name: "first token", startMs: 250, ms: 1_000 },
      ],
      detail: { waitedMs: 5_000 },
    });
  });

  test("a chat whose first token came before its first prompt is not a new chat", () => {
    expect(newChatSpan({ handshakeStart: 0, promptSent: 900, firstToken: 400 })).toBeUndefined();
    expect(newChatSpan({ handshakeStart: 0, firstToken: 400 })).toBeUndefined();
  });

  test("the reporter sends one new-chat span per handshake", () => {
    const h = harness();
    h.reporter.setOn(true);
    h.perf.markAgent("handshakeStart");
    h.perf.markAgent("handshakeReady");
    h.perf.markAgent("composerReady");
    h.perf.markAgent("promptSent");
    h.perf.markAgent("firstToken");
    h.perf.markAgent("firstToken");
    const spans = h.reporter.buildReport()!.spans;
    expect(spans.map((span) => span.name)).toEqual(["new chat"]);
    expect(spans[0]!.parts.map((part) => part.name)).toEqual(["handshake", "composer ready", "first token"]);
  });

  test("a page load: navigation to first paint, each launch mark a part", () => {
    const span = pageLoadSpan({
      page_origin_epoch_ms: 10_000,
      connectStart_epoch_ms: 10_050,
      connected_epoch_ms: 10_200,
      transcriptMount_epoch_ms: 10_250,
      painted_epoch_ms: 10_400,
      firstEvent_epoch_ms: 10_500,
      handshake_attempts: 1,
    })!;
    expect(span.name).toBe("page load");
    expect(span.budget).toBe("page.load");
    expect(span.ms).toBe(400);
    expect(span.parts).toEqual([
      { name: "connect start", startMs: 0, ms: 50 },
      { name: "connected", startMs: 50, ms: 150 },
      { name: "transcript mount", startMs: 200, ms: 50 },
      { name: "first paint", startMs: 250, ms: 150 },
      { name: "first event", startMs: 400, ms: 100 },
    ]);
    expect(pageLoadSpan({ page_origin_epoch_ms: 1, connected_epoch_ms: 2 })).toBeUndefined();
  });

  test("a workspace switch: shown, first frame, two quiet frames", () => {
    expect(workspaceSwitchSpan(1_000, 1_016, 1_050, true)).toEqual({
      name: "workspace switch",
      budget: "workspace.switch",
      ms: 50,
      parts: [
        { name: "first frame", startMs: 0, ms: 16 },
        { name: "settled", startMs: 16, ms: 34 },
      ],
    });
  });

  test("the reporter times a switch until the transcript stops being replaced", () => {
    const h = harness();
    h.reporter.setOn(true);
    h.reporter.visibilityChanged(true);
    const frame = (time: number) => h.frames.shift()!(time);
    frame(1_016);
    h.reporter.transcriptReplaced();
    frame(1_032);
    frame(1_048);
    frame(1_064);
    expect(h.frames.length).toBe(0);
    const [span] = h.reporter.buildReport()!.spans;
    expect(span!.name).toBe("workspace switch");
    expect(span!.ms).toBe(64);
    expect(span!.parts).toEqual([
      { name: "first frame", startMs: 0, ms: 16 },
      { name: "settled", startMs: 16, ms: 48 },
    ]);
  });

  test("a switch hidden again before it settles is dropped", () => {
    const h = harness();
    h.reporter.setOn(true);
    h.reporter.visibilityChanged(true);
    h.reporter.visibilityChanged(false);
    expect(h.frames.length).toBe(0);
    expect(h.reporter.buildReport()).toBeUndefined();
  });
});

describe("key to paint", () => {
  const key = (paint: number, extra: Record<string, number> = {}) => ({
    key: "a",
    listener: 1,
    work: 2,
    frame: paint - 1,
    paint,
    chars: 5_000,
    next_frame_ms: 16.7,
    paint_epoch_ms: 1_000,
    ...extra,
  });

  test("the slowest key is the total and its stages the parts; every key's paint is in the detail", () => {
    const span = keyPaintSpan([key(10), key(40), key(12, { chars: 4 })], 16.7)!;
    expect(span.name).toBe("key to paint");
    expect(span.budget).toBe("composer.key_paint");
    expect(span.ms).toBe(40);
    expect(span.parts.map((part) => part.name)).toEqual(["listener", "edit", "frame", "paint"]);
    expect(span.parts.at(-1)).toEqual({ name: "paint", startMs: 39, ms: 1 });
    expect(span.detail).toMatchObject({ keys: 3, p50Ms: 12, p99Ms: 40, chars: 5_000, paintMs: [10, 40, 12] });
    // The 40 ms key's frame began 39 ms after its keydown: two vsyncs passed at 16.7 ms.
    expect(span.detail!.droppedFrames).toBe(2);
    expect(keyPaintSpan([])).toBeUndefined();
  });

  test("the reporter sends each key once, waiting a report for a key's frame-after mark", async () => {
    const h = harness();
    h.reporter.attach(h.send);
    await flush();
    h.perf.typing.push(key(10), key(11, { next_frame_ms: undefined as unknown as number }));
    h.perf.typingPushed += 2;
    h.timers[0]!();
    await flush();
    const first = h.sent.at(-1)!.spans as { name: string; detail: { keys: number } }[];
    expect(first.find((span) => span.name === "key to paint")?.detail.keys).toBe(1);
    h.perf.typing[1]!.next_frame_ms = 16.7;
    h.advance(1_000);
    h.timers[0]!();
    await flush();
    const second = h.sent.at(-1)!.spans as { name: string; detail: { keys: number; paintMs: number[] } }[];
    expect(second.find((span) => span.name === "key to paint")?.detail).toMatchObject({ keys: 1, paintMs: [11] });
  });

  test("keys typed before the watch turned on are not reported", async () => {
    const h = harness();
    h.perf.typing.push(key(10));
    h.perf.typingPushed += 1;
    h.reporter.attach(h.send);
    await flush();
    h.perf.render("Row");
    h.timers[0]!();
    await flush();
    expect((h.sent.at(-1)!.spans as unknown[]).length).toBe(0);
  });
});

describe("helpers", () => {
  test("renderDelta skips row mounts and counts remounts together", () => {
    const current = new Map([
      ["Row", 5],
      ["mount:a", 1],
      ["remount:a", 2],
      ["remount:b", 1],
    ]);
    expect(renderDelta(current, new Map([["Row", 2]]))).toEqual({ Row: 3, "row remount": 3 });
    // A count below its last one was reset meanwhile: all of it is new.
    expect(renderDelta(new Map([["Row", 1]]), new Map([["Row", 4]]))).toEqual({ Row: 1 });
  });

  test("bytesByMethod skips lifecycle entries and entries already reported", () => {
    const wire = new AcpWireLog(
      () => 0,
      () => 0,
    );
    wire.sent("aaaa", "a", 1);
    wire.lifecycle("close");
    wire.sent("bbbbbb", "b", 2);
    const entries = wire.entries();
    expect(bytesByMethod(entries, 0)).toEqual([
      { label: "b", bytes: 6 },
      { label: "a", bytes: 4 },
    ]);
    expect(bytesByMethod(entries, entries.find((entry) => entry.method === "a")!.seq)).toEqual([
      { label: "b", bytes: 6 },
    ]);
  });
});

const sendBase = {
  rowId: "local-p1",
  transport: "cloud" as const,
  freshChat: false,
  rows: 6,
  fromKey: true,
  shifts: 0,
  inputShifts: 0,
  shiftScore: 0,
  shiftWhat: [],
  shiftsObserved: true,
};

describe("the send span", () => {
  test("times Enter to the frame painting the sent row and the reserved turn, with the first token", () => {
    const span = sendSpan({
      ...sendBase,
      start: 100,
      userAt: 108,
      userFrame: 3,
      reservedAt: 108,
      reservedFrame: 3,
      tokenAt: 1_300,
      shifts: 1,
      shiftScore: 0.12345,
      shiftWhat: ["div.acpmux-row"],
    });
    expect(span.name).toBe("send");
    expect(span.budget).toBe("chat.send_paint");
    expect(span.ms).toBe(8);
    expect(span.parts.map((part) => part.name)).toEqual(["user row painted", "reserved turn painted", "first token"]);
    expect(span.detail).toEqual({
      firstTokenMs: 1_200,
      shifts: 1,
      inputShifts: 0,
      shiftScore: 0.1235,
      shiftWhat: ["div.acpmux-row"],
      reserved: true,
      painted: true,
      transport: "cloud",
      freshChat: false,
      rows: 6,
      fromKey: true,
    });
  });

  test("a reserved turn a frame later is not the same frame, and the span runs to it", () => {
    const span = sendSpan({ ...sendBase, start: 0, userAt: 8, userFrame: 1, reservedAt: 25, reservedFrame: 2 });
    expect(span.ms).toBe(25);
    expect(span.detail?.reserved).toBe(false);
    expect(span.detail?.firstTokenMs).toBeNull();
  });

  test("an unpainted send is timed to its limit, and an engine without layout-shift says null", () => {
    const span = sendSpan({ ...sendBase, start: 0, shiftsObserved: false });
    expect(span.ms).toBe(5_000);
    expect(span.detail?.painted).toBe(false);
    expect(span.detail?.shifts).toBeNull();
    expect(span.detail?.shiftScore).toBeNull();
  });
});

describe("the chat switch span", () => {
  test("times the pick to the paint of the new chat's rows, with when it settled", () => {
    const span = chatSwitchSpan(
      {
        start: 10,
        sessionId: "s2",
        transport: () => "local",
        before: new Set(),
        frames: 4,
        paintedAt: 22,
        rows: 9,
        quiet: 2,
        settledAt: 60,
      },
      60,
    );
    expect(span).toEqual({
      name: "chat switch",
      budget: "chat.switch_paint",
      ms: 12,
      parts: [
        { name: "rows painted", startMs: 0, ms: 12 },
        { name: "settled", startMs: 12, ms: 38 },
      ],
      detail: { rows: 9, transport: "local", settledMs: 50, painted: true },
    });
  });
});

function drawn() {
  const page = { ids: ["a", "b"], user: false, reserved: false };
  const probe = {
    sendRows: () => ({ user: page.user, reserved: page.user && page.reserved }),
    rowIds: () => page.ids,
  };
  return { page, probe };
}

const runFrames = (frames: ((time: number) => void)[]) => {
  for (const run of frames.splice(0)) run(0);
};

const reportedSpans = (sent: Record<string, unknown>[]) =>
  sent.flatMap((params) => (params.op === "report" ? ((params.spans as { name: string }[]) ?? []) : []));

describe("per-send timing", () => {
  test("while off, a send mark costs one check and reaches nothing", () => {
    const { probe } = drawn();
    const h = harness({ probe, afterPaint: (run) => run() });
    h.perf.markSend(() => {
      throw new Error("read while off");
    });
    h.perf.markToken();
    h.perf.markChatSwitch("s2", () => {
      throw new Error("read while off");
    });
    expect(h.frames.length).toBe(0);
  });

  test("a send is timed to its rows' frame, its first token and the shifts over it, then reported", async () => {
    const { page, probe } = drawn();
    const h = harness({ probe, afterPaint: (run) => run() });
    h.reporter.attach(h.send);
    await flush();
    h.reporter.sendStarted({
      start: 1_000,
      fromKey: true,
      rowId: "local-p1",
      transport: "local",
      freshChat: true,
      rows: 2,
    });
    h.advance(4);
    runFrames(h.frames);
    page.user = true;
    h.advance(6);
    runFrames(h.frames);
    page.reserved = true;
    h.advance(16);
    runFrames(h.frames);
    expect(h.frames.length).toBe(0);
    h.shiftObservers[0]!([
      { startTime: 1_100, value: 0.2, hadRecentInput: false, sources: [] } as unknown as PerformanceEntry,
      { startTime: 1_101, value: 0.1, hadRecentInput: true, sources: [] } as unknown as PerformanceEntry,
    ]);
    h.advance(500);
    h.reporter.tokenCame(h.now());
    runFrames(h.frames);
    h.reporter.tick();
    await flush();
    expect(reportedSpans(h.sent).some((span) => span.name === "send")).toBe(false);
    h.advance(5_000);
    h.reporter.tick();
    await flush();
    const span = reportedSpans(h.sent).find((each) => each.name === "send") as ReturnType<typeof sendSpan>;
    expect(span.ms).toBe(26);
    expect(span.detail).toMatchObject({
      firstTokenMs: 526,
      shifts: 1,
      inputShifts: 1,
      reserved: false,
      painted: true,
      transport: "local",
      freshChat: true,
    });
  });

  test("a send with no first token goes out at the two-minute limit", async () => {
    const { page, probe } = drawn();
    page.user = page.reserved = true;
    const h = harness({ probe, afterPaint: (run) => run() });
    h.reporter.attach(h.send);
    await flush();
    h.reporter.sendStarted({ start: 1_000, fromKey: true, rowId: "r", transport: "remote", freshChat: false, rows: 3 });
    h.advance(8);
    runFrames(h.frames);
    h.advance(120_000);
    h.reporter.tick();
    await flush();
    const span = reportedSpans(h.sent).find((each) => each.name === "send") as ReturnType<typeof sendSpan>;
    expect(span.ms).toBe(8);
    expect(span.detail).toMatchObject({ firstTokenMs: null, reserved: true, transport: "remote" });
  });

  test("a chat switch is timed to the first frame with none of the old rows", async () => {
    const { page, probe } = drawn();
    const h = harness({ probe, afterPaint: (run) => run() });
    h.reporter.attach(h.send);
    await flush();
    h.reporter.chatSwitched("s2", 1_000, () => "cloud");
    h.advance(10);
    runFrames(h.frames);
    page.ids = ["c", "d", "e"];
    h.advance(10);
    runFrames(h.frames);
    h.advance(16);
    runFrames(h.frames);
    h.advance(16);
    runFrames(h.frames);
    expect(h.frames.length).toBe(0);
    h.reporter.tick();
    await flush();
    const span = reportedSpans(h.sent).find((each) => each.name === "chat switch") as ReturnType<typeof chatSwitchSpan>;
    expect(span.ms).toBe(20);
    expect(span.detail).toEqual({ rows: 3, transport: "cloud", settledMs: 52, painted: true });
  });
});
