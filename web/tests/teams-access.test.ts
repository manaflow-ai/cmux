import { describe, expect, test } from "bun:test";
import { requireTeamAccess } from "../services/teams/access";
import { loadTeamDetail } from "../services/teams/detail";
import { roleFromGrants, viewerPermissionsFromGrants } from "../services/teams/permissions";
import {
  ADMIN_GRANTS,
  ADMIN_ID,
  MEMBER_GRANTS,
  MEMBER_ID,
  MemoryInviteStore,
  OTHER_TEAM_ID,
  OUTSIDER_ID,
  standardTeam,
  TEAM_ID,
} from "./teams-fixture";

async function errorBody(response: Response) {
  return (await response.json()) as { error: { code: string; message: string } };
}

describe("requireTeamAccess", () => {
  test("refuses a malformed team id and the synthetic personal team as team_not_found", async () => {
    const stack = standardTeam();
    for (const teamId of ["not-a-uuid", "", ADMIN_ID]) {
      const result = await requireTeamAccess({ id: ADMIN_ID }, teamId, { stack: stack.app() });
      expect(result.ok).toBe(false);
      if (result.ok) continue;
      expect(result.refusal).toEqual({ code: "team_not_found", status: 403 });
      expect(result.response.status).toBe(403);
      expect((await errorBody(result.response)).error.code).toBe("team_not_found");
    }
  });

  test("gives a missing team and a non-member the same refusal", async () => {
    const stack = standardTeam();
    const missing = await requireTeamAccess({ id: ADMIN_ID }, OTHER_TEAM_ID, { stack: stack.app() });
    const outsider = await requireTeamAccess({ id: OUTSIDER_ID }, TEAM_ID, { stack: stack.app() });
    expect(missing.ok || missing.refusal.code).toBe("team_not_found");
    expect(outsider.ok || outsider.refusal.code).toBe("team_not_found");
  });

  test("refuses a member without the required permission or role as forbidden", async () => {
    const stack = standardTeam();
    const invite = await requireTeamAccess({ id: MEMBER_ID }, TEAM_ID, { stack: stack.app(), permission: "inviteMembers" });
    expect(invite.ok).toBe(false);
    if (!invite.ok) {
      expect(invite.refusal).toEqual({ code: "forbidden", status: 403, permission: "$invite_members" });
      expect((await errorBody(invite.response)).error.code).toBe("forbidden");
    }
    const admin = await requireTeamAccess({ id: MEMBER_ID }, TEAM_ID, { stack: stack.app(), admin: true });
    expect(admin.ok || admin.refusal).toEqual({ code: "forbidden", status: 403, permission: "team_admin" });
  });

  test("a member with an invite grant but no admin role is refused admin-only work", async () => {
    const stack = standardTeam();
    stack.grants.set(`${TEAM_ID}:${MEMBER_ID}`, new Set([...MEMBER_GRANTS, "$invite_members"]));
    const result = await requireTeamAccess({ id: MEMBER_ID }, TEAM_ID, {
      stack: stack.app(),
      admin: true,
      permission: "inviteMembers",
    });
    expect(result.ok).toBe(false);
  });

  test("fails closed with a retryable 503 when Stack is unavailable", async () => {
    const stack = standardTeam();
    stack.failListUsers = true;
    const result = await requireTeamAccess({ id: ADMIN_ID }, TEAM_ID, { stack: stack.app() });
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.refusal).toEqual({ code: "permission_unavailable", status: 503 });
    expect(result.response.status).toBe(503);
    expect(result.response.headers.get("retry-after")).toBe("5");
  });

  // Regression: a team deleted mid-request answered a retryable 503.
  test("a team deleted during the request is team_not_found, not an outage", async () => {
    const stack = standardTeam();
    stack.teamGoneOnListUsers = true;
    const result = await requireTeamAccess({ id: ADMIN_ID }, TEAM_ID, { stack: stack.app() });
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.refusal).toEqual({ code: "team_not_found", status: 403 });
    expect(result.response.headers.get("retry-after")).toBeNull();
  });

  test("grants an admin every capability including billing", async () => {
    const stack = standardTeam();
    const result = await requireTeamAccess({ id: ADMIN_ID }, TEAM_ID, {
      stack: stack.app(),
      admin: true,
      permission: "deleteTeam",
    });
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.access.role).toBe("admin");
    expect(Object.values(result.access.permissions).every(Boolean)).toBe(true);
  });
});

describe("role and permission mapping", () => {
  test("admin is team_admin; billing follows the admin role", () => {
    expect(roleFromGrants(new Set(ADMIN_GRANTS))).toBe("admin");
    expect(roleFromGrants(new Set(MEMBER_GRANTS))).toBe("member");
    expect(viewerPermissionsFromGrants(new Set(MEMBER_GRANTS))).toEqual({
      updateTeam: false,
      deleteTeam: false,
      inviteMembers: false,
      readMembers: true,
      removeMembers: false,
      manageApiKeys: false,
      manageBilling: false,
    });
    // Holding $update_team without team_admin never implies billing.
    expect(viewerPermissionsFromGrants(new Set(["$update_team"])).manageBilling).toBe(false);
  });
});

describe("loadTeamDetail", () => {
  test("hides invitations and links from members and shows them to admins", async () => {
    const stack = standardTeam();
    stack.addInvitation(TEAM_ID, "new@example.com");
    const store = new MemoryInviteStore();
    await store.upsertInviteRole({ stackTeamId: TEAM_ID, email: "new@example.com", role: "admin", invitedByUserId: ADMIN_ID });
    await store.createLink({ stackTeamId: TEAM_ID, tokenHash: "a".repeat(64), createdByUserId: ADMIN_ID, expiresAt: null, maxUses: null });
    const deps = { store, hasActiveSubscription: async () => true };

    const memberAccess = await requireTeamAccess({ id: MEMBER_ID }, TEAM_ID, { stack: stack.app() });
    const adminAccess = await requireTeamAccess({ id: ADMIN_ID }, TEAM_ID, { stack: stack.app() });
    if (!memberAccess.ok || !adminAccess.ok) throw new Error("access refused");

    const memberView = await loadTeamDetail(memberAccess.access, deps);
    expect(memberView.invitations).toEqual([]);
    expect(memberView.links).toEqual([]);
    expect(memberView.members).toHaveLength(2);
    expect(memberView.viewer.role).toBe("member");
    expect(memberView.members.find((member) => member.isViewer)?.userId).toBe(MEMBER_ID);

    const adminView = await loadTeamDetail(adminAccess.access, deps);
    expect(adminView.invitations).toEqual([
      expect.objectContaining({ email: "new@example.com", role: "admin" }),
    ]);
    expect(adminView.links).toHaveLength(1);
    expect(adminView.billing).toEqual({ planId: null, seats: null, memberLimit: null, memberCount: 2, hasActiveSubscription: true });
    expect(adminView.members.find((member) => member.userId === ADMIN_ID)?.role).toBe("admin");
  });

  test("shows only the viewer when they cannot read members", async () => {
    const stack = standardTeam();
    stack.grants.set(`${TEAM_ID}:${MEMBER_ID}`, new Set(["team_member"]));
    const access = await requireTeamAccess({ id: MEMBER_ID }, TEAM_ID, { stack: stack.app() });
    if (!access.ok) throw new Error("access refused");
    const view = await loadTeamDetail(access.access, { store: new MemoryInviteStore(), hasActiveSubscription: async () => false });
    expect(view.members.map((member) => member.userId)).toEqual([MEMBER_ID]);
    expect(view.billing.memberCount).toBe(2);
  });
});
