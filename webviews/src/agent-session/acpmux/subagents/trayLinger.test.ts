// l10n-allow-file: test fixture names, not shipped UI.
// What ended stays in the composer hat for a grace, then goes; never while the hat is held (Leo,
// 2026-11-07: "if you have things expanded and you're looking at them, they shouldn't just disappear
// like that"). trayLinger.ts, with an injected clock.
import { describe, expect, test } from "bun:test";
import { createLinger, lingeringTrayItems, stepLinger } from "./trayLinger";
import type { TrayItem } from "./runningTray";

const GRACE = 1_000;
const command = (id: string, state: "running" | "completed" | "failed", extra: object = {}): TrayItem => ({
  kind: "command",
  id,
  command: { id, command: `echo ${id}`, state, toolCallId: id, startedAt: 0, ...extra },
});

describe("trayLinger", () => {
  test("a command seen running stays as done after it ends, then expires after the grace", () => {
    const linger = createLinger();
    stepLinger(linger, { live: ["command:c1"], ended: [], hold: false, now: 0, grace: GRACE });
    const ended = stepLinger(linger, { live: [], ended: [{ key: "command:c1" }], hold: false, now: 100, grace: GRACE });
    expect([...ended.kept.keys()]).toEqual(["command:c1"]);
    expect(ended.next).toBe(1_100);
    const before = stepLinger(linger, {
      live: [],
      ended: [{ key: "command:c1" }],
      hold: false,
      now: 1_099,
      grace: GRACE,
    });
    expect(before.kept.has("command:c1")).toBe(true);
    const after = stepLinger(linger, {
      live: [],
      ended: [{ key: "command:c1" }],
      hold: false,
      now: 1_100,
      grace: GRACE,
    });
    expect(after.kept.size).toBe(0);
    expect(after.next).toBeUndefined();
    // Gone stays gone while it stays ended.
    const later = stepLinger(linger, {
      live: [],
      ended: [{ key: "command:c1" }],
      hold: false,
      now: 1_200,
      grace: GRACE,
    });
    expect(later.kept.size).toBe(0);
  });

  test("while the hat is held nothing expires; after it folds the rest of the grace resumes", () => {
    const linger = createLinger();
    stepLinger(linger, { live: ["command:c1"], ended: [], hold: false, now: 0, grace: GRACE });
    const ended = [{ key: "command:c1" }];
    stepLinger(linger, { live: [], ended, hold: false, now: 0, grace: GRACE });
    // 400 ms unheld, then held for a long read.
    const held = stepLinger(linger, { live: [], ended, hold: true, now: 400, grace: GRACE });
    expect(held.next).toBeUndefined();
    const longRead = stepLinger(linger, { live: [], ended, hold: true, now: 60_000, grace: GRACE });
    expect(longRead.kept.has("command:c1")).toBe(true);
    expect(longRead.next).toBeUndefined();
    // Folded at 60 s: 600 ms of grace left.
    const folded = stepLinger(linger, { live: [], ended, hold: false, now: 60_000, grace: GRACE });
    expect(folded.kept.has("command:c1")).toBe(true);
    expect(folded.next).toBe(60_600);
    expect(stepLinger(linger, { live: [], ended, hold: false, now: 60_599, grace: GRACE }).kept.size).toBe(1);
    expect(stepLinger(linger, { live: [], ended, hold: false, now: 60_600, grace: GRACE }).kept.size).toBe(0);
  });

  test("history this view never watched does not show as just finished; a recent known end does", () => {
    const linger = createLinger();
    const step = stepLinger(linger, {
      live: [],
      ended: [
        { key: "agent:old", endedAt: -10_000 },
        { key: "agent:recent", endedAt: 800 },
        { key: "session:unknown" },
      ],
      hold: false,
      now: 1_000,
      grace: GRACE,
    });
    expect([...step.kept.keys()]).toEqual(["agent:recent"]);
    expect(step.kept.get("agent:recent")).toBe(800);
    expect(step.next).toBe(1_800);
  });

  test("a run that resumes under the same key starts a fresh grace when it ends again", () => {
    const linger = createLinger();
    const ended = [{ key: "agent:a" }];
    stepLinger(linger, { live: ["agent:a"], ended: [], hold: false, now: 0, grace: GRACE });
    stepLinger(linger, { live: [], ended, hold: false, now: 0, grace: GRACE });
    expect(stepLinger(linger, { live: [], ended, hold: false, now: 2_000, grace: GRACE }).kept.size).toBe(0);
    stepLinger(linger, { live: ["agent:a"], ended: [], hold: false, now: 3_000, grace: GRACE });
    expect(stepLinger(linger, { live: [], ended, hold: false, now: 3_500, grace: GRACE }).kept.size).toBe(1);
  });

  test("the same input at the same time gives the same answer (a render may run it twice)", () => {
    const linger = createLinger();
    stepLinger(linger, { live: ["command:c1"], ended: [], hold: false, now: 0, grace: GRACE });
    const input = { live: [], ended: [{ key: "command:c1" }], hold: true, now: 500, grace: GRACE };
    const once = stepLinger(linger, input);
    const twice = stepLinger(linger, input);
    expect([...twice.kept]).toEqual([...once.kept]);
    expect(stepLinger(linger, { ...input, hold: false, now: 900 }).next).toBe(1_900);
  });

  test("the ended items that stay, latest first; a finished command takes the end this view saw", () => {
    const items = [command("c1", "completed"), command("c2", "failed", { endedAt: 50 }), command("c3", "completed")];
    const kept = new Map([
      ["command:c1", 300],
      ["command:c2", 50],
    ]);
    const shown = lingeringTrayItems(items, kept);
    expect(shown.map((item) => item.id)).toEqual(["c1", "c2"]);
    expect(shown[0]!.kind === "command" && shown[0]!.command.endedAt).toBe(300);
    expect(shown[1]!.kind === "command" && shown[1]!.command.endedAt).toBe(50);
  });
});

describe("trayLinger review follow-ups", () => {
  test("F2: a completion delivered late while the hat was held all along does not expire at once", () => {
    const linger = createLinger();
    // Seen running, the hat held from the start; the end (stamped at 0) arrives after a 3-minute
    // reconnect.
    stepLinger(linger, { live: ["agent:a"], ended: [], hold: true, now: 0, grace: GRACE });
    const ended = [{ key: "agent:a", endedAt: 0 }];
    const late = stepLinger(linger, { live: [], ended, hold: true, now: 180_000, grace: GRACE });
    expect(late.kept.has("agent:a")).toBe(true);
    // It keeps its end for its order and time.
    expect(late.kept.get("agent:a")).toBe(0);
    // Folded: the whole grace is left, from when the hold ended.
    const folded = stepLinger(linger, { live: [], ended, hold: false, now: 200_000, grace: GRACE });
    expect(folded.kept.has("agent:a")).toBe(true);
    expect(folded.next).toBe(200_000 + GRACE);
    expect(stepLinger(linger, { live: [], ended, hold: false, now: 200_000 + GRACE, grace: GRACE }).kept.size).toBe(0);
  });
});
