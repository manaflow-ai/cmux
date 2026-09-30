import type { TeamAccess } from "./access";
import { TeamApiError } from "./errors";
import { databaseTeamInviteStore, type TeamInviteStore } from "./repository";
import { withStackDeadline, type StackSentInvitation } from "./stack";
import type { TeamInvitation, TeamRole } from "./types";

export { MAX_INVITE_EMAILS } from "./limits";

export type InvitationDependencies = { readonly store?: TeamInviteStore };

export type InviteFailureCode = "already_member" | "invite_failed";

export function normalizeInviteEmail(email: string): string {
  return email.trim().toLowerCase();
}

function invitationEmail(invitation: StackSentInvitation): string | null {
  return invitation.recipientEmail ? normalizeInviteEmail(invitation.recipientEmail) : null;
}

function toInvitation(invitation: StackSentInvitation, roles: ReadonlyMap<string, TeamRole>): TeamInvitation {
  const email = invitationEmail(invitation);
  return {
    id: invitation.id,
    email,
    role: (email && roles.get(email)) || "member",
    expiresAt: invitation.expiresAt.toISOString(),
  };
}

async function listStackInvitations(access: TeamAccess): Promise<readonly StackSentInvitation[]> {
  return withStackDeadline(() => access.team.listInvitations());
}

/** Pending Stack invitations joined with the role cmux stored for each email. */
export async function listTeamInvitations(
  access: TeamAccess,
  dependencies: InvitationDependencies = {},
): Promise<TeamInvitation[]> {
  const invitations = await listStackInvitations(access);
  return mapInvitations(access.team.id, invitations, dependencies.store ?? databaseTeamInviteStore);
}

async function mapInvitations(
  teamId: string,
  invitations: readonly StackSentInvitation[],
  store: TeamInviteStore,
): Promise<TeamInvitation[]> {
  const emails = [...new Set(invitations.map(invitationEmail).filter((email): email is string => email !== null))];
  const roles = await store.inviteRoles(teamId, emails);
  return invitations.map((invitation) => toInvitation(invitation, roles));
}

/**
 * Invite each email through Stack, which sends the only email. The role is
 * stored before the invitation exists, so no accept can race ahead of it.
 * Re-inviting overwrites the stored role.
 */
export async function inviteTeamMembers(
  access: TeamAccess,
  input: { readonly emails: readonly string[]; readonly role: TeamRole; readonly callbackUrl: string },
  dependencies: InvitationDependencies = {},
): Promise<{ invitations: TeamInvitation[]; failed: { email: string; code: InviteFailureCode }[] }> {
  const store = dependencies.store ?? databaseTeamInviteStore;
  const memberEmails = new Set(
    access.members.map((member) => member.primaryEmail ? normalizeInviteEmail(member.primaryEmail) : null)
      .filter((email): email is string => email !== null),
  );
  const emails = [...new Set(input.emails.map(normalizeInviteEmail))];
  const failed: { email: string; code: InviteFailureCode }[] = [];
  const sent: string[] = [];
  const previous = emails.some((email) => !memberEmails.has(email)) ? await listStackInvitations(access) : [];
  for (const email of emails) {
    if (memberEmails.has(email)) {
      failed.push({ email, code: "already_member" });
      continue;
    }
    const previousRole = (await store.inviteRoles(access.team.id, [email])).get(email);
    try {
      await store.upsertInviteRole({ stackTeamId: access.team.id, email, role: input.role, invitedByUserId: access.userId });
      await withStackDeadline(() => access.team.inviteUser({ email, callbackUrl: input.callbackUrl }));
      sent.push(email);
    } catch {
      console.error("team invitation send failed", { teamId: access.team.id });
      failed.push({ email, code: "invite_failed" });
      await restoreInviteRole(store, access, email, previousRole);
      continue;
    }
    await revokeSuperseded(previous.filter((invitation) => invitationEmail(invitation) === email));
  }
  if (sent.length === 0) return { invitations: [], failed };
  const all = await listStackInvitations(access);
  const sentSet = new Set(sent);
  const mine = latestPerEmail(all.filter((invitation) => sentSet.has(invitationEmail(invitation) ?? "")));
  return { invitations: await mapInvitations(access.team.id, mine, store), failed };
}

