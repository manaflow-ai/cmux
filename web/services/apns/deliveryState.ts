import type { ApnsSendResult, ApnsTarget } from "./sender";
import { isTransientApnsResult } from "./sender";

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
