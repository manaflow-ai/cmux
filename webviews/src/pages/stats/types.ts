// The Stats page's op (`cmux.stats.summary`, hq#1920): the app relays it to acpmux's
// `_acpmux/stats`, which folds this machine's agent session logs. Counts and times only.

export const StatsOps = {
  /** `{days, tzOffsetMinutes}` → `StatsSummary`. */
  summary: "cmux.stats.summary",
} as const;

/** The ranges the page offers, in days. */
export const RANGES = [7, 30, 84] as const;
export type Range = (typeof RANGES)[number];

export interface HarnessStats {
  harness: string;
  sessions: number;
  turns: number;
  workingMs: number;
}

export interface DayStats {
  /** `YYYY-MM-DD` in the person's calendar. */
  day: string;
  turns: number;
  workingMs: number;
}

export interface StatsSummary {
  since: number;
  until: number;
  tzOffsetMinutes: number;
  sessions: number;
  turns: number;
  turnsCompleted: number;
  turnsCancelled: number;
  turnsFailed: number;
  prompts: number;
  steers: number;
  toolCalls: number;
  permissionRequests: number;
  permissionAuto: number;
  /**
   * Questions answered in range and those still open or lost; their sum is `permissionRequests`.
   * This and the fields to `limitErrors` are absent from an older acpmux.
   */
  permissionAnswered?: number;
  permissionUnanswered?: number;
  /** Ask to answer, summed over the answered questions, and the longest one. */
  permissionWaitMs?: number;
  permissionWaitMaxMs?: number;
  /** Times an agent hit a usage, rate or credit limit, or its account was refused. */
  limitErrors?: number;
  /** Agent turn time summed over sessions: two agents for an hour is two hours. */
  workingMs: number;
  /** Time agents waited on a permission answer. */
  waitingMs: number;
  peakParallel: number;
  peakParallelAt: number | null;
  harnesses: HarnessStats[];
  /** Active days only, oldest first. */
  days: DayStats[];
  /** Working ms per hour of the day, 0 to 23. */
  hours: number[];
  streak: { current: number; longest: number };
}
