// bench/paintWindow.ts reads a browser-wide trace: pages of one site share one renderer, so a reading for one page that
// counted every frame in the trace gave each of 20 idle chat pages the 40 main frames a second all 20 drew together
// (chat-100k-flat, run 44093806454). readPaintTrace scopes frames, paints, layout and style to the page's own frame.
import { describe, expect, test } from "bun:test";
import { readPaintTrace, type TraceEvent } from "../bench/paintWindow";

const PID = 10;
const MAIN = 1;
const COMPOSITOR = 2;
const meta: TraceEvent[] = [
  { name: "process_name", ph: "M", pid: PID, tid: 0, ts: 0, args: { name: "Renderer" } },
  { name: "thread_name", ph: "M", pid: PID, tid: MAIN, ts: 0, args: { name: "CrRendererMain" } },
  { name: "thread_name", ph: "M", pid: PID, tid: COMPOSITOR, ts: 0, args: { name: "Compositor" } },
];
/// One main frame of `frame` drawn on layer tree `tree`: its tree id, a begin, a draw, and (when `paint`) a paint.
const frameOf = (frame: string, tree: number, paint = false): TraceEvent[] => [
  { name: "SetLayerTreeId", ph: "I", pid: PID, tid: MAIN, ts: 1, args: { data: { frame, layerTreeId: tree } } },
  { name: "BeginMainThreadFrame", ph: "I", pid: PID, tid: MAIN, ts: 2, args: { layerTreeId: tree, data: {} } },
  { name: "UpdateLayoutTree", ph: "X", pid: PID, tid: MAIN, ts: 3, dur: 1000, args: { beginData: { frame } } },
  ...(paint
    ? [{ name: "Paint", ph: "X", pid: PID, tid: MAIN, ts: 4, dur: 2000, args: { data: { frame } } } as TraceEvent]
    : []),
  { name: "DrawFrame", ph: "I", pid: PID, tid: COMPOSITOR, ts: 5, args: { layerTreeId: tree } },
  { name: "RunTask", ph: "X", pid: PID, tid: MAIN, ts: 6, dur: 3000 },
];

describe("readPaintTrace", () => {
  // Page A (tree 1) drew 2 frames, one painted; page B (tree 2) drew 40, none painted, over 10 s.
  const events = [
    ...meta,
    ...frameOf("A", 1, true),
    ...frameOf("A", 1),
    ...Array.from({ length: 40 }, () => frameOf("B", 2)).flat(),
  ];

  test("a page's reading counts only its own frames, paints and style", () => {
    const a = readPaintTrace(events, 10, "A");
    expect(a.mainFramesPerS).toBe(0.2);
    expect(a.framesPerS).toBe(0.2);
    expect(a.paintsPerS).toBe(0.1);
    expect(a.styleMsPerS).toBeCloseTo(0.2);
    const b = readPaintTrace(events, 10, "B");
    expect(b.mainFramesPerS).toBe(4);
    expect(b.paintsPerS).toBe(0);
  });

  test("main-thread task time stays the renderer's, every page in it", () => {
    expect(readPaintTrace(events, 10, "A").taskMsPerS).toBeCloseTo(12.6);
  });

  test("with no page named, every renderer's frames count", () => {
    const all = readPaintTrace(events, 10);
    expect(all.mainFramesPerS).toBe(4.2);
    expect(all.paintsPerS).toBe(0.1);
  });

  test("a page that drew nothing in the window reads 0", () => {
    expect(readPaintTrace(events, 10, "C").mainFramesPerS).toBe(0);
  });
});
