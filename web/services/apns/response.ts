import { isTransientApnsResult, type ApnsSendResult } from "./sender";

export interface PushSendSummary {
  readonly sent: number;
  readonly devices: number;
  readonly pruned: number;
  readonly transientFailures: number;
  readonly permanentFailures: number;
  readonly retryAfterSeconds?: number;
}

export function summarizeApnsSendResults(results: readonly ApnsSendResult[]): PushSendSummary {
  const sent = results.filter((r) => r.status >= 200 && r.status < 300).length;
  const pruned = results.filter((r) => r.prune).length;
  const transientFailures = results.filter(isTransientApnsResult).length;
  const permanentFailures = results.length - sent - transientFailures;
  const retryAfterSeconds = results.reduce<number | undefined>(
    (maximum, result) => {
      if (
        !isTransientApnsResult(result)
        || result.retryAfterSeconds == null
        || result.retryAfterSeconds <= 0
      ) {
        return maximum;
      }
      return maximum == null
        ? result.retryAfterSeconds
        : Math.max(maximum, result.retryAfterSeconds);
    },
    undefined,
  );
  return {
    sent,
    devices: results.length,
    pruned,
    transientFailures,
    permanentFailures,
    ...(retryAfterSeconds == null ? {} : { retryAfterSeconds }),
  };
}
