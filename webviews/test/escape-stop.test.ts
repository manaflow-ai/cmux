// Esc on an empty composer stops a running turn only on a second press inside the window, unless
// Debug Settings' "Esc stops a turn on a double press" is off (escapeStop.ts, composerSettings.ts).
// The real pane's keys are covered by agent-pane-steer.test.ts.
import { describe, expect, test } from "bun:test";
import { DEFAULT_COMPOSER, readComposerSettings } from "../src/agent-session/acpmux/composerSettings";
import { ESCAPE_STOP_WINDOW_MS, escapeStopPress } from "../src/agent-session/acpmux/escapeStop";

describe("escapeStopPress", () => {
  test("the first press arms the stop and does not stop the turn", () => {
    expect(escapeStopPress(undefined, 1_000, true)).toEqual({ stop: false, armedAt: 1_000 });
  });

  test("a second press inside the window stops the turn", () => {
    expect(escapeStopPress(1_000, 1_000 + ESCAPE_STOP_WINDOW_MS - 1, true).stop).toBe(true);
    expect(escapeStopPress(1_000, 1_000 + ESCAPE_STOP_WINDOW_MS, true).stop).toBe(true);
  });

  test("a second press after the window arms the stop again", () => {
    const late = 1_000 + ESCAPE_STOP_WINDOW_MS + 1;
    expect(escapeStopPress(1_000, late, true)).toEqual({ stop: false, armedAt: late });
  });

  test("a clock that went back does not count as a double press", () => {
    expect(escapeStopPress(1_000, 900, true)).toEqual({ stop: false, armedAt: 900 });
  });

  test("with the Debug Settings toggle off, one press stops the turn", () => {
    expect(escapeStopPress(undefined, 1_000, false)).toEqual({ stop: true });
  });

  test("the window is browser focus mode's Esc Esc window, 1.6 s (plans/cmux-next/focus.md)", () => {
    expect(ESCAPE_STOP_WINDOW_MS).toBe(1_600);
  });
});

describe("escapeDoublePress setting", () => {
  test("is on by default, and when the host leaves it out", () => {
    expect(DEFAULT_COMPOSER.escapeDoublePress).toBe(true);
    expect(readComposerSettings({}).escapeDoublePress).toBe(true);
    expect(readComposerSettings({ escapeDoublePress: "no" }).escapeDoublePress).toBe(true);
  });

  test("the host can turn it off", () => {
    expect(readComposerSettings({ escapeDoublePress: false }).escapeDoublePress).toBe(false);
  });
});
