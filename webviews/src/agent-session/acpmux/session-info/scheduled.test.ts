import { describe, expect, test } from "bun:test";
import { translatorFor } from "../i18n";
import type { SummaryWakeup } from "../summary/sessionSummary";
import {
  nextScheduledChange,
  RECURRING_CRON_LIFETIME_MS,
  scheduledStatus,
  scheduledTimerDelay,
  scheduledTrailing,
  splitScheduled,
} from "./scheduled";

const t = translatorFor("en");
const MIN = 60_000;
const start = new Date(2026, 10, 3, 3, 0).getTime();

const wakeup = (id: string, delayMin: number, extra: Partial<SummaryWakeup> = {}): SummaryWakeup => ({
  id,
  text: `Wake ${id}`,
  kind: "wakeup",
  startedAt: start,
  dueAt: start + delayMin * MIN,
  ...extra,
});
const cron = (id: string, expression: string, extra: Partial<SummaryWakeup> = {}): SummaryWakeup => ({
  id,
  text: `Job ${id}`,
  kind: "cron",
  cron: expression,
  startedAt: start,
  ...extra,
});

describe("scheduledStatus", () => {
  test("a wakeup is ahead until its time, then done", () => {
    const item = wakeup("a", 4);
    expect(scheduledStatus(item, start + 3 * MIN)).toEqual({ state: "scheduled", dueAt: start + 4 * MIN });
    expect(scheduledStatus(item, start + 4 * MIN)).toEqual({ state: "done", endedAt: start + 4 * MIN });
  });

  test("a wakeup with no known time stays ahead", () => {
    expect(scheduledStatus(wakeup("a", 4, { dueAt: undefined }), start + 1e9).state).toBe("scheduled");
  });

  test("a recurring cron job expires after Claude's 7 days; a one-shot one is done after its run", () => {
    const hourly = cron("h", "17 * * * *");
    expect(scheduledStatus(hourly, start + 60 * MIN).state).toBe("scheduled");
    expect(scheduledStatus(hourly, start + RECURRING_CRON_LIFETIME_MS)).toEqual({
      state: "expired",
      endedAt: start + RECURRING_CRON_LIFETIME_MS,
    });
    const once = cron("o", "30 3 3 11 *", { recurring: false });
    expect(scheduledStatus(once, start + 29 * MIN).state).toBe("scheduled");
    expect(scheduledStatus(once, start + 30 * MIN)).toEqual({ state: "done", endedAt: start + 30 * MIN });
  });

  test("a cron job a CronDelete removed is cancelled; a failed call is failed", () => {
    expect(scheduledStatus(cron("c", "17 * * * *", { cancelledAt: start + 5 * MIN }), start + 6 * MIN)).toEqual({
      state: "cancelled",
      endedAt: start + 5 * MIN,
    });
    expect(scheduledStatus(wakeup("f", 4, { failed: true }), start).state).toBe("failed");
  });
});

describe("splitScheduled", () => {
  test("expired waits leave the active list and fold into finished, latest first", () => {
    const items = [wakeup("a", 2), wakeup("b", 10), wakeup("c", 5), cron("h", "17 * * * *")];
    const { active, finished } = splitScheduled(items, start + 6 * MIN);
    expect(active.map((entry) => entry.item.id)).toEqual(["b", "h"]);
    expect(finished.map((entry) => entry.item.id)).toEqual(["c", "a"]);
  });
});

describe("nextScheduledChange", () => {
  test("the earliest end still ahead, so one timer covers every item", () => {
    const items = [wakeup("a", 2), wakeup("b", 10), wakeup("c", 5)];
    expect(nextScheduledChange(items, start)).toBe(start + 2 * MIN);
    expect(nextScheduledChange(items, start + 3 * MIN)).toBe(start + 5 * MIN);
    expect(nextScheduledChange(items, start + 11 * MIN)).toBeUndefined();
    expect(nextScheduledChange([], start)).toBeUndefined();
  });
});

describe("scheduledTimerDelay", () => {
  test("a millisecond past the end, and never past setTimeout's longest wait", () => {
    expect(scheduledTimerDelay(start + 2 * MIN, start)).toBe(2 * MIN + 1);
    expect(scheduledTimerDelay(start, start + MIN)).toBe(1);
    // A one-shot cron job a month ahead: the timer fires at the cap and re-arms, never at once.
    expect(scheduledTimerDelay(start + 31 * 86_400_000, start)).toBe(2 ** 31 - 1);
  });
});

describe("scheduledTrailing", () => {
  const trailing = (item: SummaryWakeup, now: number) =>
    scheduledTrailing(t, "en-US", { item, status: scheduledStatus(item, now) });

  test("ahead: a cron job's schedule in words, a wakeup's time of day", () => {
    expect(trailing(cron("h", "17 * * * *"), start)).toBe("hourly at :17");
    expect(trailing(wakeup("a", 37), start)).toBe("3:37 AM");
  });

  test("ended: its state and, when it ran, how long it waited", () => {
    expect(trailing(wakeup("a", 4), start + 5 * MIN)).toBe("Done · 4m");
    expect(trailing(cron("h", "17 * * * *"), start + RECURRING_CRON_LIFETIME_MS)).toBe("Expired");
    expect(trailing(cron("c", "17 * * * *", { cancelledAt: start + MIN }), start + 2 * MIN)).toBe("Cancelled");
    expect(trailing(wakeup("f", 4, { failed: true }), start)).toBe("Failed");
  });
});
