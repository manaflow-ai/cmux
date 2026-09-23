import { getStackServerApp, isStackConfigured } from "../../app/lib/stack";
import { billingPlanIdFromMetadata } from "../billing/teamResolution";
import { isPaidVmPlan, resolveVmEntitlements } from "./entitlements";
import type { CloudVmRow } from "./repository";

export type CurrentVmEntitlementsResolver = (
  input: Pick<CloudVmRow, "userId" | "billingTeamId">,
) => Promise<{ readonly planId: string } | null>;

type MetadataOwner = { readonly clientReadOnlyMetadata?: unknown; readonly isAnonymous?: boolean };
export type ExpiryEntitlementLookup = {
  readonly getUser: (id: string) => Promise<MetadataOwner | null>;
  readonly getTeam: (id: string) => Promise<MetadataOwner | null>;
};

/**
 * A destructive sweep needs fresh grant metadata, never the request identity
 * cache. Protect either payer's paid access; an unknown plan or missing account
 * cannot establish that the machine is disposable. The candidate query also
 * protects active Stripe subscriptions while their Stack mirror catches up.
 */
export async function resolveExpiredVmEntitlements(
  input: Pick<CloudVmRow, "userId" | "billingTeamId">,
  lookup?: ExpiryEntitlementLookup,
  environment: Record<string, string | undefined> = process.env,
): Promise<{ readonly planId: string } | null> {
  try {
    if (!lookup) {
      if (!isStackConfigured()) return null;
      const app = getStackServerApp();
      lookup = { getUser: (id) => app.getUser(id), getTeam: (id) => app.getTeam(id) };
    }
    const user = await lookup.getUser(input.userId);
    if (!user) return null;
    const owners = [user];
    if (input.billingTeamId && input.billingTeamId !== input.userId) {
      const team = await lookup.getTeam(input.billingTeamId);
      if (!team) return null;
      owners.push(team);
    }
    const plans = owners.map((owner) =>
      billingPlanIdFromMetadata(owner.clientReadOnlyMetadata)?.trim().toLowerCase() ?? "free",
    );
    const paidPlan = plans.find(isPaidVmPlan);
    if (paidPlan) return { planId: paidPlan };
    // Custom/unknown values are not proof of free access.
    if (!plans.every((plan) => plan === "free")) return null;
    const teamId = input.billingTeamId && input.billingTeamId !== input.userId ? input.billingTeamId : null;
    const userPlan = billingPlanIdFromMetadata(user.clientReadOnlyMetadata);
    const billingPlan = billingPlanIdFromMetadata(owners[owners.length - 1].clientReadOnlyMetadata);
    // Reuse request entitlement policy for development grants and configured
    // defaults, rather than interpreting an absent metadata plan as always free.
    const entitlements = resolveVmEntitlements({
      id: input.userId,
      isAnonymous: user.isAnonymous,
      displayName: null,
      primaryEmail: null,
      billingCustomerType: teamId ? "team" : "user",
      billingTeamId: teamId ?? input.userId,
      selectedTeamId: teamId,
      teams: teamId ? [{ id: teamId, displayName: null, billingPlanId: billingPlan, billingSeats: null }] : [],
      teamIds: teamId ? [teamId] : [],
      userBillingPlanId: userPlan,
      billingPlanId: billingPlan,
      billingSeats: null,
    }, environment);
    return { planId: entitlements.planId };
  } catch {
    return null;
  }
}