/**
 * A failed send leaves any previous invitation valid, so it must keep the role
 * that invitation was sent with, and a first invite that failed stores none.
 */
async function restoreInviteRole(
  store: TeamInviteStore,
  access: TeamAccess,
  email: string,
  previousRole: TeamRole | undefined,
): Promise<void> {
  try {
    if (previousRole) {
      await store.upsertInviteRole({ stackTeamId: access.team.id, email, role: previousRole, invitedByUserId: access.userId });
    } else {
      await store.deleteInviteRole(access.team.id, email);
    }
  } catch {
    console.error("team invitation role restore failed", { teamId: access.team.id });
  }
}

/**
 * A re-invite leaves one pending invitation per email: the older codes are
 * revoked after the new one exists, so a failed send never strands the
 * recipient without a working invitation.
 */
async function revokeSuperseded(invitations: readonly StackSentInvitation[]): Promise<void> {
  for (const invitation of invitations) {
    await withStackDeadline(() => invitation.revoke()).catch(() => {
      console.error("superseded team invitation revoke failed", { invitationId: invitation.id });
    });
  }
}

function latestPerEmail(invitations: readonly StackSentInvitation[]): StackSentInvitation[] {
  const byEmail = new Map<string, StackSentInvitation>();
  for (const invitation of invitations) {
    const email = invitationEmail(invitation) ?? invitation.id;
    const existing = byEmail.get(email);
    if (!existing || existing.expiresAt < invitation.expiresAt) byEmail.set(email, invitation);
  }
  return [...byEmail.values()];
}

async function findInvitation(access: TeamAccess, invitationId: string): Promise<StackSentInvitation> {
  const invitations = await listStackInvitations(access);
  const invitation = invitations.find((candidate) => candidate.id === invitationId);
  if (!invitation) throw new TeamApiError("invitation_not_found", 404);
  return invitation;
}

/**
 * Stack cannot resend, so invite the same email again, then revoke the old
 * code. The stored role is kept, and a failed send leaves the old code valid.
 */
export async function resendTeamInvitation(
  access: TeamAccess,
  invitationId: string,
  callbackUrl: string,
  dependencies: InvitationDependencies = {},
): Promise<TeamInvitation> {
  const store = dependencies.store ?? databaseTeamInviteStore;
  const invitation = await findInvitation(access, invitationId);
  const email = invitationEmail(invitation);
  if (!email) throw new TeamApiError("invitation_invalid", 409, "This invitation has no email address to resend to.");
  await withStackDeadline(() => access.team.inviteUser({ email, callbackUrl }));
  await revokeSuperseded([invitation]);
  const replacement = latestPerEmail(
    (await listStackInvitations(access)).filter((candidate) => invitationEmail(candidate) === email),
  )[0];
  if (!replacement) throw new TeamApiError("invitation_not_found", 404);
  const [mapped] = await mapInvitations(access.team.id, [replacement], store);
  return mapped!;
}

/** Revoke an invitation and drop its stored role once no invitation for that email remains. */
export async function revokeTeamInvitation(
  access: TeamAccess,
  invitationId: string,
  dependencies: InvitationDependencies = {},
): Promise<void> {
  const store = dependencies.store ?? databaseTeamInviteStore;
  const invitation = await findInvitation(access, invitationId);
  await withStackDeadline(() => invitation.revoke());
  const email = invitationEmail(invitation);
  if (!email) return;
  const remaining = await listStackInvitations(access);
  if (!remaining.some((candidate) => invitationEmail(candidate) === email)) {
    await store.deleteInviteRole(access.team.id, email);
  }
}
