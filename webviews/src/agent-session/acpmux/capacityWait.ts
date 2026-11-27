// A chat waiting for capacity (RFD model-overload-smoothing §3.8; Leo, 2026-11-24: "fix 529s
// properly with better designs", "send a fella to do the deep work + design and stuff to smooth
// over these siuations better pleaseeeeeee"). acpmux decides the wait (hub/capacity_wait.rs, the
// session row's `capacityWait`): which turn it continues, why, and when. The pane only words it:
// "Waiting for capacity, about 40 s" with a live countdown, the raw error under Details, and in a
// list "Paused for capacity, resumes ~22:41". Never red: red is a turn nothing will continue.
import { createContext } from "react";
import type { Translate } from "./i18n";
import { intl } from "../../ui/intl";

export type CapacityWaitState = {
  reason: "capacity" | "rate_limit";
  /** When it goes on (epoch ms); unknown while acpmux still decides. */
  resumesAt?: number;
  /** The cut turn it continues. */
  turnId?: string;
  /** Since when it waits (epoch ms). */
  since?: number;
  /** The harness's own error, for Details only. */
  error?: string;
};

/// The chat's wait, for its transcript (TurnRows.tsx): provided beside the chat's id (App.tsx).
export const CapacityWaitContext = createContext<(CapacityWaitState & { groupedHelpers?: boolean }) | undefined>(
  undefined,
);

const ms = (value: unknown) => (typeof value === "number" && Number.isFinite(value) && value > 0 ? value : undefined);
const words = (value: unknown, max: number) =>
  typeof value === "string" && value.trim() ? value.trim().slice(0, max) : undefined;

/// acpmux's `capacityWait` field, or undefined when the row says none (or an older acpmux).
export function readCapacityWait(raw: unknown): CapacityWaitState | undefined {
  if (!raw || typeof raw !== "object") return undefined;
  const value = raw as Record<string, unknown>;
  if (value.reason !== "capacity" && value.reason !== "rate_limit") return undefined;
  const resumesAt = ms(value.resumesAt);
  const since = ms(value.since);
  const turnId = words(value.turnId, 200);
  const error = words(value.error, 600);
  return {
    reason: value.reason,
    ...(resumesAt !== undefined && { resumesAt }),
    ...(turnId !== undefined && { turnId }),
    ...(since !== undefined && { since }),
    ...(error !== undefined && { error }),
  };
}

/// Whether the wait continues this failed turn: its card says so instead of failing.
export function waitsFor(wait: CapacityWaitState | undefined, turnId: string | undefined): boolean {
  return wait !== undefined && wait.turnId !== undefined && wait.turnId === turnId;
}

/// "40s", "3m 5s", "about 2 h": rounded as the wait grows, so a long one does not tick every second.
export function aboutTime(seconds: number): string {
  if (seconds < 10) return `${Math.max(1, Math.ceil(seconds))}s`;
  if (seconds < 60) return `${Math.ceil(seconds / 5) * 5}s`;
  if (seconds < 600) {
    const m = Math.floor(seconds / 60);
    const s = Math.round((seconds % 60) / 15) * 15;
    return s === 0 ? `${m}m` : s === 60 ? `${m + 1}m` : `${m}m ${s}s`;
  }
  if (seconds < 5400) return `${Math.round(seconds / 60)}m`;
  return `${Math.round(seconds / 3600)}h`;
}

/// When it resumes, in the person's clock: "22:41".
export function resumesClock(at: number): string {
  return intl.DateTimeFormat(undefined, { hour: "2-digit", minute: "2-digit" }).format(new Date(at));
}

/// The wait's line: "Waiting for capacity, about 40s", or "…, any moment now" once its time passed
/// or while none is known yet.
export function capacityEta(t: Translate, wait: CapacityWaitState, now: number): string {
  const left = wait.resumesAt === undefined ? undefined : (wait.resumesAt - now) / 1000;
  return left === undefined || left <= 1
    ? t("capacity.wait.soon")
    : t("capacity.wait.about", { time: aboutTime(left) });
}

/// How far the wait has gone, 0 to 1, for a bar; undefined without both ends.
export function capacityProgress(wait: CapacityWaitState, now: number): number | undefined {
  if (wait.since === undefined || wait.resumesAt === undefined || wait.resumesAt <= wait.since) return undefined;
  return Math.min(1, Math.max(0, (now - wait.since) / (wait.resumesAt - wait.since)));
}
