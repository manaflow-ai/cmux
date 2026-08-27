import type { ApnsSendResult, ApnsTarget } from "./sender";
import {
  APNS_DEFAULT_MAX_DELIVERY_DURATION_MS,
  isTransientApnsResult,
} from "./sender";

/** Never reschedule a deferred retry sooner than this after a failure. */
export const MINIMUM_DEFERRED_RETRY_SECONDS = 30;
/** Scheduling headroom beyond the bounded APNs delivery duration. */
const DEFERRED_RETRY_SCHEDULING_MARGIN_MS = 1_000;

/**
 * Bounds each transient outcome's provider backoff by the event's remaining
 * life. A deferred retry scheduled at or past the event TTL can never send,
 * so an unclamped backoff longer than the TTL (an APNs 5xx asks for 15
 * minutes; events live 2-5) silently guarantees the alert is lost while the
 * caller is told to retry. The clamp keeps a retry viable when the event
 * still has room for one, keeps a floor so a recovering provider is never
 * hammered, and leaves backoffs the event outlives untouched. When even the
 * floor lands past the TTL, the target is finalized as expired immediately
 * instead of advertising an impossible recovery.
 */
export function clampRetryToEventLife(
  outcomes: readonly ApnsSendResult[],
  completedAt: Date,
  expirationEpochSeconds: number,
): ApnsSendResult[] {
  const viableRetrySeconds = Math.floor(
    (
      expirationEpochSeconds * 1_000
      - completedAt.getTime()
      - APNS_DEFAULT_MAX_DELIVERY_DURATION_MS
      - DEFERRED_RETRY_SCHEDULING_MARGIN_MS
    ) / 1_000,
  );
  return outcomes.map((outcome) => {
    if (!isTransientApnsResult(outcome)) return outcome;
    if (viableRetrySeconds < MINIMUM_DEFERRED_RETRY_SECONDS) {
      return {
        ...(outcome.targetId == null ? {} : { targetId: outcome.targetId }),
        deviceToken: outcome.deviceToken,
        status: 0,
        reason: "event_expired",
        prune: false,
      };
    }
    return {
      ...outcome,
      retryAfterSeconds: Math.min(
        viableRetrySeconds,
        Math.max(
          MINIMUM_DEFERRED_RETRY_SECONDS,
          outcome.retryAfterSeconds ?? 0,
        ),
      ),
    };
  });
}

/**
 * Replaces only outcomes observed again on a later same-correlation attempt.
 * A successful or permanent target is retained until the logical event TTL,
 * so it can never be selected for another alert.
 */
export function mergePushDeliveryOutcomes(
  previous: readonly ApnsSendResult[],
  latest: readonly ApnsSendResult[],
): ApnsSendResult[] {
  const byToken = new Map(
    previous.map((result) => [deliveryIdentity(result), result]),
  );
  for (const result of latest) {
    byToken.set(deliveryIdentity(result), result);
  }
  return [...byToken.values()];
}

/** Selects only tokens whose most recent outcome is absent or transient. */
export function unresolvedPushTargets(
  currentTargets: readonly ApnsTarget[],
  outcomes: readonly ApnsSendResult[],
): ApnsTarget[] {
  const byToken = new Map(
    outcomes.map((result) => [deliveryIdentity(result), result]),
  );
  return currentTargets.filter((target) => {
    const result = byToken.get(deliveryIdentity(target));
    return result == null || isTransientApnsResult(result);
  });
}

function deliveryIdentity(value: ApnsTarget | ApnsSendResult): string {
  return value.targetId ?? value.deviceToken;
}
