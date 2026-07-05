import type { Family, LimitWindow } from "./types";

export const ACTIVE_TRAFFIC_WINDOW_MS = 10 * 60 * 1000;
export const ACTIVE_POLL_INTERVAL_MS = 2 * 60 * 1000;
export const IDLE_POLL_INTERVAL_MS = 15 * 60 * 1000;

export function usagePollIntervalMs(now: number, lastTrafficAt: number): number {
  return now - lastTrafficAt <= ACTIVE_TRAFFIC_WINDOW_MS ? ACTIVE_POLL_INTERVAL_MS : IDLE_POLL_INTERVAL_MS;
}

export function shouldPollCredential(input: {
  now: number;
  lastTrafficAt: number;
  lastPolledAt?: number;
}): boolean {
  if (typeof input.lastPolledAt !== "number") return true;
  return input.now - input.lastPolledAt >= usagePollIntervalMs(input.now, input.lastTrafficAt);
}

export function nextUsagePollAt(input: {
  now: number;
  lastTrafficAt: number;
  lastPolledAt?: number;
}): number {
  if (typeof input.lastPolledAt !== "number") return input.now;
  return input.lastPolledAt + usagePollIntervalMs(input.now, input.lastTrafficAt);
}

export function zeroHeadroomUsageWindows(family: Family): LimitWindow[] {
  return [
    {
      name: family === "anthropic" ? "usage_poll_auth" : "primary_window",
      usedPercent: 100,
      limitWindowSeconds: IDLE_POLL_INTERVAL_MS / 1000,
      resetAfterSeconds: IDLE_POLL_INTERVAL_MS / 1000,
    },
  ];
}

export function normalizeUsagePoll(family: Family, payload: unknown, now: number): LimitWindow[] {
  return family === "anthropic" ? normalizeAnthropicUsage(payload, now) : normalizeOpenAiUsage(payload);
}

export function normalizeOpenAiUsage(payload: unknown): LimitWindow[] {
  const record = asRecord(payload);
  const rateLimit = asRecord(record?.rate_limit);
  const windows: LimitWindow[] = [];
  for (const key of ["primary_window", "secondary_window"]) {
    const window = asRecord(rateLimit?.[key]);
    const parsed = usageWindowFromPercent(key, window);
    if (parsed) windows.push(parsed);
  }
  return windows;
}

export function normalizeAnthropicUsage(payload: unknown, now: number): LimitWindow[] {
  const record = asRecord(payload);
  const windows: LimitWindow[] = [];
  for (const key of ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"]) {
    const window = asRecord(record?.[key]);
    if (!window) continue;
    const utilization = numberValue(window.utilization);
    const resetsAt = typeof window.resets_at === "string" ? Date.parse(window.resets_at) : Number.NaN;
    if (utilization === null || !Number.isFinite(resetsAt)) continue;
    windows.push({
      name: key,
      usedPercent: clampPercent(utilization),
      limitWindowSeconds: key === "five_hour" ? 5 * 60 * 60 : 7 * 24 * 60 * 60,
      resetAfterSeconds: Math.max(0, Math.ceil((resetsAt - now) / 1000)),
    });
  }
  return windows;
}

function usageWindowFromPercent(name: string, window: Record<string, unknown> | null): LimitWindow | null {
  if (!window) return null;
  const usedPercent = numberValue(window.used_percent);
  const limitWindowSeconds = numberValue(window.limit_window_seconds);
  const resetAfterSeconds = numberValue(window.reset_after_seconds);
  if (usedPercent === null || limitWindowSeconds === null || resetAfterSeconds === null) return null;
  return { name, usedPercent: clampPercent(usedPercent), limitWindowSeconds, resetAfterSeconds };
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : null;
}

function numberValue(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function clampPercent(value: number): number {
  return Math.max(0, Math.min(100, value));
}
