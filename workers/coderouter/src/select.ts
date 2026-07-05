import type { CredentialClass, CredentialLimitState, LimitWindow } from "./types";

export interface SelectCandidate {
  id: string;
  class: CredentialClass;
  assignmentCount: number;
  limitState: CredentialLimitState;
}

export interface WindowSummary {
  headroom: number;
  shortHeadroom: number;
  shortResetAfterSeconds: number | null;
  expiryPressure: number;
  exhausted: boolean;
  cooldownActive: boolean;
  soonestResetSeconds?: number;
}

export interface ScoredCandidate extends SelectCandidate {
  tier: number;
  usable: boolean;
  summary: WindowSummary;
}

export function summarizeWindows(windows: LimitWindow[], now: number, cooldownUntil?: number): WindowSummary {
  const cooldownActive = typeof cooldownUntil === "number" && cooldownUntil > now;
  if (windows.length === 0) {
    return {
      headroom: 1,
      shortHeadroom: 1,
      shortResetAfterSeconds: null,
      expiryPressure: 0,
      exhausted: cooldownActive,
      cooldownActive,
      soonestResetSeconds: cooldownActive ? Math.ceil((cooldownUntil - now) / 1000) : undefined,
    };
  }
  let headroom = 1;
  let shortHeadroom = 1;
  let shortResetAfterSeconds: number | null = null;
  let soonestResetSeconds: number | undefined;
  for (const window of windows) {
    const remaining = Math.max(0, 1 - window.usedPercent / 100);
    headroom = Math.min(headroom, remaining);
    if (window.limitWindowSeconds <= 21600) {
      shortHeadroom = Math.min(shortHeadroom, remaining);
      if (window.resetAfterSeconds > 0) {
        shortResetAfterSeconds =
          shortResetAfterSeconds === null
            ? window.resetAfterSeconds
            : Math.min(shortResetAfterSeconds, window.resetAfterSeconds);
      }
    }
    if (window.resetAfterSeconds > 0) {
      soonestResetSeconds =
        soonestResetSeconds === undefined ? window.resetAfterSeconds : Math.min(soonestResetSeconds, window.resetAfterSeconds);
    }
  }
  if (cooldownActive) {
    const cooldownReset = Math.ceil(((cooldownUntil ?? now) - now) / 1000);
    soonestResetSeconds = soonestResetSeconds === undefined ? cooldownReset : Math.min(soonestResetSeconds, cooldownReset);
  }
  const expiryPressure = shortResetAfterSeconds && shortResetAfterSeconds > 0 ? headroom / shortResetAfterSeconds : 0;
  return {
    headroom,
    shortHeadroom,
    shortResetAfterSeconds,
    expiryPressure,
    exhausted: cooldownActive || headroom <= 0 || shortHeadroom <= 0,
    cooldownActive,
    soonestResetSeconds,
  };
}

export function scoreCandidate(candidate: SelectCandidate, now: number): ScoredCandidate {
  const summary = summarizeWindows(candidate.limitState.windows, now, candidate.limitState.cooldownUntil);
  const usableForNewSession = summary.headroom >= 0.4 && summary.shortHeadroom >= 0.4 && !summary.cooldownActive;
  let tier: number;
  if (candidate.class === "oauth" && usableForNewSession) tier = 0;
  else if (candidate.class === "byok" && !summary.cooldownActive) tier = 1;
  else if (candidate.class === "managed" && !summary.cooldownActive) tier = 2;
  else if (candidate.class === "oauth" && !summary.exhausted) tier = 3;
  else if (candidate.class === "oauth" && !summary.cooldownActive) tier = 4;
  else tier = 99;
  return { ...candidate, tier, usable: tier < 99, summary };
}

export function selectCredential(candidates: SelectCandidate[], now: number): ScoredCandidate | null {
  const scored = candidates.map((candidate) => scoreCandidate(candidate, now)).filter((candidate) => candidate.usable);
  if (scored.length === 0) return null;
  scored.sort(compareScoredCandidates);
  return scored[0] ?? null;
}

export function compareScoredCandidates(a: ScoredCandidate, b: ScoredCandidate): number {
  if (a.tier !== b.tier) return a.tier - b.tier;
  const aUsable = a.summary.headroom >= 0.4 && a.summary.shortHeadroom >= 0.4;
  const bUsable = b.summary.headroom >= 0.4 && b.summary.shortHeadroom >= 0.4;
  if (aUsable !== bUsable) return aUsable ? -1 : 1;
  if (a.summary.expiryPressure !== b.summary.expiryPressure) return b.summary.expiryPressure - a.summary.expiryPressure;
  if (a.summary.headroom !== b.summary.headroom) return b.summary.headroom - a.summary.headroom;
  if (a.assignmentCount !== b.assignmentCount) return a.assignmentCount - b.assignmentCount;
  return a.id.localeCompare(b.id);
}
