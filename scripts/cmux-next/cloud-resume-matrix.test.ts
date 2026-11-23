import { describe, expect, test } from "bun:test";
import { armOrder, parseServerTiming, parseWakeFacts, percentile, resumeMarkdown, type ResumeSample } from "./cloud-resume-matrix.ts";

describe("parseWakeFacts", () => {
  test("takes the gap spanning the event and the first relay line after it, guest clock corrected", () => {
    // The guest runs 2000 ms ahead of the runner; the event was at runner time 100_000.
    const t0 = 100_000;
    const out = [
      "@@now 112000", // exec sent 109_900, answered 110_100: midpoint 110_000, offset 2000
      "@@gap 90000 95000", // an earlier freeze: not this wake
      "@@gap 50000 102700", // the pause: spans guest 102_000; running 700 ms after the event
      "@@gap 103000 104500", // a second freeze after it
      "@@j 101.500 cmux-host: relay registration on r1: registered", // before the event: an earlier wake
      "@@j 103.900 cmux-host: relay registration on r1: registered",
      "@@j 102.950 cmux-host: notify event=resumed",
    ].join("\n");
    expect(parseWakeFacts(out, t0, 109_900, 110_100)).toEqual({ offset: 2000, running: 700, registered: 1900, resumed: 950 });
  });
  test("an unreadable guest gives nulls", () => {
    expect(parseWakeFacts("", 1, 2, 3)).toEqual({ offset: null, running: null, registered: null, resumed: null });
  });
});

test("parseServerTiming", () => {
  expect(parseServerTiming("provider;dur=812.4, vmapi;dur=40, total;desc=x;dur=1490")).toEqual({ provider: 812, vmapi: 40, total: 1490 });
  expect(parseServerTiming(null)).toBeUndefined();
});

test("armOrder rotates so no arm always goes first", () => {
  expect(armOrder(["direct", "platform", "send"], 0)).toEqual(["direct", "platform", "send"]);
  expect(armOrder(["direct", "platform", "send"], 1)).toEqual(["platform", "send", "direct"]);
});

test("percentile is nearest rank", () => {
  const xs = Array.from({ length: 20 }, (_, i) => i + 1);
  expect(percentile(xs, 50)).toBe(10);
  expect(percentile(xs, 95)).toBe(19);
  expect(percentile([], 50)).toBeNull();
});

test("resumeMarkdown judges first byte p95 against the direct answer's p95", () => {
  const s = (arm: ResumeSample["arm"], answered: number | null, fb: number): ResumeSample => ({ pause_s: 30, arm, i: 0, machine: "m", at: "", paused_ms: 30_000, answered_ms: answered, running_ms: null, registered_ms: null, first_byte_ms: fb, ack_ms: null, clock_offset_ms: 0, error: "" });
  const md = resumeMarkdown([s("direct", 800, 1500), s("platform", 1200, 2300), s("send", null, 2600)]);
  expect(md).toContain("| 30 s | platform | 1 | 0 | 1.20 / 1.20 | - / - | - / - | 2.30 / 2.30 | 1.50 |");
  expect(md).toContain("| 30 s | send | 1 | 0 | - / - | - / - | - / - | 2.60 / 2.60 | 1.80 |");
});
