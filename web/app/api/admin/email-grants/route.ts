import { NextRequest } from "next/server";

import {
  AdminInvalidEmailError,
  createPendingEmailGrant,
  isAdminGrantablePlanId,
  isMissingGrantsTableError,
  revokePendingEmailGrant,
  searchAdminUsers,
  setManualPlanGrant,
} from "../../../../services/admin/proGrants";
import {
  adminJsonResponse,
  readJsonBody,
  requireAdmin,
} from "../../../../services/admin/routeAuth";
import { canonicalizeEmailForMatching } from "../../../../services/billing/emailMatching";
import { enforceBrowserMutationProtection } from "../../../../services/vms/routeHelpers";

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

  const body = await readJsonBody(request);
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return adminJsonResponse({ error: "invalid_body" }, 400);
  }
  const { email, plan } = body as { email?: unknown; plan?: unknown };
  if (typeof email !== "string" || !email.trim() || !isAdminGrantablePlanId(plan)) {
    return adminJsonResponse({ error: "invalid_body" }, 400);
  }

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
    const user = await setManualPlanGrant({
      targetUserId: matches[0]!.id,
      plan,
      admin: gate.admin,
    });
    return adminJsonResponse({ user });
  }
  if (matches.length > 1) {
    return adminJsonResponse({ error: "ambiguous_email" }, 409);
  }

  try {
    const { unclearedUserIds, ...pendingGrant } = await createPendingEmailGrant({
      email,
      plan,
      admin: gate.admin,
    });
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
  if (typeof grantId !== "string" || !/^[0-9a-f-]{36}$/i.test(grantId)) {
    return adminJsonResponse({ error: "invalid_body" }, 400);
  }
  try {
    const result = await revokePendingEmailGrant({ grantId, admin: gate.admin });
    return adminJsonResponse({ ok: true, ...result });
  } catch (error) {
    if (isMissingGrantsTableError(error)) {
      console.error("admin.pending_grants.table_missing", { hint: "run the admin_plan_grants migration" });
      return adminJsonResponse({ error: "grants_unavailable" }, 503);
    }
    throw error;
  }
}
