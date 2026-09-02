import { NextRequest } from "next/server";

import {
  adminJsonResponse,
  readJsonBody,
  requireAdmin,
} from "../../../../services/admin/routeAuth";
import { isStripeBillingConfigured } from "../../../../services/billing/stripe";
import { applySubscriptionAction } from "../../../../services/billing/subscriptionManagement";
import { captureBillingError } from "../../../../services/errors";
import { enforceBrowserMutationProtection } from "../../../../services/vms/routeHelpers";

/**
 * POST /api/admin/subscriptions { scope: "user" | "team", ownerId, action: "cancel" | "resume" }
 *
 * Manual downgrade for paying customers: cancel at period end (access stays
 * until the paid period ends) or resume a scheduled cancellation. Uses the
 * same Stripe path as the self-serve billing form.
 */
export async function POST(request: NextRequest) {
  const protection = enforceBrowserMutationProtection(request);
  if (protection) return protection;
  const gate = await requireAdmin(request);
  if (!gate.ok) return gate.response;

  const body = await readJsonBody(request);
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return adminJsonResponse({ error: "invalid_body" }, 400);
  }
  const { scope, ownerId, action } = body as {
    scope?: unknown;
    ownerId?: unknown;
    action?: unknown;
  };
  if (
    (scope !== "user" && scope !== "team") ||
    typeof ownerId !== "string" || !ownerId.trim() ||
    (action !== "cancel" && action !== "resume")
  ) {
    return adminJsonResponse({ error: "invalid_body" }, 400);
  }
  if (!isStripeBillingConfigured()) {
    return adminJsonResponse({ error: "billing_unavailable" }, 503);
  }

  try {
    const applied = await applySubscriptionAction({ scope, ownerId: ownerId.trim(), action });
    if (!applied) return adminJsonResponse({ error: "no_subscription" }, 404);
    return adminJsonResponse({ ok: true, action });
  } catch (error) {
    captureBillingError(error, {
      route: "/api/admin/subscriptions",
      stackUserId: gate.admin.id,
      action,
      scope,
    });
    return adminJsonResponse({ error: "billing_error" }, 502);
  }
}
