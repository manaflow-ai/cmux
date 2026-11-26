import { getStackServerApp, isStackConfigured } from "../../../app/lib/stack";
import { cloudDb } from "../../../db/client";
import { activeNextPlanForUser, syncNextPlanMetadata } from "../nextPlanBilling";
import { reconcileProPlanMetadata, withFreshProMetadataUserIfAvailable } from "../pro";

/**
 * Re-derives the user's plan mirrors from every billing source under the
 * account-deletion guard Stripe fulfillment uses: `cmuxPlan` from the classic
 * Stripe rows and App Store subscriptions, and `cmuxNextPlan` from the NEXT
 * Stripe rows and App Store `next_*` subscriptions (higher plan wins in
 * each). An operator `cmuxVmPlan` override is left alone, exactly as for
 * Stripe.
 */
export async function applyPersonalPlanEntitlement(userId: string): Promise<void> {
  if (!isStackConfigured()) throw new Error("Stack Auth is required to apply an Apple entitlement");
  const user = await getStackServerApp().getUser(userId);
  if (!user) return;
  await reconcileProPlanMetadata(user);
  await withFreshProMetadataUserIfAvailable(userId, async (freshUser, lease) => {
    await syncNextPlanMetadata(freshUser, await activeNextPlanForUser(cloudDb(), userId), lease);
    return true;
  });
}
