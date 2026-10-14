import { NextRequest } from "next/server";

import { auditRequestId, withAdminAudit } from "../../../../services/admin/auditLog";
import {
  adminJsonResponse,
  readJsonBody,
  requireAdmin,
} from "../../../../services/admin/routeAuth";
import { isStripeBillingConfigured } from "../../../../services/billing/stripe";
import {
  applySubscriptionAction,
  revokeFounderEntitlementForStackUser,
} from "../../../../services/billing/subscriptionManagement";
import { captureBillingError } from "../../../../services/errors";
import { enforceBrowserMutationProtection } from "../../../../services/vms/routeHelpers";

/**
 * POST /api/admin/subscriptions { scope: "user" | "team", ownerId, action: "cancel" | "resume" | "revoke-founder" }
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

  const parsed = parseSubscriptionBody(await readJsonBody(request));
  // Audited from here on, including a malformed body and Stripe being
  // unconfigured: both are authenticated admin actions.
  return withAdminAudit(
    {
      actor: gate.admin,
      action: parsed?.action === "resume"
        ? "subscription_resume"
        : parsed?.action === "revoke-founder"
          ? "founder_access_revoke"
          : "subscription_cancel",
      targetKind: parsed?.scope ?? "subscription",
      targetId: parsed?.ownerId ?? null,
      details: parsed ? { action: parsed.action, scope: parsed.scope } : null,
      requestId: auditRequestId(request),
    },
    async () => {
      if (!parsed) return adminJsonResponse({ error: "invalid_body" }, 400);
      if (parsed.action !== "revoke-founder" && !isStripeBillingConfigured()) {
        return adminJsonResponse({ error: "billing_unavailable" }, 503);
      }
      if (parsed.action === "revoke-founder") return revokeFounderAccess(parsed);
      return applySubscription(
        { scope: parsed.scope, ownerId: parsed.ownerId, action: parsed.action },
        gate.admin.id,
      );
    },
  );
}

type SubscriptionBody = {
  scope: "user" | "team";
  ownerId: string;
  action: "cancel" | "resume" | "revoke-founder";
};

type RecurringSubscriptionBody = {
  scope: "user" | "team";
  ownerId: string;
  action: "cancel" | "resume";
};

function parseSubscriptionBody(body: unknown): SubscriptionBody | null {
  if (!body || typeof body !== "object" || Array.isArray(body)) return null;
  const { scope, ownerId, action } = body as { scope?: unknown; ownerId?: unknown; action?: unknown };
  if (scope !== "user" && scope !== "team") return null;
  if (typeof ownerId !== "string" || !ownerId.trim()) return null;
  if (action !== "cancel" && action !== "resume" && action !== "revoke-founder") return null;
  if (action === "revoke-founder" && scope !== "user") return null;
  return { scope, ownerId: ownerId.trim(), action };
}

async function revokeFounderAccess(
  { ownerId }: SubscriptionBody,
): Promise<Response> {
  try {
    const applied = await revokeFounderEntitlementForStackUser(ownerId);
    if (!applied) return adminJsonResponse({ error: "no_founder_entitlement" }, 404);
    return adminJsonResponse({ ok: true, action: "revoke-founder" });
  } catch (error) {
    captureBillingError(error, {
      route: "/api/admin/subscriptions",
      action: "revoke-founder",
      scope: "user",
    });
    return adminJsonResponse({ error: "billing_error" }, 502);
  }
}

async function applySubscription(
  { scope, ownerId, action }: RecurringSubscriptionBody,
  adminUserId: string,
): Promise<Response> {
  try {
    const applied = await applySubscriptionAction({ scope, ownerId, action });
    if (!applied) return adminJsonResponse({ error: "no_subscription" }, 404);
    return adminJsonResponse({ ok: true, action });
  } catch (error) {
    captureBillingError(error, {
      route: "/api/admin/subscriptions",
      stackUserId: adminUserId,
      action,
      scope,
    });
    return adminJsonResponse({ error: "billing_error" }, 502);
  }
}
