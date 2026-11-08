import { describe, expect, test } from "bun:test";
import { chatSchedule, parseLoop } from "./schedule";

// A fixed local time: Sunday 8 November 2026, 10:00.
const NOW = new Date(2026, 10, 8, 10, 0, 0, 0);
const at = (hours: number, minutes: number, dayOffset = 0) =>
  new Date(2026, 10, 8 + dayOffset, hours, minutes, 0, 0).getTime();

describe("parseLoop", () => {
  test("an interval, then the prompt", () => {
    expect(parseLoop("5m check CI and fix what broke", NOW)).toEqual({
      kind: "set",
      request: { prompt: "check CI and fix what broke", everyMinutes: 5 },
    });
    expect(parseLoop("2h /babysit-prs", NOW)).toEqual({
      kind: "set",
      request: { prompt: "/babysit-prs", everyMinutes: 120 },
    });
  });

  test("idle, with a run limit and an end time", () => {
    expect(parseLoop("idle x5 until 18:00 keep going", NOW)).toEqual({
      kind: "set",
      request: { prompt: "keep going", idle: true, maxRuns: 5, until: at(18, 0) },
    });
  });

  test("at a time later today, or tomorrow once it passed", () => {
    expect(parseLoop("at 14:30 write the standup", NOW)).toEqual({
      kind: "set",
      request: { prompt: "write the standup", at: at(14, 30) },
    });
    expect(parseLoop("at 9am write the standup", NOW)).toEqual({
      kind: "set",
      request: { prompt: "write the standup", at: at(9, 0, 1) },
    });
  });

  test("controls for the chat's schedule", () => {
    expect(parseLoop("pause", NOW)).toEqual({ kind: "pause" });
    expect(parseLoop("resume", NOW)).toEqual({ kind: "resume" });
    expect(parseLoop("stop", NOW)).toEqual({ kind: "stop" });
    expect(parseLoop("off", NOW)).toEqual({ kind: "stop" });
  });

  test("anything else is no schedule", () => {
    expect(parseLoop("", NOW)).toBeUndefined();
    expect(parseLoop("5m", NOW)).toBeUndefined();
    expect(parseLoop("check CI", NOW)).toBeUndefined();
    expect(parseLoop("0m check CI", NOW)).toBeUndefined();
    expect(parseLoop("at noon check CI", NOW)).toBeUndefined();
    expect(parseLoop("idle x0 go", NOW)).toBeUndefined();
  });
});

describe("chatSchedule", () => {
  test("reads the daemon's schedule", () => {
    expect(
      chatSchedule({
        id: "sch-1",
        prompt: "check CI",
        trigger: { kind: "every", minutes: 5 },
        maxRuns: 3,
        runs: 1,
        nextRunAt: 42,
        paused: false,
        createdAt: 1,
      }),
    ).toEqual({
      id: "sch-1",
      prompt: "check CI",
      trigger: { kind: "every", minutes: 5 },
      maxRuns: 3,
      until: undefined,
      runs: 1,
      nextRunAt: 42,
      paused: false,
    });
  });

  test("none or a malformed one is undefined", () => {
    expect(chatSchedule(null)).toBeUndefined();
    expect(chatSchedule({ id: "x", prompt: "p", trigger: { kind: "cron" } })).toBeUndefined();
    expect(chatSchedule({ id: "x", trigger: { kind: "idle" } })).toBeUndefined();
  });
});
