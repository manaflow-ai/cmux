import { describe, expect, test } from "bun:test";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { sessionSummary, transcriptBackground } from "./sessionSummary";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

const call = (id: string, title: string, input: Record<string, unknown>, extra: Partial<Tool> = {}) => ({
  kind: "tool",
  text: title,
  tool: { id, title, status: "completed", inputSummary: JSON.stringify(input), startedAt: 1_000_000, ...extra },
});
const rows = (...items: ReturnType<typeof call>[]): AcpmuxRow[] => [
  { id: "r", version: 1, at: 1_000_000, kind: "activity", items },
];

describe("sessionSummary scheduled", () => {
  test("a wakeup's due time is its call's start plus its delay, clamped to Claude's 60 s ... 1 h", () => {
    const [short, long, plain] = sessionSummary(
      rows(
        call("w1", "ScheduleWakeup", { delaySeconds: 5, reason: "Soon" }),
        call("w2", "ScheduleWakeup", { delaySeconds: 99_999, reason: "Later" }),
        call("w3", "ScheduleWakeup", { delaySeconds: 240, prompt: "check CI" }),
      ),
    ).scheduled;
    expect(short).toMatchObject({ kind: "wakeup", text: "Soon", dueAt: 1_000_000 + 60_000 });
    expect(long).toMatchObject({ dueAt: 1_000_000 + 3_600_000 });
    expect(plain).toMatchObject({ text: "check CI", startedAt: 1_000_000, dueAt: 1_000_000 + 240_000 });
  });

  test("a cron job carries its schedule and recurrence, and a CronDelete naming its id cancels it", () => {
    const [kept, removed] = sessionSummary(
      rows(
        call(
          "c1",
          "CronCreate",
          { cron: "17 * * * *", prompt: "Hourly pass", recurring: false },
          { output: "Scheduled job ab12cd" },
        ),
        call(
          "c2",
          "CronCreate",
          { cron: "*/5 * * * *", prompt: "Poll" },
          { output: "Scheduled recurring job ef34gh (*/5 * * * *)" },
        ),
        call("d", "CronDelete", { id: "ef34gh" }, { startedAt: 2_000_000 }),
      ),
    ).scheduled;
    expect(kept).toMatchObject({ kind: "cron", cron: "17 * * * *", recurring: false });
    expect(kept!.cancelledAt).toBeUndefined();
    expect(removed).toMatchObject({ cron: "*/5 * * * *", cancelledAt: 2_000_000 });
  });

  test("a failed call is kept as failed, and the running count leaves it out", () => {
    const transcript = rows(
      call("w", "ScheduleWakeup", { delaySeconds: 60, reason: "ok" }),
      call("f", "ScheduleWakeup", { delaySeconds: 60, reason: "bad" }, { status: "failed" }),
    );
    expect(sessionSummary(transcript).scheduled.map((item) => [item.id, item.failed])).toEqual([
      ["w", undefined],
      ["f", true],
    ]);
    expect(transcriptBackground(transcript).scheduled).toBe(1);
  });
});
