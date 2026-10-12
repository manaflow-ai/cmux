import { getStackServerApp, isStackConfigured } from "../../../app/lib/stack";
import { reconcileProPlanMetadata } from "../pro";

/**
 * Re-derives the user's `cmuxPlan` mirror from every billing source (Stripe
 * rows and Apple subscriptions, higher plan wins) under the account-deletion
 * guard Stripe fulfillment uses. An operator `cmuxVmPlan` override is left
 * alone, exactly as for Stripe.
 */
export async function applyPersonalPlanEntitlement(userId: string): Promise<void> {
  if (!isStackConfigured()) throw new Error("Stack Auth is required to apply an Apple entitlement");
  const user = await getStackServerApp().getUser(userId);
  if (!user) return;
  await reconcileProPlanMetadata(user);
}
