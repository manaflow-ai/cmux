// Side effects every Apple write path shares: who a token belongs to,
// re-deriving the plans a subscription write touched, and the grant event.
// Kept apart from service.ts so the cron modules can use them without an
// import cycle.

import { appleBillingPeriodForProduct } from "./config";
import type { AppleIapDependencies } from "./service";
import type { AppleIapStore, AppleSubscriptionRow, AppleSubscriptionWrite } from "./store";

export async function tokenOwner(token: string | null | undefined, store: AppleIapStore): Promise<string | null> {
  return token ? await store.userIdForAccountToken(token) : null;
}

/**
 * Re-derives the plan of the subscription's owner and, after an ownership
 * move, of the previous owner, who falls back to Stripe or free.
 */
export async function applyEntitlements(write: AppleSubscriptionWrite, deps: AppleIapDependencies): Promise<void> {
  await deps.applyEntitlement(write.current.userId);
  if (write.transferredFrom) await deps.applyEntitlement(write.transferredFrom);
}

/**
 * `subscription_entitlement_granted` once the written subscription is the
 * plan the user now holds through Apple. Sent from both the app-posted
 * transaction and the notification for the same transaction; the shared
 * insert ID keeps one event per transaction (a purchase, then each renewal).
 * Best effort: analytics never fails a purchase.
 */
export async function captureEntitlementGranted(
  written: AppleSubscriptionRow,
  deps: AppleIapDependencies,
): Promise<void> {
  if (!deps.activeEntitlement) return;
  try {
    const granting = await deps.activeEntitlement(written.userId);
    if (granting?.originalTransactionId !== written.originalTransactionId) return;
    await deps.captureEvent({
      event: "subscription_entitlement_granted",
      distinctId: written.userId,
      insertId: `apple_entitlement:${written.lastTransactionId ?? written.originalTransactionId}`,
      properties: {
        source: "apple",
        plan_id: written.planId,
        product_id: written.productId,
        billing_period: appleBillingPeriodForProduct(written.productId, written.bundleId),
        environment: written.environment,
        original_transaction_id: written.originalTransactionId,
        transaction_id: written.lastTransactionId,
        status: written.status,
        expires_at: written.expiresAt?.toISOString() ?? null,
      },
    });
  } catch (error) {
    console.warn("Apple entitlement analytics failed", {
      originalTransactionId: written.originalTransactionId,
      error: errorText(error),
    });
  }
}

export function errorText(error: unknown): string {
  const text = error instanceof Error ? `${error.name}: ${error.message}` : String(error);
  return text.slice(0, 200);
}
