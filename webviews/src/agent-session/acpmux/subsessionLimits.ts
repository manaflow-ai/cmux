// How many of a chat's sub-sessions (the chats its agent started with `start_session`) run a turn
// at once: acpmux's `subsessionLimits.maxRunning`, read from the attach reply's session detail and its `limits`
// records, set with `_acpmux/subsession/limits` (session-info/SubagentLimitStepper.tsx). Leo, 2026-10-21:
// "increase or decrease subagent amounts ad hoc".
import type { SubsessionLimits, SubsessionLimitSource } from "./model";

/// The range acpmux takes for `maxRunning`.
export const MAX_RUNNING = { min: 1, max: 1000 } as const;

const SOURCES: readonly SubsessionLimitSource[] = ["session", "inherited", "workspace", "settings", "default"];

const count = (value: unknown) =>
  typeof value === "number" && Number.isFinite(value) && value >= 0 ? Math.floor(value) : undefined;

/// `maxRunning` held inside acpmux's range.
export const clampRunning = (value: number) => Math.min(MAX_RUNNING.max, Math.max(MAX_RUNNING.min, Math.round(value)));

/// acpmux's `subsessionLimits` as the pane reads it, or nothing from an acpmux without
/// `maxRunning` (its older width and depth limits alone draw no stepper).
export function subsessionLimits(value: unknown): SubsessionLimits | undefined {
  if (!value || typeof value !== "object") return undefined;
  const limits = value as Record<string, unknown>;
  const max = count(limits.maxRunning);
  if (max === undefined || max < MAX_RUNNING.min) return undefined;
  const source = SOURCES.find((each) => each === limits.maxRunningSource);
  const running = count(limits.running);
  const queued = count(limits.queued);
  return {
    maxRunning: Math.min(MAX_RUNNING.max, max),
    ...(source ? { maxRunningSource: source } : {}),
    ...(running !== undefined ? { running } : {}),
    ...(queued !== undefined ? { queued } : {}),
  };
}
