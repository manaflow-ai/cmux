// An in-memory `cmux.stats.summary` provider for the browser dev loop (`/stats/?mock`) and the
// gallery: a deterministic few weeks of agent work, shaped like acpmux's `_acpmux/stats` answer.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { StatsOps, type DayStats, type StatsSummary } from "./types";

const DAY_MS = 86_400_000;
const HOUR_MS = 3_600_000;

/** `busy` is a working machine; `empty` has no sessions in range yet. */
export type MockStatsKind = "busy" | "empty";

export class MockStatsProvider implements PageClient {
  constructor(
    private readonly kind: MockStatsKind = "busy",
    private readonly failure?: { code: string; message: string },
  ) {}

  async call<R>(op: string, params: unknown): Promise<R> {
    if (this.failure) throw pageError(this.failure.code, this.failure.message);
    if (op !== StatsOps.summary) throw pageError("cmux.op.unknown", op);
    const { days = 84, tzOffsetMinutes = 0 } = (params ?? {}) as { days?: number; tzOffsetMinutes?: number };
    return mockSummary(this.kind, days, tzOffsetMinutes, Date.now()) as R;
  }

  async subscribe(): Promise<() => void> {
    return () => {};
  }

  handle(_op: string, _handler: PageHandler): () => void {
    return () => {};
  }
}

export function mockSummary(
  kind: MockStatsKind,
  rangeDays: number,
  tzOffsetMinutes: number,
  until: number,
): StatsSummary {
  const today = Math.floor((until + tzOffsetMinutes * 60_000) / DAY_MS);
  const days: DayStats[] = [];
  if (kind === "busy") {
    for (let day = today - rangeDays + 1; day <= today; day++) {
      // Weekends are light, one week in five is off: a deterministic stand-in for real use.
      const weekday = (((day + 4) % 7) + 7) % 7;
      const seed = (day * 2_654_435_761) % 997;
      if (weekday === 0 || seed % 5 === 0) continue;
      const hours = weekday === 6 ? 1 + (seed % 2) : 2 + (seed % 7);
      days.push({
        day: new Date(day * DAY_MS).toISOString().slice(0, 10),
        turns: hours * 6 + (seed % 9),
        workingMs: hours * HOUR_MS + (seed % 50) * 60_000,
      });
    }
  }
  const workingMs = days.reduce((sum, day) => sum + day.workingMs, 0);
  const turns = days.reduce((sum, day) => sum + day.turns, 0);
  const curve = [0, 0, 0, 0, 0, 0, 0, 1, 3, 6, 8, 7, 4, 6, 8, 9, 8, 6, 4, 3, 3, 2, 1, 0];
  const weight = curve.reduce((sum, value) => sum + value, 0);
  const share = (part: number) => Math.round(workingMs * part);
  return {
    since: until - rangeDays * DAY_MS,
    until,
    tzOffsetMinutes,
    sessions: Math.round(turns / 9),
    turns,
    turnsCompleted: Math.round(turns * 0.86),
    turnsCancelled: Math.round(turns * 0.1),
    turnsFailed: turns - Math.round(turns * 0.86) - Math.round(turns * 0.1),
    prompts: turns,
    steers: Math.round(turns * 0.12),
    toolCalls: turns * 14,
    permissionRequests: Math.round(turns * 0.3),
    permissionAuto: Math.round(turns * 0.9),
    permissionAnswered: Math.round(turns * 0.3) - Math.round(turns * 0.01),
    permissionUnanswered: Math.round(turns * 0.01),
    // Summed per question, so two open at once count twice: at least the time spent waiting.
    permissionWaitMs: Math.round(workingMs * 0.044),
    permissionWaitMaxMs: days.length ? 14 * 60_000 + 20_000 : 0,
    limitErrors: days.length ? 3 : 0,
    workingMs,
    waitingMs: Math.round(workingMs * 0.04),
    peakParallel: days.length ? 5 : 0,
    peakParallelAt: days.length ? until - 2 * DAY_MS : null,
    harnesses: days.length
      ? [
          {
            harness: "claude",
            sessions: Math.round(turns / 15),
            turns: Math.round(turns * 0.6),
            workingMs: share(0.6),
          },
          { harness: "codex", sessions: Math.round(turns / 30), turns: Math.round(turns * 0.3), workingMs: share(0.3) },
          {
            harness: "opencode",
            sessions: Math.round(turns / 90),
            turns: Math.round(turns * 0.1),
            workingMs: share(0.1),
          },
        ]
      : [],
    days,
    hours: curve.map((value) => share(value / weight)),
    streak: days.length ? { current: 4, longest: 11 } : { current: 0, longest: 0 },
  };
}
