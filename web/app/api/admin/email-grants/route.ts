import { NextRequest } from "next/server";

import {
  type AdminGrantablePlanId,
  AdminInvalidEmailError,
  createPendingEmailGrant,
  isAdminGrantablePlanId,
  isMissingGrantsTableError,
  revokePendingEmailGrant,
  searchAdminUsers,
  setManualPlanGrant,
} from "../../../../services/admin/proGrants";
import { auditRequestId, withAdminAudit } from "../../../../services/admin/auditLog";
import {
  adminJsonResponse,
  readJsonBody,
  requireAdmin,
} from "../../../../services/admin/routeAuth";
import { canonicalizeEmailForMatching } from "../../../../services/billing/emailMatching";
import { enforceBrowserMutationProtection } from "../../../../services/vms/routeHelpers";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * POST /api/admin/email-grants { email, plan: "pro" | "founders" }
 *
 * Grants directly when exactly one non-anonymous Stack user owns the email
 * with a verified mailbox. Otherwise records a pending grant that is applied
 * at that email's next verified sign-in.
 */
export async function POST(request: NextRequest) {
  const protection = enforceBrowserMutationProtection(request);
  if (protection) return protection;
  const gate = await requireAdmin(request);
  if (!gate.ok) return gate.response;

  const parsed = parseEmailGrantBody(await readJsonBody(request));
  // Audited from here on: a malformed body from an admin is still recorded.
  return withAdminAudit(
    {
      actor: gate.admin,
      action: "email_grant_create",
      targetKind: "email",
      targetId: parsed ? canonicalizeEmailForMatching(parsed.email) : null,
      targetLabel: parsed?.email ?? null,
      details: parsed ? { plan: parsed.plan } : null,
      requestId: auditRequestId(request),
    },
    async () =>
      parsed
        ? createEmailGrant(parsed.email, parsed.plan, gate.admin)
        : adminJsonResponse({ error: "invalid_body" }, 400),
  );
}

function parseEmailGrantBody(body: unknown): { email: string; plan: AdminGrantablePlanId } | null {
  if (!body || typeof body !== "object" || Array.isArray(body)) return null;
  const { email, plan } = body as { email?: unknown; plan?: unknown };
  if (typeof email !== "string" || !email.trim() || !isAdminGrantablePlanId(plan)) return null;
  return { email: email.trim(), plan };
}

async function createEmailGrant(
  email: string,
  plan: AdminGrantablePlanId,
  admin: { id: string; primaryEmail: string | null },
): Promise<Response> {
  // Only a VERIFIED owner of the address is granted directly. An unverified
  // account can be registered by anyone with someone else's email, so those
  // wait in the pending table until a verified sign-in claims the grant.
  const canonical = canonicalizeEmailForMatching(email);
  const matches = (await searchAdminUsers(email)).filter(
    (user) =>
      user.emailVerified &&
      user.email &&
      canonicalizeEmailForMatching(user.email) === canonical,
  );
  if (matches.length === 1) {
    const user = await setManualPlanGrant({ targetUserId: matches[0]!.id, plan, admin });
    return adminJsonResponse({ user });
  }
  if (matches.length > 1) {
    return adminJsonResponse({ error: "ambiguous_email" }, 409);
  }

  try {
    const { unclearedUserIds, ...pendingGrant } = await createPendingEmailGrant({ email, plan, admin });
    // Recorded, but a superseded grant is still active on these accounts
    // until their next sign-in or a manual "Remove grant". Say so.
    return adminJsonResponse({ pendingGrant, unclearedUserIds });
  } catch (error) {
    if (error instanceof AdminInvalidEmailError) {
      return adminJsonResponse({ error: "invalid_email" }, 400);
    }
    if (isMissingGrantsTableError(error)) {
      console.error("admin.pending_grants.table_missing", { hint: "run the admin_plan_grants migration" });
      return adminJsonResponse({ error: "grants_unavailable" }, 503);
    }
    throw error;
  }
}

/** DELETE /api/admin/email-grants { grantId } — revoke a pending grant. */
export async function DELETE(request: NextRequest) {
  const protection = enforceBrowserMutationProtection(request);
  if (protection) return protection;
  const gate = await requireAdmin(request);
  if (!gate.ok) return gate.response;

  const body = await readJsonBody(request);
  const grantId = body && typeof body === "object" && !Array.isArray(body)
    ? (body as { grantId?: unknown }).grantId
    : undefined;
  const validGrantId = typeof grantId === "string" && UUID_PATTERN.test(grantId) ? grantId : null;
  // Audited from here on: a malformed body from an admin is still recorded.
  return withAdminAudit(
    {
      actor: gate.admin,
      action: "email_grant_revoke",
      targetKind: "email_grant",
      targetId: validGrantId,
      requestId: auditRequestId(request),
    },
    async () => {
      if (!validGrantId) return adminJsonResponse({ error: "invalid_body" }, 400);
      try {
        const result = await revokePendingEmailGrant({ grantId: validGrantId, admin: gate.admin });
        return adminJsonResponse({ ok: true, ...result });
      } catch (error) {
        if (isMissingGrantsTableError(error)) {
          console.error("admin.pending_grants.table_missing", { hint: "run the admin_plan_grants migration" });
          return adminJsonResponse({ error: "grants_unavailable" }, 503);
        }
        throw error;
      }
    },
  );
}
