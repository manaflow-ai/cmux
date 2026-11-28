// Handlers for /api/admin/members, built by a factory so tests can inject the
// member store and the invitation sender. route.ts exports the default wiring.

import type { NextRequest } from "next/server";

import { auditRequestId, withAdminAudit, type AdminAuditDb } from "../../../../services/admin/auditLog";
import { sendAdminMemberInviteEmail, type AdminInviteSender } from "../../../../services/admin/memberInviteEmail";
import {
  AdminMemberAlreadyActiveError,
  AdminMemberInvalidEmailError,
  AdminMemberNotFoundError,
  AdminMemberSelfRevokeError,
  adminMemberRow,
  inviteAdminMember,
  listAdminMembers,
  revokeAdminMember,
  type AdminMembersStore,
} from "../../../../services/admin/members";
import {
  adminJsonResponse,
  readJsonBody,
  requireAdmin,
  type AdminPrincipal,
} from "../../../../services/admin/routeAuth";
import { enforceBrowserMutationProtection } from "../../../../services/vms/routeHelpers";

export type AdminMembersRouteDependencies = {
  readonly store?: AdminMembersStore;
  readonly auditDb?: AdminAuditDb;
  readonly sendInvite: AdminInviteSender;
  readonly now?: () => Date;
};

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function createAdminMembersHandlers(deps: AdminMembersRouteDependencies) {
  /** GET /api/admin/members — every member row, newest invite first. */
  async function GET(request: NextRequest) {
    const gate = await requireAdmin(request);
    if (!gate.ok) return gate.response;
    const members = await listAdminMembers({ store: deps.store });
    return adminJsonResponse({ members });
  }

  /** POST /api/admin/members { email } — invite (or re-invite) an admin. */
  async function POST(request: NextRequest) {
    const protection = enforceBrowserMutationProtection(request);
    if (protection) return protection;
    const gate = await requireAdmin(request);
    if (!gate.ok) return gate.response;

    // Audited from here on: a malformed body from an authenticated admin is
    // still an admin action, recorded with no target.
    const email = readEmail(await readJsonBody(request));
    return withAdminAudit(
      {
        actor: gate.admin,
        action: "member_invite",
        targetKind: "admin_member",
        targetLabel: email?.toLowerCase() ?? null,
        requestId: auditRequestId(request),
        db: deps.auditDb,
      },
      () => (email ? invite(email, gate.admin) : invalidBody()),
    );
  }

  async function invite(email: string, admin: AdminPrincipal): Promise<Response> {
    let member;
    try {
      ({ member } = await inviteAdminMember({ email, admin, store: deps.store, now: deps.now }));
    } catch (error) {
      if (error instanceof AdminMemberInvalidEmailError) {
        return adminJsonResponse({ error: "invalid_email" }, 400);
      }
      if (error instanceof AdminMemberAlreadyActiveError) {
        return adminJsonResponse({ error: "already_member" }, 409);
      }
      throw error;
    }
    const { sent } = await deps.sendInvite({ to: member.email, inviterEmail: admin.primaryEmail });
    return adminJsonResponse({ member: adminMemberRow(member), emailSent: sent });
  }

  /** DELETE /api/admin/members { memberId } — revoke; the caller cannot revoke themselves. */
  async function DELETE(request: NextRequest) {
    const protection = enforceBrowserMutationProtection(request);
    if (protection) return protection;
    const gate = await requireAdmin(request);
    if (!gate.ok) return gate.response;

    const memberId = readMemberId(await readJsonBody(request));
    return withAdminAudit(
      {
        actor: gate.admin,
        action: "member_revoke",
        targetKind: "admin_member",
        targetId: memberId,
        requestId: auditRequestId(request),
        db: deps.auditDb,
      },
      () => (memberId ? revoke(memberId, gate.admin) : invalidBody()),
    );
  }

  async function revoke(memberId: string, admin: AdminPrincipal): Promise<Response> {
    try {
      await revokeAdminMember({ memberId, admin, store: deps.store, now: deps.now });
      return adminJsonResponse({ ok: true });
    } catch (error) {
      if (error instanceof AdminMemberSelfRevokeError) {
        return adminJsonResponse({ error: "self_revoke" }, 400);
      }
      if (error instanceof AdminMemberNotFoundError) {
        return adminJsonResponse({ error: "member_not_found" }, 404);
      }
      throw error;
    }
  }

  return { GET, POST, DELETE };
}

export const defaultAdminMembersDependencies: AdminMembersRouteDependencies = {
  sendInvite: sendAdminMemberInviteEmail,
};

async function invalidBody(): Promise<Response> {
  return adminJsonResponse({ error: "invalid_body" }, 400);
}

function readEmail(body: unknown): string | null {
  if (!body || typeof body !== "object" || Array.isArray(body)) return null;
  const { email } = body as { email?: unknown };
  return typeof email === "string" && email.trim() ? email.trim() : null;
}

function readMemberId(body: unknown): string | null {
  if (!body || typeof body !== "object" || Array.isArray(body)) return null;
  const { memberId } = body as { memberId?: unknown };
  return typeof memberId === "string" && UUID_PATTERN.test(memberId) ? memberId : null;
}
