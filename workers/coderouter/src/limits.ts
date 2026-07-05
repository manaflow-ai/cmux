import type { CredentialClass, CredentialLimitState, EndpointClass, Family, LimitWindow } from "./types";

export interface ParsedLimitUpdate {
  windows: LimitWindow[];
  cooldownUntil?: number;
  consecutive429: number;
  consecutive401: number;
  needsReauth: boolean;
}

export function headroom(windows: LimitWindow[]): number {
  if (windows.length === 0) return 1;
  return Math.min(...windows.map((window) => Math.max(0, 1 - window.usedPercent / 100)));
}

export function parseRetryAfterSeconds(value: string | null): number | null {
  if (!value) return null;
  const seconds = Number(value);
  if (Number.isFinite(seconds) && seconds >= 0) return seconds;
  const date = Date.parse(value);
  if (Number.isFinite(date)) return Math.max(0, Math.ceil((date - Date.now()) / 1000));
  return null;
}

export function cooldownAfter429(now: number, retryAfterHeader: string | null, previousConsecutive429 = 0): {
  cooldownUntil: number;
  consecutive429: number;
} {
  const retryAfter = parseRetryAfterSeconds(retryAfterHeader);
  const consecutive429 = previousConsecutive429 + 1;
  const backoff = Math.min(900, 60 * 2 ** Math.max(0, consecutive429 - 1));
  const seconds = retryAfter ?? backoff;
  return { cooldownUntil: now + seconds * 1000, consecutive429 };
}

export function applyLimitHeaders(input: {
  family: Family;
  endpointClass: EndpointClass;
  credentialClass: CredentialClass;
  status: number;
  headers: Record<string, string>;
  now: number;
  previousConsecutive429?: number;
  previousConsecutive401?: number;
}): ParsedLimitUpdate {
  const headers = lowerRecord(input.headers);
  const windows = input.credentialClass === "oauth" ? [] : parseWindows(input.family, headers, input.now);
  let cooldownUntil: number | undefined;
  let consecutive429 = input.status === 429 ? (input.previousConsecutive429 ?? 0) : 0;
  let consecutive401 = input.status === 401 ? (input.previousConsecutive401 ?? 0) + 1 : 0;
  let needsReauth = false;
  if (input.status === 429) {
    const cooldown = cooldownAfter429(input.now, headers["retry-after"] ?? null, input.previousConsecutive429 ?? 0);
    cooldownUntil = cooldown.cooldownUntil;
    consecutive429 = cooldown.consecutive429;
  }
  if (input.status === 401 && input.credentialClass === "oauth") {
    cooldownUntil = input.now + 5 * 60 * 1000;
    needsReauth = consecutive401 >= 2;
  }
  return { windows, cooldownUntil, consecutive429, consecutive401, needsReauth };
}

export function mergeReportedLimitState(
  previous: CredentialLimitState,
  update: ParsedLimitUpdate,
): CredentialLimitState {
  return {
    ...previous,
    windows: update.windows.length > 0 ? update.windows : previous.windows,
    cooldownUntil: update.cooldownUntil ?? previous.cooldownUntil,
    consecutive429: update.consecutive429,
    consecutive401: update.consecutive401,
    needsReauth: update.needsReauth || previous.needsReauth,
  };
}

export function parseWindows(family: Family, headers: Record<string, string>, now: number): LimitWindow[] {
  return family === "anthropic" ? parseAnthropicWindows(headers, now) : parseOpenAiWindows(headers);
}

function parseAnthropicWindows(headers: Record<string, string>, now: number): LimitWindow[] {
  const windows: LimitWindow[] = [];
  const names = new Set<string>();
  for (const key of Object.keys(headers)) {
    const match = /^anthropic-ratelimit-(.+)-remaining$/.exec(key);
    if (match?.[1]) names.add(match[1]);
  }
  for (const name of names) {
    const remaining = numberHeader(headers[`anthropic-ratelimit-${name}-remaining`]);
    const limit = numberHeader(headers[`anthropic-ratelimit-${name}-limit`]);
    if (remaining === null || limit === null || limit <= 0) continue;
    const reset = headers[`anthropic-ratelimit-${name}-reset`];
    windows.push({
      name,
      usedPercent: clampPercent((1 - remaining / limit) * 100),
      limitWindowSeconds: guessWindowSeconds(name),
      resetAfterSeconds: parseResetSeconds(reset, now),
    });
  }
  return windows;
}

function parseOpenAiWindows(headers: Record<string, string>): LimitWindow[] {
  const windows: LimitWindow[] = [];
  for (const name of ["requests", "tokens"]) {
    const remaining = numberHeader(headers[`x-ratelimit-remaining-${name}`]);
    const limit = numberHeader(headers[`x-ratelimit-limit-${name}`]);
    if (remaining === null || limit === null || limit <= 0) continue;
    windows.push({
      name,
      usedPercent: clampPercent((1 - remaining / limit) * 100),
      limitWindowSeconds: parseDurationSeconds(headers[`x-ratelimit-reset-${name}`]) ?? 60,
      resetAfterSeconds: parseDurationSeconds(headers[`x-ratelimit-reset-${name}`]) ?? 60,
    });
  }
  return windows;
}

function lowerRecord(headers: Record<string, string>): Record<string, string> {
  const lowered: Record<string, string> = {};
  for (const [key, value] of Object.entries(headers)) lowered[key.toLowerCase()] = value;
  return lowered;
}

function numberHeader(value: string | undefined): number | null {
  if (value === undefined) return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function clampPercent(value: number): number {
  return Math.max(0, Math.min(100, value));
}

function parseResetSeconds(value: string | undefined, now: number): number {
  if (!value) return 0;
  const seconds = parseDurationSeconds(value);
  if (seconds !== null) return seconds;
  const date = Date.parse(value);
  return Number.isFinite(date) ? Math.max(0, Math.ceil((date - now) / 1000)) : 0;
}

function parseDurationSeconds(value: string | undefined): number | null {
  if (!value) return null;
  const trimmed = value.trim();
  const numeric = Number(trimmed);
  if (Number.isFinite(numeric)) return numeric;
  const match = /^(\d+(?:\.\d+)?)(ms|s|m|h)?$/.exec(trimmed);
  if (!match?.[1]) return null;
  const amount = Number(match[1]);
  const unit = match[2] ?? "s";
  if (unit === "ms") return Math.ceil(amount / 1000);
  if (unit === "m") return Math.ceil(amount * 60);
  if (unit === "h") return Math.ceil(amount * 3600);
  return Math.ceil(amount);
}

function guessWindowSeconds(name: string): number {
  if (name.includes("day")) return 7 * 24 * 60 * 60;
  if (name.includes("hour")) return 60 * 60;
  if (name.includes("minute")) return 60;
  return 60;
}
