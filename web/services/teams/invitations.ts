import type { TeamAccess } from "./access";
import { TeamApiError } from "./errors";
import { resendTeamInviteMailer, type TeamInviteMailer } from "./inviteEmail";
import { generateInviteLinkToken, hashInviteLinkToken } from "./links";
import { databaseTeamInviteStore, type StoredEmailInvitation, type TeamInviteStore } from "./repository";
import { assertSeatsAvailable, memberLimitForTeam } from "./seats";
import type { TeamInvitation, TeamRole } from "./types";

export { MAX_INVITE_EMAILS } from "./limits";

export const EMAIL_INVITATION_EXPIRY_DAYS = 7;
const DAY_MS = 24 * 60 * 60 * 1000;

export type InvitationDependencies = {
  readonly store?: TeamInviteStore;
  readonly mailer?: TeamInviteMailer;
  readonly now?: () => Date;
};

export type InviteFailureCode = "already_member" | "invite_failed";

/** Builds the emailed accept URL for a raw token; the caller knows the request origin. */
export type InviteUrlBuilder = (token: string) => string;

export function normalizeInviteEmail(email: string): string {
  return email.trim().toLowerCase();
}

export function toInvitation(invitation: StoredEmailInvitation): TeamInvitation {
  return {
    id: invitation.id,
    email: invitation.email,
    role: invitation.role,
    expiresAt: invitation.expiresAt.toISOString(),
  };
}

/** The inviter as the team sees them, for the email's first line. */
export function inviterDisplayName(access: TeamAccess): string | null {
  const inviter = access.members.find((member) => member.id === access.userId);
  return inviter?.teamProfile?.displayName || inviter?.displayName || inviter?.primaryEmail || null;
}

/** Pending invitations of one team. */
export async function listTeamInvitations(
  access: TeamAccess,
  dependencies: InvitationDependencies = {},
): Promise<TeamInvitation[]> {
  const store = dependencies.store ?? databaseTeamInviteStore;
  return (await store.listPendingEmailInvitations(access.team.id)).map(toInvitation);
}

/**
 * Invite each email: the row is written first, then the email goes out. A
 * failed send deletes the row so nothing pending exists without an email,
 * and a re-invite revokes the older pending row only after the new email
 * went out, so a failed resend never strands the recipient.
 */
export async function inviteTeamMembers(
  access: TeamAccess,
  input: { readonly emails: readonly string[]; readonly role: TeamRole; readonly acceptUrl: InviteUrlBuilder },
  dependencies: InvitationDependencies = {},
): Promise<{ invitations: TeamInvitation[]; failed: { email: string; code: InviteFailureCode }[] }> {
  const store = dependencies.store ?? databaseTeamInviteStore;
  const mailer = dependencies.mailer ?? resendTeamInviteMailer;
  const now = dependencies.now ?? (() => new Date());
  const memberEmails = new Set(
    access.members.map((member) => member.primaryEmail ? normalizeInviteEmail(member.primaryEmail) : null)
      .filter((email): email is string => email !== null),
  );
  const emails = [...new Set(input.emails.map(normalizeInviteEmail))];
  const failed: { email: string; code: InviteFailureCode }[] = [];
  const invitations: TeamInvitation[] = [];
  const newEmails = emails.filter((email) => !memberEmails.has(email));
  const previous = newEmails.length > 0 ? await store.listPendingEmailInvitations(access.team.id) : [];
  if (newEmails.length > 0 && memberLimitForTeam(access.team) !== null) {
    const pending = new Set(previous.map((invitation) => invitation.email));
    assertSeatsAvailable({
      team: access.team,
      occupied: access.members.length + pending.size,
      adding: newEmails.filter((email) => !pending.has(email)).length,
    });
  }
  const inviterName = inviterDisplayName(access);
  for (const email of emails) {
    if (memberEmails.has(email)) {
      failed.push({ email, code: "already_member" });
      continue;
    }
    const token = generateInviteLinkToken();
    const expiresAt = new Date(now().getTime() + EMAIL_INVITATION_EXPIRY_DAYS * DAY_MS);
    const row = await store.createEmailInvitation({
      stackTeamId: access.team.id,
      email,
      role: input.role,
      invitedByUserId: access.userId,
      tokenHash: hashInviteLinkToken(token),
      expiresAt,
    });
    try {
      await mailer.send({
        to: email,
        teamName: access.team.displayName,
        inviterName,
        role: input.role,
        acceptUrl: input.acceptUrl(token),
        expiresAt,
      });
    } catch (error) {
      console.error("team invitation email failed", {
        teamId: access.team.id,
        errorType: error instanceof Error ? error.name : typeof error,
        message: error instanceof Error ? error.message.slice(0, 300) : String(error).slice(0, 300),
      });
      await store.deleteEmailInvitation(row.id).catch(() => {
        console.error("team invitation cleanup failed", { teamId: access.team.id, invitationId: row.id });
      });
      failed.push({ email, code: "invite_failed" });
      continue;
    }
    await store.revokeOtherPendingEmailInvitations(access.team.id, email, row.id);
    invitations.push(toInvitation(row));
  }
  return { invitations, failed };
}

async function findPendingInvitation(
  access: TeamAccess,
  invitationId: string,
  store: TeamInviteStore,
): Promise<StoredEmailInvitation> {
  const invitation = await store.findEmailInvitation(invitationId);
  if (!invitation || invitation.stackTeamId !== access.team.id) throw new TeamApiError("invitation_not_found", 404);
  if (invitation.acceptedAt || invitation.declinedAt || invitation.revokedAt) {
    throw new TeamApiError("invitation_not_found", 404);
  }
  return invitation;
}

/** Send the same invitation again with a fresh token and expiry. The old link stops working. */
export async function resendTeamInvitation(
  access: TeamAccess,
  invitationId: string,
  acceptUrl: InviteUrlBuilder,
  dependencies: InvitationDependencies = {},
): Promise<TeamInvitation> {
  const store = dependencies.store ?? databaseTeamInviteStore;
  const mailer = dependencies.mailer ?? resendTeamInviteMailer;
  const now = dependencies.now ?? (() => new Date());
  const invitation = await findPendingInvitation(access, invitationId, store);
  const token = generateInviteLinkToken();
  const expiresAt = new Date(now().getTime() + EMAIL_INVITATION_EXPIRY_DAYS * DAY_MS);
  await mailer.send({
    to: invitation.email,
    teamName: access.team.displayName,
    inviterName: inviterDisplayName(access),
    role: invitation.role,
    acceptUrl: acceptUrl(token),
    expiresAt,
  });
  await store.refreshEmailInvitation(invitation.id, { tokenHash: hashInviteLinkToken(token), expiresAt });
  return toInvitation({ ...invitation, expiresAt });
}

export async function revokeTeamInvitation(
  access: TeamAccess,
  invitationId: string,
  dependencies: InvitationDependencies = {},
): Promise<void> {
  const store = dependencies.store ?? databaseTeamInviteStore;
  const found = await store.revokeEmailInvitation(access.team.id, invitationId);
  if (!found) throw new TeamApiError("invitation_not_found", 404);
}
