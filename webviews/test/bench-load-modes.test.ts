// The load modes the web harnesses apply (bench/loadModes.ts) come from the shared registry, and each knob becomes
// the right call: 60 chunks/s is a delta every 16.7 ms, 2,000 lines/s of tool output is a tool call every N deltas
// (the mock's log is 300 lines), and the typing probe's raw arrays become the rows the design asks for (longest
// task, frames over 16 ms, keys that shared a frame). cmuxterm-hq docs/design/chat-instant-under-load.md, "The
// bench"; Leo, 2026-11-16: "but typing under load is not good enough".
import { describe, expect, test } from "bun:test";
import {
  GATE_P95_MS,
  MODES,
  TYPING_PROBE_SCRIPT,
  focusedStreamOptions,
  modeById,
  parseModes,
  summarizeTypingProbe,
  turnsForRows,
} from "../bench/loadModes";

describe("the shared load modes", () => {
  test("are the ones the design names, in order", () => {
    expect(MODES.map((mode) => mode.id)).toEqual(["L0", "L1", "L2", "L3", "L4", "L5"]);
    expect(GATE_P95_MS).toBe(16);
  });

  test("parse by id, by `all`, and by the words the bench used before", () => {
    expect(parseModes("all").length).toBe(MODES.length);
    expect(parseModes("L2,L5").map((mode) => mode.id)).toEqual(["L2", "L5"]);
    expect(parseModes("idle,stream").map((mode) => mode.id)).toEqual(["L0", "L1"]);
    expect(parseModes(undefined, "L4").map((mode) => mode.id)).toEqual(["L4"]);
  });

  test("refuse an unknown mode instead of measuring the wrong load", () => {
    expect(() => modeById("L9")).toThrow(/unknown load mode L9/);
  });

  test("rise from idle to everything at once", () => {
    const by = Object.fromEntries(MODES.map((mode) => [mode.id, mode]));
    expect(by.L0!.web).toMatchObject({ focusedStream: null, otherChats: 0, cpuSaturation: false, rows: null });
    expect(by.L1!.web.focusedStream).toEqual({ chunksPerSecond: 60, toolLinesPerSecond: 2000 });
    expect(by.L2!.web).toMatchObject({ otherChats: 10, otherChatChunksPerSecond: 30 });
    expect(by.L3!.web.rows).toBe(100_000);
    expect(by.L4!.web.cpuSaturation).toBe(true);
    expect(by.L5!.web).toMatchObject({ rows: 100_000, otherChats: 10, cpuSaturation: true });
    expect(by.L5!.web.focusedStream).toEqual(by.L1!.web.focusedStream);
  });

  test("say what a page harness cannot express, rather than dropping it quietly", () => {
    const l5 = modeById("L5");
    expect(l5.webMissing?.join(" ")).toContain("terminals");
    expect(modeById("L1").webMissing ?? []).toEqual([]);
  });
});

describe("a mode's knobs become the calls that put the page under it", () => {
  test("60 chunks a second is a delta every 16.7 ms", () => {
    const options = focusedStreamOptions({ chunksPerSecond: 60, toolLinesPerSecond: 2000 }, 5);
    expect(options.chunk_ms).toBe(17);
    expect(options.seconds).toBe(5);
    expect(options.scroll_speed).toBe(0);
  });

  test("2,000 tool lines a second is a tool call every 9 deltas (the mock's log is 300 lines)", () => {
    const options = focusedStreamOptions({ chunksPerSecond: 60, toolLinesPerSecond: 2000 }, 5);
    expect(options.tool_every).toBe(9);
    // 60 deltas/s / 9 deltas per tool call x 300 lines is 2,000 lines a second, within rounding.
    expect(Math.round((60 / options.tool_every) * 300)).toBeGreaterThan(1800);
    expect(Math.round((60 / options.tool_every) * 300)).toBeLessThan(2200);
  });

  test("no tool output asks for no tool calls", () => {
    expect(focusedStreamOptions({ chunksPerSecond: 30, toolLinesPerSecond: 0 }, 2).tool_every).toBe(0);
  });

  test("a row count becomes the seed's turns (a light turn is about three rows)", () => {
    expect(turnsForRows(100_000)).toBe(33_333);
    expect(turnsForRows(60)).toBe(20);
    expect(turnsForRows(1)).toBe(1);
  });
});

describe("the typing probe's rows", () => {
  test("count the keys that shared a frame with another key: a burst", () => {
    const probe = summarizeTypingProbe({
      longTasks: [20, 5, 60],
      frames: [8, 16, 17, 40],
      // Three keys drawn in frame 100 (a burst of three), one of its own in frame 200.
      keys: [
        [95, 100],
        [96, 100],
        [97, 100],
        [190, 200],
      ],
      longTaskSupport: true,
    });
    expect(probe.keys_sharing_a_frame).toBe(3);
    expect(probe.longest_task_ms).toBe(60);
    expect(probe.long_tasks).toBe(3);
    // 17 ms and 40 ms missed a 60 Hz frame; 16 ms did not.
    expect(probe.frames_over_16ms).toBe(2);
    expect(probe.frames).toBe(4);
  });

  test("report no long tasks where the engine has no long-task entries (WebKit), rather than zero", () => {
    const probe = summarizeTypingProbe({ longTasks: [], frames: [8], keys: [], longTaskSupport: false });
    expect(probe.longest_task_ms).toBeNull();
    expect(probe.long_tasks).toBeNull();
    expect(probe.keys_sharing_a_frame).toBe(0);
  });

  test("the page-side probe records nothing until the harness starts it", () => {
    // The probe must not hold a frame loop open while the page is meant to be idle (the design's idle budget).
    expect(TYPING_PROBE_SCRIPT).toContain("state.recording = false");
    expect(TYPING_PROBE_SCRIPT).toContain("state.start");
    expect(TYPING_PROBE_SCRIPT).toContain("state.stop");
  });
});
