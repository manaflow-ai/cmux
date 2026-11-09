// l10n-allow-file: test fixture names, not shipped UI.
// What ended stays in the composer hat for a grace, then goes; never while the hat is held (Leo,
// 2026-11-07: "if you have things expanded and you're looking at them, they shouldn't just disappear
// like that"). trayLinger.ts, with an injected clock.
import { describe, expect, test } from "bun:test";
import * as trayLinger from "./trayLinger";
import type { TrayItem } from "./runningTray";

const { createLinger, lingeringTrayItems, stepLinger } = trayLinger;

const GRACE = 1_000;
// The grace alone: no look cooldown and no leaving together (each has its own tests below).
const BASE = { grace: GRACE, cooldown: 0, together: 0 };
const command = (id: string, state: "running" | "completed" | "failed", extra: object = {}): TrayItem => ({
  kind: "command",
  id,
  command: { id, command: `echo ${id}`, state, toolCallId: id, startedAt: 0, ...extra },
});

describe("trayLinger", () => {
  test("a command seen running stays as done after it ends, then expires after the grace", () => {
    const linger = createLinger();
    stepLinger(linger, { live: ["command:c1"], ended: [], hold: false, now: 0, ...BASE });
    const ended = stepLinger(linger, { live: [], ended: [{ key: "command:c1" }], hold: false, now: 100, ...BASE });
    expect([...ended.kept.keys()]).toEqual(["command:c1"]);
    expect(ended.next).toBe(1_100);
    const before = stepLinger(linger, {
      live: [],
      ended: [{ key: "command:c1" }],
      hold: false,
      now: 1_099,
      ...BASE,
    });
    expect(before.kept.has("command:c1")).toBe(true);
    const after = stepLinger(linger, {
      live: [],
      ended: [{ key: "command:c1" }],
      hold: false,
      now: 1_100,
      ...BASE,
    });
    expect(after.kept.size).toBe(0);
    expect(after.next).toBeUndefined();
    // Gone stays gone while it stays ended.
    const later = stepLinger(linger, {
      live: [],
      ended: [{ key: "command:c1" }],
      hold: false,
      now: 1_200,
      ...BASE,
    });
    expect(later.kept.size).toBe(0);
  });

  test("while the hat is held nothing expires; after it folds the rest of the grace resumes", () => {
    const linger = createLinger();
    stepLinger(linger, { live: ["command:c1"], ended: [], hold: false, now: 0, ...BASE });
    const ended = [{ key: "command:c1" }];
    stepLinger(linger, { live: [], ended, hold: false, now: 0, ...BASE });
    // 400 ms unheld, then held for a long read.
    const held = stepLinger(linger, { live: [], ended, hold: true, now: 400, ...BASE });
    expect(held.next).toBeUndefined();
    const longRead = stepLinger(linger, { live: [], ended, hold: true, now: 60_000, ...BASE });
    expect(longRead.kept.has("command:c1")).toBe(true);
    expect(longRead.next).toBeUndefined();
    // Folded at 60 s: 600 ms of grace left.
    const folded = stepLinger(linger, { live: [], ended, hold: false, now: 60_000, ...BASE });
    expect(folded.kept.has("command:c1")).toBe(true);
    expect(folded.next).toBe(60_600);
    expect(stepLinger(linger, { live: [], ended, hold: false, now: 60_599, ...BASE }).kept.size).toBe(1);
    expect(stepLinger(linger, { live: [], ended, hold: false, now: 60_600, ...BASE }).kept.size).toBe(0);
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
      ...BASE,
    });
    expect([...step.kept.keys()]).toEqual(["agent:recent"]);
    expect(step.kept.get("agent:recent")).toBe(800);
    expect(step.next).toBe(1_800);
  });

  test("a run that resumes under the same key starts a fresh grace when it ends again", () => {
    const linger = createLinger();
    const ended = [{ key: "agent:a" }];
    stepLinger(linger, { live: ["agent:a"], ended: [], hold: false, now: 0, ...BASE });
    stepLinger(linger, { live: [], ended, hold: false, now: 0, ...BASE });
    expect(stepLinger(linger, { live: [], ended, hold: false, now: 2_000, ...BASE }).kept.size).toBe(0);
    stepLinger(linger, { live: ["agent:a"], ended: [], hold: false, now: 3_000, ...BASE });
    expect(stepLinger(linger, { live: [], ended, hold: false, now: 3_500, ...BASE }).kept.size).toBe(1);
  });

  test("the same input at the same time gives the same answer (a render may run it twice)", () => {
    const linger = createLinger();
    stepLinger(linger, { live: ["command:c1"], ended: [], hold: false, now: 0, ...BASE });
    const input = { live: [], ended: [{ key: "command:c1" }], hold: true, now: 500, ...BASE };
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
    stepLinger(linger, { live: ["agent:a"], ended: [], hold: true, now: 0, ...BASE });
    const ended = [{ key: "agent:a", endedAt: 0 }];
    const late = stepLinger(linger, { live: [], ended, hold: true, now: 180_000, ...BASE });
    expect(late.kept.has("agent:a")).toBe(true);
    // It keeps its end for its order and time.
    expect(late.kept.get("agent:a")).toBe(0);
    // Folded: the whole grace is left, from when the hold ended.
    const folded = stepLinger(linger, { live: [], ended, hold: false, now: 200_000, ...BASE });
    expect(folded.kept.has("agent:a")).toBe(true);
    expect(folded.next).toBe(200_000 + GRACE);
    expect(stepLinger(linger, { live: [], ended, hold: false, now: 200_000 + GRACE, ...BASE }).kept.size).toBe(0);
  });
});

