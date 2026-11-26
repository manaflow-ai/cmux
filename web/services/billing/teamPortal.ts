import { eq } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { stripeCustomers } from "../../db/schema";
import { stripe } from "./stripe";

export async function stripeCustomerIdForStackTeam(stackTeamId: string): Promise<string | null> {
  const rows = await cloudDb()
    .select({ id: stripeCustomers.id })
    .from(stripeCustomers)
    .where(eq(stripeCustomers.stackTeamId, stackTeamId))
    .limit(1);
  return rows[0]?.id ?? null;
}

/** Where a team's Stripe portal returns: the dashboard billing view for that team. */
export function teamBillingReturnURL(origin: string, teamId: string): string {
  const url = new URL("/dashboard/billing", origin);
  url.searchParams.set("team", teamId);
  return url.toString();
}

/**
 * A Stripe Billing Portal session for a team's customer, or null when the team
 * has never had a Stripe customer. Callers authorize the team first.
 */
export async function teamPortalSession(input: {
  readonly teamId: string;
  readonly origin: string;
  readonly customerId?: string | null;
}): Promise<{ readonly url: string } | null> {
  const customerId = input.customerId ?? await stripeCustomerIdForStackTeam(input.teamId);
  if (!customerId) return null;
  const session = await stripe().billingPortal.sessions.create({
    customer: customerId,
    return_url: teamBillingReturnURL(input.origin, input.teamId),
  });
  if (!session.url) throw new Error("Stripe Billing Portal Session did not include a URL");
  return { url: session.url };
}
