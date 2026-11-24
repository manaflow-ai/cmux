// The chat simulator's recording window (scripts/chat-sim-watch.ts and chat-sim-follow.ts `--start/--end`).
// Leo, 2026-11-22: "that clip goes for 1 minute long and the only relevant and differentiating bit is at
// the last 10 seconds. so you guys need to be able to set these scenarios up faster and better and record
// better." A window read off a whole run's video finds the same steps the whole run played there.
import { describe, expect, test } from "bun:test";
import { playbackAt, playbackWindow } from "../src/agent-session/acpmux/sim/playback";

describe("chat-sim playback window", () => {
  test("each step's playback time is its scaled wait, bounded by the gap limits", () => {
    // waits of 10 ms (raised to 16), 1000 ms at x2 (500), an idle hour (capped at 1500)
    expect(playbackAt([0, 10, 1010, 3_601_010], 2, 16, 1500)).toEqual([0, 16, 516, 2016]);
    expect(playbackAt([], 1, 16, 1500)).toEqual([]);
  });

  test("a window plays the steps from its start through its end", () => {
    const playback = [0, 16, 516, 2016, 3000];
    expect(playbackWindow(playback, 500, 2016)).toEqual({ first: 2, end: 4 });
    expect(playbackWindow(playback, 0, Number.POSITIVE_INFINITY)).toEqual({ first: 0, end: 5 });
    expect(playbackWindow(playback, 9000, Number.POSITIVE_INFINITY)).toEqual({ first: 5, end: 5 });
  });
});
