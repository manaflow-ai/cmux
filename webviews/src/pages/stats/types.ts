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
  /** The person's opt-in usage patterns on this machine (cmux-usage-patterns); absent from an older acpmux. */
  usagePatterns?: UsagePatterns;
}

/** Opt-in local counters: `enabled` is the `diagnostics.usagePatterns` setting now. */
export interface UsagePatterns {
  enabled: boolean;
  rollup: {
    /** Unix ms of the first count kept, 0 for none. */
    since: number;
    updated: number;
    /** family → key → count. Keys are identifiers (command names, harness kinds), never content. */
    counts: Record<string, Record<string, number>>;
    /** UTC day → family → count. */
    days: Record<string, Record<string, number>>;
    hours: number[];
    peaks: Record<string, number>;
  };
}
