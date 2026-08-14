import { z } from "zod";

import { resolveProPlanStatus } from "../../../services/billing/pro";
import { os, requireAuth } from "../base";

export const accountMeOutputSchema = z.object({
  userId: z.string(),
  // Empty string when the Stack user has no primary email, mirroring userId's
  // null-safe mapping and keeping the generated Swift type a plain String.
  email: z.string(),
  planId: z.enum(["free", "pro"]),
  isPro: z.boolean(),
  billingManagement: z.enum(["stripe", "external", "none"]),
});

export type AccountMe = z.infer<typeof accountMeOutputSchema>;

export const accountMeProcedure = os
  .route({
    method: "GET",
    path: "/account/me",
    operationId: "account.me",
    summary: "Get the authenticated account and plan",
    description:
      "Returns the signed-in user's id, primary email, and resolved billing plan (free or pro).",
    tags: ["Account"],
    successStatus: 200,
  })
  .output(accountMeOutputSchema)
  .use(requireAuth)
  .handler(async ({ context }): Promise<AccountMe> => {
    // requireAuth guarantees context.user is non-null here.
    const { user } = context;
    // resolveProPlanStatus reconciles the cmuxPlan metadata against the real
    // Stripe/Stack subscription state and returns the authoritative plan.
    const status = await resolveProPlanStatus(user);
    return {
      // id is always present on a real Stack user; the ?? keeps this total for
      // the DB-free unit test, which drives the plan via a Stack-product fake.
      userId: user.id ?? "",
      email: user.primaryEmail ?? "",
      planId: status.planId,
      isPro: status.isPro,
      billingManagement: status.billingManagement,
    };
  });
