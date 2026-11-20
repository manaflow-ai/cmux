import { readRateLimitedUntil, readRetry, type RetryState } from "./subagents/retryState";

/** The daemon owns retry scheduling; the pane only reports its wait and the attempt it sent.
 *  `rateLimitedUntil`: the daemon holds every turn on the account's rate limit until then (Unix ms). */
export type AutoResumeStatus = { retry?: RetryState; attempt?: number; rateLimitedUntil?: number };

/** Manual retries and subagent continuations are not an automatic retry of this chat. */
export function autoResumeAttempt(msg: unknown): number | undefined {
  const provenance = (msg as { _meta?: { provenance?: Record<string, unknown> } } | undefined)?._meta?.provenance;
  const attempt = provenance?.attempt;
  return provenance?.kind === "auto_resume" &&
    provenance.manual !== true &&
    typeof attempt === "number" &&
    Number.isSafeInteger(attempt) &&
    attempt > 0
    ? attempt
    : undefined;
}

export function autoResumeStatus(
  retry: unknown,
  attempt: number | undefined,
  rateLimitedUntil?: unknown,
): AutoResumeStatus | undefined {
  const waiting = readRetry(retry);
  const held = readRateLimitedUntil(rateLimitedUntil);
  const status: AutoResumeStatus = {
    ...(waiting && { retry: waiting }),
    ...(attempt && { attempt }),
    ...(held !== undefined && { rateLimitedUntil: held }),
  };
  return Object.keys(status).length > 0 ? status : undefined;
}
