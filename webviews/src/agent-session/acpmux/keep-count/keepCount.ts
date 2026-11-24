// The keep-running switch's count (cmuxterm-hq RFD 0135, Onboarding): "2 of 3 kept running", the
// awake hours behind them, and what flipping this chat's switch will do. The numbers and the
// choice of sentence are Rust's (cmux-cloud-start-core `keep_count`, op `cloud_hybrid_keep_count`);
// this file only names the wire shape and picks the strings.
import { useExperimentSwitch } from "../../../experiments/switches";
import type { StringKey, StringValues } from "../i18n";

/// The Settings > Advanced > Experiments switch (`experiments.keepRunningCount`, off by default) that
/// shows the count beside the keep-running switch.
export const KEEP_COUNT_SWITCH = "keepRunningCount";

/// Whether the keep-running switch's mount draws the count: off unless the person turned the
/// experiment on. The mount (the hybrid-chats Session Info row) reads this and keeps its own count
/// when it is off.
export function useKeepCountShown(): boolean {
  return useExperimentSwitch(KEEP_COUNT_SWITCH);
}

export type KeepPlan = "trial" | "intro" | "plus" | "pro" | "agents20" | "max";

export type KeepNext =
  | { do: "startsTrial"; slots: number; hours: number }
  | { do: "keeps"; after: number }
  | { do: "full" }
  | { do: "hoursUsedUp" }
  | { do: "frees"; after: number };

/// `cloud_hybrid_keep_count`'s answer (keep_count.rs `Count`).
export type KeepCount = {
  plan: KeepPlan | null;
  kept: number;
  slots: number;
  hoursUsed: number | null;
  hours: number | null;
  window: "week" | "month" | null;
  hoursLow: boolean;
  next: KeepNext;
};

export type KeepLine = { key: StringKey; values?: StringValues };

/// "2 of 3 kept running", or nothing with no plan (the next line says what turning it on starts).
export function countLine(count: KeepCount): KeepLine | undefined {
  if (count.plan === null) return undefined;
  return { key: "keepCount.ofSlots", values: { kept: count.kept, slots: count.slots } };
}

/// "41 of 100 hours used", when the hours were read.
export function hoursLine(count: KeepCount): KeepLine | undefined {
  if (count.hoursUsed === null || count.hours === null) return undefined;
  const key = count.window === "week" ? "keepCount.hoursWeek" : "keepCount.hours";
  return { key, values: { used: count.hoursUsed, hours: count.hours } };
}

/// What flipping the switch will do.
export function nextLine(count: KeepCount): KeepLine {
  const next = count.next;
  switch (next.do) {
    case "startsTrial":
      return { key: "keepCount.next.startsTrial", values: { slots: next.slots, hours: next.hours } };
    case "keeps":
      return { key: "keepCount.next.keeps", values: { after: next.after, slots: count.slots } };
    case "full":
      return { key: "keepCount.next.full", values: { slots: count.slots } };
    case "hoursUsedUp":
      return { key: "keepCount.next.hoursUsedUp" };
    case "frees":
      return { key: "keepCount.next.frees", values: { after: next.after, slots: count.slots } };
  }
}

/// The share of hours used, 0 to 1, for a meter; undefined when not read.
export function hoursShare(count: KeepCount): number | undefined {
  if (count.hoursUsed === null || !count.hours) return undefined;
  return Math.min(1, Math.max(0, count.hoursUsed / count.hours));
}

/// Pips draw one dot a slot up to this many; a bigger plan draws a bar instead.
export const MAX_PIPS = 10;