// Leo, 2026-11-08: "i also feel like the hat auto removing/auto hiding stuff that's super done is
// maybe a bit jarring? we can maybe increase the ttl just a tad/not remove it for a bit if the user
// recently looked at it".
describe("trayLinger: a look buys time, and lines leave together", () => {
  const ended = [{ key: "command:c1" }];
  /// A linger that watched `command:c1` run and end at 0, under `cfg` (the app's defaults unset).
  const watched = (cfg: object = {}) => {
    const linger = createLinger();
    stepLinger(linger, { live: ["command:c1"], ended: [], hold: false, now: 0, ...cfg });
    stepLinger(linger, { live: [], ended, hold: false, now: 0, ...cfg });
    return linger;
  };
  /// When `command:c1` (ended at 0) leaves under the app's defaults, with `look` the hover's span.
  const removedAt = (look?: [number, number]) => {
    const linger = watched();
    if (look) {
      stepLinger(linger, { live: [], ended, hold: true, now: look[0] });
      return stepLinger(linger, { live: [], ended, hold: false, now: look[1] }).next;
    }
    return stepLinger(linger, { live: [], ended, hold: false, now: 1 }).next;
  };

  test("the app's grace is longer than the two minutes it was, with a cooldown and a together window", () => {
    expect(trayLinger.TRAY_LINGER_MS).toBe(180_000);
    expect(trayLinger.TRAY_LOOK_COOLDOWN_MS).toBe(30_000);
    expect(trayLinger.TRAY_LEAVE_TOGETHER_MS).toBe(20_000);
    // Never looked at: three minutes after it ended.
    expect(removedAt()).toBe(180_000);
    // A one-second hover at 100 s: the held second does not count.
    expect(removedAt([100_000, 101_000])).toBe(181_000);
    // A one-second hover at 175 s, just before it was due: it stays the cooldown after the look.
    expect(removedAt([175_000, 176_000])).toBe(206_000);
  });

  test("a line about to go when a look ends stays the cooldown after it", () => {
    const cfg = { grace: GRACE, cooldown: 500, together: 0 };
    const linger = watched(cfg);
    // 990 ms unseen-by-hover, then a 10 ms hover: 10 ms of grace were left.
    stepLinger(linger, { live: [], ended, hold: true, now: 990, ...cfg });
    const released = stepLinger(linger, { live: [], ended, hold: false, now: 1_000, ...cfg });
    expect(released.kept.has("command:c1")).toBe(true);
    expect(released.next).toBe(1_500);
    // The same pass again (a render may run it twice) buys nothing more.
    expect(stepLinger(linger, { live: [], ended, hold: false, now: 1_000, ...cfg }).next).toBe(1_500);
    expect(stepLinger(linger, { live: [], ended, hold: false, now: 1_499, ...cfg }).kept.size).toBe(1);
    expect(stepLinger(linger, { live: [], ended, hold: false, now: 1_500, ...cfg }).kept.size).toBe(0);
  });

  test("a look early in the grace leaves the rest of it as it was", () => {
    const cfg = { grace: 10_000, cooldown: 500, together: 0 };
    const linger = watched(cfg);
    stepLinger(linger, { live: [], ended, hold: true, now: 1_000, ...cfg });
    expect(stepLinger(linger, { live: [], ended, hold: false, now: 2_000, ...cfg }).next).toBe(11_000);
  });

  test("the grace counts only time the hat could be seen; out of sight, no timer runs", () => {
    const cfg = { ...BASE, seen: true };
    const linger = watched(cfg);
    stepLinger(linger, { live: [], ended, hold: false, now: 400, ...cfg });
    // Another window or app for a minute: nothing goes, and nothing is armed.
    const away = stepLinger(linger, { live: [], ended, hold: false, now: 400, ...cfg, seen: false });
    expect(away.next).toBeUndefined();
    expect(stepLinger(linger, { live: [], ended, hold: false, now: 60_400, ...cfg, seen: false }).kept.size).toBe(1);
    // Back: 600 ms of grace left, and seeing it again is no look (no cooldown).
    const back = stepLinger(linger, { live: [], ended, hold: false, now: 60_400, ...cfg, cooldown: 30_000 });
    expect(back.next).toBe(61_000);
    expect(stepLinger(linger, { live: [], ended, hold: false, now: 61_000, ...cfg }).kept.size).toBe(0);
  });

  test("lines due within the together window of the first leave with it, in one pass", () => {
    const linger = createLinger();
    const cfg = { grace: GRACE, cooldown: 0, together: 400 };
    stepLinger(linger, { live: ["command:a", "command:b", "command:c"], ended: [], hold: false, now: 0, ...cfg });
    const all = [{ key: "command:a" }, { key: "command:b" }, { key: "command:c" }];
    stepLinger(linger, { live: ["command:b", "command:c"], ended: [all[0]!], hold: false, now: 0, ...cfg });
    stepLinger(linger, { live: ["command:c"], ended: all.slice(0, 2), hold: false, now: 300, ...cfg });
    const lastly = stepLinger(linger, { live: [], ended: all, hold: false, now: 900, ...cfg });
    expect(lastly.next).toBe(1_000);
    // a is due at 1000; b (1300) is within 400 ms of it and goes with it; c (1900) stays.
    const due = stepLinger(linger, { live: [], ended: all, hold: false, now: 1_000, ...cfg });
    expect([...due.kept.keys()]).toEqual(["command:c"]);
    expect(due.next).toBe(1_900);
  });

  test("a look that ends lines up the lines it held, so they leave together", () => {
    const linger = createLinger();
    const cfg = { grace: GRACE, cooldown: 500, together: 100 };
    stepLinger(linger, { live: ["command:a", "command:b"], ended: [], hold: false, now: 0, ...cfg });
    const all = [{ key: "command:a" }, { key: "command:b" }];
    stepLinger(linger, { live: ["command:b"], ended: [all[0]!], hold: false, now: 0, ...cfg });
    stepLinger(linger, { live: [], ended: all, hold: false, now: 200, ...cfg });
    stepLinger(linger, { live: [], ended: all, hold: true, now: 900, ...cfg });
    // a had 100 ms left, b 300 ms: both stay the cooldown, to 1500, and go then.
    expect(stepLinger(linger, { live: [], ended: all, hold: false, now: 1_000, ...cfg }).next).toBe(1_500);
    expect(stepLinger(linger, { live: [], ended: all, hold: false, now: 1_500, ...cfg }).kept.size).toBe(0);
  });
});
